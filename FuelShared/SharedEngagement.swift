import AppIntents
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

enum FuelSharedStore {
    static let appGroupIdentifier = "group.com.pak.fuel"
    private static let summaryKey = "widget.daily-summary.v1"
    private static let hydrationQueueKey = "engagement.hydration-queue.v1"
    private static let routeKey = "engagement.pending-route.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
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
    static func enqueueHydration(amountMilliliters: Int) -> PendingHydrationCommand {
        let command = PendingHydrationCommand(amountMilliliters: max(1, amountMilliliters))
        var commands = pendingHydrationCommands()
        commands.append(command)
        saveHydrationCommands(commands)

        var summary = loadSummary()
        summary.hydrationMilliliters += command.amountMilliliters
        summary.lastUpdated = .now
        saveSummary(summary)
        return command
    }

    static func pendingHydrationCommands() -> [PendingHydrationCommand] {
        guard let data = defaults.data(forKey: hydrationQueueKey),
              let commands = try? JSONDecoder().decode([PendingHydrationCommand].self, from: data) else {
            return []
        }
        return commands
    }

    static func acknowledgeHydrationCommands(ids: Set<UUID>) {
        saveHydrationCommands(pendingHydrationCommands().filter { !ids.contains($0.id) })
    }

    static func enqueueRoute(_ url: URL) {
        defaults.set(url.absoluteString, forKey: routeKey)
    }

    static func consumeRoute() -> URL? {
        guard let value = defaults.string(forKey: routeKey) else { return nil }
        defaults.removeObject(forKey: routeKey)
        return URL(string: value)
    }

    static func clearEngagementData() {
        defaults.removeObject(forKey: summaryKey)
        defaults.removeObject(forKey: hydrationQueueKey)
        defaults.removeObject(forKey: routeKey)
    }

    private static func saveHydrationCommands(_ commands: [PendingHydrationCommand]) {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: hydrationQueueKey)
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
        let command = FuelSharedStore.enqueueHydration(amountMilliliters: amountMilliliters)
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
