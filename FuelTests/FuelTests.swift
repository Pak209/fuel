import Foundation
import SwiftData
import Testing
@testable import Fuel

struct FuelTests {
    private let scoreService = LocalHealthScoreService()

    @Test func healthScoreUsesLoggedDataAndStaysBounded() {
        let nutrition = DailyNutritionSummary(
            consumed: .init(calories: 2_100, protein: 110, carbohydrates: 220, fat: 70, fiber: 26),
            targets: .init(),
            hydrationMilliliters: 1_750,
            mealCount: 3
        )
        let activity = DailyActivitySummary(steps: 8_500, stepGoal: 10_000, activeCalories: 500, availability: .available)
        let sleep = SleepSummary(durationMinutes: 450, targetMinutes: 480, quality: "Good", availability: .available)
        let score = scoreService.score(for: .init(nutrition: nutrition, activity: activity, sleep: sleep, date: .now.addingTimeInterval(-86_400)))

        #expect((0...100).contains(score.overall))
        #expect(score.categories[.protein] == 92)
        #expect(score.categories[.hydration] == 88)
    }

    @Test func unavailableWearableDataDoesNotPretendToBeZero() {
        let nutrition = DailyNutritionSummary(consumed: .init(calories: 2_300, protein: 120, carbohydrates: 250, fat: 75, fiber: 30), hydrationMilliliters: 2_000, mealCount: 3)
        let historicalDate = Date.now.addingTimeInterval(-86_400)
        let score = scoreService.score(for: .init(
            nutrition: nutrition,
            activity: .init(availability: .unavailable),
            sleep: .init(availability: .unavailable),
            date: historicalDate
        ))

        #expect(score.overall > 90)
        #expect(score.categories[.recovery] == 0)
        #expect(score.unavailableCategories.contains(.recovery))
    }

    @Test func recommendationAsksForFirstMealWhenDayIsEmpty() {
        let recommendation = RulesNutritionRecommendationService().recommendation(for: .init(nutrition: .init(), activity: .init(), sleep: .init()))
        #expect(recommendation.title.hasPrefix("Log "))
        #expect(recommendation.estimatedImprovement == 0)
    }

    @Test func fiberRuleAppliesAfterHydrationIsOnTrack() {
        let nutrition = DailyNutritionSummary(
            consumed: .init(calories: 1_600, protein: 90, carbohydrates: 180, fat: 55, fiber: 8),
            hydrationMilliliters: 1_500,
            mealCount: 2
        )
        let result = RulesNutritionRecommendationService().recommendation(for: .init(nutrition: nutrition, activity: .init(), sleep: .init()))
        #expect(result.nutrients.contains("Fiber"))
    }

    @Test func nutritionAdditionAggregatesEveryTrackedField() {
        let first = NutritionEstimate(calories: 400, protein: 20, carbohydrates: 40, fat: 10, fiber: 6, sodium: 300)
        let second = NutritionEstimate(calories: 300, protein: 15, carbohydrates: 30, fat: 9, fiber: 5, sodium: 250)
        let total = first + second
        #expect(total.calories == 700)
        #expect(total.fiber == 11)
        #expect(total.sodium == 550)
    }

    @Test func dayBoundaryUsesTheProfilesTimeZoneAndHandlesDST() {
        let service = DayBoundaryService()
        let components = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "America/Los_Angeles"), year: 2026, month: 3, day: 8, hour: 12)
        let date = components.date!
        let interval = service.interval(containing: date, timeZoneIdentifier: "America/Los_Angeles")

        #expect(interval.contains(date))
        #expect(interval.end.timeIntervalSince(interval.start) == 23 * 60 * 60)
        #expect(service.cacheKey(for: interval).contains("2026-03-08"))
    }

    @Test @MainActor func repositoriesPersistProfileTargetsAndMeals() throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        var profile = try repositories.profiles.profile()
        profile.firstName = "Daniel"
        profile.allergies = ["Peanuts", "Shellfish"]
        profile.foodsToAvoid = ["Olives"]
        try repositories.profiles.save(profile)
        var targets = try repositories.targets.currentTargets()
        targets.proteinGrams = 145
        try repositories.targets.save(targets)

        let interval = DayBoundaryService().interval(containing: .now, timeZoneIdentifier: profile.timeZoneIdentifier)
        let meal = Meal(name: "Lunch", type: .lunch, date: .now, nutrition: .init(calories: 650, protein: 42, carbohydrates: 70, fat: 21, fiber: 10), items: [MealItem(name: "Chicken")])
        try repositories.meals.save(meal)

        #expect(try repositories.profiles.profile().firstName == "Daniel")
        #expect(try repositories.profiles.profile().allergies == ["Peanuts", "Shellfish"])
        #expect(try repositories.profiles.profile().foodsToAvoid == ["Olives"])
        #expect(try repositories.targets.currentTargets().proteinGrams == 145)
        #expect(try repositories.meals.meals(in: interval).count == 1)
        #expect(try repositories.meals.meals(in: interval).first?.items.first?.name == "Chicken")
    }

    @Test @MainActor func settingsAreCreatedOnceAndPersistChanges() throws {
        let container = try makeContainer()
        let repository = SwiftDataSettingsRepository(context: container.mainContext)
        let settings = try repository.settings()
        settings.healthKitEnabled = true
        try repository.save()

        let reloaded = SwiftDataSettingsRepository(context: container.mainContext)
        #expect(try reloaded.settings().healthKitEnabled)
        #expect(try container.mainContext.fetch(FetchDescriptor<AppSettingsRecord>()).count == 1)
    }

    @Test @MainActor func mealRepositorySeparatesCalendarDays() throws {
        let container = try makeContainer()
        let repository = SwiftDataMealRepository(context: container.mainContext)
        let zone = "America/Los_Angeles"
        let day = ISO8601DateFormatter().date(from: "2026-08-18T19:00:00Z")!
        let interval = DayBoundaryService().interval(containing: day, timeZoneIdentifier: zone)
        try repository.save(Meal(name: "Inside", type: .lunch, date: day, nutrition: .zero))
        try repository.save(Meal(name: "Outside", type: .dinner, date: interval.end, nutrition: .zero))

        let results = try repository.meals(in: interval)
        #expect(results.map(\.name) == ["Inside"])
    }

    @Test @MainActor func hydrationRejectsInvalidAmountsAndPersistsValidEntries() throws {
        let container = try makeContainer()
        let repository = SwiftDataHydrationRepository(context: container.mainContext)
        let interval = DayBoundaryService().interval(containing: .now, timeZoneIdentifier: TimeZone.current.identifier)
        do {
            try repository.add(amountMilliliters: 0, at: .now, provenance: .userEntered)
            Issue.record("Expected a validation error")
        } catch LocalDataError.invalidAmount {}
        try repository.add(amountMilliliters: 250, at: .now, provenance: .userEntered)
        let entry = try #require(try repository.entries(in: interval).first)
        #expect(entry.amountMilliliters == 250)
        try repository.update(entry, amountMilliliters: 400, date: entry.date.addingTimeInterval(60))
        #expect(try repository.entries(in: interval).first?.amountMilliliters == 400)
    }

    @Test @MainActor func dailySummaryIncludesOnlyInRangeLoggedData() {
        let interval = DayBoundaryService().interval(containing: .now, timeZoneIdentifier: TimeZone.current.identifier)
        let inside = Meal(name: "Inside", type: .lunch, date: .now, nutrition: .init(calories: 500, protein: 30, carbohydrates: 50, fat: 18, fiber: 7))
        let planned = Meal(name: "Planned", type: .dinner, date: .now, nutrition: .init(calories: 700, protein: 40, carbohydrates: 60, fat: 25, fiber: 8))
        planned.status = .planned
        let outside = Meal(name: "Tomorrow", type: .breakfast, date: interval.end, nutrition: .init(calories: 300, protein: 15, carbohydrates: 30, fat: 8, fiber: 4))
        let water = [HydrationEntry(date: .now, amountMilliliters: 500), HydrationEntry(date: interval.end, amountMilliliters: 500)]

        let result = DailySummaryService().build(interval: interval, targets: .init(), meals: [inside, planned, outside], hydrationEntries: water, activity: .init(), sleep: .init(), workouts: [])
        #expect(result.nutrition.calories == 500)
        #expect(result.nutrition.mealCount == 1)
        #expect(result.nutrition.hydrationMilliliters == 500)
        #expect(result.meals.map(\.name) == ["Inside", "Planned"])
        #expect(result.meals.last?.status == .planned)
    }

    @Test @MainActor func dailySummaryCacheRoundTripsAndInvalidates() throws {
        let container = try makeContainer()
        let repository = SwiftDataDailySummaryCacheRepository(context: container.mainContext)
        let interval = DayBoundaryService().interval(containing: .now, timeZoneIdentifier: TimeZone.current.identifier)
        let snapshot = DailyHealthSnapshot.empty(for: interval)
        try repository.save(snapshot, dayKey: "today", sourceRevision: 1)
        #expect(try repository.snapshot(for: "today")?.interval == interval)
        try repository.remove(for: "today")
        #expect(try repository.snapshot(for: "today") == nil)
    }

    @Test @MainActor func coordinatorFallsBackToMarkedCacheWhenADataSourceFails() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let profile = try repositories.profiles.profile()
        let targets = try repositories.targets.currentTargets()
        let boundary = DayBoundaryService()
        let interval = boundary.interval(containing: .now, timeZoneIdentifier: profile.timeZoneIdentifier)
        let cached = DailyHealthSnapshot.empty(for: interval, targets: targets)
        try repositories.summaryCache.save(cached, dayKey: boundary.cacheKey(for: interval), sourceRevision: 1)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: FailingHealthDataService())

        let result = try await coordinator.snapshot(for: .now, profile: profile, targets: targets)
        #expect(result.isFromCache)
        #expect(result.interval == interval)
    }

    @Test @MainActor func appStateSaveRebuildsAuthoritativeSnapshot() async throws {
        let container = try makeContainer()
        let state = AppState(healthService: MockHealthDataService())
        state.configure(context: container.mainContext)
        await state.loadInitialData()
        try await state.saveMeal(.init(name: "Test bowl", type: .lunch, date: .now, nutrition: .init(calories: 500, protein: 31, carbohydrates: 40, fat: 20, fiber: 8), items: [], provenance: .userEntered, confidence: nil, imageData: nil))

        #expect(state.snapshot.nutrition.calories == 500)
        #expect(state.snapshot.meals.first?.name == "Test bowl")
        #expect(state.healthScore.overall > 0)
    }

    @Test @MainActor func appStateWaterEntryRebuildsSnapshot() async throws {
        let container = try makeContainer()
        let state = AppState(healthService: MockHealthDataService())
        state.configure(context: container.mainContext)
        await state.loadInitialData()
        try await state.addWater(milliliters: 250)

        #expect(state.snapshot.nutrition.hydrationMilliliters == 250)
        #expect((state.healthScore.categories[.hydration] ?? 0) > 0)
    }

    @Test @MainActor func editingAMealRecalculatesTheSameDailySnapshot() async throws {
        let container = try makeContainer()
        let state = AppState(healthService: MockHealthDataService())
        state.configure(context: container.mainContext)
        await state.loadInitialData()
        try await state.saveMeal(.init(name: "Original", type: .lunch, date: .now, nutrition: .init(calories: 400, protein: 20, carbohydrates: 40, fat: 15, fiber: 5), items: [], provenance: .userEntered, confidence: nil, imageData: nil))
        let meal = try #require(try container.mainContext.fetch(FetchDescriptor<Meal>()).first)
        try await state.updateMeal(meal, with: .init(name: "Corrected", type: .lunch, date: .now, nutrition: .init(calories: 650, protein: 40, carbohydrates: 60, fat: 22, fiber: 9), items: [], provenance: .userEntered, confidence: nil, imageData: nil))

        #expect(state.snapshot.nutrition.calories == 650)
        #expect(state.snapshot.meals.first?.name == "Corrected")
        #expect(state.snapshot.meals.first?.provenance == .userEntered)
    }

    @Test func localPhotoStoreRoundTripsAndDeletesProtectedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = LocalMealPhotoStore(directory: directory)
        let source = Data([1, 2, 3, 4])
        let fileName = try await store.save(source, id: UUID())
        #expect(try await store.load(fileName: fileName) == source)
        try await store.delete(fileName: fileName)
        do {
            _ = try await store.load(fileName: fileName)
            Issue.record("Expected the deleted photo to be unavailable")
        } catch {}
    }

    @Test func mockRecognitionProducesTypedResult() async throws {
        let result = try await MockFoodRecognitionService().analyze(imageData: Data([1]))
        #expect(result.mealName == "Chicken burrito bowl")
        #expect(result.items.count == 6)
        #expect(result.items.allSatisfy { $0.provenance == .aiEstimated })
    }

    @Test func premiumEntitlementRemainsBehindProtocol() {
        #expect(!MockEntitlementService(tier: .free).canAccess(.weeklyReports))
        #expect(MockEntitlementService(tier: .premium).canAccess(.weeklyReports))
    }

    @Test func commonFoodSearchReturnsSourceAwareServingNutrition() async throws {
        let database = LocalFoodDatabaseService()
        let result = try #require(try await database.search("banana").first)
        let serving = result.nutrition(quantity: 1, unit: .serving)

        #expect(result.id == "fuel-common:banana")
        #expect(result.sourceName == "Fuel common foods")
        #expect(serving.calories > result.nutritionPer100Grams.calories)
    }

    @Test func mealItemPortionRecalculationPreservesDatabaseBasisAndCorrection() {
        var item = MealItem(
            name: "Test",
            quantity: 2,
            unit: .ounce,
            nutrition: .zero,
            provenance: .nutritionDatabase,
            nutritionPer100Grams: .init(calories: 100, protein: 10, carbohydrates: 5, fat: 2, fiber: 1),
            gramsPerUnit: [.ounce: 28.3495]
        )
        item.recalculateNutrition()

        #expect(item.nutrition.calories == 57)
        #expect(item.nutrition.protein > 5.6)
    }

    @Test func recommendationsRespectDietAndAllergyExclusions() {
        let nutrition = DailyNutritionSummary(
            consumed: .init(calories: 1_200, protein: 30, carbohydrates: 140, fat: 40, fiber: 5),
            hydrationMilliliters: 1_500,
            mealCount: 2
        )
        var profile = UserProfile()
        profile.dietaryPreference = .vegan
        profile.allergies = ["almonds"]
        let result = RulesNutritionRecommendationService().recommendation(for: .init(
            nutrition: nutrition,
            activity: .init(),
            sleep: .init(),
            profile: profile
        ))
        let copy = ([result.title] + result.alternatives).joined(separator: " ").lowercased()

        #expect(!copy.contains("almond"))
        #expect(!copy.contains("yogurt"))
        #expect(!copy.contains("chicken"))
        #expect(!copy.contains("salmon"))
    }

    @Test func conservativeTargetsStayWithinSafetyBoundsAndRecordAssumptions() {
        var profile = UserProfile()
        profile.weightKG = 42
        profile.goal = .gradualLoss
        profile.activityLevel = "Sedentary"
        let result = ConservativeGoalCalculationService().calculate(profile: profile)

        #expect(result.targets.calories >= 1_400)
        #expect(result.targets.proteinGrams >= 45)
        #expect(result.targets.hydrationMilliliters >= 1_500)
        #expect(!result.assumptions.isEmpty)
    }

    @Test func calorieBalanceDisclosesWearableUncertainty() {
        let nutrition = DailyNutritionSummary(consumed: .init(calories: 1_800, protein: 80, carbohydrates: 200, fat: 60, fiber: 20), mealCount: 3)
        let activity = DailyActivitySummary(steps: 9_000, activeCalories: 500, availability: .available, basalCalories: 1_650)
        let result = LocalCalorieBalanceService().balance(nutrition: nutrition, activity: activity)

        #expect(result.availability == .complete)
        #expect(result.estimatedExpenditureRange?.contains(2_150) == true)
        #expect(result.explanation.contains("estimate"))
    }

    @Test @MainActor func softDeleteAndRestorePreserveMealForUndo() throws {
        let container = try makeContainer()
        let repository = SwiftDataMealRepository(context: container.mainContext)
        let meal = Meal(name: "Undo meal", type: .lunch, date: .now, nutrition: .zero)
        try repository.save(meal)
        try repository.delete(meal)
        #expect(try repository.allMeals().isEmpty)
        #expect(meal.status == .deleted)
        try repository.restore(meal)
        #expect(try repository.allMeals().map(\.name) == ["Undo meal"])
    }

    @Test @MainActor func phaseTwoPreferencesFavoritesAndGoalHistoryPersist() throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        var preferences = try repositories.preferences.preferences()
        preferences.onboardingCompleted = true
        preferences.unitSystem = .imperial
        try repositories.preferences.save(preferences)
        let meal = Meal(name: "Favorite bowl", type: .dinner, date: .now, nutrition: .init(calories: 600, protein: 30, carbohydrates: 70, fat: 20, fiber: 10))
        try repositories.favorites.save(MealTemplate(meal: meal))
        try repositories.goalHistory.append(targets: .init(), explanation: "Test", effectiveDate: .now)

        #expect(try repositories.preferences.preferences().onboardingCompleted)
        #expect(try repositories.preferences.preferences().unitSystem == .imperial)
        #expect(try repositories.favorites.favorites().first?.name == "Favorite bowl")
        #expect(try repositories.goalHistory.history().first?.explanation == "Test")
    }

    @Test @MainActor func recentFoodsAreUniqueAndNewestFirst() throws {
        let container = try makeContainer()
        let coordinator = DailyDataCoordinator(
            repositories: LocalRepositoryContainer(context: container.mainContext),
            healthService: MockHealthDataService()
        )
        let older = Meal(name: "Older", type: .lunch, date: .now.addingTimeInterval(-60), nutrition: .zero, items: [
            MealItem(name: "Banana", nutrition: .init(calories: 100, protein: 0, carbohydrates: 0, fat: 0, fiber: 0)),
            MealItem(name: "Yogurt", nutrition: .init(calories: 120, protein: 0, carbohydrates: 0, fat: 0, fiber: 0))
        ])
        let newer = Meal(name: "Newer", type: .snack, date: .now, nutrition: .zero, items: [
            MealItem(name: "Banana", nutrition: .init(calories: 90, protein: 0, carbohydrates: 0, fat: 0, fiber: 0)),
            MealItem(name: "Almonds", nutrition: .init(calories: 160, protein: 0, carbohydrates: 0, fat: 0, fiber: 0))
        ])
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        try repositories.meals.save(older)
        try repositories.meals.save(newer)

        let recent = try coordinator.recentFoodItems()
        #expect(recent.map(\.name) == ["Banana", "Almonds", "Yogurt"])
        #expect(recent.first?.nutrition.calories == 90)
    }

    @Test func insightsRequireThreeDaysAndComputeRealRangeValues() {
        let boundary = DayBoundaryService()
        let targets = DailyTargets()
        let snapshots = (0..<3).map { offset in
            let date = Date.now.addingTimeInterval(Double(offset - 2) * 86_400)
            let interval = boundary.interval(containing: date, timeZoneIdentifier: TimeZone.current.identifier)
            return DailyHealthSnapshot(
                interval: interval,
                nutrition: .init(consumed: .init(calories: 2_000 + offset * 100, protein: 90, carbohydrates: 220, fat: 70, fiber: 25), targets: targets, hydrationMilliliters: 2_000, mealCount: 3),
                activity: .init(steps: 8_000, availability: .available),
                sleep: .init(),
                meals: [],
                workouts: [],
                lastUpdated: .now,
                isFromCache: false
            )
        }
        let report = LocalInsightsService().report(from: snapshots)

        #expect(report.hasMinimumSample)
        #expect(report.averageCalories == 2_100)
        #expect(report.hydrationGoalDays == 3)
        #expect(report.insights.contains { $0.id == "fiber-frequency" })
    }

    @Test func invalidRecognitionImageReturnsManualFallbackError() async {
        do {
            _ = try await OnDeviceFoodRecognitionService(database: LocalFoodDatabaseService()).analyze(imageData: Data([1, 2, 3]))
            Issue.record("Expected invalid image error")
        } catch FoodServiceError.invalidImage {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func scoreV2ExplainsMissingRecoveryAndEvidence() {
        let nutrition = DailyNutritionSummary(consumed: .init(calories: 2_000, protein: 100, carbohydrates: 220, fat: 65, fiber: 28), hydrationMilliliters: 1_800, mealCount: 3)
        let score = LocalHealthScoreService().score(for: .init(nutrition: nutrition, activity: .init(availability: .unavailable), sleep: .init(availability: .unavailable)))

        #expect(score.algorithmVersion == 2)
        #expect(score.unavailableCategories.contains(.recovery))
        #expect(score.categoryExplanations[.recovery]?.contains("excluded") == true)
    }

    @Test func scoreV2UsesPaceForAnInProgressDayButFullTargetsForHistory() {
        let current = ISO8601DateFormatter().date(from: "2026-08-18T17:00:00Z")!
        let service = LocalHealthScoreService(now: { current })
        let nutrition = DailyNutritionSummary(
            consumed: .init(calories: 700, protein: 35, carbohydrates: 75, fat: 24, fiber: 8),
            targets: .init(),
            hydrationMilliliters: 600,
            mealCount: 1,
            averageEstimateConfidence: 0.9
        )
        let currentScore = service.score(for: .init(nutrition: nutrition, activity: .init(), sleep: .init(), date: current))
        let historicalScore = service.score(for: .init(nutrition: nutrition, activity: .init(), sleep: .init(), date: current.addingTimeInterval(-86_400)))

        #expect(currentScore.overall > historicalScore.overall)
        #expect(currentScore.evidenceCompleteness > 0)
        #expect(currentScore.evidenceCompleteness < 1)
    }

    @Test func recommendationDoesNotPushMoreFoodAfterTargetIsReached() {
        let nutrition = DailyNutritionSummary(
            consumed: .init(calories: 2_600, protein: 120, carbohydrates: 280, fat: 85, fiber: 31, potassium: 2_500),
            targets: .init(),
            hydrationMilliliters: 2_000,
            mealCount: 3
        )
        let result = RulesNutritionRecommendationService().recommendation(for: .init(nutrition: nutrition, activity: .init(), sleep: .init()))

        #expect(result.key == "target-reached-review")
        #expect(result.estimatedImprovement == 0)
        #expect(result.reason.contains("not suggesting additional food"))
    }

    @Test func overlappingHealthIntervalsAreMergedWithoutDoubleCounting() {
        let start = Date(timeIntervalSince1970: 1_000)
        let merged = HealthIntervalMerger.merge([
            .init(start: start, end: start.addingTimeInterval(60 * 60)),
            .init(start: start.addingTimeInterval(30 * 60), end: start.addingTimeInterval(90 * 60)),
            .init(start: start.addingTimeInterval(2 * 60 * 60), end: start.addingTimeInterval(3 * 60 * 60))
        ])

        #expect(merged.count == 2)
        #expect(merged.reduce(0) { $0 + $1.duration } == 150 * 60)
    }

    @Test @MainActor func exportContainsReviewedMealsAndWater() async throws {
        let container = try makeContainer()
        let repositories = LocalRepositoryContainer(context: container.mainContext)
        let coordinator = DailyDataCoordinator(repositories: repositories, healthService: MockHealthDataService())
        let profile = try repositories.profiles.profile()
        let targets = try repositories.targets.currentTargets()
        let preferences = try repositories.preferences.preferences()
        _ = try await coordinator.saveMeal(.init(
            name: "Export bowl",
            type: .dinner,
            date: .now,
            nutrition: .init(calories: 620, protein: 35, carbohydrates: 70, fat: 22, fiber: 11),
            items: [MealItem(name: "Beans", provenance: .userEntered, correctedAt: .now)],
            provenance: .userEntered,
            confidence: nil,
            imageData: nil
        ))
        try coordinator.addWater(milliliters: 350, at: .now, timeZoneIdentifier: profile.timeZoneIdentifier)
        let url = try await LocalDataExportService().write(coordinator.exportPayload(profile: profile, targets: targets, preferences: preferences))
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FuelExportPayload.self, from: Data(contentsOf: url))

        #expect(decoded.meals.first?.name == "Export bowl")
        #expect(decoded.meals.first?.items.first?.isUserCorrected == true)
        #expect(decoded.hydration.first?.amountMilliliters == 350)
    }

    @Test @MainActor func deletingAllDataResetsDailyStateAndOnboarding() async throws {
        let container = try makeContainer()
        let state = AppState(healthService: MockHealthDataService())
        state.configure(context: container.mainContext)
        await state.loadInitialData()
        var preferences = state.preferences
        preferences.onboardingCompleted = true
        try state.updatePreferences(preferences)
        try await state.saveMeal(.init(name: "Temporary", type: .lunch, date: .now, nutrition: .init(calories: 400, protein: 20, carbohydrates: 45, fat: 15, fiber: 6), items: [], provenance: .userEntered, confidence: nil, imageData: nil))
        try await state.addWater(milliliters: 250)

        try await state.deleteAllLocalData()

        #expect(state.snapshot.nutrition.mealCount == 0)
        #expect(state.snapshot.nutrition.hydrationMilliliters == 0)
        #expect(!state.preferences.onboardingCompleted)
        #expect(try container.mainContext.fetch(FetchDescriptor<Meal>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<HydrationEntry>()).isEmpty)
    }

    /// A damaged store must surface as an error the startup path can show in
    /// `StartupFailureView`, never as a process abort — the ObjC exception
    /// Core Data raises for an unreadable store is invisible to Swift `catch`.
    @Test func corruptStoreReportsFailureInsteadOfKillingTheProcess() throws {
        let directory = URL.temporaryDirectory.appending(path: "FuelStoreHealth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "default.store")
        try Data("this is not a SQLite database, not even close".utf8).write(to: storeURL)

        #expect(StoreHealth.openFailureReason(forStoreAt: storeURL) != nil)
        // A store that isn't there yet is a first launch, not a failure.
        #expect(StoreHealth.openFailureReason(forStoreAt: directory.appending(path: "absent.store")) == nil)

        // And a genuinely *raised* NSException — the shape Swift cannot catch —
        // comes back as an NSError from the shim rather than aborting.
        var caught: NSError?
        #expect(throws: (any Error).self) {
            do {
                try StoreHealth.catchingObjCExceptions {
                    NSException(name: .invalidArgumentException, reason: "simulated store failure", userInfo: nil).raise()
                }
            } catch {
                caught = error as NSError
                throw error
            }
        }
        #expect(caught?.domain == "FuelObjCException")
        #expect(caught?.localizedDescription == "simulated store failure")

        // The check has to look where SwiftData actually puts the store: Fuel
        // has an app group, so the default store lands in the shared container,
        // not the app's own Application Support directory.
        let resolved = StoreHealth.defaultStoreURL(for: Schema(versionedSchema: FuelSchemaV3.self))
        #expect(resolved.lastPathComponent == "default.store")
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FuelSharedStore.appGroupIdentifier) {
            #expect(resolved.path.hasPrefix(group.path))
        }
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: FuelSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private enum ExpectedTestError: Error { case failure }

private struct FailingHealthDataService: HealthDataService {
    var isAvailable: Bool { true }
    func authorizationStatus() async -> HealthPermissionState { .authorized }
    func requestAuthorization() async -> HealthPermissionState { .authorized }
    func activity(for interval: DayInterval) async throws -> DailyActivitySummary { throw ExpectedTestError.failure }
    func sleep(for interval: DayInterval) async throws -> SleepSummary { throw ExpectedTestError.failure }
    func workouts(for interval: DayInterval) async throws -> [WorkoutSummary] { throw ExpectedTestError.failure }
    func bodyMeasurements() async throws -> BodyMeasurementSummary { throw ExpectedTestError.failure }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func enableBackgroundDelivery() async throws { throw ExpectedTestError.failure }
}
