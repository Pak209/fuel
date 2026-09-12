import Foundation
import SwiftData
import Testing
@testable import Fuel

/// Exercises sync at its suspension boundary: server replies arrive after local
/// edits, another caller, or a previously persisted pull cursor. Every backend
/// interaction is in memory and explicitly released by the test.
@MainActor
struct SyncContinuityTests {
    @Test func emptyUploadQueueStillPullsUsingThePersistedCursor() async throws {
        let fixture = try SyncContinuityFixture()
        try fixture.coordinator.updateServerRevision(12)
        let remoteMeal = fixture.makeMeal(name: "Dinner from another device")
        remoteMeal.createdAt = Date(timeIntervalSince1970: 1_650_000_000)
        remoteMeal.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        remoteMeal.timeZoneIdentifier = "Pacific/Auckland"
        let response = SyncBatchResponse(
            acceptedIdempotencyKeys: [],
            conflicts: [],
            serverRevision: 13,
            remoteChanges: [try fixture.change(for: remoteMeal, revision: 13)]
        )
        let backend = ContinuityBackend(response: response)
        let engine = CloudSyncEngine(backend: backend)

        let state = await engine.synchronize(coordinator: fixture.coordinator)

        let requests = await backend.requests
        #expect(requests.count == 1)
        #expect(requests.first?.operations.isEmpty == true)
        #expect(requests.first?.sinceRevision == 12)
        let restoredMeal = try #require(try fixture.repositories.meals.meal(id: remoteMeal.id))
        #expect(restoredMeal.name == remoteMeal.name)
        #expect(restoredMeal.createdAt == remoteMeal.createdAt)
        #expect(restoredMeal.updatedAt == remoteMeal.updatedAt)
        #expect(restoredMeal.timeZoneIdentifier == "Pacific/Auckland")
        #expect(try fixture.coordinator.accountMetadata().serverRevision == 13)
        guard case .current = state else {
            Issue.record("Expected a successful pull with no local uploads, got \(state)")
            return
        }
    }

    @Test func overlappingSyncCallsJoinTheSameInFlightBackendRequest() async throws {
        let fixture = try SyncContinuityFixture()
        _ = try await fixture.coordinator.saveMeal(fixture.draft(name: "Lunch"))
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let firstNow = Date(timeIntervalSince1970: 1_900_000_000)
        let first = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator, now: firstNow)
        }
        let request = await backend.firstRequest()
        let response = fixture.accepting(request, revision: 1)

        // This task cannot begin on MainActor until the direct synchronize call
        // below suspends. The second caller therefore enters while the first
        // backend request is still held, without sleeps or scheduler polling.
        let release = Task { @MainActor in
            await backend.releaseFirst(with: response)
        }
        let secondState = await engine.synchronize(
            coordinator: fixture.coordinator,
            now: firstNow.addingTimeInterval(60)
        )
        let firstState = await first.value
        await release.value

        #expect(await backend.requests.count == 1)
        #expect(firstState == .current(firstNow))
        #expect(secondState == firstState)
        #expect(try fixture.coordinator.allSyncOperations().isEmpty)
    }

    @Test func acceptedPredecessorDoesNotAcknowledgeAnEditMadeDuringUpload() async throws {
        let fixture = try SyncContinuityFixture()
        let meal = try await fixture.coordinator.saveMeal(fixture.draft(name: "Original lunch"))
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let upload = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        let request = await backend.firstRequest()
        let predecessor = try #require(request.operations.first)

        try await fixture.coordinator.updateMeal(meal, with: fixture.draft(name: "Corrected lunch"))
        var response = fixture.accepting(request, revision: 1)
        response.remoteChanges = [.init(
            entityType: predecessor.entityType,
            entityIdentifier: predecessor.entityIdentifier,
            operation: predecessor.operation,
            serverRevision: 1,
            serverUpdatedAt: predecessor.updatedAt,
            serverPayload: predecessor.payload
        )]
        await backend.releaseFirst(with: response)
        _ = await upload.value

        let remaining = try fixture.coordinator.allSyncOperations()
        let successor = try #require(remaining.first)
        #expect(remaining.count == 1)
        #expect(successor.idempotencyKey != predecessor.idempotencyKey)
        #expect(successor.state == .pending)
        #expect(successor.attempts == 0)
        #expect(try JSONDecoder().decode(ExportedMeal.self, from: successor.payloadData).name == "Corrected lunch")
        #expect(try fixture.repositories.meals.meal(id: meal.id)?.name == "Corrected lunch")
        #expect(try JSONDecoder().decode(ExportedMeal.self, from: predecessor.payload).name == "Original lunch")
    }

    @Test func remoteWinningPredecessorConflictDoesNotOverwriteANewerQueuedEdit() async throws {
        let fixture = try SyncContinuityFixture()
        let meal = try await fixture.coordinator.saveMeal(fixture.draft(name: "Original lunch"))
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let upload = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        let request = await backend.firstRequest()
        let predecessor = try #require(request.operations.first)
        var remoteMeal = try JSONDecoder().decode(ExportedMeal.self, from: predecessor.payload)
        remoteMeal.name = "Server version of original lunch"
        let conflict = SyncConflict(
            entityType: predecessor.entityType,
            entityIdentifier: predecessor.entityIdentifier,
            operation: predecessor.operation,
            serverRevision: 7,
            serverUpdatedAt: predecessor.updatedAt.addingTimeInterval(3_600),
            serverPayload: try JSONEncoder().encode(remoteMeal)
        )

        try await fixture.coordinator.updateMeal(meal, with: fixture.draft(name: "Most recent lunch edit"))
        await backend.releaseFirst(with: .init(
            acceptedIdempotencyKeys: [],
            conflicts: [conflict],
            serverRevision: 7,
            remoteChanges: []
        ))
        _ = await upload.value

        let remaining = try fixture.coordinator.allSyncOperations()
        let successor = try #require(remaining.first)
        #expect(remaining.count == 1)
        #expect(successor.idempotencyKey != predecessor.idempotencyKey)
        #expect(successor.state == .pending)
        #expect(try JSONDecoder().decode(ExportedMeal.self, from: successor.payloadData).name == "Most recent lunch edit")
        #expect(try fixture.repositories.meals.meal(id: meal.id)?.name == "Most recent lunch edit")
        #expect(try fixture.coordinator.accountMetadata().serverRevision == 7)
    }

    @Test(arguments: ContinuitySessionChange.allCases)
    func sessionChangeDuringUploadPreservesAnImmediatelyRecoverableOperation(_ sessionChange: ContinuitySessionChange) async throws {
        let fixture = try SyncContinuityFixture()
        let meal = try await fixture.coordinator.saveMeal(fixture.draft(name: "Meal awaiting upload"))
        let queued = try #require(try fixture.coordinator.allSyncOperations().first)
        for _ in 0..<2 {
            try fixture.coordinator.markSyncFailed(queued, error: BackendError.transport("Previous outage"), now: .distantPast)
        }
        let originalKey = queued.idempotencyKey
        let originalPayload = queued.payloadData
        let originalMutationDate = queued.updatedAt
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let upload = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        let request = await backend.firstRequest()

        switch sessionChange {
        case .disableSync:
            try fixture.coordinator.setSyncEnabled(false)
        case .refreshSameAccount:
            try fixture.coordinator.applyAccountSession(fixture.accountSession)
        case .signOutAndReconnectSameAccount:
            try fixture.coordinator.signOutAccount()
            try fixture.coordinator.applyAccountSession(fixture.accountSession)
        }
        await backend.releaseFirst(with: fixture.accepting(request, revision: 1))
        _ = await upload.value

        let remaining = try fixture.coordinator.allSyncOperations()
        let recovered = try #require(remaining.first)
        #expect(remaining.count == 1)
        #expect(recovered.idempotencyKey == originalKey)
        #expect(recovered.payloadData == originalPayload)
        #expect(recovered.updatedAt == originalMutationDate)
        #expect(recovered.attempts == 2)
        #expect(recovered.state == .pending)
        #expect(recovered.nextAttemptAt == nil)
        #expect(try fixture.coordinator.accountMetadata().serverRevision == 0)
        #expect(try fixture.repositories.meals.meal(id: meal.id)?.name == "Meal awaiting upload")

        try fixture.coordinator.setSyncEnabled(true)
        #expect(try fixture.coordinator.readySyncOperations().map(\.idempotencyKey) == [originalKey])
        _ = await engine.synchronize(coordinator: fixture.coordinator)
        let requests = await backend.requests
        #expect(requests.count == 2)
        #expect(requests.last?.operations.first?.idempotencyKey == originalKey)
        #expect(try fixture.coordinator.allSyncOperations().isEmpty)
    }

    @Test func exhaustedCreatePredecessorYieldsToTheNewerEditWithoutLosingCreateIntent() async throws {
        let fixture = try SyncContinuityFixture()
        let meal = try await fixture.coordinator.saveMeal(fixture.draft(name: "Original unsynced meal"))
        let predecessor = try #require(try fixture.coordinator.allSyncOperations().first)
        for _ in 0..<(DailyDataCoordinator.maxRetryAttempts - 1) {
            try fixture.coordinator.markSyncFailed(predecessor, error: BackendError.transport("Previous outage"), now: .distantPast)
        }
        let predecessorKey = predecessor.idempotencyKey
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let upload = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        _ = await backend.firstRequest()

        try await fixture.coordinator.updateMeal(meal, with: fixture.draft(name: "Latest corrected meal"))
        await backend.failFirst(with: .transport("Final predecessor attempt failed"))
        _ = await upload.value

        let ready = try fixture.coordinator.readySyncOperations()
        let successor = try #require(ready.first)
        #expect(ready.count == 1)
        #expect(successor.idempotencyKey != predecessorKey)
        #expect(successor.operation == .create)
        #expect(successor.attempts == 0)
        #expect(successor.state == .pending)
        #expect(try JSONDecoder().decode(ExportedMeal.self, from: successor.payloadData).name == "Latest corrected meal")

        _ = await engine.synchronize(coordinator: fixture.coordinator)
        let requests = await backend.requests
        #expect(requests.count == 2)
        let retried = try #require(requests.last?.operations.first)
        #expect(retried.operation == .create)
        #expect(retried.idempotencyKey != predecessorKey)
        #expect(try JSONDecoder().decode(ExportedMeal.self, from: retried.payload).name == "Latest corrected meal")
        #expect(try fixture.repositories.meals.meal(id: meal.id)?.name == "Latest corrected meal")
    }

    @Test func successorQueueOrderSurvivesTheClockMovingBehindItsUploadingPredecessor() async throws {
        let fixture = try SyncContinuityFixture()
        let meal = try await fixture.coordinator.saveMeal(fixture.draft(name: "Before clock correction"))
        let predecessor = try #require(try fixture.coordinator.allSyncOperations().first)
        // The next real mutation happens before this persisted timestamp, just
        // as it would after correcting a device clock that had been far ahead.
        predecessor.createdAt = Date(timeIntervalSinceReferenceDate: 4_000_000_000)
        try fixture.repositories.syncQueue.save(predecessor)
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let upload = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        let request = await backend.firstRequest()

        try await fixture.coordinator.updateMeal(meal, with: fixture.draft(name: "After clock correction"))
        let queued = try fixture.coordinator.allSyncOperations()
        let successor = try #require(queued.first { $0.id != predecessor.id })
        #expect(queued.count == 2)
        #expect(queued.map(\.id) == [predecessor.id, successor.id])
        #expect(successor.createdAt > predecessor.createdAt)
        #expect(successor.updatedAt == meal.updatedAt)
        #expect(successor.updatedAt < predecessor.createdAt)

        await backend.releaseFirst(with: fixture.accepting(request, revision: 1))
        _ = await upload.value
        #expect(try fixture.coordinator.readySyncOperations().map(\.id) == [successor.id])
    }

    @Test func clockRollbackCannotLetASuccessorBypassItsFailedPredecessorsBackoff() async throws {
        let fixture = try SyncContinuityFixture()
        let meal = try await fixture.coordinator.saveMeal(fixture.draft(name: "Original upload"))
        let predecessor = try #require(try fixture.coordinator.allSyncOperations().first)
        let predecessorKey = predecessor.idempotencyKey
        predecessor.createdAt = Date(timeIntervalSinceReferenceDate: 4_000_000_000)
        try fixture.repositories.syncQueue.save(predecessor)
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let attemptDate = Date(timeIntervalSince1970: 1_900_000_000)
        let upload = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator, now: attemptDate)
        }
        _ = await backend.firstRequest()

        try await fixture.coordinator.updateMeal(meal, with: fixture.draft(name: "Edit waiting its turn"))
        let successor = try #require(try fixture.coordinator.allSyncOperations().first { $0.id != predecessor.id })
        await backend.failFirst(with: .transport("Retryable outage after clock correction"))
        _ = await upload.value

        let nextAttempt = try #require(predecessor.nextAttemptAt)
        #expect(successor.createdAt > predecessor.createdAt)
        #expect(try fixture.coordinator.readySyncOperations(at: nextAttempt.addingTimeInterval(-1)).isEmpty)
        #expect(try fixture.coordinator.readySyncOperations(at: nextAttempt).map(\.id) == [predecessor.id])

        _ = await engine.synchronize(coordinator: fixture.coordinator, now: nextAttempt)
        let requests = await backend.requests
        #expect(requests.count == 2)
        #expect(requests.last?.operations.map(\.idempotencyKey) == [predecessorKey])
        #expect(try fixture.coordinator.readySyncOperations(at: nextAttempt).map(\.id) == [successor.id])
        #expect(try fixture.repositories.meals.meal(id: meal.id)?.name == "Edit waiting its turn")
    }

    @Test func cancelingTheOnlySyncWaiterCancelsTransportWithoutSpendingRetryBudget() async throws {
        let fixture = try SyncContinuityFixture()
        _ = try await fixture.coordinator.saveMeal(fixture.draft(name: "Canceled upload"))
        let operation = try #require(try fixture.coordinator.allSyncOperations().first)
        for _ in 0..<2 {
            try fixture.coordinator.markSyncFailed(operation, error: BackendError.transport("Previous outage"), now: .distantPast)
        }
        let originalKey = operation.idempotencyKey
        let originalPayload = operation.payloadData
        let originalMutationDate = operation.updatedAt
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let upload = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        _ = await backend.firstRequest()

        upload.cancel()
        _ = await upload.value
        await backend.firstCancellation()

        let remaining = try fixture.coordinator.allSyncOperations()
        let recovered = try #require(remaining.first)
        #expect(remaining.count == 1)
        #expect(await backend.cancellationCount == 1)
        #expect(recovered.idempotencyKey == originalKey)
        #expect(recovered.payloadData == originalPayload)
        #expect(recovered.updatedAt == originalMutationDate)
        #expect(recovered.attempts == 2)
        #expect(recovered.state == .pending)
        #expect(recovered.nextAttemptAt == nil)
        #expect(try fixture.coordinator.accountMetadata().serverRevision == 0)

        _ = await engine.synchronize(coordinator: fixture.coordinator)
        #expect(await backend.requests.count == 2)
        #expect(try fixture.coordinator.allSyncOperations().isEmpty)
    }

    @Test func cancelingOneOfTwoWaitersLeavesTheOtherWaitersUploadAlive() async throws {
        let fixture = try SyncContinuityFixture()
        _ = try await fixture.coordinator.saveMeal(fixture.draft(name: "Shared upload"))
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let firstNow = Date(timeIntervalSince1970: 1_900_000_000)
        let first = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator, now: firstNow)
        }
        let request = await backend.firstRequest()
        let response = fixture.accepting(request, revision: 1)
        let cancellation = Task { @MainActor in
            // The direct second synchronize below enters before this task runs.
            first.cancel()
            _ = await first.value
            #expect(await backend.cancellationCount == 0)
            #expect(await backend.hasHeldFirstRequest)
            await backend.releaseFirst(with: response)
        }

        let survivingState = await engine.synchronize(coordinator: fixture.coordinator)
        await cancellation.value

        #expect(survivingState == .current(firstNow))
        #expect(await backend.requests.count == 1)
        #expect(await backend.cancellationCount == 0)
        #expect(try fixture.coordinator.allSyncOperations().isEmpty)
    }

    @Test func cancelingEveryOverlappingWaiterCancelsTheirOneSharedTransport() async throws {
        let fixture = try SyncContinuityFixture()
        _ = try await fixture.coordinator.saveMeal(fixture.draft(name: "Shared canceled upload"))
        let originalKey = try #require(try fixture.coordinator.allSyncOperations().first?.idempotencyKey)
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let first = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        _ = await backend.firstRequest()
        let secondHandle = ContinuitySyncTaskHandle()
        secondHandle.task = Task { @MainActor in
            let cancelBoth = Task { @MainActor in
                // This runs only once the second direct call has suspended.
                first.cancel()
                secondHandle.task?.cancel()
            }
            let state = await engine.synchronize(coordinator: fixture.coordinator)
            await cancelBoth.value
            return state
        }

        _ = await secondHandle.task?.value
        _ = await first.value
        await backend.firstCancellation()

        let remaining = try fixture.coordinator.allSyncOperations()
        let recovered = try #require(remaining.first)
        #expect(await backend.requests.count == 1)
        #expect(await backend.cancellationCount == 1)
        #expect(remaining.count == 1)
        #expect(recovered.idempotencyKey == originalKey)
        #expect(recovered.state == .pending)
        #expect(recovered.attempts == 0)
        #expect(recovered.nextAttemptAt == nil)
        #expect(try fixture.coordinator.readySyncOperations().map(\.idempotencyKey) == [originalKey])
    }

    @Test(arguments: InvalidContinuityBatch.allCases)
    func invalidBatchCannotPartiallyAcknowledgeOrApplyChanges(_ invalidity: InvalidContinuityBatch) async throws {
        let fixture = try SyncContinuityFixture()
        let firstMeal = try await fixture.coordinator.saveMeal(fixture.draft(name: "First local meal"))
        let secondMeal = try await fixture.coordinator.saveMeal(fixture.draft(name: "Second local meal"))
        try fixture.coordinator.updateServerRevision(10)
        let originalQueue = try fixture.coordinator.allSyncOperations()
        let originalKeys = Set(originalQueue.map(\.idempotencyKey))
        let originalPayloads = Dictionary(uniqueKeysWithValues: originalQueue.map { ($0.idempotencyKey, $0.payloadData) })
        let originalSyncDate = try fixture.coordinator.accountMetadata().lastSyncAt
        let backend = ContinuityBackend(holdingFirstRequest: true)
        let engine = CloudSyncEngine(backend: backend)
        let sync = Task { @MainActor in
            await engine.synchronize(coordinator: fixture.coordinator)
        }
        let request = await backend.firstRequest()
        let operations = request.operations
        let firstOperation = try #require(operations.first)
        let secondOperation = try #require(operations.last)
        #expect(operations.count == 2)
        var response = fixture.accepting(request, revision: 12)

        switch invalidity {
        case .missingAcknowledgment:
            response.acceptedIdempotencyKeys = [firstOperation.idempotencyKey]
        case .unknownAcknowledgment:
            response.acceptedIdempotencyKeys.append("not-in-the-request")
        case .duplicateAcknowledgment:
            response.acceptedIdempotencyKeys.append(firstOperation.idempotencyKey)
        case .malformedLaterRemotePayload:
            var validChange = try fixture.change(for: firstMeal, revision: 11)
            var exported = ExportedMeal(meal: firstMeal)
            exported.name = "Must never be partially applied"
            validChange.serverPayload = try JSONEncoder().encode(exported)
            var invalidChange = try fixture.change(for: secondMeal, revision: 12)
            invalidChange.serverPayload = Data("not-json".utf8)
            response.remoteChanges = [validChange, invalidChange]
        case .malformedConflictPayload:
            response.acceptedIdempotencyKeys = [firstOperation.idempotencyKey]
            response.conflicts = [.init(
                entityType: secondOperation.entityType,
                entityIdentifier: secondOperation.entityIdentifier,
                operation: secondOperation.operation,
                serverRevision: 12,
                serverUpdatedAt: secondOperation.updatedAt.addingTimeInterval(60),
                serverPayload: Data("not-json".utf8)
            )]
        }

        await backend.releaseFirst(with: response)
        let state = await sync.value

        guard case .failed = state else {
            Issue.record("Expected invalid batch rejection for \(invalidity), got \(state)")
            return
        }
        let remaining = try fixture.coordinator.allSyncOperations()
        #expect(Set(remaining.map(\.idempotencyKey)) == originalKeys)
        #expect(Dictionary(uniqueKeysWithValues: remaining.map { ($0.idempotencyKey, $0.payloadData) }) == originalPayloads)
        #expect(remaining.allSatisfy { $0.state != .uploading })
        #expect(try fixture.repositories.meals.meal(id: firstMeal.id)?.name == "First local meal")
        #expect(try fixture.repositories.meals.meal(id: secondMeal.id)?.name == "Second local meal")
        #expect(try fixture.coordinator.accountMetadata().serverRevision == 10)
        #expect(try fixture.coordinator.accountMetadata().lastSyncAt == originalSyncDate)
    }

    @Test(arguments: [29, 30])
    func changesAtOrBelowThePersistedCursorCannotOverwriteLocalData(staleRevision: Int) async throws {
        let fixture = try SyncContinuityFixture()
        let meal = fixture.makeMeal(name: "Current meal")
        try fixture.repositories.meals.save(meal)
        try fixture.coordinator.updateServerRevision(30)
        var staleChange = try fixture.change(for: meal, revision: staleRevision)
        var staleExport = ExportedMeal(meal: meal)
        staleExport.name = "Obsolete server meal"
        staleChange.serverPayload = try JSONEncoder().encode(staleExport)
        let backend = ContinuityBackend(response: .init(
            acceptedIdempotencyKeys: [],
            conflicts: [],
            serverRevision: 31,
            remoteChanges: [staleChange]
        ))
        let engine = CloudSyncEngine(backend: backend)

        _ = await engine.synchronize(coordinator: fixture.coordinator)

        #expect(await backend.requests.count == 1)
        #expect(try fixture.repositories.meals.meal(id: meal.id)?.name == "Current meal")
        #expect(try fixture.coordinator.accountMetadata().serverRevision >= 30)
        #expect(try fixture.coordinator.allSyncOperations().isEmpty)
    }
}

enum InvalidContinuityBatch: CaseIterable, Sendable {
    case missingAcknowledgment
    case unknownAcknowledgment
    case duplicateAcknowledgment
    case malformedLaterRemotePayload
    case malformedConflictPayload
}

enum ContinuitySessionChange: CaseIterable, Sendable {
    case disableSync
    case refreshSameAccount
    case signOutAndReconnectSameAccount
}

@MainActor
private final class ContinuitySyncTaskHandle {
    var task: Task<SyncExecutionState, Never>?
}

@MainActor
private struct SyncContinuityFixture {
    let container: ModelContainer
    let repositories: LocalRepositoryContainer
    let coordinator: DailyDataCoordinator
    let mealDate = Date(timeIntervalSince1970: 1_700_000_000)

    var accountSession: AccountSessionResult {
        .init(userIdentifierHash: "sync-continuity-account", displayName: nil, emailHint: nil, cloudConnected: true)
    }

    init() throws {
        let schema = Schema(versionedSchema: FuelSchemaV3.self)
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        repositories = LocalRepositoryContainer(context: container.mainContext)
        coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(
            userIdentifierHash: "sync-continuity-account",
            displayName: nil,
            emailHint: nil,
            cloudConnected: true
        ))
    }

    func draft(name: String) -> MealDraft {
        .init(
            name: name,
            type: .lunch,
            date: mealDate,
            nutrition: .init(calories: 400, protein: 25, carbohydrates: 40, fat: 12, fiber: 5),
            items: [],
            provenance: .userEntered,
            confidence: nil,
            imageData: nil
        )
    }

    func makeMeal(name: String) -> Meal {
        let draft = draft(name: name)
        return Meal(name: name, type: draft.type, date: draft.date, nutrition: draft.nutrition)
    }

    func change(for meal: Meal, revision: Int) throws -> SyncConflict {
        .init(
            entityType: "meal",
            entityIdentifier: meal.id.uuidString,
            operation: .update,
            serverRevision: revision,
            serverUpdatedAt: meal.updatedAt,
            serverPayload: try JSONEncoder().encode(ExportedMeal(meal: meal))
        )
    }

    func accepting(_ request: SyncBatchRequest, revision: Int) -> SyncBatchResponse {
        .init(
            acceptedIdempotencyKeys: request.operations.map(\.idempotencyKey),
            conflicts: [],
            serverRevision: revision,
            remoteChanges: []
        )
    }
}

private actor ContinuityBackend: BackendServicing {
    nonisolated let isConfigured = true
    private(set) var requests: [SyncBatchRequest] = []
    private let holdingFirstRequest: Bool
    private let response: SyncBatchResponse?
    private var firstRequestWaiters: [CheckedContinuation<SyncBatchRequest, Never>] = []
    private var firstReply: CheckedContinuation<SyncBatchResponse, Error>?
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellationCount = 0

    var hasHeldFirstRequest: Bool { firstReply != nil }

    init(holdingFirstRequest: Bool = false, response: SyncBatchResponse? = nil) {
        self.holdingFirstRequest = holdingFirstRequest
        self.response = response
    }

    func synchronize(_ request: SyncBatchRequest, idempotencyKey: String) async throws -> SyncBatchResponse {
        requests.append(request)
        if holdingFirstRequest && requests.count == 1 {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    firstReply = continuation
                    for waiter in firstRequestWaiters { waiter.resume(returning: request) }
                    firstRequestWaiters.removeAll()
                }
            } onCancel: {
                Task { await self.cancelFirst() }
            }
        }
        return response ?? .init(
            acceptedIdempotencyKeys: request.operations.map(\.idempotencyKey),
            conflicts: [],
            serverRevision: 100,
            remoteChanges: []
        )
    }

    func firstRequest() async -> SyncBatchRequest {
        if let first = requests.first { return first }
        return await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func releaseFirst(with response: SyncBatchResponse) {
        guard let firstReply else {
            Issue.record("The test attempted to release a backend call that was not held")
            return
        }
        self.firstReply = nil
        firstReply.resume(returning: response)
    }

    func failFirst(with error: BackendError) {
        guard let firstReply else {
            Issue.record("The test attempted to fail a backend call that was not held")
            return
        }
        self.firstReply = nil
        firstReply.resume(throwing: error)
    }

    func firstCancellation() async {
        if cancellationCount > 0 { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func cancelFirst() {
        guard let firstReply else { return }
        self.firstReply = nil
        cancellationCount += 1
        firstReply.resume(throwing: CancellationError())
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
    }

    func authenticate(_ request: AppleAuthenticationRequest, idempotencyKey: String) async throws -> AuthenticationSessionResponse { throw BackendError.notConfigured }
    func fetchProfile() async throws -> ProfileResponse { throw BackendError.notConfigured }
    func updateProfile(_ request: ProfileUpdateRequest) async throws -> ProfileResponse { throw BackendError.notConfigured }
    func uploadRecognition(_ request: PhotoAnalysisUploadRequest, idempotencyKey: String) async throws -> RecognitionJobResponse { throw BackendError.notConfigured }
    func recognitionStatus(jobIdentifier: String) async throws -> RecognitionJobResponse { throw BackendError.notConfigured }
    func searchNutrition(_ request: NutritionSearchRequest) async throws -> NutritionSearchResponse { throw BackendError.notConfigured }
    func recommendation(_ request: RemoteRecommendationRequest) async throws -> RemoteRecommendationResponse { throw BackendError.notConfigured }
    func requestAccountExport() async throws -> AccountExportResponse { throw BackendError.notConfigured }
    func deleteAccount() async throws { throw BackendError.notConfigured }
    func remoteConfiguration() async throws -> RemoteFeatureConfiguration { throw BackendError.notConfigured }
}
