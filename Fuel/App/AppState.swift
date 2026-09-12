import Foundation
import Observation
import SwiftData
import WidgetKit

enum AppDataPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    var profile: UserProfile
    var targets: DailyTargets
    var snapshot: DailyHealthSnapshot
    var selectedDate: Date
    var preferences = UserPreferences()
    var favorites: [MealTemplate] = []
    var pendingRecognitions: [PendingRecognitionRecord] = []
    var excludedRecommendationKeys: Set<String> = []
    var selectedTab: AppTab = .today
    var presentedRoute: AppRoute?
    var permissionState: HealthPermissionState = .notDetermined
    var notificationAuthorizationState: NotificationAuthorizationState = .notDetermined
    var accountSummary: CloudAccountSummary
    var syncState: SyncExecutionState = .localOnly
    var dataPhase: AppDataPhase = .idle
    var transientMessage: String?

    let scoreService: any HealthScoreService
    let recommendationService: any NutritionRecommendationService
    let calorieBalanceService: any CalorieBalanceService
    let goalCalculationService: any GoalCalculationService
    let insightsService: any InsightsService
    let dataExportService: any DataExportService
    let recognitionService: any FoodRecognitionService
    let foodDatabase: any FoodDatabaseService
    let imageProcessor: any MealImageProcessing
    let healthService: any HealthDataService
    let notificationScheduler: any NotificationScheduling
    let connectivityMonitor: any ConnectivityMonitoring
    let backendService: any BackendServicing
    let accountSessionService: AccountSessionService
    let syncEngine: CloudSyncEngine
    let entitlements: any EntitlementService

    @ObservationIgnored private var coordinator: DailyDataCoordinator?
    @ObservationIgnored private var healthUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var connectivityTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightRecognitionIDs: Set<UUID> = []
    @ObservationIgnored private var isConsumingSharedRoute = false
    @ObservationIgnored private let consumesSharedHydrationCommands: Bool

    init(
        scoreService: any HealthScoreService = LocalHealthScoreService(),
        recommendationService: any NutritionRecommendationService = RulesNutritionRecommendationService(),
        calorieBalanceService: any CalorieBalanceService = LocalCalorieBalanceService(),
        goalCalculationService: any GoalCalculationService = ConservativeGoalCalculationService(),
        insightsService: any InsightsService = LocalInsightsService(),
        dataExportService: any DataExportService = LocalDataExportService(),
        recognitionService: (any FoodRecognitionService)? = nil,
        foodDatabase: any FoodDatabaseService = CompositeFoodDatabaseService(),
        imageProcessor: any MealImageProcessing = MealImageProcessor(),
        healthService: any HealthDataService = LiveHealthKitService(),
        notificationScheduler: any NotificationScheduling = LocalNotificationScheduler(),
        connectivityMonitor: any ConnectivityMonitoring = LiveConnectivityMonitor(),
        backendService: (any BackendServicing)? = nil,
        entitlements: any EntitlementService = MockEntitlementService(),
        consumesSharedHydrationCommands: Bool = true,
        now: Date = .now
    ) {
        let profile = UserProfile()
        let targets = DailyTargets()
        let interval = DayBoundaryService().interval(containing: now, timeZoneIdentifier: profile.timeZoneIdentifier)
        self.profile = profile
        self.targets = targets
        snapshot = .empty(for: interval, targets: targets)
        selectedDate = now
        self.scoreService = scoreService
        self.recommendationService = recommendationService
        self.calorieBalanceService = calorieBalanceService
        self.goalCalculationService = goalCalculationService
        self.insightsService = insightsService
        self.dataExportService = dataExportService
        self.foodDatabase = foodDatabase
        // Photo recognition resolves labels against the bundled catalog only, so a scan
        // never generates Open Food Facts traffic; interactive search keeps `foodDatabase`.
        self.recognitionService = recognitionService ?? OnDeviceFoodRecognitionService(database: LocalFoodDatabaseService())
        self.imageProcessor = imageProcessor
        self.healthService = healthService
        self.notificationScheduler = notificationScheduler
        self.connectivityMonitor = connectivityMonitor
        let backend = backendService ?? BackendAPIClient()
        self.backendService = backend
        accountSessionService = AccountSessionService(backend: backend)
        syncEngine = CloudSyncEngine(backend: backend)
        accountSummary = .localOnly(backendConfigured: backend.isConfigured)
        self.entitlements = entitlements
        self.consumesSharedHydrationCommands = consumesSharedHydrationCommands
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-FuelTab"),
           arguments.indices.contains(index + 1),
           let tab = AppTab(rawValue: arguments[index + 1]) {
            selectedTab = tab
        }
    }

    var input: DailyHealthInput {
        .init(
            nutrition: snapshot.nutrition,
            activity: snapshot.activity,
            sleep: snapshot.sleep,
            workouts: snapshot.workouts,
            meals: snapshot.meals,
            profile: profile,
            date: selectedDate,
            excludedRecommendationKeys: excludedRecommendationKeys
        )
    }
    var healthScore: HealthScore { scoreService.score(for: input) }
    var recommendation: NutritionRecommendation { recommendationService.recommendation(for: input) }
    var calorieBalance: CalorieBalance { calorieBalanceService.balance(nutrition: snapshot.nutrition, activity: snapshot.activity) }
    var isConfigured: Bool { coordinator != nil }

    func configure(context: ModelContext) {
        guard coordinator == nil else { return }
        coordinator = DailyDataCoordinator(repositories: LocalRepositoryContainer(context: context), healthService: healthService)
    }

    func loadInitialData() async {
        guard let coordinator else {
            dataPhase = .failed(LocalDataError.notConfigured.localizedDescription)
            return
        }
        dataPhase = .loading
        do {
            #if DEBUG
            try await applyUITestLaunchArgumentsIfNeeded()
            #endif
            permissionState = await healthService.authorizationStatus()
            (profile, targets) = try coordinator.bootstrap()
            preferences = try coordinator.preferences()
            notificationAuthorizationState = await notificationScheduler.authorizationState()
            try await notificationScheduler.apply(preferences: preferences, requestingAuthorization: false)
            #if DEBUG
            try await seedDemoDataIfRequested(using: coordinator)
            #endif
            favorites = try coordinator.favorites()
            try coordinator.reconcileInterruptedWork()
            if consumesSharedHydrationCommands {
                try await consumeSharedHydrationCommands(using: coordinator)
            }
            pendingRecognitions = try coordinator.pendingRecognitionJobs()
            refreshAccountSummary(using: coordinator)
            let feedback = try coordinator.recentRecommendationFeedback(since: Date.now.addingTimeInterval(-7 * 86_400))
            excludedRecommendationKeys = Set(feedback.filter { $0.kind != .helpful }.map(\.recommendationKey))
            snapshot = try await coordinator.snapshot(for: selectedDate, profile: profile, targets: targets)
            updateNoDataPermissionState()
            dataPhase = .loaded
            recordAnalytics(.appLaunched)
            startHealthUpdatesIfNeeded()
            startConnectivityUpdatesIfNeeded()
            publishWidgetSummary()
            await consumeSharedRoute()
        } catch {
            Observability.log(error, category: .data, message: "Initial data load failed")
            dataPhase = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard let coordinator else { return }
        do {
            if consumesSharedHydrationCommands {
                try await consumeSharedHydrationCommands(using: coordinator)
            }
            snapshot = try await coordinator.snapshot(for: selectedDate, profile: profile, targets: targets)
            pendingRecognitions = try coordinator.pendingRecognitionJobs()
            refreshAccountSummary(using: coordinator)
            updateNoDataPermissionState()
            dataPhase = .loaded
            publishWidgetSummary()
        } catch {
            Observability.log(error, category: .data, message: "Data refresh failed")
            dataPhase = .failed(error.localizedDescription)
        }
    }

    func historicalSnapshots(days: Int) async throws -> [DailyHealthSnapshot] {
        guard let coordinator else { throw LocalDataError.notConfigured }
        return try await coordinator.snapshots(ending: selectedDate, days: days, profile: profile, targets: targets)
    }

    func saveMeal(_ draft: MealDraft) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        let nutritionBeforeSave = snapshot.nutrition
        let meal = try await coordinator.saveMeal(draft)
        try await reloadAfterMutation()
        transientMessage = draft.status == .logged
            ? Self.logConfirmation(name: meal.name, before: nutritionBeforeSave, after: snapshot.nutrition)
            : "Meal saved"
        SpotlightIndexer.index(meal: meal)
        recordAnalytics(.mealLogged(source: draft.provenance == .aiEstimated ? .photoScan : .manualEntry))
    }

    /// The confirmation shown after a meal is logged, e.g.
    /// `"Logged Yogurt bowl — protein 63→74 g · 1,140 cal left"`.
    ///
    /// ED-safe by construction: every clause is an additive fact about what
    /// was just added, only one macro gain is named (so the line stays short
    /// and never reads as a checklist), calories past the
    /// target are reported as what was logged rather than as an amount
    /// "over", and the health score is never mentioned — it can move down for
    /// reasons that have nothing to do with the meal the user just recorded.
    static func logConfirmation(name: String, before: DailyNutritionSummary, after: DailyNutritionSummary) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = trimmedName.isEmpty ? "Meal logged" : "Logged \(trimmedName)"
        let macroClause = notableMacroGain(before: before, after: after)
        let addedCalories = after.calories - before.calories
        // Nothing measurable changed for the day on screen (a meal saved onto
        // another day, or an empty entry): stay with the plain confirmation
        // rather than reporting numbers that didn't move.
        guard macroClause != nil || addedCalories > 0 else { return "Meal saved" }

        var clauses: [String] = []
        if let macroClause { clauses.append(macroClause) }
        let remaining = after.targetCalories - after.calories
        if remaining > 0 {
            clauses.append("\(remaining.formatted()) cal left")
        } else if addedCalories > 0 {
            clauses.append("\(addedCalories.formatted()) cal logged")
        }
        guard !clauses.isEmpty else { return headline }
        return "\(headline) — \(clauses.joined(separator: " · "))"
    }

    /// The single most notable macro increase from this save, as
    /// `"protein 63→74 g"`. Decreases are never surfaced.
    ///
    /// "Most notable" is the largest share of that macro's own daily target,
    /// not the largest number of grams: carbohydrates outweigh every other
    /// macro in raw grams, so ranking by gram count would print "carbs" on
    /// practically every meal and say nothing about what the meal actually
    /// contributed.
    private static func notableMacroGain(before: DailyNutritionSummary, after: DailyNutritionSummary) -> String? {
        let targets = after.targets
        let macros: [(label: String, before: Double, after: Double, target: Double)] = [
            ("protein", before.consumed.protein, after.consumed.protein, targets.proteinGrams),
            ("fiber", before.consumed.fiber, after.consumed.fiber, targets.fiberGrams),
            ("carbs", before.consumed.carbohydrates, after.consumed.carbohydrates, targets.carbohydrateGrams),
            ("fat", before.consumed.fat, after.consumed.fat, targets.fatGrams)
        ]
        let gains: [(text: String, share: Double)] = macros.compactMap { macro in
            let start = Int(macro.before.rounded())
            let end = Int(macro.after.rounded())
            guard end > start else { return nil }
            let share = Double(end - start) / max(1, macro.target)
            return ("\(macro.label) \(start)→\(end) g", share)
        }
        return gains.max(by: { $0.share < $1.share })?.text
    }

    func deleteMeal(_ meal: Meal) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        let mealID = meal.id
        try await coordinator.deleteMeal(meal)
        try await reloadAfterMutation()
        transientMessage = "Meal deleted"
        SpotlightIndexer.deindex(mealID: mealID)
    }

    func restoreMeal(_ meal: Meal) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await coordinator.restoreMeal(meal)
        try await reloadAfterMutation()
        transientMessage = "Meal restored"
        SpotlightIndexer.index(meal: meal)
    }

    func duplicateMeal(_ meal: Meal, at date: Date = .now) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        let duplicate = try await coordinator.duplicateMeal(meal, at: date)
        try await reloadAfterMutation()
        transientMessage = "Meal duplicated"
        SpotlightIndexer.index(meal: duplicate)
    }

    func meal(id: UUID) throws -> Meal? {
        guard let coordinator else { throw LocalDataError.notConfigured }
        return try coordinator.meal(id: id)
    }

    func completePlannedMeal(_ meal: Meal) async throws {
        let draft = MealDraft(
            name: meal.name,
            type: meal.type,
            date: meal.date,
            nutrition: meal.nutrition,
            items: meal.items,
            provenance: meal.provenance,
            confidence: meal.confidence,
            imageData: nil,
            notes: meal.notes,
            status: .logged
        )
        try await updateMeal(meal, with: draft)
    }

    func hydrationEntriesForSelectedDay() throws -> [HydrationEntry] {
        guard let coordinator else { throw LocalDataError.notConfigured }
        return try coordinator.hydrationEntries(for: selectedDate, timeZoneIdentifier: profile.timeZoneIdentifier)
    }

    func recentFoodItems(limit: Int = 12) throws -> [MealItem] {
        guard let coordinator else { throw LocalDataError.notConfigured }
        return try coordinator.recentFoodItems(limit: limit)
    }

    func updateHydration(_ entry: HydrationEntry, amountMilliliters: Double, date: Date) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.updateHydration(entry, amountMilliliters: amountMilliliters, date: date, timeZoneIdentifier: profile.timeZoneIdentifier)
        try await reloadAfterMutation()
        transientMessage = "Water updated"
    }

    func deleteHydration(_ entry: HydrationEntry) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.deleteHydration(entry, timeZoneIdentifier: profile.timeZoneIdentifier)
        try await reloadAfterMutation()
        transientMessage = "Water entry deleted"
    }

    func saveFavorite(from meal: Meal) throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.saveFavorite(from: meal)
        favorites = try coordinator.favorites()
        transientMessage = "Saved to favorites"
    }

    func deleteFavorite(id: UUID) throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.deleteFavorite(id: id)
        favorites = try coordinator.favorites()
        transientMessage = "Favorite removed"
    }

    func updateMeal(_ meal: Meal, with draft: MealDraft) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await coordinator.updateMeal(meal, with: draft)
        try await reloadAfterMutation()
        transientMessage = "Meal updated"
        SpotlightIndexer.index(meal: meal)
    }

    func addWater(milliliters: Double = 250, at date: Date = .now) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.addWater(milliliters: milliliters, at: date, timeZoneIdentifier: profile.timeZoneIdentifier)
        try await reloadAfterMutation()
        transientMessage = "Water added"
        recordAnalytics(.waterLogged(source: .quickAdd))
    }

    func updateProfile(_ newProfile: UserProfile) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.saveProfile(newProfile)
        profile = newProfile
        try await reloadAfterMutation()
    }

    func updateTargets(_ newTargets: DailyTargets, explanation: String = "Targets updated manually") async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.saveTargets(newTargets, explanation: explanation)
        targets = newTargets
        try await reloadAfterMutation()
    }

    func updatePreferences(_ newPreferences: UserPreferences) throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.savePreferences(newPreferences)
        preferences = newPreferences
    }

    func updateNotificationPreferences(_ newPreferences: UserPreferences) async throws {
        try updatePreferences(newPreferences)
        try await notificationScheduler.apply(preferences: newPreferences, requestingAuthorization: true)
        notificationAuthorizationState = await notificationScheduler.authorizationState()
    }

    func exportData() async throws -> LocalExportArtifact {
        guard let coordinator else { throw LocalDataError.notConfigured }
        let payload = try coordinator.exportPayload(profile: profile, targets: targets, preferences: preferences)
        let artifact = try await dataExportService.write(payload)
        recordAnalytics(.exportRequested)
        return artifact
    }

    func cleanupExpiredExports() async {
        do { try await dataExportService.cleanupExpired() }
        catch { Observability.log(error, category: .data, message: "Expired export cleanup failed") }
    }

    func removeExport(_ artifact: LocalExportArtifact) async {
        do { try await dataExportService.remove(artifact) }
        catch { Observability.log(error, category: .data, message: "Export removal failed") }
    }

    func deleteAllLocalData() async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await dataExportService.removeAll()
        try await coordinator.deleteAllLocalData()
        await notificationScheduler.removeAllFuelNotifications()
        try FuelSharedStore.clearEngagementData()
        SpotlightIndexer.deindexAll()
        (profile, targets) = try coordinator.bootstrap()
        preferences = try coordinator.preferences()
        favorites = try coordinator.favorites()
        excludedRecommendationKeys = []
        selectedDate = .now
        snapshot = try await coordinator.snapshot(for: selectedDate, profile: profile, targets: targets)
        pendingRecognitions = []
        publishWidgetSummary()
        dataPhase = .loaded
    }

    func completeAppleSignIn(_ payload: AppleSignInPayload) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        let result = try await accountSessionService.signIn(payload)
        try coordinator.applyAccountSession(result)
        refreshAccountSummary(using: coordinator)
        transientMessage = result.cloudConnected ? "Cloud account connected" : "Apple identity saved; cloud remains unconfigured"
        if result.cloudConnected { await synchronizeNow() }
    }

    func signOutAccount() async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await accountSessionService.signOut()
        try coordinator.signOutAccount()
        refreshAccountSummary(using: coordinator)
        syncState = .localOnly
    }

    func deleteRemoteAccount() async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await accountSessionService.deleteRemoteAccount()
        try coordinator.signOutAccount()
        refreshAccountSummary(using: coordinator)
        syncState = .localOnly
        transientMessage = "Cloud account deleted; local data was kept"
    }

    func setCloudSyncEnabled(_ enabled: Bool) throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        guard !enabled || backendService.isConfigured else { throw BackendError.notConfigured }
        try coordinator.setSyncEnabled(enabled)
        refreshAccountSummary(using: coordinator)
    }

    func synchronizeNow() async {
        guard let coordinator, accountSummary.cloudConnected else {
            syncState = .localOnly
            return
        }
        let pending = (try? coordinator.readySyncOperations().count) ?? 0
        syncState = pending > 0 ? .syncing(pending) : .idle
        syncState = await syncEngine.synchronize(coordinator: coordinator)
        refreshAccountSummary(using: coordinator)
        if case .current = syncState {
            recordAnalytics(.syncCompleted(operationCount: pending))
            await refresh()
        }
    }

    func requestRemoteAccountExport() async throws -> URL {
        guard accountSummary.cloudConnected else { throw BackendError.notConfigured }
        return try await backendService.requestAccountExport().downloadURL
    }

    func queueRecognitionForLater(imageData: Data) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        _ = try await coordinator.queueRecognition(imageData: imageData)
        pendingRecognitions = try coordinator.pendingRecognitionJobs()
        transientMessage = "Scan saved for retry"
        recordAnalytics(.scanQueued)
    }

    /// Consumes a route handed off by the widget/extension. Safe to call on both cold start
    /// and every warm activation: `consumeRoute()` clears the stored value, and the in-flight
    /// guard keeps a cold start from handling the same route twice.
    func consumeSharedRoute() async {
        guard !isConsumingSharedRoute else { return }
        isConsumingSharedRoute = true
        defer { isConsumingSharedRoute = false }
        guard let route = FuelSharedStore.consumeRoute() else { return }
        await handle(route)
    }

    func retryPendingRecognition(_ record: PendingRecognitionRecord, isManual: Bool = true) async {
        guard let coordinator else { return }
        guard record.state != .processing, inFlightRecognitionIDs.insert(record.id).inserted else { return }
        defer { inFlightRecognitionIDs.remove(record.id) }
        recordAnalytics(.scanRetried(attempt: record.attempts + 1))
        do {
            if isManual { try coordinator.resetRecognitionForRetry(record) }
            try coordinator.markRecognitionProcessing(record)
            let data = try await coordinator.pendingRecognitionImageData(record)
            let result = try await recognitionService.analyze(imageData: data)
            try coordinator.markRecognitionCompleted(record, result: result)
        } catch {
            Observability.log(error, category: .data, message: "Pending recognition retry failed")
            try? coordinator.markRecognitionFailed(record, error: error)
        }
        pendingRecognitions = (try? coordinator.pendingRecognitionJobs()) ?? pendingRecognitions
    }

    func retryReadyPendingRecognitions(now: Date = .now) async {
        guard let coordinator else { return }
        let jobs = pendingRecognitions.filter {
            ($0.state == .pending || $0.state == .failed)
                && !coordinator.isRetryExhausted($0)
                && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
        }
        for job in jobs {
            guard !Task.isCancelled else { return }
            await retryPendingRecognition(job, isManual: false)
        }
    }

    func draftForPendingRecognition(_ record: PendingRecognitionRecord) async throws -> MealDraft {
        guard let coordinator else { throw LocalDataError.notConfigured }
        guard let data = record.resultData,
              let result = try? JSONDecoder().decode(FoodRecognitionResult.self, from: data) else {
            throw FoodServiceError.unavailable
        }
        let imageData = try await coordinator.pendingRecognitionImageData(record)
        return .init(
            name: result.mealName,
            type: .snack,
            date: .now,
            nutrition: result.nutrition,
            items: result.items,
            provenance: .aiEstimated,
            confidence: result.confidence,
            imageData: imageData,
            notes: result.warnings.joined(separator: " ")
        )
    }

    func deletePendingRecognition(_ record: PendingRecognitionRecord) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await coordinator.deletePendingRecognition(record)
        pendingRecognitions = try coordinator.pendingRecognitionJobs()
    }

    func handle(_ url: URL) async {
        guard let route = AppRoute(url: url) else { return }
        presentedRoute = nil
        switch route {
        case .today:
            selectedTab = .today
        case .scan:
            selectedTab = .scan
        case .insights:
            selectedTab = .insights
        case .meals:
            selectedTab = .meals
        case .notificationSettings:
            selectedTab = .profile
            presentedRoute = route
        case .healthConnection:
            selectedTab = .profile
            presentedRoute = route
        case .addWater:
            selectedTab = .today
            presentedRoute = route
        }
    }

    /// Handles the trusted command emitted only by a validated hydration
    /// notification action. Public URLs intentionally cannot call this path.
    func handleNotificationQuickAddWater() async {
        selectedTab = .today
        presentedRoute = nil
        do { try await addWater(milliliters: 250) }
        catch {
            Observability.log(error, category: .data, message: "Quick-add water from notification failed")
            transientMessage = error.localizedDescription
        }
    }

    func recordRecommendationFeedback(_ kind: RecommendationFeedbackKind) throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        let key = recommendation.key
        try coordinator.recommendationFeedback(for: key, kind: kind)
        if kind != .helpful { excludedRecommendationKeys.insert(key) }
    }

    func requestHealthAuthorization() async -> HealthPermissionState {
        permissionState = .requesting
        let result = await healthService.requestAuthorization()
        permissionState = result
        if let coordinator {
            do { try coordinator.setHealthKitEnabled(result == .authorized) }
            catch {
                Observability.log(error, category: .data, message: "Failed to persist HealthKit permission state")
                dataPhase = .failed(error.localizedDescription)
            }
        }
        if result == .authorized { await refresh() }
        startHealthUpdatesIfNeeded()
        return result
    }

    private func startHealthUpdatesIfNeeded() {
        guard permissionState == .authorized || permissionState == .noRecentData,
              healthUpdateTask == nil else { return }
        healthUpdateTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await healthService.enableBackgroundDelivery()
            } catch {
                Observability.log(error, category: .data, message: "Failed to enable HealthKit background delivery")
                transientMessage = "Background Health updates are unavailable; Fuel will refresh when opened."
            }
            for await _ in healthService.updates() {
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    private func startConnectivityUpdatesIfNeeded() {
        guard connectivityTask == nil else { return }
        connectivityTask = Task { [weak self] in
            guard let self else { return }
            for await isConnected in connectivityMonitor.updates() {
                guard !Task.isCancelled else { break }
                if isConnected { await retryReadyPendingRecognitions() }
                if isConnected, accountSummary.cloudConnected { await synchronizeNow() }
            }
        }
    }

    private func reloadAfterMutation() async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        snapshot = try await coordinator.snapshot(for: selectedDate, profile: profile, targets: targets)
        dataPhase = .loaded
        publishWidgetSummary()
    }

    private func consumeSharedHydrationCommands(using coordinator: DailyDataCoordinator) async throws {
        while true {
            let commands: [PendingHydrationCommand]
            do {
                commands = try FuelSharedStore.pendingHydrationCommands(limit: FuelSharedStore.hydrationDrainBatchSize)
            } catch SharedHydrationQueueError.corruptedQueue {
                if try FuelSharedStore.repairCorruptHydrationCommands() {
                    transientMessage = "Fuel discarded unreadable shortcut entries without changing your water log."
                }
                continue
            }
            guard !commands.isEmpty else { return }
            var acknowledged = Set<UUID>()
            do {
                for command in commands {
                    do {
                        let inserted = try coordinator.consumeHydrationCommand(
                            command,
                            timeZoneIdentifier: profile.timeZoneIdentifier
                        )
                        acknowledged.insert(command.id)
                        if inserted { recordAnalytics(.waterLogged(source: .widget)) }
                    } catch LocalDataError.invalidExternalCommand {
                        acknowledged.insert(command.id)
                        Observability.log(
                            LocalDataError.invalidExternalCommand,
                            category: .data,
                            message: "Rejected invalid shared hydration command"
                        )
                    }
                }
                try FuelSharedStore.acknowledgeHydrationCommands(ids: acknowledged)
            } catch {
                try? FuelSharedStore.acknowledgeHydrationCommands(ids: acknowledged)
                throw error
            }
            guard commands.count == FuelSharedStore.hydrationDrainBatchSize else { return }
            await Task.yield()
        }
    }

    private func publishWidgetSummary() {
        let summary = SharedDailySummary(
            healthScore: snapshot.dataCompleteness > 0 ? healthScore.overall : nil,
            caloriesRemaining: max(targets.calories - snapshot.nutrition.calories, 0),
            proteinRemainingGrams: max(Int((targets.proteinGrams - snapshot.nutrition.protein).rounded()), 0),
            hydrationMilliliters: Int(snapshot.nutrition.hydrationMilliliters.rounded()),
            hydrationTargetMilliliters: Int(targets.hydrationMilliliters.rounded()),
            lastUpdated: snapshot.lastUpdated
        )
        FuelSharedStore.saveSummary(summary)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func refreshAccountSummary(using coordinator: DailyDataCoordinator) {
        do {
            let account = try coordinator.accountMetadata()
            accountSummary = .init(
                isSignedIn: account.appleUserIdentifierHash != nil,
                cloudConnected: account.syncEnabled && backendService.isConfigured,
                displayName: account.displayName,
                emailHint: account.emailHint,
                lastSyncAt: account.lastSyncAt,
                pendingOperationCount: try coordinator.allSyncOperations().count,
                backendConfigured: backendService.isConfigured
            )
            if !accountSummary.cloudConnected { syncState = .localOnly }
        } catch {
            Observability.log(error, category: .sync, message: "Account summary refresh failed")
            accountSummary = .localOnly(backendConfigured: backendService.isConfigured)
        }
    }

    private func updateNoDataPermissionState() {
        guard permissionState == .authorized,
              snapshot.activity.availability == .unavailable,
              snapshot.sleep.availability == .unavailable,
              snapshot.workouts.isEmpty else { return }
        permissionState = .noRecentData
        Task {
            do {
                try await notificationScheduler.scheduleHealthConnectionIssue(ifEnabled: preferences)
            } catch {
                Observability.log(error, category: .app, message: "Failed to schedule health-connection-issue notification")
            }
        }
    }

    /// Records an analytics event if, and only if, local usage counting is
    /// enabled (`FeatureFlag.analyticsCollectionEnabled`). Centralizing the
    /// flag check here keeps every call site a one-line, always-safe call.
    private func recordAnalytics(_ event: AnalyticsEvent) {
        guard FeatureFlagStore.shared.resolvedValue(for: .analyticsCollectionEnabled) else { return }
        Analytics.record(event)
    }

    #if DEBUG
    /// UI-test-only startup hook, checked early in `loadInitialData()`.
    /// "--uitest-reset" wipes local data and leaves onboarding incomplete
    /// (the state `deleteAllLocalData()` already produces).
    /// "--uitest-complete-onboarding" wipes local data and then marks
    /// onboarding complete so UI tests can reach the tab bar immediately,
    /// without driving the onboarding flow first.
    private func applyUITestLaunchArgumentsIfNeeded() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let shouldReset = arguments.contains("--uitest-reset")
        let shouldCompleteOnboarding = arguments.contains("--uitest-complete-onboarding")
        guard shouldReset || shouldCompleteOnboarding else { return }
        try await deleteAllLocalData()
        if shouldCompleteOnboarding {
            var updatedPreferences = preferences
            updatedPreferences.onboardingCompleted = true
            try updatePreferences(updatedPreferences)
        }
    }
    #endif

    #if DEBUG
    private func seedDemoDataIfRequested(using coordinator: DailyDataCoordinator) async throws {
        guard ProcessInfo.processInfo.arguments.contains("-FuelDemoData"),
              try coordinator.allMeals().isEmpty else { return }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: profile.timeZoneIdentifier) ?? .autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let breakfastDate = calendar.date(byAdding: .hour, value: 8, to: day),
                  let dinnerDate = calendar.date(byAdding: .hour, value: 19, to: day) else { continue }
            let breakfast = MealItem(
                name: "Greek yogurt with berries",
                confidence: 0.92,
                nutrition: .init(calories: 360 + offset * 5, protein: 28, carbohydrates: 42, fat: 9, fiber: 7, potassium: 520),
                provenance: .aiEstimated,
                sourceName: "Fuel common foods"
            )
            let dinner = MealItem(
                name: offset.isMultiple(of: 2) ? "Salmon grain bowl" : "Tofu grain bowl",
                nutrition: .init(calories: 780 - offset * 8, protein: 46, carbohydrates: 82, fat: 28, fiber: 13, potassium: 980),
                provenance: .userEntered,
                correctedAt: dinnerDate
            )
            _ = try await coordinator.saveMeal(.init(
                name: "Yogurt bowl",
                type: .breakfast,
                date: breakfastDate,
                nutrition: breakfast.nutrition,
                items: [breakfast],
                provenance: .aiEstimated,
                confidence: breakfast.confidence,
                imageData: nil
            ))
            _ = try await coordinator.saveMeal(.init(
                name: dinner.name,
                type: .dinner,
                date: dinnerDate,
                nutrition: dinner.nutrition,
                items: [dinner],
                provenance: .userEntered,
                confidence: nil,
                imageData: nil
            ))
            let water = 1_750.0 + Double((offset % 3) * 250)
            try coordinator.addWater(milliliters: water, at: day.addingTimeInterval(13 * 60 * 60), timeZoneIdentifier: profile.timeZoneIdentifier)
        }
        if let latest = try coordinator.allMeals().first { try coordinator.saveFavorite(from: latest) }
    }
    #endif
}

enum AppTab: String, CaseIterable, Identifiable {
    case today = "Today", scan = "Scan", insights = "Insights", meals = "Meals", profile = "Profile"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: "house.fill"
        case .scan: "camera.viewfinder"
        case .insights: "chart.bar.xaxis"
        case .meals: "takeoutbag.and.cup.and.straw.fill"
        case .profile: "person.crop.circle"
        }
    }
}
