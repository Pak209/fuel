import Foundation
import Security
import SwiftData
import Testing
@testable import Fuel

/// Phase 7/8 security + sync regression coverage: backend transport hardening
/// (URL/payload validation, idempotency, bounded retry), the Keychain boundary,
/// conflict resolution, the local sync queue, an end-to-end `CloudSyncEngine`
/// pass with a mocked backend, the V1→V3 on-disk migration, and the remote
/// feature-configuration validator. No test in this file performs real network
/// I/O — `BackendTransport` and `BackendServicing` are replaced with recording
/// mocks defined at the bottom of this file.
struct SyncSecurityTests {

    // MARK: - 1. URL validation

    @Test func httpsBaseURLIsAccepted() {
        let config = BackendConfiguration(environment: .production, baseURL: URL(string: "https://api.fuel.app/v1"))
        #expect(config.validatedBaseURL != nil)
        #expect(config.isConfigured)
    }

    @Test func plainHTTPIsRejectedForNonLocalhostRegardlessOfEnvironment() {
        let production = BackendConfiguration(environment: .production, baseURL: URL(string: "http://api.fuel.app"))
        let development = BackendConfiguration(environment: .development, baseURL: URL(string: "http://example.com"))
        #expect(production.validatedBaseURL == nil)
        #expect(development.validatedBaseURL == nil)
    }

    @Test func debugCarveOutAllowsPlainHTTPOnlyForLocalhostAddresses() {
        let localhost = BackendConfiguration(environment: .development, baseURL: URL(string: "http://localhost:8080"))
        let loopback = BackendConfiguration(environment: .development, baseURL: URL(string: "http://127.0.0.1:8080"))
        #if DEBUG
        #expect(localhost.validatedBaseURL != nil)
        #expect(loopback.validatedBaseURL != nil)
        #else
        #expect(localhost.validatedBaseURL == nil)
        #expect(loopback.validatedBaseURL == nil)
        #endif
    }

    @Test func malformedOrDangerousSchemesAreRejected() {
        var noHostComponents = URLComponents()
        noHostComponents.scheme = "https"
        noHostComponents.path = "/v1"
        let missingHost = BackendConfiguration(environment: .production, baseURL: noHostComponents.url)
        let fileURL = BackendConfiguration(environment: .production, baseURL: URL(string: "file:///etc/passwd"))
        let javascriptURL = BackendConfiguration(environment: .production, baseURL: URL(string: "javascript:alert(1)"))

        #expect(missingHost.validatedBaseURL == nil)
        #expect(fileURL.validatedBaseURL == nil)
        #expect(javascriptURL.validatedBaseURL == nil)
    }

    @Test func insecureConfigurationLeavesTheClientUnconfiguredSoNoRequestIsEverSent() async throws {
        let transport = RecordingBackendTransport(steps: [])
        let client = BackendAPIClient(
            configuration: .init(environment: .development, baseURL: URL(string: "http://example.com")),
            transport: transport,
            credentials: KeychainCredentialStore(service: "com.pak.fuel.tests.\(UUID().uuidString)")
        )
        #expect(!client.isConfigured)
        do {
            _ = try await client.authenticate(.init(identityToken: "t", authorizationCode: "c", nonce: "n"), idempotencyKey: "k")
            Issue.record("Expected notConfigured to be thrown for an insecure, non-localhost base URL")
        } catch BackendError.notConfigured {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let count = await transport.invocationCount
        #expect(count == 0)
    }

    // MARK: - 2. Payload caps

    @Test func requestBodyOverTheEndpointCapThrowsWithoutHittingTransport() async throws {
        let transport = RecordingBackendTransport(steps: [])
        let client = makeClient(transport: transport)
        let hugeToken = String(repeating: "a", count: 1_100_000)
        do {
            _ = try await client.authenticate(.init(identityToken: hugeToken, authorizationCode: "c", nonce: "n"), idempotencyKey: "k")
            Issue.record("Expected payloadTooLarge to be thrown")
        } catch BackendError.payloadTooLarge {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let count = await transport.invocationCount
        #expect(count == 0)
    }

    @Test func oversizedResponseIsRejectedAfterExhaustingRetries() async throws {
        let oversized = Data(count: 5_000_001)
        let transport = RecordingBackendTransport(steps: Array(repeating: .success(status: 200, body: oversized), count: 3))
        let client = makeClient(transport: transport)
        do {
            _ = try await client.authenticate(.init(identityToken: "t", authorizationCode: "c", nonce: "n"), idempotencyKey: "k")
            Issue.record("Expected invalidResponse to be thrown for an oversized payload")
        } catch BackendError.invalidResponse {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let count = await transport.invocationCount
        #expect(count == 3)
    }

    // MARK: - 3. Idempotency

    @Test func mutatingRequestCarriesAStableIdempotencyKeyHeaderAcrossRetries() async throws {
        let transport = RecordingBackendTransport(steps: [
            .success(status: 500, body: Data()),
            .success(status: 500, body: Data()),
            .success(status: 200, body: try encodeISO8601(AuthenticationSessionResponse(accessToken: "a", refreshToken: "b", expiresAt: .now.addingTimeInterval(3_600), accountIdentifier: "id")))
        ])
        let client = makeClient(transport: transport)
        _ = try await client.authenticate(.init(identityToken: "t", authorizationCode: "c", nonce: "n"), idempotencyKey: "stable-key-456")
        let recorded = await transport.recordedRequests
        #expect(recorded.count == 3)
        let keys = Set(recorded.map { $0.value(forHTTPHeaderField: "Idempotency-Key") })
        #expect(keys == ["stable-key-456"])
    }

    @Test @MainActor func syncOperationIdempotencyKeyStaysStableAcrossAFailedSyncAttempt() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(userIdentifierHash: "hash", displayName: nil, emailHint: nil, cloudConnected: true))
        _ = try await coordinator.saveMeal(.init(name: "Bowl", type: .lunch, date: .now, nutrition: .init(calories: 300, protein: 20, carbohydrates: 30, fat: 10, fiber: 4), items: [], provenance: .userEntered, confidence: nil, imageData: nil))

        let originalKey = try #require(try coordinator.allSyncOperations().first?.idempotencyKey)

        let mockBackend = MockBackendServicing()
        await mockBackend.setSynchronizeHandler { _, _ in throw BackendError.transport("simulated transient failure") }
        let engine = CloudSyncEngine(backend: mockBackend)

        _ = await engine.synchronize(coordinator: coordinator, now: .now)
        _ = await engine.synchronize(coordinator: coordinator, now: .now.addingTimeInterval(60))

        let calls = await mockBackend.synchronizeCalls
        #expect(calls.count == 2)
        let keysUsed = Set(calls.flatMap { $0.request.operations.map(\.idempotencyKey) })
        #expect(keysUsed == [originalKey])
        #expect(try coordinator.allSyncOperations().first?.idempotencyKey == originalKey)
    }

    // MARK: - 4. Retry boundedness

    @Test func retryableTransportFailureIsAttemptedAtMostTheCodedMaximum() async throws {
        struct TransientFailure: Error {}
        let transport = RecordingBackendTransport(steps: Array(repeating: .failure(TransientFailure()), count: 5))
        let client = makeClient(transport: transport)
        do {
            _ = try await client.authenticate(.init(identityToken: "t", authorizationCode: "c", nonce: "n"), idempotencyKey: "k")
            Issue.record("Expected the request to fail after exhausting retries")
        } catch {}
        let count = await transport.invocationCount
        #expect(count == 3)
    }

    @Test func nonRetryableErrorsAbortImmediatelyWithoutRetrying() async throws {
        // 401/403 map to .unauthorized, which the client treats as terminal.
        let unauthorizedTransport = RecordingBackendTransport(steps: [.success(status: 401, body: Data())])
        let unauthorizedClient = makeClient(transport: unauthorizedTransport)
        do {
            _ = try await unauthorizedClient.authenticate(.init(identityToken: "t", authorizationCode: "c", nonce: "n"), idempotencyKey: "k")
            Issue.record("Expected unauthorized to be thrown")
        } catch BackendError.unauthorized {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await unauthorizedTransport.invocationCount == 1)

        // Cancellation must propagate as-is, never be retried.
        let cancellationTransport = RecordingBackendTransport(steps: [.failure(CancellationError())])
        let cancellationClient = makeClient(transport: cancellationTransport)
        do {
            _ = try await cancellationClient.authenticate(.init(identityToken: "t", authorizationCode: "c", nonce: "n"), idempotencyKey: "k")
            Issue.record("Expected CancellationError to propagate")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await cancellationTransport.invocationCount == 1)
    }

    @Test func rateLimitedResponsesAreRetriedUpToTheBoundThenSurfaceRateLimited() async throws {
        let transport = RecordingBackendTransport(steps: Array(repeating: .success(status: 429, body: Data()), count: 5))
        let client = makeClient(transport: transport)
        do {
            _ = try await client.authenticate(.init(identityToken: "t", authorizationCode: "c", nonce: "n"), idempotencyKey: "k")
            Issue.record("Expected rateLimited to be thrown")
        } catch BackendError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let count = await transport.invocationCount
        #expect(count == 3)
    }

    // MARK: - 5. Keychain boundary

    @Test func keychainRoundTripsStoreReadDeleteAndDeleteAllClearsEveryCredential() async throws {
        let service = "com.pak.fuel.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)

        try await store.save("secret-access-token", for: .accessToken)
        try await store.save("secret-refresh-token", for: .refreshToken)

        #expect(try await store.string(for: .accessToken) == "secret-access-token")

        try await store.delete(.accessToken)
        #expect(try await store.string(for: .accessToken) == nil)
        #expect(try await store.string(for: .refreshToken) == "secret-refresh-token")

        try await store.deleteAll()
        for credential in KeychainCredential.allCases {
            #expect(try await store.string(for: credential) == nil)
        }
    }

    @Test func keychainStoresCredentialsAsAfterFirstUnlockThisDeviceOnly() async throws {
        let service = "com.pak.fuel.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        try await store.save("secret-value", for: .accessToken)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainCredential.accessToken.rawValue,
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #expect(status == errSecSuccess)
        let attributes = try #require(item as? [String: Any])
        let accessible = attributes[kSecAttrAccessible as String] as? String
        #expect(accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))

        try await store.deleteAll()
    }

    // MARK: - 6. Conflict resolver

    @Test func conflictResolverPrefersLocalWhenLocalTimestampIsNewer() {
        let local = SyncOperationRecord(entityType: "meal", entityIdentifier: "1", operation: .update, payloadData: Data(), clientRevision: 1)
        local.updatedAt = Date(timeIntervalSince1970: 200)
        let remote = SyncConflict(entityType: "meal", entityIdentifier: "1", operation: .update, serverRevision: 5, serverUpdatedAt: Date(timeIntervalSince1970: 100), serverPayload: Data())
        #expect(SyncConflictResolver().resolve(local: local, remote: remote) == .useLocal)
    }

    @Test func conflictResolverPrefersServerWhenServerTimestampIsNewer() {
        let local = SyncOperationRecord(entityType: "meal", entityIdentifier: "1", operation: .update, payloadData: Data(), clientRevision: 5)
        local.updatedAt = Date(timeIntervalSince1970: 100)
        let remote = SyncConflict(entityType: "meal", entityIdentifier: "1", operation: .update, serverRevision: 1, serverUpdatedAt: Date(timeIntervalSince1970: 200), serverPayload: Data())
        #expect(SyncConflictResolver().resolve(local: local, remote: remote) == .useRemote)
    }

    @Test func conflictResolverBreaksTimestampTiesUsingRevision() {
        let sameInstant = Date(timeIntervalSince1970: 500)
        let local = SyncOperationRecord(entityType: "meal", entityIdentifier: "1", operation: .update, payloadData: Data(), clientRevision: 9)
        local.updatedAt = sameInstant
        let remote = SyncConflict(entityType: "meal", entityIdentifier: "1", operation: .update, serverRevision: 3, serverUpdatedAt: sameInstant, serverPayload: Data())
        #expect(SyncConflictResolver().resolve(local: local, remote: remote) == .useLocal)
    }

    @Test func conflictResolverPrefersServerWhenTimestampsAndRevisionsAreEqual() {
        let sameInstant = Date(timeIntervalSince1970: 500)
        let local = SyncOperationRecord(entityType: "meal", entityIdentifier: "1", operation: .update, payloadData: Data(), clientRevision: 4)
        local.updatedAt = sameInstant
        let remote = SyncConflict(entityType: "meal", entityIdentifier: "1", operation: .update, serverRevision: 4, serverUpdatedAt: sameInstant, serverPayload: Data())
        #expect(SyncConflictResolver().resolve(local: local, remote: remote) == .useRemote)
    }

    // MARK: - 7. Sync queue

    @Test @MainActor func enqueueingAnUpdateAfterACreateCoalescesIntoASingleCreateEntry() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(userIdentifierHash: "hash", displayName: nil, emailHint: nil, cloudConnected: true))

        let meal = try await coordinator.saveMeal(.init(name: "Bowl", type: .lunch, date: .now, nutrition: .init(calories: 300, protein: 20, carbohydrates: 30, fat: 10, fiber: 4), items: [], provenance: .userEntered, confidence: nil, imageData: nil))
        try await coordinator.updateMeal(meal, with: .init(name: "Bigger bowl", type: .lunch, date: .now, nutrition: .init(calories: 500, protein: 30, carbohydrates: 40, fat: 15, fiber: 6), items: [], provenance: .userEntered, confidence: nil, imageData: nil))

        let mealOps = try coordinator.allSyncOperations().filter { $0.entityType == "meal" && $0.entityIdentifier == meal.id.uuidString }
        #expect(mealOps.count == 1)
        #expect(mealOps.first?.operation == .create)
    }

    @Test @MainActor func markSyncFailedIncrementsAttemptsAndGrowsTheBackoffWindow() throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let op = SyncOperationRecord(entityType: "meal", entityIdentifier: "x", operation: .create, payloadData: Data(), clientRevision: 1)
        try repositories.syncQueue.save(op)
        let now = Date(timeIntervalSince1970: 1_000_000)

        try coordinator.markSyncFailed(op, error: BackendError.server(status: 500), now: now)
        #expect(op.attempts == 1)
        let firstDelay = try #require(op.nextAttemptAt).timeIntervalSince(now)

        try coordinator.markSyncFailed(op, error: BackendError.server(status: 500), now: now)
        #expect(op.attempts == 2)
        let secondDelay = try #require(op.nextAttemptAt).timeIntervalSince(now)

        #expect(secondDelay > firstDelay)
    }

    @Test @MainActor func operationsAtMaxRetryAttemptsAreExcludedFromReadySyncOperations() throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let op = SyncOperationRecord(entityType: "meal", entityIdentifier: "y", operation: .update, payloadData: Data(), clientRevision: 1)
        try repositories.syncQueue.save(op)
        let now = Date.now

        for _ in 0..<DailyDataCoordinator.maxRetryAttempts {
            try coordinator.markSyncFailed(op, error: BackendError.transport("boom"), now: now)
        }
        #expect(op.attempts == DailyDataCoordinator.maxRetryAttempts)

        // Terminal failures clear nextAttemptAt, so only the attempts filter (not
        // the date filter) is what excludes this record going forward.
        #expect(op.nextAttemptAt == nil)
        let ready = try coordinator.readySyncOperations(at: now.addingTimeInterval(60 * 60 * 24))
        #expect(ready.isEmpty)
    }

    @Test @MainActor func syncQueueEntityTypesAreLimitedToKnownLocalDomainTypes() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(userIdentifierHash: "hash", displayName: nil, emailHint: nil, cloudConnected: true))

        let meal = try await coordinator.saveMeal(.init(name: "Bowl", type: .lunch, date: .now, nutrition: .init(calories: 400, protein: 20, carbohydrates: 40, fat: 10, fiber: 5), items: [], provenance: .userEntered, confidence: nil, imageData: nil))
        try coordinator.addWater(milliliters: 200, at: .now, timeZoneIdentifier: TimeZone.current.identifier)
        var preferences = try coordinator.preferences()
        preferences.onboardingCompleted = true
        try coordinator.savePreferences(preferences)
        var profile = try repositories.profiles.profile()
        profile.firstName = "Test"
        try coordinator.saveProfile(profile)
        try coordinator.saveTargets(.init())
        try await coordinator.deleteMeal(meal)

        let entityTypes = Set(try coordinator.allSyncOperations().map(\.entityType))
        let allowed: Set<String> = ["meal", "hydration", "preferences", "profile", "targets"]
        #expect(!entityTypes.isEmpty)
        #expect(entityTypes.isSubset(of: allowed))
        // HealthKit-derived data (activity/sleep/workouts/body measurements) is
        // never written to the sync queue by any coordinator code path.
        for forbidden in ["activity", "sleep", "workout", "workouts", "healthKit", "bodyMeasurement"] {
            #expect(!entityTypes.contains(forbidden))
        }
    }

    // MARK: - 8. Integration: CloudSyncEngine + mock BackendServicing

    @Test @MainActor func cloudSyncEngineHappyPathMarksOperationsAcceptedAndStoresServerRevision() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(userIdentifierHash: "hash", displayName: nil, emailHint: nil, cloudConnected: true))
        _ = try await coordinator.saveMeal(.init(name: "Bowl", type: .lunch, date: .now, nutrition: .init(calories: 300, protein: 20, carbohydrates: 30, fat: 10, fiber: 4), items: [], provenance: .userEntered, confidence: nil, imageData: nil))
        try coordinator.addWater(milliliters: 200, at: .now, timeZoneIdentifier: TimeZone.current.identifier)
        #expect(try coordinator.allSyncOperations().count == 2)

        let mockBackend = MockBackendServicing()
        await mockBackend.setSynchronizeHandler { request, _ in
            SyncBatchResponse(acceptedIdempotencyKeys: request.operations.map(\.idempotencyKey), conflicts: [], serverRevision: 42, remoteChanges: nil)
        }
        let engine = CloudSyncEngine(backend: mockBackend)
        let now = Date.now
        let state = await engine.synchronize(coordinator: coordinator, now: now)

        guard case .current(let syncedAt) = state else {
            Issue.record("Expected a current state, got \(state)")
            return
        }
        #expect(syncedAt == now)
        #expect(try coordinator.allSyncOperations().isEmpty)
        let account = try repositories.accountMetadata.account()
        #expect(account.serverRevision == 42)
        #expect(account.lastSyncAt != nil)
    }

    @Test @MainActor func cloudSyncEngineConflictPathRetriesLocalWhenLocalIsNewer() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(userIdentifierHash: "hash", displayName: nil, emailHint: nil, cloudConnected: true))
        let meal = try await coordinator.saveMeal(.init(name: "Bowl", type: .lunch, date: .now, nutrition: .init(calories: 300, protein: 20, carbohydrates: 30, fat: 10, fiber: 4), items: [], provenance: .userEntered, confidence: nil, imageData: nil))
        let mealID = meal.id.uuidString
        let originalKey = try #require(try coordinator.allSyncOperations().first?.idempotencyKey)

        var remoteMeal = ExportedMeal(meal: meal)
        remoteMeal.createdAt = .now.addingTimeInterval(-2_000)
        remoteMeal.updatedAt = .now.addingTimeInterval(-1_000)
        let remotePayload = try JSONEncoder().encode(remoteMeal)
        let remoteUpdatedAt = remoteMeal.updatedAt

        let mockBackend = MockBackendServicing()
        await mockBackend.setSynchronizeHandler { _, _ in
            // Local queue record's `updatedAt` is set to "now" on save, so it is
            // guaranteed newer than a server timestamp from the recent past.
            SyncBatchResponse(
                acceptedIdempotencyKeys: [],
                conflicts: [SyncConflict(entityType: "meal", entityIdentifier: mealID, operation: .create, serverRevision: 9, serverUpdatedAt: remoteUpdatedAt, serverPayload: remotePayload)],
                serverRevision: 10,
                remoteChanges: nil
            )
        }
        let engine = CloudSyncEngine(backend: mockBackend)
        let state = await engine.synchronize(coordinator: coordinator, now: .now)

        guard case .conflict(let count) = state else {
            Issue.record("Expected a conflict state, got \(state)")
            return
        }
        #expect(count == 1)
        let remainingOps = try coordinator.allSyncOperations()
        #expect(remainingOps.count == 1)
        #expect(remainingOps.first?.state == .pending)
        #expect(remainingOps.first?.idempotencyKey != originalKey)
    }

    @Test @MainActor func cloudSyncEngineConflictPathAppliesRemoteChangeWhenServerIsNewer() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(userIdentifierHash: "hash", displayName: nil, emailHint: nil, cloudConnected: true))
        let meal = try await coordinator.saveMeal(.init(name: "Bowl", type: .lunch, date: .now, nutrition: .init(calories: 300, protein: 20, carbohydrates: 30, fat: 10, fiber: 4), items: [], provenance: .userEntered, confidence: nil, imageData: nil))
        let mealID = meal.id.uuidString

        var remoteExport = ExportedMeal(meal: meal)
        remoteExport.name = "Server Bowl"
        let remotePayload = try JSONEncoder().encode(remoteExport)

        let mockBackend = MockBackendServicing()
        await mockBackend.setSynchronizeHandler { _, _ in
            SyncBatchResponse(
                acceptedIdempotencyKeys: [],
                conflicts: [SyncConflict(entityType: "meal", entityIdentifier: mealID, operation: .create, serverRevision: 5, serverUpdatedAt: .now.addingTimeInterval(3_600), serverPayload: remotePayload)],
                serverRevision: 20,
                remoteChanges: nil
            )
        }
        let engine = CloudSyncEngine(backend: mockBackend)
        let state = await engine.synchronize(coordinator: coordinator, now: .now)

        // A pure server-wins resolution accepts the local op via applyRemoteChange
        // + acceptSyncOperation without ever incrementing the conflict counter.
        guard case .current = state else {
            Issue.record("Expected a current state after a server-wins resolution, got \(state)")
            return
        }
        #expect(try coordinator.allSyncOperations().isEmpty)
        #expect(try repositories.meals.meal(id: meal.id)?.name == "Server Bowl")
    }

    @Test @MainActor func cloudSyncEngineUnauthorizedFailureSurfacesAsFailedWithoutLosingQueuedOperations() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        try coordinator.applyAccountSession(.init(userIdentifierHash: "hash", displayName: nil, emailHint: nil, cloudConnected: true))
        _ = try await coordinator.saveMeal(.init(name: "Bowl", type: .lunch, date: .now, nutrition: .init(calories: 300, protein: 20, carbohydrates: 30, fat: 10, fiber: 4), items: [], provenance: .userEntered, confidence: nil, imageData: nil))

        let mockBackend = MockBackendServicing()
        await mockBackend.setSynchronizeHandler { _, _ in throw BackendError.unauthorized }
        let engine = CloudSyncEngine(backend: mockBackend)
        let state = await engine.synchronize(coordinator: coordinator, now: .now)

        // There's no dedicated "sign-in required" case in SyncExecutionState; an
        // unauthorized failure surfaces as `.failed` carrying the sign-in-again
        // message, and the queued operation is preserved (not dropped).
        guard case .failed(let message) = state else {
            Issue.record("Expected a failed state signalling sign-in is required, got \(state)")
            return
        }
        #expect(message.contains("Sign in"))
        let remaining = try coordinator.allSyncOperations()
        #expect(remaining.count == 1)
        #expect(remaining.first?.state == .failed)
        #expect(remaining.first?.attempts == 1)
    }

    @Test func accountExportAcceptsHttpsDownloadWithFutureExpiry() async throws {
        let credentials = KeychainCredentialStore(service: "com.pak.fuel.tests.\(UUID().uuidString)")
        try await credentials.save("token", for: .accessToken)
        let response = AccountExportResponse(downloadURL: URL(string: "https://exports.fuel.test/abc")!, expiresAt: .now.addingTimeInterval(3_600))
        let transport = RecordingBackendTransport(steps: [.success(status: 200, body: try encodeISO8601(response))])
        let client = BackendAPIClient(configuration: .init(environment: .development, baseURL: URL(string: "https://api.fuel.test")), transport: transport, credentials: credentials)

        let result = try await client.requestAccountExport()
        #expect(result.downloadURL.scheme == "https")

        try await credentials.deleteAll()
    }

    @Test func accountExportRejectsInsecureOrExpiredDownloadLinks() async throws {
        let credentials = KeychainCredentialStore(service: "com.pak.fuel.tests.\(UUID().uuidString)")
        try await credentials.save("token", for: .accessToken)

        let httpResponse = AccountExportResponse(downloadURL: URL(string: "http://exports.fuel.test/abc")!, expiresAt: .now.addingTimeInterval(3_600))
        let httpTransport = RecordingBackendTransport(steps: [.success(status: 200, body: try encodeISO8601(httpResponse))])
        let httpClient = BackendAPIClient(configuration: .init(environment: .development, baseURL: URL(string: "https://api.fuel.test")), transport: httpTransport, credentials: credentials)
        do {
            _ = try await httpClient.requestAccountExport()
            Issue.record("Expected an http download URL to be rejected")
        } catch BackendError.invalidResponse {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let expiredResponse = AccountExportResponse(downloadURL: URL(string: "https://exports.fuel.test/abc")!, expiresAt: .now.addingTimeInterval(-3_600))
        let expiredTransport = RecordingBackendTransport(steps: [.success(status: 200, body: try encodeISO8601(expiredResponse))])
        let expiredClient = BackendAPIClient(configuration: .init(environment: .development, baseURL: URL(string: "https://api.fuel.test")), transport: expiredTransport, credentials: credentials)
        do {
            _ = try await expiredClient.requestAccountExport()
            Issue.record("Expected an expired download URL to be rejected")
        } catch BackendError.invalidResponse {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        try await credentials.deleteAll()
    }

    // MARK: - 9. Migration V1 → V3

    @Test @MainActor func migratingFromSchemaV1ToV3PreservesALoggedMeal() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "FuelMigrationTest-\(UUID().uuidString).sqlite")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: shmURL)
            try? FileManager.default.removeItem(at: walURL)
        }

        do {
            let v1Schema = Schema(versionedSchema: FuelSchemaV1.self)
            let configuration = ModelConfiguration(schema: v1Schema, url: url)
            let container = try ModelContainer(for: v1Schema, configurations: [configuration])
            let meal = Meal(name: "Legacy Lunch", type: .lunch, date: .now, nutrition: .init(calories: 480, protein: 28, carbohydrates: 55, fat: 16, fiber: 6))
            container.mainContext.insert(meal)
            try container.mainContext.save()
        }

        let v3Schema = Schema(versionedSchema: FuelSchemaV3.self)
        let migratedConfiguration = ModelConfiguration(schema: v3Schema, url: url)
        let migratedContainer = try ModelContainer(for: v3Schema, migrationPlan: FuelMigrationPlan.self, configurations: [migratedConfiguration])
        let meals = try migratedContainer.mainContext.fetch(FetchDescriptor<Meal>())

        #expect(meals.count == 1)
        #expect(meals.first?.name == "Legacy Lunch")
        #expect(meals.first?.nutrition.calories == 480)
    }

    // MARK: - 10. RemoteFeatureConfigurationValidator + Analytics

    @Test func unknownRemoteFlagKeysAreIgnoredByValidation() {
        let config = RemoteFeatureConfiguration(schemaVersion: 1, minimumAppVersion: "1.0.0", scoringAlgorithmVersion: 1, enabledFlags: ["totallyUnknownFlag": true, "hapticsEnabled": false], expiresAt: .now.addingTimeInterval(3_600))
        switch RemoteFeatureConfigurationValidator.validate(config, currentAppVersion: "1.0.0") {
        case .success(let validated):
            #expect(validated.flags[.hapticsEnabled] == false)
            #expect(validated.flags.count == 1)
        case .failure(let reasons):
            Issue.record("Expected success, got \(reasons)")
        }
    }

    @Test func fixedPolicyFlagsCannotBeChangedByRemoteConfiguration() {
        let config = RemoteFeatureConfiguration(schemaVersion: 1, minimumAppVersion: "1.0.0", scoringAlgorithmVersion: 1, enabledFlags: ["remoteConfigAllowed": true], expiresAt: .now.addingTimeInterval(3_600))
        switch RemoteFeatureConfigurationValidator.validate(config, currentAppVersion: "1.0.0") {
        case .success(let validated):
            #expect(validated.flags[.remoteConfigAllowed] == nil)
        case .failure(let reasons):
            Issue.record("Expected success, got \(reasons)")
        }
        #expect(RemoteFeatureConfigurationValidator.applying(true, to: .remoteConfigAllowed) == FeatureFlag.remoteConfigAllowed.defaultValue)
    }

    @Test func tightenOnlyFlagsCanNarrowButNeverWiden() {
        let widen = RemoteFeatureConfiguration(schemaVersion: 1, minimumAppVersion: "1.0.0", scoringAlgorithmVersion: 1, enabledFlags: ["cloudSyncAllowed": true], expiresAt: .now.addingTimeInterval(3_600))
        switch RemoteFeatureConfigurationValidator.validate(widen, currentAppVersion: "1.0.0") {
        case .success(let validated):
            #expect(validated.flags[.cloudSyncAllowed] == nil)
        case .failure(let reasons):
            Issue.record("Expected success, got \(reasons)")
        }

        let tighten = RemoteFeatureConfiguration(schemaVersion: 1, minimumAppVersion: "1.0.0", scoringAlgorithmVersion: 1, enabledFlags: ["cloudSyncAllowed": false], expiresAt: .now.addingTimeInterval(3_600))
        switch RemoteFeatureConfigurationValidator.validate(tighten, currentAppVersion: "1.0.0") {
        case .success(let validated):
            #expect(validated.flags[.cloudSyncAllowed] == false)
        case .failure(let reasons):
            Issue.record("Expected success, got \(reasons)")
        }
    }

    @Test func expiredRemoteConfigurationIsRejectedWholesale() {
        let config = RemoteFeatureConfiguration(schemaVersion: 1, minimumAppVersion: "1.0.0", scoringAlgorithmVersion: 1, enabledFlags: ["hapticsEnabled": false], expiresAt: .now.addingTimeInterval(-60))
        switch RemoteFeatureConfigurationValidator.validate(config, currentAppVersion: "1.0.0") {
        case .success(let validated):
            Issue.record("Expected an expired configuration to be rejected, got \(validated)")
        case .failure(let reasons):
            #expect(reasons.failures.contains(.expired))
        }
    }

    @Test func localCountingSinkCountsRecordedEvents() {
        // AnalyticsEvent's compile-time-closed payload types (no String case
        // anywhere in the taxonomy) are a type-system guarantee, not something a
        // runtime test can meaningfully exercise; only the counting behavior below
        // is tested.
        let suiteName = "com.pak.fuel.tests.analytics.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        let sink = LocalCountingSink(defaults: defaults)
        sink.record(.appLaunched)
        sink.record(.mealLogged(source: .manualEntry))
        sink.record(.mealLogged(source: .manualEntry))
        let counters = sink.counters()
        #expect(counters["appLaunched"] == 1)
        #expect(counters["mealLogged.manualEntry"] == 2)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Helpers

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: FuelSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeClient(transport: RecordingBackendTransport) -> BackendAPIClient {
        BackendAPIClient(
            configuration: .init(environment: .development, baseURL: URL(string: "https://api.fuel.test")),
            transport: transport,
            credentials: KeychainCredentialStore(service: "com.pak.fuel.tests.\(UUID().uuidString)")
        )
    }

    private func encodeISO8601<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

/// Records every `URLRequest` handed to it and replays a scripted sequence of
/// responses/errors — one entry per call, holding on the last entry once the
/// script is exhausted. Used in place of `URLSessionBackendTransport` so no
/// test in this file performs real network I/O.
private actor RecordingBackendTransport: BackendTransport {
    enum Step {
        case success(status: Int, body: Data)
        case failure(Error)
    }

    private var steps: [Step]
    private(set) var recordedRequests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var invocationCount: Int { recordedRequests.count }

    func data(for request: URLRequest) async throws -> BackendHTTPResponse {
        recordedRequests.append(request)
        let index = recordedRequests.count - 1
        let step = index < steps.count ? steps[index] : (steps.last ?? .success(status: 200, body: Data()))
        switch step {
        case .success(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return BackendHTTPResponse(data: body, response: response)
        case .failure(let error):
            throw error
        }
    }
}

/// Minimal `BackendServicing` test double. Every endpoint other than
/// `synchronize` throws `.notConfigured` by default since no test in this file
/// exercises them; `synchronize` calls are recorded and dispatched to an
/// injectable handler so tests can script accept/conflict/failure responses.
private actor MockBackendServicing: BackendServicing {
    nonisolated let isConfigured: Bool
    private var synchronizeHandler: (@Sendable (SyncBatchRequest, String) async throws -> SyncBatchResponse)?
    private(set) var synchronizeCalls: [(request: SyncBatchRequest, idempotencyKey: String)] = []

    init(isConfigured: Bool = true) {
        self.isConfigured = isConfigured
    }

    func setSynchronizeHandler(_ handler: @escaping @Sendable (SyncBatchRequest, String) async throws -> SyncBatchResponse) {
        synchronizeHandler = handler
    }

    func authenticate(_ request: AppleAuthenticationRequest, idempotencyKey: String) async throws -> AuthenticationSessionResponse {
        throw BackendError.notConfigured
    }

    func fetchProfile() async throws -> ProfileResponse {
        throw BackendError.notConfigured
    }

    func updateProfile(_ request: ProfileUpdateRequest) async throws -> ProfileResponse {
        throw BackendError.notConfigured
    }

    func uploadRecognition(_ request: PhotoAnalysisUploadRequest, idempotencyKey: String) async throws -> RecognitionJobResponse {
        throw BackendError.notConfigured
    }

    func recognitionStatus(jobIdentifier: String) async throws -> RecognitionJobResponse {
        throw BackendError.notConfigured
    }

    func searchNutrition(_ request: NutritionSearchRequest) async throws -> NutritionSearchResponse {
        throw BackendError.notConfigured
    }

    func synchronize(_ request: SyncBatchRequest, idempotencyKey: String) async throws -> SyncBatchResponse {
        synchronizeCalls.append((request, idempotencyKey))
        guard let synchronizeHandler else { throw BackendError.notConfigured }
        return try await synchronizeHandler(request, idempotencyKey)
    }

    func recommendation(_ request: RemoteRecommendationRequest) async throws -> RemoteRecommendationResponse {
        throw BackendError.notConfigured
    }

    func requestAccountExport() async throws -> AccountExportResponse {
        throw BackendError.notConfigured
    }

    func deleteAccount() async throws {
        throw BackendError.notConfigured
    }

    func remoteConfiguration() async throws -> RemoteFeatureConfiguration {
        throw BackendError.notConfigured
    }
}
