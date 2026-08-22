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
        self.recognitionService = recognitionService ?? OnDeviceFoodRecognitionService(database: foodDatabase)
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
            permissionState = await healthService.authorizationStatus()
            (profile, targets) = try coordinator.bootstrap()
            preferences = try coordinator.preferences()
            notificationAuthorizationState = await notificationScheduler.authorizationState()
            try await notificationScheduler.apply(preferences: preferences, requestingAuthorization: false)
            #if DEBUG
            try await seedDemoDataIfRequested(using: coordinator)
            #endif
            favorites = try coordinator.favorites()
            try consumeSharedHydrationCommands(using: coordinator)
            pendingRecognitions = try coordinator.pendingRecognitionJobs()
            refreshAccountSummary(using: coordinator)
            let feedback = try coordinator.recentRecommendationFeedback(since: Date.now.addingTimeInterval(-7 * 86_400))
            excludedRecommendationKeys = Set(feedback.filter { $0.kind != .helpful }.map(\.recommendationKey))
            snapshot = try await coordinator.snapshot(for: selectedDate, profile: profile, targets: targets)
            updateNoDataPermissionState()
            dataPhase = .loaded
            startHealthUpdatesIfNeeded()
            startConnectivityUpdatesIfNeeded()
            publishWidgetSummary()
            if let route = FuelSharedStore.consumeRoute() { await handle(route) }
        } catch {
            dataPhase = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard let coordinator else { return }
        do {
            try consumeSharedHydrationCommands(using: coordinator)
            snapshot = try await coordinator.snapshot(for: selectedDate, profile: profile, targets: targets)
            pendingRecognitions = try coordinator.pendingRecognitionJobs()
            refreshAccountSummary(using: coordinator)
            updateNoDataPermissionState()
            dataPhase = .loaded
            publishWidgetSummary()
        } catch {
            dataPhase = .failed(error.localizedDescription)
        }
    }

    func historicalSnapshots(days: Int) async throws -> [DailyHealthSnapshot] {
        guard let coordinator else { throw LocalDataError.notConfigured }
        return try await coordinator.snapshots(ending: selectedDate, days: days, profile: profile, targets: targets)
    }

    func saveMeal(_ draft: MealDraft) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        _ = try await coordinator.saveMeal(draft)
        try await reloadAfterMutation()
        transientMessage = "Meal saved"
    }

    func deleteMeal(_ meal: Meal) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await coordinator.deleteMeal(meal)
        try await reloadAfterMutation()
        transientMessage = "Meal deleted"
    }

    func restoreMeal(_ meal: Meal) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.restoreMeal(meal)
        try await reloadAfterMutation()
        transientMessage = "Meal restored"
    }

    func duplicateMeal(_ meal: Meal, at date: Date = .now) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        _ = try await coordinator.duplicateMeal(meal, at: date)
        try await reloadAfterMutation()
        transientMessage = "Meal duplicated"
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
    }

    func addWater(milliliters: Double = 250, at date: Date = .now) async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try coordinator.addWater(milliliters: milliliters, at: date, timeZoneIdentifier: profile.timeZoneIdentifier)
        try await reloadAfterMutation()
        transientMessage = "Water added"
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

    func exportData() async throws -> URL {
        guard let coordinator else { throw LocalDataError.notConfigured }
        let payload = try coordinator.exportPayload(profile: profile, targets: targets, preferences: preferences)
        return try await dataExportService.write(payload)
    }

    func deleteAllLocalData() async throws {
        guard let coordinator else { throw LocalDataError.notConfigured }
        try await coordinator.deleteAllLocalData()
        await notificationScheduler.removeAllFuelNotifications()
        FuelSharedStore.clearEngagementData()
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
        if case .current = syncState { await refresh() }
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
    }

    func retryPendingRecognition(_ record: PendingRecognitionRecord) async {
        guard let coordinator else { return }
        do {
            try coordinator.markRecognitionProcessing(record)
            let data = try await coordinator.pendingRecognitionImageData(record)
            let result = try await recognitionService.analyze(imageData: data)
            try coordinator.markRecognitionCompleted(record, result: result)
        } catch {
            try? coordinator.markRecognitionFailed(record, error: error)
        }
        pendingRecognitions = (try? coordinator.pendingRecognitionJobs()) ?? pendingRecognitions
    }

    func retryReadyPendingRecognitions(now: Date = .now) async {
        let jobs = pendingRecognitions.filter {
            ($0.state == .pending || $0.state == .failed)
                && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
        }
        for job in jobs {
            guard !Task.isCancelled else { return }
            await retryPendingRecognition(job)
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
            let shouldAdd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { $0.name == "add" }) == true
            if shouldAdd {
                do { try await addWater() }
                catch { transientMessage = error.localizedDescription }
            } else {
                presentedRoute = route
            }
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
            catch { dataPhase = .failed(error.localizedDescription) }
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

    private func consumeSharedHydrationCommands(using coordinator: DailyDataCoordinator) throws {
        let commands = FuelSharedStore.pendingHydrationCommands()
        guard !commands.isEmpty else { return }
        var acknowledged = Set<UUID>()
        for command in commands {
            _ = try coordinator.consumeHydrationCommand(command, timeZoneIdentifier: profile.timeZoneIdentifier)
            acknowledged.insert(command.id)
        }
        FuelSharedStore.acknowledgeHydrationCommands(ids: acknowledged)
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
            try? await notificationScheduler.scheduleHealthConnectionIssue(ifEnabled: preferences)
        }
    }

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
