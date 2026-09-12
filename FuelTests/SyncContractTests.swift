import Foundation
import Testing
@testable import Fuel

struct SyncContractTests {
    @Test func omittedCursorRemainsCompatibleAndExplicitCursorRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SyncBatchRequest.self, from: Data(#"{"operations":[]}"#.utf8))
        #expect(legacy.sinceRevision == nil)
        #expect(SyncBatchRequest(operations: []).sinceRevision == nil)

        let request = SyncBatchRequest(operations: [], sinceRevision: 42)
        let restored = try JSONDecoder().decode(SyncBatchRequest.self, from: JSONEncoder().encode(request))
        #expect(restored.sinceRevision == 42)
        try SyncContractValidator.validateRequest(restored)
    }

    @Test func normalizedIdentityMatchesUUIDCaseButKeepsEntityTypesSeparate() {
        let identifier = UUID().uuidString
        let meal = SyncEntityIdentity(entityType: "meal", entityIdentifier: identifier)
        #expect(meal == SyncEntityIdentity(entityType: "meal", entityIdentifier: identifier.lowercased()))
        #expect(meal != SyncEntityIdentity(entityType: "hydration", entityIdentifier: identifier))
        #expect(SyncEntityIdentity(entityType: "profile", entityIdentifier: "primary") != nil)
        #expect(SyncEntityIdentity(entityType: "targets", entityIdentifier: "current") != nil)
        #expect(SyncEntityIdentity(entityType: "preferences", entityIdentifier: "primary") != nil)
    }

    @Test func requestRejectsDuplicateKeysAndCaseVariantEntityDuplicates() {
        let first = operation()
        var duplicateKey = operation()
        duplicateKey.idempotencyKey = first.idempotencyKey
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [first, duplicateKey]))
        }

        var duplicateEntity = first
        duplicateEntity.idempotencyKey = UUID().uuidString
        duplicateEntity.entityIdentifier = first.entityIdentifier.lowercased()
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [first, duplicateEntity]))
        }
    }

    @Test func requestRejectsNegativeRevisionsAndNonfiniteDates() {
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [], sinceRevision: -1))
        }
        var invalid = operation()
        invalid.clientRevision = -1
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [invalid]))
        }
        invalid.clientRevision = 0
        invalid.updatedAt = Date(timeIntervalSince1970: .infinity)
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [invalid]))
        }
    }

    @Test(arguments: ["", "has a space", "line\r\nbreak", "key/segment", "é", String(repeating: "a", count: 129)])
    func requestRejectsInvalidIdempotencyKeys(_ key: String) {
        var invalid = operation()
        invalid.idempotencyKey = key
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [invalid]))
        }
    }

    @Test(arguments: [
        ["healthKit", "primary"], ["meal", "not-a-uuid"], ["hydration", "primary"],
        ["profile", "other-account"], ["preferences", "current"], ["targets", "primary"]
    ])
    func requestRejectsUnsupportedEntitiesAndIdentifiers(_ identity: [String]) {
        var invalid = operation()
        invalid.entityType = identity[0]
        invalid.entityIdentifier = identity[1]
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [invalid]))
        }
    }

    @Test func singletonDeletionIsUnsupportedInBothDirections() {
        var invalid = operation()
        invalid.entityType = "profile"
        invalid.entityIdentifier = "primary"
        invalid.operation = .delete
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: [invalid]))
        }
        let change = remote(type: "preferences", identifier: "primary", revision: 1, operation: .delete)
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(response(revision: 1, changes: [change]), for: .init(operations: []))
        }
    }

    @Test func requestCapsOperationCountIndividualPayloadAndEncodedBatchSize() throws {
        let atLimit = (0..<SyncContractValidator.maximumOperations).map { _ in operation() }
        try SyncContractValidator.validateRequest(.init(operations: atLimit))
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.validateRequest(.init(operations: atLimit + [operation()]))
        }

        var oversized = operation()
        oversized.payload = Data(count: SyncContractValidator.maximumEntityPayloadBytes + 1)
        #expect(throws: BackendError.payloadTooLarge) {
            try SyncContractValidator.validateRequest(.init(operations: [oversized]))
        }
        var first = operation()
        var second = operation()
        first.payload = Data(count: 400_000)
        second.payload = Data(count: 400_000)
        #expect(throws: BackendError.payloadTooLarge) {
            try SyncContractValidator.validateRequest(.init(operations: [first, second]))
        }
    }

    @Test func batchSelectionUsesEncodedBytesAndKeepsTheLongestOrderedPrefix() throws {
        var ordered = (0..<5).map { _ in operation() }
        let sizes = [300_000, 200_000, 100_000, 200_000, 1]
        for index in ordered.indices { ordered[index].payload = Data(count: sizes[index]) }

        let selected = try SyncContractValidator.makeBatchRequest(from: ordered, sinceRevision: 37)
        #expect(selected.sinceRevision == 37)
        #expect(selected.operations == Array(ordered.prefix(3)))
        try SyncContractValidator.validateRequest(selected)
        // The raw payloads fit in 1MB, but their base64 representation and metadata do not.
        #expect(ordered.prefix(4).reduce(0) { $0 + $1.payload.count } < BackendEndpoint.mealSync.maximumRequestBytes)
        #expect(throws: BackendError.payloadTooLarge) {
            try SyncContractValidator.validateRequest(.init(operations: Array(ordered.prefix(4)), sinceRevision: 37))
        }
        let remainder = try SyncContractValidator.makeBatchRequest(from: Array(ordered.dropFirst(selected.operations.count)), sinceRevision: 38)
        #expect(remainder.operations == Array(ordered.suffix(2)))
    }

    @Test func successiveByteLimitedBatchesEventuallyIncludeSmallOperationsAfterLargeOnes() throws {
        var ordered = (0..<5).map { _ in operation() }
        for index in 0..<3 { ordered[index].payload = Data(count: 400_000) }
        var pending = ordered
        var submitted: [SyncOperationPayload] = []
        var batches = 0

        while !pending.isEmpty, batches < ordered.count {
            let request = try SyncContractValidator.makeBatchRequest(from: pending, sinceRevision: batches)
            #expect(!request.operations.isEmpty)
            submitted.append(contentsOf: request.operations)
            pending.removeFirst(request.operations.count)
            batches += 1
        }
        #expect(pending.isEmpty)
        #expect(submitted == ordered)
        #expect(batches == 3)
    }

    @Test func batchSelectionEnforcesOperationLimitAndPreservesAnEmptyPull() throws {
        let ordered = (0..<101).map { _ in operation() }
        let selected = try SyncContractValidator.makeBatchRequest(from: ordered, sinceRevision: 42)
        #expect(selected.operations == Array(ordered.prefix(100)))
        let remainder = try SyncContractValidator.makeBatchRequest(from: Array(ordered.dropFirst(100)), sinceRevision: 43)
        #expect(remainder.operations == [ordered[100]])

        let pull = try SyncContractValidator.makeBatchRequest(from: [], sinceRevision: 44)
        #expect(pull.operations.isEmpty)
        #expect(pull.sinceRevision == 44)
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.makeBatchRequest(from: [], sinceRevision: -1)
        }
    }

    @Test func batchSelectionReportsInvalidAndOversizedSingleRecordsInsteadOfDroppingThem() {
        var oversized = operation()
        oversized.payload = Data(count: SyncContractValidator.maximumEntityPayloadBytes + 1)
        for ordered in [[oversized, operation()], [operation(), oversized, operation()]] {
            #expect(throws: BackendError.payloadTooLarge) {
                try SyncContractValidator.makeBatchRequest(from: ordered, sinceRevision: 0)
            }
        }

        var invalid = operation()
        invalid.entityIdentifier = "invalid"
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.makeBatchRequest(from: [operation(), invalid])
        }
        let original = operation()
        var duplicate = original
        duplicate.idempotencyKey = UUID().uuidString
        duplicate.entityIdentifier = original.entityIdentifier.lowercased()
        #expect(throws: BackendError.invalidPayload) {
            try SyncContractValidator.makeBatchRequest(from: [original, duplicate])
        }
    }

    @Test func batchSelectionIncludesJSONEscapingWhenSizingIndividualRecords() throws {
        var escapedPayload = operation()
        // This base64 text consists mostly of slashes, escaped by the transport's default
        // JSONEncoder. Raw bytes and base64 length alone both underestimate its wire size.
        escapedPayload.payload = Data(repeating: 0xFF, count: 500_000)
        let request = SyncBatchRequest(operations: [escapedPayload])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try encoder.encode(request).count > BackendEndpoint.mealSync.maximumRequestBytes)
        #expect(throws: BackendError.payloadTooLarge) {
            try SyncContractValidator.makeBatchRequest(from: [escapedPayload, operation()])
        }
    }

    @Test func responseAcceptsCompleteMixedOutcomesAndCanonicalServerEcho() throws {
        let accepted = operation()
        let conflicted = operation()
        let request = SyncBatchRequest(operations: [accepted, conflicted], sinceRevision: 10)
        // A conflict may describe a server value older than the requested pull cursor.
        let conflict = remote(identifier: conflicted.entityIdentifier.lowercased(), revision: 7)
        let echo = remote(identifier: accepted.entityIdentifier.lowercased(), revision: 11)
        let water = remote(type: "hydration", revision: 12)
        let valid = response(accepted: [accepted.idempotencyKey], conflicts: [conflict], revision: 12, changes: [echo, water])
        try SyncContractValidator.validateResponse(valid, for: request)
    }

    @Test func responseRejectsForeignDuplicateAndMissingAcceptanceKeys() {
        let sent = operation()
        let other = operation()
        let request = SyncBatchRequest(operations: [sent, other])
        for keys in [["not-submitted", other.idempotencyKey], [sent.idempotencyKey, sent.idempotencyKey], [sent.idempotencyKey], []] {
            #expect(throws: BackendError.invalidResponse) {
                try SyncContractValidator.validateResponse(response(accepted: keys, revision: 1), for: request)
            }
        }
    }

    @Test func responseRejectsAcceptedAndConflictedOutcomeForSameOperation() {
        let sent = operation()
        let invalid = response(
            accepted: [sent.idempotencyKey],
            conflicts: [remote(identifier: sent.entityIdentifier, revision: 1)], revision: 1
        )
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(invalid, for: .init(operations: [sent]))
        }
    }

    @Test func responseRejectsForeignAndDuplicateConflictEntities() {
        let sent = operation()
        let request = SyncBatchRequest(operations: [sent])
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(response(conflicts: [remote(revision: 1)], revision: 1), for: request)
        }

        let other = operation()
        let conflict = remote(identifier: sent.entityIdentifier, revision: 1)
        var duplicate = conflict
        duplicate.entityIdentifier = sent.entityIdentifier.lowercased()
        // Two sent entries keep this below the count cap so identity validation is exercised.
        let invalid = response(accepted: [other.idempotencyKey], conflicts: [conflict, duplicate], revision: 1)
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(invalid, for: .init(operations: [sent, other]))
        }
    }

    @Test func responseRejectsRegressingCursorAndOutOfRangeConflictRevisions() {
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(response(revision: 9), for: .init(operations: [], sinceRevision: 10))
        }
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(response(revision: -1), for: .init(operations: []))
        }
        let sent = operation()
        for revision in [-1, 21] {
            #expect(throws: BackendError.invalidResponse) {
                try SyncContractValidator.validateResponse(
                    response(conflicts: [remote(identifier: sent.entityIdentifier, revision: revision)], revision: 20),
                    for: .init(operations: [sent], sinceRevision: 10)
                )
            }
        }
    }

    @Test func responseRejectsFeedAtOrBehindCursorAndAheadOfReturnedCursor() {
        for revision in [-1, 0, 9, 10, 13] {
            #expect(throws: BackendError.invalidResponse) {
                try SyncContractValidator.validateResponse(
                    response(revision: 12, changes: [remote(revision: revision)]),
                    for: .init(operations: [], sinceRevision: 10)
                )
            }
        }
    }

    @Test func responseRejectsOutOfOrderFeedDuplicateRevisionsAndDuplicateEntities() {
        let first = remote(revision: 11)
        var sameEntity = first
        sameEntity.entityIdentifier = first.entityIdentifier.lowercased()
        sameEntity.serverRevision = 12
        let invalidFeeds = [[remote(revision: 12), first], [first, remote(revision: 11)], [first, sameEntity]]
        for changes in invalidFeeds {
            #expect(throws: BackendError.invalidResponse) {
                try SyncContractValidator.validateResponse(response(revision: 12, changes: changes), for: .init(operations: [], sinceRevision: 10))
            }
        }
    }

    @Test func responseRejectsConflictDuplicatedInFeed() {
        let sent = operation()
        let conflict = remote(identifier: sent.entityIdentifier, revision: 11)
        let invalid = response(conflicts: [conflict], revision: 11, changes: [conflict])
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(invalid, for: .init(operations: [sent], sinceRevision: 10))
        }
    }

    @Test func responseRejectsUnknownEntityMalformedIdentifierAndNonfiniteTimestamp() {
        var unknown = remote(revision: 1)
        unknown.entityType = "healthKit"
        var badID = remote(revision: 1)
        badID.entityIdentifier = "not-a-uuid"
        var badDate = remote(revision: 1)
        badDate.serverUpdatedAt = Date(timeIntervalSince1970: .nan)
        for invalid in [unknown, badID, badDate] {
            #expect(throws: BackendError.invalidResponse) {
                try SyncContractValidator.validateResponse(response(revision: 1, changes: [invalid]), for: .init(operations: []))
            }
        }
    }

    @Test func responseCapsChangeCountIndividualPayloadAndEncodedBatchSize() throws {
        let atLimit = (1...SyncContractValidator.maximumRemoteChanges).map { remote(revision: $0) }
        try SyncContractValidator.validateResponse(response(revision: 500, changes: atLimit), for: .init(operations: []))
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(response(revision: 501, changes: atLimit + [remote(revision: 501)]), for: .init(operations: []))
        }

        var oversized = remote(revision: 1)
        oversized.serverPayload = Data(count: SyncContractValidator.maximumEntityPayloadBytes + 1)
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(response(revision: 1, changes: [oversized]), for: .init(operations: []))
        }
        let largeFeed = (1...8).map { revision in
            var change = remote(revision: revision)
            change.serverPayload = Data(count: SyncContractValidator.maximumEntityPayloadBytes)
            return change
        }
        #expect(throws: BackendError.invalidResponse) {
            try SyncContractValidator.validateResponse(response(revision: 8, changes: largeFeed), for: .init(operations: []))
        }
    }

    @Test func payloadContentsRemainTheTypedPayloadValidatorsResponsibility() throws {
        // Envelope validation bounds opaque data; it must not substitute for decoding all
        // typed payloads before the engine begins a local transaction.
        let invalidJSON = Data("not JSON".utf8)
        var sent = operation()
        sent.payload = invalidJSON
        var change = remote(identifier: sent.entityIdentifier, revision: 1)
        change.serverPayload = invalidJSON
        let request = SyncBatchRequest(operations: [sent])
        try SyncContractValidator.validateRequest(request)
        try SyncContractValidator.validateResponse(response(conflicts: [change], revision: 1), for: request)
    }

    @Test func clientRejectsInvalidRequestBeforeCredentialsOrTransport() async throws {
        let transport = ContractRecordingTransport(body: Data())
        let client = BackendAPIClient(
            configuration: .init(environment: .development, baseURL: URL(string: "https://fuel.test")),
            transport: transport,
            credentials: .init(service: "com.pak.fuel.contract.\(UUID().uuidString)")
        )
        await #expect(throws: BackendError.invalidPayload) {
            _ = try await client.synchronize(.init(operations: [], sinceRevision: -1), idempotencyKey: "batch")
        }
        #expect(await transport.requests.count == 0)
    }

    @Test func clientRejectsIncompleteSuccessfulHTTPResponseAndSendsCursor() async throws {
        let sent = operation()
        let transport = ContractRecordingTransport(body: try JSONEncoder().encode(response(revision: 42)))
        let credentials = KeychainCredentialStore(service: "com.pak.fuel.contract.\(UUID().uuidString)")
        try await credentials.save("test-token", for: .accessToken)
        let client = BackendAPIClient(
            configuration: .init(environment: .development, baseURL: URL(string: "https://fuel.test")),
            transport: transport, credentials: credentials
        )
        await #expect(throws: BackendError.invalidResponse) {
            _ = try await client.synchronize(.init(operations: [sent], sinceRevision: 40), idempotencyKey: "batch")
        }
        try await credentials.deleteAll()
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(requests.first?.httpBody)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SyncBatchRequest.self, from: body).sinceRevision == 40)
    }

    private func operation() -> SyncOperationPayload {
        .init(
            idempotencyKey: UUID().uuidString, entityType: "meal", entityIdentifier: UUID().uuidString,
            operation: .update, payload: Data("{}".utf8), clientRevision: 1,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func remote(
        type: String = "meal", identifier: String = UUID().uuidString,
        revision: Int, operation: SyncOperationKind = .update
    ) -> SyncConflict {
        .init(
            entityType: type, entityIdentifier: identifier, operation: operation,
            serverRevision: revision, serverUpdatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            serverPayload: Data("{}".utf8)
        )
    }

    private func response(
        accepted: [String] = [], conflicts: [SyncConflict] = [], revision: Int,
        changes: [SyncConflict]? = nil
    ) -> SyncBatchResponse {
        .init(acceptedIdempotencyKeys: accepted, conflicts: conflicts, serverRevision: revision, remoteChanges: changes)
    }
}

private actor ContractRecordingTransport: BackendTransport {
    let body: Data
    private(set) var requests: [URLRequest] = []

    init(body: Data) { self.body = body }

    func data(for request: URLRequest) async throws -> BackendHTTPResponse {
        requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return .init(data: body, response: response)
    }
}
