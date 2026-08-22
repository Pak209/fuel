import Foundation
import UserNotifications

enum ReminderKind: String, CaseIterable, Codable, Hashable, Sendable {
    case breakfast
    case lunch
    case dinner
    case hydration
    case dailyReview
    case weeklySummary
    case healthConnection
    case goalProgress
}

struct PlannedReminder: Hashable, Sendable {
    var identifier: String
    var kind: ReminderKind
    var title: String
    var body: String
    var dateComponents: DateComponents
    var deepLink: URL

    var repeats: Bool { kind != .healthConnection }
}

struct ReminderPlanner: Sendable {
    func recurringReminders(for preferences: UserPreferences) -> [PlannedReminder] {
        var reminders: [PlannedReminder] = []

        if preferences.mealRemindersEnabled {
            let kinds: [ReminderKind] = [.breakfast, .lunch, .dinner]
            let copy = [
                ("Breakfast when it works for you", "A quick log now can make today’s summary more useful."),
                ("A quick lunch check-in", "Log what you ate, or come back later—either works."),
                ("Dinner check-in", "Add dinner when you have a moment. Estimates are always editable.")
            ]
            for (index, hour) in preferences.mealReminderHours.prefix(3).enumerated() {
                let adjusted = allowedHour(hour, preferences: preferences)
                reminders.append(.init(
                    identifier: "fuel.reminder.meal.\(index)",
                    kind: kinds[index],
                    title: copy[index].0,
                    body: copy[index].1,
                    dateComponents: DateComponents(hour: adjusted, minute: 0),
                    deepLink: URL(string: "fuel://scan")!
                ))
            }
        }

        if preferences.hydrationRemindersEnabled {
            let interval = min(max(preferences.hydrationReminderIntervalHours, 1), 8)
            for hour in daylightHours(preferences: preferences).enumerated().compactMap({ index, hour in
                index.isMultiple(of: interval) ? hour : nil
            }) {
                reminders.append(.init(
                    identifier: "fuel.reminder.hydration.\(hour)",
                    kind: .hydration,
                    title: "Hydration check-in",
                    body: "If you’ve had some water, you can add it with one tap.",
                    dateComponents: DateComponents(hour: hour, minute: 0),
                    deepLink: URL(string: "fuel://today/water")!
                ))
            }
        }

        if preferences.dailyReviewEnabled {
            reminders.append(.init(
                identifier: "fuel.reminder.review.daily",
                kind: .dailyReview,
                title: "Your day at a glance",
                body: "Review what’s logged and fill any gaps only if it’s useful to you.",
                dateComponents: DateComponents(hour: allowedHour(preferences.dailyReviewHour, preferences: preferences), minute: 0),
                deepLink: URL(string: "fuel://today")!
            ))
        }

        if preferences.weeklySummaryEnabled {
            reminders.append(.init(
                identifier: "fuel.reminder.summary.weekly",
                kind: .weeklySummary,
                title: "Your weekly Fuel summary is ready",
                body: "See patterns from the days you logged—missing days are left out, not judged.",
                dateComponents: DateComponents(
                    hour: allowedHour(preferences.weeklySummaryHour, preferences: preferences),
                    minute: 0,
                    weekday: min(max(preferences.weeklySummaryWeekday, 1), 7)
                ),
                deepLink: URL(string: "fuel://insights")!
            ))
        }

        if preferences.goalProgressRemindersEnabled {
            reminders.append(.init(
                identifier: "fuel.reminder.progress.daily",
                kind: .goalProgress,
                title: "A gentle progress check",
                body: "Open Fuel if you’d like to see what remains today. Targets are guides, not grades.",
                dateComponents: DateComponents(hour: allowedHour(17, preferences: preferences), minute: 0),
                deepLink: URL(string: "fuel://today")!
            ))
        }

        return deduplicated(reminders)
    }

    func healthConnectionReminder() -> PlannedReminder {
        .init(
            identifier: "fuel.reminder.health.connection",
            kind: .healthConnection,
            title: "Apple Health needs a check",
            body: "Fuel hasn’t received recent activity or sleep data. Your nutrition log still works normally.",
            dateComponents: .init(),
            deepLink: URL(string: "fuel://profile/health")!
        )
    }

    func isQuiet(hour: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    private func allowedHour(_ proposedHour: Int, preferences: UserPreferences) -> Int {
        let hour = min(max(proposedHour, 0), 23)
        return isQuiet(hour: hour, start: preferences.quietHoursStart, end: preferences.quietHoursEnd)
            ? min(max(preferences.quietHoursEnd, 0), 23)
            : hour
    }

    private func daylightHours(preferences: UserPreferences) -> [Int] {
        (0..<24).filter {
            !isQuiet(hour: $0, start: preferences.quietHoursStart, end: preferences.quietHoursEnd)
                && $0 >= 8
                && $0 <= 20
        }
    }

    private func deduplicated(_ reminders: [PlannedReminder]) -> [PlannedReminder] {
        var seen = Set<String>()
        return reminders.filter {
            let key = "\($0.kind.rawValue)-\($0.dateComponents.weekday ?? 0)-\($0.dateComponents.hour ?? -1)"
            return seen.insert(key).inserted
        }
    }
}

enum NotificationAuthorizationState: String, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

enum NotificationSchedulingError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Notifications are off for Fuel. You can enable them in iOS Settings."
        }
    }
}

protocol NotificationScheduling: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func apply(preferences: UserPreferences, requestingAuthorization: Bool) async throws
    func scheduleHealthConnectionIssue(ifEnabled preferences: UserPreferences) async throws
    func removeAllFuelNotifications() async
}

actor LocalNotificationScheduler: NotificationScheduling {
    static let reminderPrefix = "fuel.reminder."
    private let center: UNUserNotificationCenter
    private let planner: ReminderPlanner

    init(center: UNUserNotificationCenter = .current(), planner: ReminderPlanner = .init()) {
        self.center = center
        self.planner = planner
    }

    func authorizationState() async -> NotificationAuthorizationState {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .provisional, .ephemeral: .provisional
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    func apply(preferences: UserPreferences, requestingAuthorization: Bool) async throws {
        var state = await authorizationState()
        if preferences.hasEnabledReminders, state == .notDetermined, requestingAuthorization {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            state = await authorizationState()
        }

        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.reminderPrefix) && $0 != "fuel.reminder.health.connection" }
        center.removePendingNotificationRequests(withIdentifiers: existing)

        guard preferences.hasEnabledReminders else { return }
        guard state == .authorized || state == .provisional else {
            if requestingAuthorization { throw NotificationSchedulingError.permissionDenied }
            return
        }

        for reminder in planner.recurringReminders(for: preferences) {
            try await center.add(request(for: reminder))
        }
    }

    func scheduleHealthConnectionIssue(ifEnabled preferences: UserPreferences) async throws {
        guard preferences.healthConnectionAlertsEnabled else { return }
        let state = await authorizationState()
        guard state == .authorized || state == .provisional else { return }
        let reminder = planner.healthConnectionReminder()
        let content = content(for: reminder)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try await center.add(.init(identifier: reminder.identifier, content: content, trigger: trigger))
    }

    func removeAllFuelNotifications() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: pending)
    }

    private func request(for reminder: PlannedReminder) -> UNNotificationRequest {
        .init(
            identifier: reminder.identifier,
            content: content(for: reminder),
            trigger: UNCalendarNotificationTrigger(dateMatching: reminder.dateComponents, repeats: reminder.repeats)
        )
    }

    private func content(for reminder: PlannedReminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.categoryIdentifier = NotificationRouteCoordinator.categoryIdentifier(for: reminder.kind)
        content.userInfo[NotificationRouteCoordinator.deepLinkKey] = reminder.deepLink.absoluteString
        return content
    }
}
