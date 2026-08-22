import Foundation
import OSLog
#if canImport(MetricKit)
import MetricKit
#endif

/// On-device MetricKit boundary.
///
/// Privacy posture: this type only ever *receives* MetricKit payloads that iOS
/// already aggregates on-device (battery, hangs, launch time, disk writes, crash
/// diagnostics, etc). It never adds identifiers, never attaches user content, and
/// never transmits anything over the network — there is no networking code in this
/// file at all. Payloads are converted to their built-in JSON representation and
/// written to a local file under Application Support, protected with
/// `.completeFileProtectionUntilFirstUserAuthentication` so the data is encrypted
/// at rest before the user's first unlock after a reboot. A hard cap on the number
/// of stored files keeps disk usage bounded; oldest files are pruned first. Callers
/// (a later wiring task) are expected to surface list/export/delete through
/// Settings/diagnostics UI, gated behind an explicit user opt-in — this type itself
/// does not decide whether collection is enabled.
final class MetricsCollector: NSObject {
    static let shared = MetricsCollector()

    /// Maximum number of stored payload files (metrics + diagnostics combined).
    /// Oldest files beyond this cap are deleted as new ones arrive.
    static let maximumStoredFiles = 30

    private let logger = Observability.logger(.data)
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.pak.fuel.metricscollector", qos: .utility)

    private lazy var storageDirectory: URL? = {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("Metrics", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
        } catch {
            Observability.log(error, category: .data, message: "Failed to create metrics storage directory")
            return nil
        }
        return directory
    }()

    private override init() {
        super.init()
    }

    /// Begins receiving MetricKit callbacks. Safe to call multiple times; MetricKit
    /// de-duplicates subscribers internally. No-op on platforms without MetricKit.
    func start() {
        #if canImport(MetricKit)
        if #available(iOS 13.0, *) {
            MXMetricManager.shared.add(self)
        }
        #endif
    }

    func stop() {
        #if canImport(MetricKit)
        if #available(iOS 13.0, *) {
            MXMetricManager.shared.remove(self)
        }
        #endif
    }

    // MARK: - Storage

    /// Metadata describing a stored payload file, for use by list/export UI.
    struct StoredPayload: Identifiable, Sendable {
        var id: String { fileName }
        let fileName: String
        let url: URL
        let createdAt: Date
        let kind: Kind

        enum Kind: String, Sendable {
            case metric
            case diagnostic
        }
    }

    /// Lists currently stored payload summaries, newest first.
    func listStoredPayloads() -> [StoredPayload] {
        guard let directory = storageDirectory else { return [] }
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.compactMap { url -> StoredPayload? in
            let name = url.lastPathComponent
            let kind: StoredPayload.Kind = name.hasPrefix("diagnostic-") ? .diagnostic : .metric
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return StoredPayload(fileName: name, url: url, createdAt: created, kind: kind)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Returns the raw JSON data for a stored payload, for export/share sheets.
    func exportPayload(_ payload: StoredPayload) -> Data? {
        try? Data(contentsOf: payload.url)
    }

    /// Deletes a single stored payload.
    func deletePayload(_ payload: StoredPayload) {
        try? fileManager.removeItem(at: payload.url)
    }

    /// Deletes all stored payloads.
    func deleteAllPayloads() {
        for payload in listStoredPayloads() {
            deletePayload(payload)
        }
    }

    private func persist(jsonData: Data, kind: StoredPayload.Kind) {
        queue.async { [weak self] in
            guard let self, let directory = self.storageDirectory else { return }
            let prefix = kind == .diagnostic ? "diagnostic" : "metric"
            let fileName = "\(prefix)-\(UUID().uuidString).json"
            let url = directory.appendingPathComponent(fileName)
            do {
                try jsonData.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                Observability.log(error, category: .data, message: "Failed to persist MetricKit payload")
                return
            }
            self.enforceStorageCap(in: directory)
        }
    }

    private func enforceStorageCap(in directory: URL) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        guard contents.count > Self.maximumStoredFiles else { return }
        let sorted = contents.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return lhsDate < rhsDate
        }
        let overflow = sorted.count - Self.maximumStoredFiles
        for url in sorted.prefix(overflow) {
            try? fileManager.removeItem(at: url)
        }
    }
}

#if canImport(MetricKit)
extension MetricsCollector: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            persist(jsonData: payload.jsonRepresentation(), kind: .metric)
        }
        logger.info("Received \(payloads.count, privacy: .public) MetricKit metric payload(s)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persist(jsonData: payload.jsonRepresentation(), kind: .diagnostic)
        }
        logger.info("Received \(payloads.count, privacy: .public) MetricKit diagnostic payload(s)")
    }
}
#endif
