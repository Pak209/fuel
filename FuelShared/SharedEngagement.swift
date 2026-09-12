import AppIntents
import Darwin
import Foundation
import WidgetKit

struct SharedDailySummary: Codable, Hashable, Sendable {
    var healthScore: Int?
    var caloriesRemaining: Int
    var proteinRemainingGrams: Int
    var hydrationMilliliters: Int
    var hydrationTargetMilliliters: Int
    var lastUpdated: Date

    static let empty = SharedDailySummary(
        healthScore: nil,
        caloriesRemaining: 0,
        proteinRemainingGrams: 0,
        hydrationMilliliters: 0,
        hydrationTargetMilliliters: 2_000,
        lastUpdated: .distantPast
    )
}

struct PendingHydrationCommand: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var amountMilliliters: Int
    var createdAt: Date

    init(id: UUID = UUID(), amountMilliliters: Int, createdAt: Date = .now) {
        self.id = id
        self.amountMilliliters = amountMilliliters
        self.createdAt = createdAt
    }
}

enum SharedHydrationQueueError: LocalizedError, Equatable, Sendable {
    case invalidAmount
    case queueFull
    case corruptedQueue
    case storageUnavailable
    case queueBusy

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "Add between 50 and 2,000 milliliters."
        case .queueFull: "Fuel already has several water entries waiting. Open the app to finish saving them, then try again."
        case .corruptedQueue: "Fuel could not safely read the waiting water entries. Open the app to repair them."
        case .storageUnavailable: "Fuel could not save this water entry. Open the app and try again."
        case .queueBusy: "Fuel is saving another water entry. Try again in a moment."
        }
    }
}

enum FuelSharedStore {
    static let appGroupIdentifier = "group.com.pak.fuel"
    static let minimumHydrationAmount = 50
    static let maximumHydrationAmount = 2_000
    static let maximumPendingHydrationCommands = 64
    static let hydrationDrainBatchSize = 16
    private static let maximumSummaryHydration = 100_000
    private static let summaryKey = "widget.daily-summary.v1"
    private static let routeKey = "engagement.pending-route.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func hydrationQueue() throws -> SharedHydrationFileQueue {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SharedHydrationQueueError.storageUnavailable
        }
        return SharedHydrationFileQueue(
            directory: container.appendingPathComponent("HydrationQueue", isDirectory: true),
            legacyDefaultsSuite: appGroupIdentifier
        )
    }

    static func loadSummary() -> SharedDailySummary {
        guard let data = defaults.data(forKey: summaryKey),
              let value = try? JSONDecoder().decode(SharedDailySummary.self, from: data) else {
            return .empty
        }
        return value
    }

    static func saveSummary(_ summary: SharedDailySummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: summaryKey)
    }

    @discardableResult
    static func enqueueHydration(amountMilliliters: Int) throws -> PendingHydrationCommand {
        let command = try hydrationQueue().enqueue(amountMilliliters: amountMilliliters)

        var summary = loadSummary()
        let safeCurrent = (0...maximumSummaryHydration).contains(summary.hydrationMilliliters)
            ? summary.hydrationMilliliters
            : 0
        summary.hydrationMilliliters = min(
            safeCurrent + command.amountMilliliters,
            maximumSummaryHydration
        )
        summary.lastUpdated = .now
        saveSummary(summary)
        return command
    }

    static func pendingHydrationCommands(limit: Int? = nil) throws -> [PendingHydrationCommand] {
        let commands = try hydrationQueue().pending()
        guard let limit else { return commands }
        return Array(commands.prefix(max(0, limit)))
    }

    static func acknowledgeHydrationCommands(ids: Set<UUID>) throws {
        try hydrationQueue().acknowledge(ids: ids)
    }

    static func repairCorruptHydrationCommands() throws -> Bool {
        try hydrationQueue().repairIfCorrupt()
    }

    static func enqueueRoute(_ url: URL) {
        defaults.set(url.absoluteString, forKey: routeKey)
    }

    static func consumeRoute() -> URL? {
        guard let value = defaults.string(forKey: routeKey) else { return nil }
        defaults.removeObject(forKey: routeKey)
        return URL(string: value)
    }

    static func clearEngagementData() throws {
        try hydrationQueue().clear()
        defaults.removeObject(forKey: summaryKey)
        defaults.removeObject(forKey: routeKey)
    }
}

/// Each transaction opens the same stable lock file, so app and extension processes
/// cannot overwrite each other's read/modify/write operations. The lock file is never
/// replaced or unlinked. Only the data file is replaced atomically; process termination
/// releases the descriptor lock automatically.
struct SharedHydrationFileQueue: Sendable {
    let directory: URL
    var legacyDefaultsSuite: String? = nil
    private let maximumBytes = 1_000_000
    private let maximumLegacyCommands = 512
    private let legacyKey = "engagement.hydration-queue.v1"
    private var dataURL: URL { directory.appendingPathComponent("commands-v2.json") }

    func enqueue(amountMilliliters: Int) throws -> PendingHydrationCommand {
        guard (FuelSharedStore.minimumHydrationAmount...FuelSharedStore.maximumHydrationAmount).contains(amountMilliliters) else {
            throw SharedHydrationQueueError.invalidAmount
        }
        return try withLock {
            var commands = try read()
            guard commands.count < FuelSharedStore.maximumPendingHydrationCommands else {
                throw SharedHydrationQueueError.queueFull
            }
            let command = PendingHydrationCommand(amountMilliliters: amountMilliliters)
            commands.append(command)
            try write(commands)
            return command
        }
    }

    func pending() throws -> [PendingHydrationCommand] {
        try withLock { try read() }
    }

    func acknowledge(ids: Set<UUID>) throws {
        try withLock {
            // Re-read while locked; commands enqueued since the consumer's snapshot survive.
            try write(read().filter { !ids.contains($0.id) })
        }
    }

    func clear() throws {
        try withLock { try write([]) }
    }

    func repairIfCorrupt() throws -> Bool {
        try withLock {
            do {
                _ = try read()
                return false
            } catch SharedHydrationQueueError.corruptedQueue {
                try write([])
                return true
            }
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let descriptor = open(directory.appendingPathComponent("queue.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SharedHydrationQueueError.storageUnavailable }
        defer { close(descriptor) }
        // A suspended extension may retain its descriptor. Never wait indefinitely
        // on the app's main actor; a busy queue reports failure without losing data.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EINTR || code == EWOULDBLOCK else { throw SharedHydrationQueueError.storageUnavailable }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SharedHydrationQueueError.queueBusy }
            usleep(1_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func read() throws -> [PendingHydrationCommand] {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: dataURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
                throw SharedHydrationQueueError.corruptedQueue
            }
            data = try Data(contentsOf: dataURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            let legacyData = legacyDefaultsSuite.flatMap { UserDefaults(suiteName: $0)?.data(forKey: legacyKey) }
            let commands = try legacyData.map(decode) ?? []
            // An empty canonical file is also a migration marker. Keeping it prevents
            // stale preferences from resurrecting acknowledged commands after a crash.
            try write(commands)
            return commands
        }
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> [PendingHydrationCommand] {
        guard data.count <= maximumBytes,
              let commands = try? JSONDecoder().decode([PendingHydrationCommand].self, from: data),
              commands.count <= maximumLegacyCommands,
              Set(commands.map(\.id)).count == commands.count else {
            throw SharedHydrationQueueError.corruptedQueue
        }
        return commands
    }

    private func write(_ commands: [PendingHydrationCommand]) throws {
        let data = try JSONEncoder().encode(commands)
        try data.write(to: dataURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let legacyDefaultsSuite {
            UserDefaults(suiteName: legacyDefaultsSuite)?.removeObject(forKey: legacyKey)
        }
    }
}

struct AddWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Water"
    static let description = IntentDescription("Add water to today’s Fuel hydration total.")

    @Parameter(title: "Amount in milliliters", default: 250, inclusiveRange: (50, 2_000))
    var amountMilliliters: Int

    init() {}

    init(amountMilliliters: Int) {
        self.amountMilliliters = amountMilliliters
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = try FuelSharedStore.enqueueHydration(amountMilliliters: amountMilliliters)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Added \(command.amountMilliliters) milliliters of water.")
    }
}

struct OpenMealLoggerIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Meal"
    static let description = IntentDescription("Open Fuel’s meal photo picker and editor.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        FuelSharedStore.enqueueRoute(URL(string: "fuel://scan")!)
        return .result()
    }
}

struct FuelAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMealLoggerIntent(),
            phrases: [
                "Log a meal with \(.applicationName)",
                "Scan food with \(.applicationName)"
            ],
            shortTitle: "Log Meal",
            systemImageName: "photo.on.rectangle"
        )
        AppShortcut(
            intent: AddWaterIntent(),
            phrases: [
                "Add water with \(.applicationName)",
                "Track hydration in \(.applicationName)"
            ],
            shortTitle: "Add Water",
            systemImageName: "drop.fill"
        )
    }
}
