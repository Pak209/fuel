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

    init(backend: any BackendServicing, conflictResolver: SyncConflictResolver = .init()) {
        self.backend = backend
        self.conflictResolver = conflictResolver
    }

    func synchronize(coordinator: DailyDataCoordinator, now: Date = .now) async -> SyncExecutionState {
        guard backend.isConfigured else { return .localOnly }
        let operations: [SyncOperationRecord]
        do {
            operations = try coordinator.readySyncOperations(at: now)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard !operations.isEmpty else { return .current(now) }

        do {
            for operation in operations { try coordinator.markSyncUploading(operation) }
            let payload = operations.map {
                SyncOperationPayload(
                    idempotencyKey: $0.idempotencyKey,
                    entityType: $0.entityType,
                    entityIdentifier: $0.entityIdentifier,
                    operation: $0.operation,
                    payload: $0.payloadData,
                    clientRevision: $0.clientRevision,
                    updatedAt: $0.updatedAt
                )
            }
            let response = try await backend.synchronize(
                .init(operations: payload),
                idempotencyKey: UUID().uuidString
            )
            let accepted = Set(response.acceptedIdempotencyKeys)
            for operation in operations where accepted.contains(operation.idempotencyKey) {
                try coordinator.acceptSyncOperation(operation)
            }

            var conflictCount = 0
            for conflict in response.conflicts {
                guard let local = operations.first(where: {
                    $0.entityType == conflict.entityType && $0.entityIdentifier == conflict.entityIdentifier
                }) else {
                    try coordinator.applyRemoteChange(conflict)
                    continue
                }
                switch conflictResolver.resolve(local: local, remote: conflict) {
                case .useLocal:
                    conflictCount += 1
                    try coordinator.retrySyncOperation(local, serverRevision: conflict.serverRevision)
                case .useRemote:
                    try coordinator.applyRemoteChange(conflict)
                    try coordinator.acceptSyncOperation(local)
                }
            }

            for change in response.remoteChanges ?? [] {
                let wasConflict = response.conflicts.contains {
                    $0.entityType == change.entityType && $0.entityIdentifier == change.entityIdentifier
                }
                if !wasConflict { try coordinator.applyRemoteChange(change) }
            }
            try coordinator.updateServerRevision(response.serverRevision)
            return conflictCount > 0 ? .conflict(conflictCount) : .current(now)
        } catch {
            for operation in operations { try? coordinator.markSyncFailed(operation, error: error, now: now) }
            let pending = (try? coordinator.allSyncOperations().count) ?? operations.count
            return error is CancellationError ? .waiting(pending) : .failed(error.localizedDescription)
        }
    }
}
