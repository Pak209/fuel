import Foundation
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
}

// MARK: - FuelSharedStore hydration queue (shared UserDefaults suite — serialized to avoid cross-test races)

@Suite(.serialized)
struct EngagementSharedStoreTests {
    @Test func hydrationQueueEnqueueThenDrainReturnsTheCommandOnceAndEmpties() {
        FuelSharedStore.clearEngagementData()
        let command = FuelSharedStore.enqueueHydration(amountMilliliters: 300)

        let drained = drainHydrationCommands()

        #expect(drained.map(\.id) == [command.id])
        #expect(drained.first?.amountMilliliters == 300)
        #expect(FuelSharedStore.pendingHydrationCommands().isEmpty)
        FuelSharedStore.clearEngagementData()
    }

    @Test func hydrationQueueDrainOnAnEmptyQueueIsANoOp() {
        FuelSharedStore.clearEngagementData()
        #expect(drainHydrationCommands().isEmpty)
        #expect(FuelSharedStore.pendingHydrationCommands().isEmpty)
    }

    @Test func hydrationQueueEnqueueAccumulatesIntoTheSharedSummary() {
        FuelSharedStore.clearEngagementData()
        _ = FuelSharedStore.enqueueHydration(amountMilliliters: 200)
        _ = FuelSharedStore.enqueueHydration(amountMilliliters: 150)

        #expect(FuelSharedStore.loadSummary().hydrationMilliliters == 350)
        FuelSharedStore.clearEngagementData()
    }

    @Test func consumeRouteReturnsTheEnqueuedURLOnceThenNil() {
        FuelSharedStore.clearEngagementData()
        #expect(FuelSharedStore.consumeRoute() == nil)

        let url = URL(string: "fuel://scan")!
        FuelSharedStore.enqueueRoute(url)

        #expect(FuelSharedStore.consumeRoute() == url)
        #expect(FuelSharedStore.consumeRoute() == nil)
    }

    /// `FuelSharedStore` has no single atomic "drain" call; the production hydration-sync path reads
    /// `pendingHydrationCommands()` and then acknowledges the ids it processed. This mirrors that pairing.
    private func drainHydrationCommands() -> [PendingHydrationCommand] {
        let commands = FuelSharedStore.pendingHydrationCommands()
        FuelSharedStore.acknowledgeHydrationCommands(ids: Set(commands.map(\.id)))
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
    @Test @MainActor func queueRecognitionCreatesADurablePendingRecordAndStoresThePhoto() async throws {
        let container = try makeInMemoryContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let imageData = Data([10, 20, 30, 40])

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
        let record = try await coordinator.queueRecognition(imageData: Data([1]))
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
        let record = try await coordinator.queueRecognition(imageData: Data([2]))

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

        let record = try await coordinator.queueRecognition(imageData: Data([3]))
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
}
