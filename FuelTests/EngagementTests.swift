import Foundation
import Darwin
import SwiftData
import Testing
@testable import Fuel

// MARK: - ReminderPlanner + AppRoute (pure, no shared state)

struct EngagementTests {
    private let planner = ReminderPlanner()

    // MARK: ReminderPlanner — enabled/disabled kinds

    @Test func noRemindersWhenAllReminderKindsAreDisabled() {
        let reminders = planner.recurringReminders(for: UserPreferences())
        #expect(reminders.isEmpty)
    }

    @Test func mealRemindersEnabledProducesBreakfastLunchDinnerAtConfiguredHours() {
        var preferences = UserPreferences()
        preferences.mealRemindersEnabled = true
        preferences.mealReminderHours = [7, 13, 19]
        preferences.quietHoursStart = 0
        preferences.quietHoursEnd = 0

        let reminders = planner.recurringReminders(for: preferences)

        #expect(reminders.count == 3)
        #expect(reminders.map(\.kind) == [.breakfast, .lunch, .dinner])
        #expect(reminders.compactMap { $0.dateComponents.hour } == [7, 13, 19])
        #expect(reminders.allSatisfy { $0.deepLink == URL(string: "fuel://scan")! })
        #expect(reminders.map(\.identifier) == ["fuel.reminder.meal.0", "fuel.reminder.meal.1", "fuel.reminder.meal.2"])
    }

    @Test func hydrationRemindersEnabledProducesOneReminderPerIntervalStepInDaylightWindow() {
        var preferences = UserPreferences()
        preferences.hydrationRemindersEnabled = true
        preferences.hydrationReminderIntervalHours = 4
        preferences.quietHoursStart = 0
        preferences.quietHoursEnd = 0

        let reminders = planner.recurringReminders(for: preferences)

        #expect(reminders.allSatisfy { $0.kind == .hydration })
        #expect(reminders.allSatisfy { $0.deepLink == URL(string: "fuel://today/water")! })
        #expect(reminders.compactMap { $0.dateComponents.hour }.sorted() == [8, 12, 16, 20])
    }

    @Test func hydrationRemindersRespectQuietHoursWithinTheDaylightWindow() {
        var preferences = UserPreferences()
        preferences.hydrationRemindersEnabled = true
        preferences.hydrationReminderIntervalHours = 1
        preferences.quietHoursStart = 9
        preferences.quietHoursEnd = 17

        let reminders = planner.recurringReminders(for: preferences)
        let hours = reminders.compactMap { $0.dateComponents.hour }.sorted()

        #expect(hours == [8, 17, 18, 19, 20])
        #expect(!hours.contains { $0 >= 9 && $0 < 17 })
    }

    @Test func dailyReviewWeeklySummaryAndGoalProgressUseTheirConfiguredSchedule() {
        var preferences = UserPreferences()
        preferences.dailyReviewEnabled = true
        preferences.dailyReviewHour = 16
        preferences.weeklySummaryEnabled = true
        preferences.weeklySummaryWeekday = 3
        preferences.weeklySummaryHour = 9
        preferences.goalProgressRemindersEnabled = true
        preferences.quietHoursStart = 0
        preferences.quietHoursEnd = 0

        let reminders = planner.recurringReminders(for: preferences)

        #expect(reminders.count == 3)
        let dailyReview = reminders.first { $0.kind == .dailyReview }
        #expect(dailyReview?.dateComponents.hour == 16)
        let weeklySummary = reminders.first { $0.kind == .weeklySummary }
        #expect(weeklySummary?.dateComponents.hour == 9)
        #expect(weeklySummary?.dateComponents.weekday == 3)
        let goalProgress = reminders.first { $0.kind == .goalProgress }
        #expect(goalProgress?.dateComponents.hour == 17)
    }

    // MARK: Quiet hours push proposed hours into the allowed window

    @Test func quietHoursPushAProposedHourToTheAllowedWindowStandardRange() {
        var preferences = UserPreferences()
        preferences.dailyReviewEnabled = true
        preferences.dailyReviewHour = 3
        preferences.goalProgressRemindersEnabled = true
        preferences.quietHoursStart = 1
        preferences.quietHoursEnd = 5

        let reminders = planner.recurringReminders(for: preferences)

        // 3 falls inside [1, 5) and is pushed to the quiet-hours end.
        #expect(reminders.first { $0.kind == .dailyReview }?.dateComponents.hour == 5)
        // 17 is outside [1, 5) and is left untouched.
        #expect(reminders.first { $0.kind == .goalProgress }?.dateComponents.hour == 17)
    }

    @Test func quietHoursPushAProposedHourToTheAllowedWindowAcrossMidnightWrapAround() {
        func adjustedDailyReviewHour(hour: Int) -> Int? {
            var preferences = UserPreferences()
            preferences.dailyReviewEnabled = true
            preferences.dailyReviewHour = hour
            preferences.quietHoursStart = 22
            preferences.quietHoursEnd = 6
            return planner.recurringReminders(for: preferences).first { $0.kind == .dailyReview }?.dateComponents.hour
        }

        // Inside the wrap-around window (>= start, or < end): pushed to the end hour.
        #expect(adjustedDailyReviewHour(hour: 23) == 6)
        #expect(adjustedDailyReviewHour(hour: 0) == 6)
        #expect(adjustedDailyReviewHour(hour: 22) == 6) // inclusive start boundary
        // Outside the wrap-around window: left untouched.
        #expect(adjustedDailyReviewHour(hour: 6) == 6) // exclusive end boundary — 6 itself is allowed and equals the pushed value coincidentally
        #expect(adjustedDailyReviewHour(hour: 21) == 21) // just before the quiet window starts
        #expect(adjustedDailyReviewHour(hour: 7) == 7) // clearly inside the allowed daytime window
    }

    // MARK: isQuiet boundaries
    //
    // The health-connection deferral decision (`LocalNotificationScheduler.scheduleHealthConnectionIssue`)
    // compares the current hour against `quietHoursStart`/`quietHoursEnd` via this exact function, then —
    // only when quiet — schedules a `UNCalendarNotificationTrigger` at `quietHoursEnd` instead of firing
    // immediately. That scheduler is an actor built around the concrete `UNUserNotificationCenter` class
    // (no protocol seam), so it can't be driven from a deterministic unit test. What we *can* pin down is
    // the pure boundary semantics the scheduler relies on for that decision, exercised here directly.
    @Test func isQuietBoundariesForStandardAndWrapAroundRangesAndTheNoQuietWindowCase() {
        // start == end means quiet hours are disabled entirely.
        #expect(planner.isQuiet(hour: 12, start: 9, end: 9) == false)

        // Standard range (start < end): inclusive start, exclusive end.
        #expect(planner.isQuiet(hour: 9, start: 9, end: 17) == true)
        #expect(planner.isQuiet(hour: 16, start: 9, end: 17) == true)
        #expect(planner.isQuiet(hour: 17, start: 9, end: 17) == false)
        #expect(planner.isQuiet(hour: 8, start: 9, end: 17) == false)

        // Wrap-around range (start > end), e.g. the default 21:00–07:00 quiet window shape.
        #expect(planner.isQuiet(hour: 22, start: 22, end: 6) == true)
        #expect(planner.isQuiet(hour: 23, start: 22, end: 6) == true)
        #expect(planner.isQuiet(hour: 0, start: 22, end: 6) == true)
        #expect(planner.isQuiet(hour: 5, start: 22, end: 6) == true)
        #expect(planner.isQuiet(hour: 6, start: 22, end: 6) == false)
        #expect(planner.isQuiet(hour: 21, start: 22, end: 6) == false)
    }

    // MARK: Deduplication
    //
    // `recurringReminders` keys deduplication on (kind, weekday, hour). Every reminder kind is emitted by
    // exactly one code path, and within that path (meal reminders, hydration reminders) the hours produced
    // are always distinct, so a literal same-kind collision can't currently be constructed through public
    // preferences. This test instead locks down the invariant dedup guarantees: even when quiet hours
    // collapse nearly every proposed hour onto the same allowed hour, reminders of different kinds are
    // still all preserved (never accidentally merged into each other) and no two reminders in the result
    // ever share an identical (kind, weekday, hour) key.
    @Test func deduplicationPreservesDistinctKindsAndNeverEmitsAnIdenticalKindWeekdayHourPair() {
        var preferences = UserPreferences()
        preferences.mealRemindersEnabled = true
        preferences.mealReminderHours = [1, 2, 3]
        preferences.hydrationRemindersEnabled = true
        preferences.dailyReviewEnabled = true
        preferences.dailyReviewHour = 4
        preferences.weeklySummaryEnabled = true
        preferences.weeklySummaryHour = 5
        preferences.weeklySummaryWeekday = 2
        preferences.goalProgressRemindersEnabled = true
        preferences.quietHoursStart = 0
        preferences.quietHoursEnd = 23 // quiets every hour except 23, collapsing almost everything

        let reminders = planner.recurringReminders(for: preferences)

        // Hydration's daylight window (8...20) is entirely quiet under this configuration, so it
        // contributes nothing; the other 6 kinds all survive, each collapsed onto hour 23.
        #expect(reminders.count == 6)
        #expect(Set(reminders.map(\.kind)).count == 6)
        #expect(reminders.allSatisfy { $0.dateComponents.hour == 23 })

        var seenKeys = Set<String>()
        for reminder in reminders {
            let key = "\(reminder.kind.rawValue)-\(reminder.dateComponents.weekday ?? 0)-\(reminder.dateComponents.hour ?? -1)"
            #expect(seenKeys.insert(key).inserted, "Unexpected duplicate reminder key: \(key)")
        }
    }

    // MARK: Copy tone

    @Test func reminderCopyAvoidsShamingLanguage() throws {
        var preferences = UserPreferences()
        preferences.mealRemindersEnabled = true
        preferences.hydrationRemindersEnabled = true
        preferences.dailyReviewEnabled = true
        preferences.weeklySummaryEnabled = true
        preferences.goalProgressRemindersEnabled = true

        let reminders = planner.recurringReminders(for: preferences)

        let breakfast = try #require(reminders.first { $0.kind == .breakfast })
        #expect(breakfast.title == "Breakfast when it works for you")
        let dinner = try #require(reminders.first { $0.kind == .dinner })
        #expect(dinner.title == "Dinner check-in")
        #expect(dinner.body == "Add dinner when you have a moment. Estimates are always editable.")

        let shamingPhrases = ["you should have", "you failed", "you missed", "bad job", "you're behind", "guilt", "shame on", "lazy", "you didn't"]
        let allCopy = reminders.map { "\($0.title) \($0.body)" }.joined(separator: " ").lowercased()
        for phrase in shamingPhrases {
            #expect(!allCopy.contains(phrase), "Reminder copy unexpectedly contains shaming phrase: \(phrase)")
        }
    }

    @Test func healthConnectionReminderHasAStableIdentifierDeepLinkAndDoesNotRepeat() {
        let reminder = planner.healthConnectionReminder()

        #expect(reminder.identifier == "fuel.reminder.health.connection")
        #expect(reminder.kind == .healthConnection)
        #expect(reminder.deepLink == URL(string: "fuel://profile/health")!)
        #expect(reminder.repeats == false)
    }

    // MARK: AppRoute(url:)

    @Test func appRouteParsesEverySupportedDeepLink() {
        #expect(AppRoute(url: URL(string: "fuel://today")!) == .today)
        #expect(AppRoute(url: URL(string: "fuel://today/water")!) == .addWater)
        #expect(AppRoute(url: URL(string: "fuel://scan")!) == .scan)
        #expect(AppRoute(url: URL(string: "fuel://insights")!) == .insights)
        #expect(AppRoute(url: URL(string: "fuel://meals")!) == .meals)
        #expect(AppRoute(url: URL(string: "fuel://profile/notifications")!) == .notificationSettings)
        #expect(AppRoute(url: URL(string: "fuel://profile/health")!) == .healthConnection)
    }

    @Test func appRouteReturnsNilForWrongSchemeUnknownHostOrMalformedPaths() {
        #expect(AppRoute(url: URL(string: "https://today")!) == nil)
        #expect(AppRoute(url: URL(string: "fuel://unknown")!) == nil)
        #expect(AppRoute(url: URL(string: "fuel:///")!) == nil)
        #expect(AppRoute(url: URL(string: "fuel://profile/unknown")!) == nil)
        #expect(AppRoute(url: URL(string: "fuel://today/extra/segments")!) == nil)
    }

    @Test func appRouteParsingIsCaseInsensitiveForSchemeHostAndPath() {
        #expect(AppRoute(url: URL(string: "FUEL://TODAY")!) == .today)
        #expect(AppRoute(url: URL(string: "Fuel://Profile/Health")!) == .healthConnection)
        #expect(AppRoute(url: URL(string: "fuel://SCAN")!) == .scan)
    }

    @Test func appRouteIgnoresQueryParametersWhenMatchingTheWaterDeepLink() {
        #expect(AppRoute(url: URL(string: "fuel://today/water?add=250")!) == .addWater)
    }

    @Test func notificationQuickAddRequiresTheExpectedActionCategoryAndReminderIdentifier() {
        let isAuthorized = NotificationRouteCoordinator.authorizesQuickAddWater

        #expect(isAuthorized(
            NotificationRouteCoordinator.quickAddWaterAction,
            NotificationRouteCoordinator.hydrationCategory,
            "fuel.reminder.hydration.12"
        ))
        #expect(!isAuthorized(
            NotificationRouteCoordinator.quickAddWaterAction,
            "fuel.category.open",
            "fuel.reminder.hydration.12"
        ))
        #expect(!isAuthorized(
            NotificationRouteCoordinator.openAction,
            NotificationRouteCoordinator.hydrationCategory,
            "fuel.reminder.hydration.12"
        ))
        #expect(!isAuthorized(
            NotificationRouteCoordinator.quickAddWaterAction,
            NotificationRouteCoordinator.hydrationCategory,
            "fuel.reminder.health.connection"
        ))
        #expect(!isAuthorized(
            NotificationRouteCoordinator.quickAddWaterAction,
            NotificationRouteCoordinator.hydrationCategory,
            "fuel.reminder.hydration.not-an-hour"
        ))
        #expect(!isAuthorized(
            NotificationRouteCoordinator.quickAddWaterAction,
            NotificationRouteCoordinator.hydrationCategory,
            "fuel.reminder.hydration.24"
        ))
    }
}

struct HydrationFileQueueTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FuelQueueTest-\(UUID().uuidString)")
    }

    @Test func simultaneousWritersPreserveEveryAcceptedCommandAfterReopening() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            do {
                let queue = SharedHydrationFileQueue(directory: directory)
                _ = try queue.enqueue(amountMilliliters: 50 + index)
            } catch { Issue.record(error) }
        }
        let saved = try SharedHydrationFileQueue(directory: directory).pending()
        #expect(saved.count == 48)
        #expect(Set(saved.map(\.id)).count == 48)
        #expect(Set(saved.map(\.amountMilliliters)) == Set(50..<98))
    }

    @Test func concurrentAcknowledgementsNeverEraseNewEntries() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SharedHydrationFileQueue(directory: directory)
        let old = try (0..<16).map { _ in try queue.enqueue(amountMilliliters: 100) }
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                let otherHandle = SharedHydrationFileQueue(directory: directory)
                if index < 16 {
                    try otherHandle.acknowledge(ids: [old[index].id])
                } else {
                    _ = try otherHandle.enqueue(amountMilliliters: 250)
                }
            } catch { Issue.record(error) }
        }
        let remaining = try queue.pending()
        #expect(remaining.count == 16)
        #expect(remaining.allSatisfy { $0.amountMilliliters == 250 })
        #expect(Set(remaining.map(\.id)).isDisjoint(with: Set(old.map(\.id))))
    }

    @Test func concurrentWritersCannotExceedTheCapacity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.concurrentPerform(iterations: 80) { _ in
            do {
                _ = try SharedHydrationFileQueue(directory: directory).enqueue(amountMilliliters: 50)
            } catch SharedHydrationQueueError.queueFull {
                // The extra writers must fail explicitly without overwriting accepted entries.
            } catch { Issue.record(error) }
        }
        #expect(try SharedHydrationFileQueue(directory: directory).pending().count == 64)
    }

    @Test func migrationKeepsIDsAndNeverReplaysStalePreferences() throws {
        let directory = temporaryDirectory()
        let suite = "FuelQueueMigrationTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let old = PendingHydrationCommand(amountMilliliters: 250)
        let data = try JSONEncoder().encode([old])
        defaults.set(data, forKey: "engagement.hydration-queue.v1")
        let queue = SharedHydrationFileQueue(directory: directory, legacyDefaultsSuite: suite)
        #expect(try queue.pending() == [old])
        try queue.acknowledge(ids: [old.id])
        defaults.set(data, forKey: "engagement.hydration-queue.v1")
        let reopened = SharedHydrationFileQueue(directory: directory, legacyDefaultsSuite: suite)
        #expect(try reopened.pending().isEmpty)
        try reopened.clear()
        #expect(defaults.data(forKey: "engagement.hydration-queue.v1") == nil)
    }

    @Test func staleCorruptionRecoveryPreservesEntriesWrittenAfterRepair() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SharedHydrationFileQueue(directory: directory)
        try queue.clear()
        let dataURL = directory.appendingPathComponent("commands-v2.json")
        try Data("broken".utf8).write(to: dataURL)
        #expect(throws: SharedHydrationQueueError.self) { try queue.pending() }
        #expect(try queue.repairIfCorrupt())
        let command = try queue.enqueue(amountMilliliters: 250)
        #expect(try !queue.repairIfCorrupt())
        #expect(try queue.pending() == [command])
    }

    @Test func failedPersistenceNeverReportsAnAcceptedCommand() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        let queue = SharedHydrationFileQueue(directory: directory)
        #expect(throws: (any Error).self) { try queue.enqueue(amountMilliliters: 250) }
        #expect(throws: (any Error).self) { try queue.clear() }
        #expect(throws: (any Error).self) { try queue.repairIfCorrupt() }
    }

    @Test func occupiedLockTimesOutWithoutWritingAndCanBeRetried() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SharedHydrationFileQueue(directory: directory)
        try queue.clear()
        let descriptor = open(directory.appendingPathComponent("queue.lock").path, O_RDWR)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: SharedHydrationQueueError.queueBusy) {
            try queue.enqueue(amountMilliliters: 250)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        #expect(flock(descriptor, LOCK_UN) == 0)
        #expect(try queue.pending().isEmpty)
        _ = try queue.enqueue(amountMilliliters: 250)
        #expect(try queue.pending().count == 1)
    }
}

// MARK: - Shared app-group store integration (serialized to avoid cross-test resets)

@Suite(.serialized)
struct EngagementSharedStoreTests {
    @Test func hydrationQueueEnqueueThenDrainReturnsTheCommandOnceAndEmpties() throws {
        try FuelSharedStore.clearEngagementData()
        let command = try FuelSharedStore.enqueueHydration(amountMilliliters: 300)

        let drained = try drainHydrationCommands()

        #expect(drained.map(\.id) == [command.id])
        #expect(drained.first?.amountMilliliters == 300)
        #expect(try FuelSharedStore.pendingHydrationCommands().isEmpty)
        try FuelSharedStore.clearEngagementData()
    }

    @Test func hydrationQueueDrainOnAnEmptyQueueIsANoOp() throws {
        try FuelSharedStore.clearEngagementData()
        #expect(try drainHydrationCommands().isEmpty)
        #expect(try FuelSharedStore.pendingHydrationCommands().isEmpty)
    }

    @Test func hydrationQueueEnqueueAccumulatesIntoTheSharedSummary() throws {
        try FuelSharedStore.clearEngagementData()
        _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 200)
        _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 150)

        #expect(FuelSharedStore.loadSummary().hydrationMilliliters == 350)
        try FuelSharedStore.clearEngagementData()
    }

    @Test func hydrationQueueRejectsInvalidAmountsAndCapacityOverflowWithoutChangingSummary() throws {
        try FuelSharedStore.clearEngagementData()
        #expect(throws: SharedHydrationQueueError.self) {
            _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 49)
        }
        #expect(throws: SharedHydrationQueueError.self) {
            _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 2_001)
        }
        for _ in 0..<FuelSharedStore.maximumPendingHydrationCommands {
            _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 50)
        }
        let before = FuelSharedStore.loadSummary()
        #expect(throws: SharedHydrationQueueError.self) {
            _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 50)
        }
        #expect(FuelSharedStore.loadSummary() == before)
        try FuelSharedStore.clearEngagementData()
    }

    @Test func corruptSummaryArithmeticCannotOverflowDuringAValidEnqueue() throws {
        try FuelSharedStore.clearEngagementData()
        FuelSharedStore.saveSummary(.init(
            healthScore: nil,
            caloriesRemaining: 0,
            proteinRemainingGrams: 0,
            hydrationMilliliters: .max,
            hydrationTargetMilliliters: 2_000,
            lastUpdated: .now
        ))
        _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 250)
        #expect(FuelSharedStore.loadSummary().hydrationMilliliters == 250)
        try FuelSharedStore.clearEngagementData()
    }

    @Test @MainActor func appLoadDrainsMoreThanOneBatchWithoutStrandingCommands() async throws {
        try FuelSharedStore.clearEngagementData()
        defer { try? FuelSharedStore.clearEngagementData() }
        for _ in 0..<(FuelSharedStore.hydrationDrainBatchSize + 1) {
            _ = try FuelSharedStore.enqueueHydration(amountMilliliters: 50)
        }
        let container = try makeInMemoryContainer()
        let state = AppState(healthService: MockHealthDataService())
        state.configure(context: container.mainContext)

        await state.loadInitialData()

        #expect(try FuelSharedStore.pendingHydrationCommands().isEmpty)
        let entries = try container.mainContext.fetch(FetchDescriptor<HydrationEntry>())
        #expect(entries.count == FuelSharedStore.hydrationDrainBatchSize + 1)
        #expect(entries.reduce(0) { $0 + Int($1.amountMilliliters) } == 850)
        #expect(FuelSharedStore.loadSummary().hydrationMilliliters == 850)
    }

    @Test func consumeRouteReturnsTheEnqueuedURLOnceThenNil() throws {
        try FuelSharedStore.clearEngagementData()
        #expect(FuelSharedStore.consumeRoute() == nil)

        let url = URL(string: "fuel://scan")!
        FuelSharedStore.enqueueRoute(url)

        #expect(FuelSharedStore.consumeRoute() == url)
        #expect(FuelSharedStore.consumeRoute() == nil)
    }

    /// `FuelSharedStore` has no single atomic "drain" call; the production hydration-sync path reads
    /// `pendingHydrationCommands()` and then acknowledges the ids it processed. This mirrors that pairing.
    private func drainHydrationCommands() throws -> [PendingHydrationCommand] {
        let commands = try FuelSharedStore.pendingHydrationCommands()
        try FuelSharedStore.acknowledgeHydrationCommands(ids: Set(commands.map(\.id)))
        return commands
    }
}

// MARK: - Offline queue behavior with an in-memory ModelContainer

private enum EngagementTestError: Error { case simulated }

@MainActor
private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: FuelSchemaV3.self)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

struct EngagementOfflineQueueTests {
    @Test @MainActor func publicWaterRoutesNavigateWithoutMutatingHydration() async throws {
        let container = try makeInMemoryContainer()
        let state = AppState(healthService: MockHealthDataService())
        state.configure(context: container.mainContext)
        let urls = [
            "fuel://today/water",
            "fuel://today/water?add",
            "fuel://today/water?add=0",
            "fuel://today/water?add=bogus",
            "FUEL://TODAY/WATER?add=250",
            "fuel:///today/water?%61dd=250"
        ]

        for value in urls {
            await state.handle(try #require(URL(string: value)))
        }

        let records = try container.mainContext.fetch(FetchDescriptor<HydrationEntry>())
        #expect(records.isEmpty)
        #expect(state.selectedTab == .today)
        #expect(state.presentedRoute == .addWater)
    }

    @Test @MainActor func trustedNotificationQuickAddPersistsExactlyTwoHundredFiftyMilliliters() async throws {
        let container = try makeInMemoryContainer()
        let state = AppState(healthService: MockHealthDataService())
        state.configure(context: container.mainContext)

        await state.handleNotificationQuickAddWater()

        let records = try container.mainContext.fetch(FetchDescriptor<HydrationEntry>())
        #expect(records.count == 1)
        #expect(records.first?.amountMilliliters == 250)
        #expect(state.selectedTab == .today)
        #expect(state.presentedRoute == nil)
    }

    @Test @MainActor func queueRecognitionCreatesADurablePendingRecordAndStoresThePhoto() async throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let imageData = testMealImageData()

        let record = try await coordinator.queueRecognition(imageData: imageData)

        #expect(record.state == .pending)
        #expect(record.attempts == 0)
        #expect(try coordinator.pendingRecognitionJobs().map(\.id) == [record.id])
        let storedData = try await coordinator.pendingRecognitionImageData(record)
        #expect(storedData == imageData)

        try await coordinator.deletePendingRecognition(record)
        #expect(try coordinator.pendingRecognitionJobs().isEmpty)
    }

    @Test @MainActor func markRecognitionFailedIncrementsAttemptsAndGrowsBackoffExponentially() async throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let record = try await coordinator.queueRecognition(imageData: testMealImageData())
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try coordinator.markRecognitionFailed(record, error: EngagementTestError.simulated, now: now)
        #expect(record.attempts == 1)
        #expect(record.state == .failed)
        #expect(record.nextAttemptAt == now.addingTimeInterval(60))

        try coordinator.markRecognitionFailed(record, error: EngagementTestError.simulated, now: now)
        #expect(record.attempts == 2)
        #expect(record.nextAttemptAt == now.addingTimeInterval(120))

        try await coordinator.deletePendingRecognition(record)
    }

    @Test @MainActor func pendingRecognitionAttemptsReachingTheCapSetsATerminalMarker() async throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let record = try await coordinator.queueRecognition(imageData: testMealImageData())

        for _ in 0..<DailyDataCoordinator.maxRetryAttempts {
            try coordinator.markRecognitionFailed(record, error: EngagementTestError.simulated, now: .now)
        }

        #expect(record.attempts == DailyDataCoordinator.maxRetryAttempts)
        #expect(record.nextAttemptAt == nil)
        #expect(coordinator.isRetryExhausted(record))

        try await coordinator.deletePendingRecognition(record)
    }

    @Test @MainActor func syncQueueAttemptsReachingTheCapExcludesTheOperationFromTheReadyList() throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let operation = SyncOperationRecord(entityType: "meal", entityIdentifier: "abc", operation: .create, payloadData: Data(), clientRevision: 1)
        try repositories.syncQueue.save(operation)

        for _ in 0..<DailyDataCoordinator.maxRetryAttempts {
            try coordinator.markSyncFailed(operation, error: EngagementTestError.simulated, now: .now)
        }

        #expect(operation.attempts == DailyDataCoordinator.maxRetryAttempts)
        #expect(operation.nextAttemptAt == nil)
        #expect(try coordinator.readySyncOperations(at: .now).isEmpty)
    }

    @Test @MainActor func reconcileInterruptedWorkResetsProcessingAndUploadingToPendingWhilePreservingAttempts() async throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())

        let record = try await coordinator.queueRecognition(imageData: testMealImageData())
        try coordinator.markRecognitionFailed(record, error: EngagementTestError.simulated, now: .now)
        try coordinator.markRecognitionProcessing(record)
        #expect(record.state == .processing)
        #expect(record.attempts == 1)

        let operation = SyncOperationRecord(entityType: "meal", entityIdentifier: "def", operation: .update, payloadData: Data(), clientRevision: 1)
        try repositories.syncQueue.save(operation)
        try coordinator.markSyncFailed(operation, error: EngagementTestError.simulated, now: .now)
        try coordinator.markSyncUploading(operation)
        #expect(operation.state == .uploading)
        #expect(operation.attempts == 1)

        try coordinator.reconcileInterruptedWork()

        #expect(record.state == .pending)
        #expect(record.attempts == 1)
        #expect(record.nextAttemptAt == nil)
        #expect(operation.state == .pending)
        #expect(operation.attempts == 1)
        #expect(operation.nextAttemptAt == nil)

        try await coordinator.deletePendingRecognition(record)
    }

    @Test @MainActor func duplicateHydrationCommandWithTheSameIdempotencyKeyCreatesExactlyOneEntry() throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let command = PendingHydrationCommand(amountMilliliters: 250)

        let firstEntry = try repositories.consumeHydrationCommand(command, dayKey: "test-day")
        let secondEntry = try repositories.consumeHydrationCommand(command, dayKey: "test-day")

        #expect(firstEntry != nil)
        #expect(firstEntry?.amountMilliliters == 250)
        #expect(secondEntry == nil)
        #expect(try repositories.hydration.allEntries().count == 1)
    }

    @Test @MainActor func hydrationCommandSinkRejectsInvalidAmountAndUnreasonableTimestamps() throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invalid = [
            PendingHydrationCommand(amountMilliliters: 49, createdAt: now),
            PendingHydrationCommand(amountMilliliters: 2_001, createdAt: now),
            PendingHydrationCommand(amountMilliliters: 250, createdAt: now.addingTimeInterval(301)),
            PendingHydrationCommand(amountMilliliters: 250, createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60))
        ]
        for command in invalid {
            #expect(throws: LocalDataError.self) {
                _ = try repositories.consumeHydrationCommand(command, dayKey: "test-day", now: now)
            }
        }
        #expect(try repositories.hydration.allEntries().isEmpty)
    }
}
