import Foundation

enum SyncExecutionState: Hashable, Sendable {
    case localOnly
    case idle
    case syncing(Int)
    case current(Date)
    case waiting(Int)
    case conflict(Int)
    case failed(String)
}

enum SyncConflictDecision: Hashable, Sendable {
    case useLocal
    case useRemote
}

struct SyncConflictResolver: Sendable {
    func resolve(local: SyncOperationRecord, remote: SyncConflict) -> SyncConflictDecision {
        if local.updatedAt > remote.serverUpdatedAt { return .useLocal }
        if local.updatedAt < remote.serverUpdatedAt { return .useRemote }
        return local.clientRevision > remote.serverRevision ? .useLocal : .useRemote
    }

    func resolve(local: SyncOperationPayload, remote: SyncConflict) -> SyncConflictDecision {
        if local.updatedAt > remote.serverUpdatedAt { return .useLocal }
        if local.updatedAt < remote.serverUpdatedAt { return .useRemote }
        return local.clientRevision > remote.serverRevision ? .useLocal : .useRemote
    }
}

struct CloudAccountSummary: Hashable, Sendable {
    var isSignedIn: Bool
    var cloudConnected: Bool
    var displayName: String?
    var emailHint: String?
    var lastSyncAt: Date?
    var pendingOperationCount: Int
    var backendConfigured: Bool

    static func localOnly(backendConfigured: Bool) -> Self {
        .init(
            isSignedIn: false,
            cloudConnected: false,
            displayName: nil,
            emailHint: nil,
            lastSyncAt: nil,
            pendingOperationCount: 0,
            backendConfigured: backendConfigured
        )
    }
}

@MainActor
final class CloudSyncEngine {
    private let backend: any BackendServicing
    private let conflictResolver: SyncConflictResolver
    private struct Waiter {
        let continuation: CheckedContinuation<SyncExecutionState, Never>
        var cancelled = false
    }

    @MainActor private final class Flight {
        let id = UUID()
        let coordinator: DailyDataCoordinator
        let session: UUID
        var task: Task<SyncExecutionState, Never>?
        var waiters: [UUID: Waiter] = [:]

        init(coordinator: DailyDataCoordinator) {
            self.coordinator = coordinator
            session = coordinator.syncSessionIdentifier
        }
    }

    private var inFlight: Flight?

    init(backend: any BackendServicing, conflictResolver: SyncConflictResolver = .init()) {
        self.backend = backend
        self.conflictResolver = conflictResolver
    }

    func synchronize(coordinator: DailyDataCoordinator, now: Date = .now) async -> SyncExecutionState {
        // A new session cannot join the old session's result or start a second
        // transport while its canceled predecessor is still cleaning up.
        while let flight = inFlight,
              flight.coordinator !== coordinator || flight.session != coordinator.syncSessionIdentifier
                || flight.waiters.values.allSatisfy(\.cancelled) {
            flight.task?.cancel()
            _ = await flight.task?.value
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .waiting((try? coordinator.allSyncOperations().count) ?? 0))
                    return
                }
                if let flight = inFlight {
                    flight.waiters[waiterID] = Waiter(continuation: continuation)
                    return
                }
                let flight = Flight(coordinator: coordinator)
                flight.waiters[waiterID] = Waiter(continuation: continuation)
                inFlight = flight
                let flightID = flight.id
                flight.task = Task {
                    let result = await self.synchronizeBatch(coordinator: coordinator, now: now)
                    self.finishFlight(id: flightID, result: result)
                    return result
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let flight = inFlight, var waiter = flight.waiters[id] else { return }
        waiter.cancelled = true
        flight.waiters[id] = waiter
        if flight.waiters.values.contains(where: { !$0.cancelled }) {
            flight.waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: .waiting((try? flight.coordinator.allSyncOperations().count) ?? 0))
        } else {
            // The last waiter completes only after transport cancellation and
            // queue recovery. One departing waiter never cancels other callers.
            flight.task?.cancel()
        }
    }

    private func finishFlight(id: UUID, result: SyncExecutionState) {
        guard let flight = inFlight, flight.id == id else { return }
        inFlight = nil
        let pending = (try? flight.coordinator.allSyncOperations().count) ?? 0
        for waiter in flight.waiters.values {
            // A storage failure during cancellation recovery must stay visible.
            if case .failed = result {
                waiter.continuation.resume(returning: result)
            } else {
                waiter.continuation.resume(returning: waiter.cancelled ? .waiting(pending) : result)
            }
        }
    }

    private func synchronizeBatch(coordinator: DailyDataCoordinator, now: Date) async -> SyncExecutionState {
        guard backend.isConfigured else { return .localOnly }
        var operations: [SyncOperationRecord] = []
        var submitted: [SyncOperationPayload] = []
        let session = coordinator.syncSessionIdentifier
        do {
            let account = try coordinator.accountMetadata()
            guard account.syncEnabled, account.appleUserIdentifierHash != nil else { return .localOnly }
            try Task.checkCancellation()
            let ready = Array(try coordinator.readySyncOperations(at: now).prefix(SyncContractValidator.maximumOperations))
            let candidates: [SyncOperationPayload] = ready.map {
                .init(idempotencyKey: $0.idempotencyKey, entityType: $0.entityType,
                      entityIdentifier: $0.entityIdentifier, operation: $0.operation,
                      payload: $0.payloadData, clientRevision: $0.clientRevision, updatedAt: $0.updatedAt)
            }
            let request = try SyncContractValidator.makeBatchRequest(from: candidates, sinceRevision: account.serverRevision)
            submitted = request.operations
            let submittedKeys = Set(submitted.map(\.idempotencyKey))
            operations = ready.filter { submittedKeys.contains($0.idempotencyKey) }
            for operation in operations { try coordinator.markSyncUploading(operation) }
            // An empty push still performs a pull, including on first sign-in.
            let response = try await backend.synchronize(
                request, idempotencyKey: UUID().uuidString
            )
            guard session == coordinator.syncSessionIdentifier else {
                try coordinator.resetSyncUploads(idempotencyKeys: Set(submitted.map(\.idempotencyKey)))
                return .localOnly
            }
            try Task.checkCancellation()
            // Validate the entire batch before acknowledging or applying any part.
            // Invalid trailing changes must not consume earlier queue entries/cursors.
            try SyncContractValidator.validateResponse(response, for: request)
            for change in response.conflicts + (response.remoteChanges ?? []) {
                try RemoteSyncPayloadValidator.validate(change)
            }

            var conflictCount = 0
            var acknowledgedKeys = Set(response.acceptedIdempotencyKeys)
            for conflict in response.conflicts {
                let identity = SyncEntityIdentity(entityType: conflict.entityType, entityIdentifier: conflict.entityIdentifier)
                guard let local = submitted.first(where: {
                    SyncEntityIdentity(entityType: $0.entityType, entityIdentifier: $0.entityIdentifier) == identity
                }), let record = operations.first(where: { $0.idempotencyKey == local.idempotencyKey }) else {
                    throw BackendError.invalidResponse
                }
                let successors = try coordinator.allSyncOperations().filter {
                    $0.id != record.id && $0.state != .completed
                        && SyncEntityIdentity(entityType: $0.entityType, entityIdentifier: $0.entityIdentifier) == identity
                }
                if !successors.isEmpty {
                    // A response about an older upload cannot replace an edit made
                    // while that upload was suspended. Rebase the successor instead.
                    for successor in successors {
                        try coordinator.retrySyncOperation(successor, serverRevision: conflict.serverRevision)
                    }
                    acknowledgedKeys.insert(local.idempotencyKey)
                    conflictCount += 1
                } else {
                    switch conflictResolver.resolve(local: local, remote: conflict) {
                    case .useLocal:
                        conflictCount += 1
                        try coordinator.retrySyncOperation(record, serverRevision: conflict.serverRevision)
                    case .useRemote:
                        try coordinator.applyRemoteChange(conflict)
                        acknowledgedKeys.insert(local.idempotencyKey)
                    }
                }
            }

            for change in response.remoteChanges ?? [] {
                let identity = SyncEntityIdentity(entityType: change.entityType, entityIdentifier: change.entityIdentifier)
                let pending = try coordinator.allSyncOperations().filter {
                    !acknowledgedKeys.contains($0.idempotencyKey) && $0.state != .completed
                        && SyncEntityIdentity(entityType: $0.entityType, entityIdentifier: $0.entityIdentifier) == identity
                }
                if pending.isEmpty {
                    try coordinator.applyRemoteChange(change)
                } else {
                    // Preserve unsent/backoff edits; their eventual push will resolve
                    // against the server. Never hide them with a pulled snapshot.
                    conflictCount += 1
                }
            }
            for operation in operations where acknowledgedKeys.contains(operation.idempotencyKey) {
                try coordinator.acceptSyncOperation(operation)
            }
            try coordinator.updateServerRevision(response.serverRevision)
            let remaining = try coordinator.allSyncOperations().count
            if conflictCount > 0 { return .conflict(conflictCount) }
            return remaining > 0 ? .waiting(remaining) : .current(now)
        } catch {
            if session != coordinator.syncSessionIdentifier || error is CancellationError {
                do {
                    try coordinator.resetSyncUploads(idempotencyKeys: Set(submitted.map(\.idempotencyKey)))
                } catch {
                    return .failed(error.localizedDescription)
                }
                return session != coordinator.syncSessionIdentifier
                    ? .localOnly : .waiting((try? coordinator.allSyncOperations().count) ?? 0)
            }
            // Never reinsert a deleted/accepted predecessor or change a successor's
            // retry state when an older request fails.
            let live = (try? coordinator.allSyncOperations()) ?? []
            let submittedKeys = Set(submitted.map(\.idempotencyKey))
            for operation in live where operation.state == .uploading && submittedKeys.contains(operation.idempotencyKey) {
                try? coordinator.markSyncFailed(operation, error: error, now: now)
            }
            let pending = (try? coordinator.allSyncOperations().count) ?? operations.count
            return error is CancellationError ? .waiting(pending) : .failed(error.localizedDescription)
        }
    }
}
