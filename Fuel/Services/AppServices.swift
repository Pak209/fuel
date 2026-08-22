import Foundation
import HealthKit

// MARK: - Health score and recommendations

protocol HealthScoreService {
    func score(for input: DailyHealthInput) -> HealthScore
}

struct LocalHealthScoreService: HealthScoreService {
    struct Weights: Hashable {
        var nutrition = 0.25
        var protein = 0.18
        var fiber = 0.15
        var hydration = 0.15
        var activity = 0.14
        var recovery = 0.13
    }

    var weights = Weights()
    var now: () -> Date = { .now }

    func score(for input: DailyHealthInput) -> HealthScore {
        let progress = expectedDayProgress(for: input.date)
        let nutrition = nutritionScore(input.nutrition, expectedProgress: progress)
        let protein = adequacy(input.nutrition.protein, target: input.nutrition.targets.proteinGrams * progress)
        let fiber = adequacy(input.nutrition.fiber, target: input.nutrition.targets.fiberGrams * progress)
        let hydration = adequacy(input.nutrition.hydrationMilliliters, target: input.nutrition.targets.hydrationMilliliters * progress)
        let activity = adequacy(Double(input.activity.steps), target: Double(input.activity.stepGoal) * progress)
        let recovery = adequacy(Double(input.sleep.durationMinutes), target: Double(input.sleep.targetMinutes))

        var weightedTotal = Double(nutrition) * weights.nutrition
            + Double(protein) * weights.protein
            + Double(fiber) * weights.fiber
            + Double(hydration) * weights.hydration
        var includedWeight = weights.nutrition + weights.protein + weights.fiber + weights.hydration

        if input.activity.availability == .available {
            weightedTotal += Double(activity) * weights.activity
            includedWeight += weights.activity
        }
        if input.sleep.availability == .available {
            weightedTotal += Double(recovery) * weights.recovery
            includedWeight += weights.recovery
        }

        let overall = includedWeight > 0 ? Int((weightedTotal / includedWeight).rounded()) : 0
        let nutritionConfidence = input.nutrition.mealCount > 0 ? (input.nutrition.averageEstimateConfidence ?? 0.75) : 0
        let availableEvidence = nutritionConfidence * 3
            + (input.nutrition.hydrationMilliliters > 0 ? 1 : 0)
            + (input.activity.availability == .available ? 1 : 0)
            + (input.sleep.availability == .available ? 1 : 0)
        return .init(
            overall: min(100, max(0, overall)),
            categories: [.nutrition: nutrition, .protein: protein, .hydration: hydration, .fiber: fiber, .recovery: recovery],
            unavailableCategories: input.sleep.availability == .available ? [] : [.recovery],
            message: statusMessage(overall: overall, mealCount: input.nutrition.mealCount),
            algorithmVersion: 2,
            evidenceCompleteness: availableEvidence / 6,
            categoryExplanations: [
                .nutrition: input.nutrition.mealCount == 0 ? "No meals are logged yet." : "Balances logged energy, protein, and fiber against a pace-adjusted share of your daily targets.",
                .protein: "\(Int(input.nutrition.protein)) of \(Int(input.nutrition.targets.proteinGrams)) daily grams logged; today’s score adjusts for time of day.",
                .hydration: "\(Int(input.nutrition.hydrationMilliliters)) of \(Int(input.nutrition.targets.hydrationMilliliters)) daily milliliters logged; today’s score adjusts for time of day.",
                .fiber: "\(Int(input.nutrition.fiber)) of \(Int(input.nutrition.targets.fiberGrams)) daily grams logged; today’s score adjusts for time of day.",
                .recovery: input.sleep.availability == .available ? "Based on \(input.sleep.durationMinutes) minutes of sleep." : "Sleep data is unavailable and is excluded from the overall score."
            ]
        )
    }

    private func nutritionScore(_ summary: DailyNutritionSummary, expectedProgress: Double) -> Int {
        guard summary.mealCount > 0, summary.targetCalories > 0 else { return 0 }
        let expectedCalories = max(1, Double(summary.targetCalories) * expectedProgress)
        let difference = abs(Double(summary.calories) - expectedCalories) / expectedCalories
        let calorieBalance = Int(max(0, 100 - difference * 100).rounded())
        let protein = adequacy(summary.protein, target: summary.targets.proteinGrams * expectedProgress)
        let fiber = adequacy(summary.fiber, target: summary.targets.fiberGrams * expectedProgress)
        return Int((Double(calorieBalance) * 0.50 + Double(protein) * 0.30 + Double(fiber) * 0.20).rounded())
    }

    private func expectedDayProgress(for date: Date) -> Double {
        let calendar = Calendar.autoupdatingCurrent
        let current = now()
        guard calendar.isDate(date, inSameDayAs: current) else { return 1 }
        let hour = Double(calendar.component(.hour, from: current))
            + Double(calendar.component(.minute, from: current)) / 60
        return min(1, max(0.25, (hour - 6) / 18))
    }

    private func adequacy(_ value: Double, target: Double) -> Int {
        guard target > 0 else { return 0 }
        return min(100, max(0, Int((value / target * 100).rounded())))
    }

    private func statusMessage(overall: Int, mealCount: Int) -> String {
        guard mealCount > 0 else { return "Log a meal to begin today’s health summary." }
        return switch overall {
        case 85...: "You’re building a well-balanced day."
        case 65..<85: "You’re making steady progress today."
        case 40..<65: "A few small choices can improve today’s balance."
        default: "Your day is still taking shape."
        }
    }
}

protocol NutritionRecommendationService {
    func recommendation(for input: DailyHealthInput) -> NutritionRecommendation
}

struct RulesNutritionRecommendationService: NutritionRecommendationService {
    func recommendation(for input: DailyHealthInput) -> NutritionRecommendation {
        if input.nutrition.mealCount == 0 {
            let meal = suggestedMealName(for: input.date)
            return recommendation(
                key: "log-first-meal",
                title: "Log \(meal) when you’re ready.",
                reason: "Fuel needs at least one logged meal to understand today’s nutrition balance.",
                improvement: 0,
                nutrients: [],
                alternatives: ["Quick-add calories and macros", "Choose a recent favorite"],
                data: ["No meals logged"],
                confidence: 1
            )
        }

        var candidates: [NutritionRecommendation] = []
        if input.nutrition.hydrationMilliliters < input.nutrition.targets.hydrationMilliliters * 0.5 {
            candidates.append(recommendation(
                key: "hydration-half-target",
                title: "Have a glass of water with your next meal.",
                reason: "Your logged water is below half of today’s target.",
                improvement: 4,
                nutrients: ["Hydration"],
                alternatives: ["Unsweetened sparkling water", "Water-rich fruit that fits your preferences"],
                data: ["Logged water", "Hydration target"],
                confidence: 0.9
            ))
        }

        let remainingCalories = input.nutrition.targetCalories - input.nutrition.calories
        if !input.workouts.isEmpty, remainingCalories > 400 {
            let choices = safeChoices(["a rice and bean bowl", "Greek yogurt with fruit", "tofu with rice", "salmon with potatoes"], profile: input.profile)
            candidates.append(recommendation(
                key: "post-workout-energy",
                title: "Consider a balanced meal after today’s activity.",
                reason: "You logged a workout and remain well below your configured food target.",
                improvement: 7,
                nutrients: ["Energy", "Protein", "Carbohydrates"],
                alternatives: choices,
                data: ["Workout", "Logged energy", "Configured target"],
                confidence: input.activity.availability == .available ? 0.8 : 0.65
            ))
        }

        if input.sleep.availability == .available,
           input.sleep.durationMinutes < Int(Double(input.sleep.targetMinutes) * 0.75) {
            candidates.append(recommendation(
                key: "short-recovery-window",
                title: "Protect a consistent wind-down tonight.",
                reason: "Last night’s recorded sleep was well below your configured recovery target.",
                improvement: 5,
                nutrients: ["Recovery"],
                alternatives: ["Set a bedtime reminder", "Keep the room cool and dark", "Review your weekly sleep pattern"],
                data: ["Recorded sleep duration", "Configured sleep target"],
                confidence: 0.85
            ))
        }

        let loggedMealProtein = input.meals
            .filter { ($0.status ?? .logged) == .logged }
            .map { $0.nutrition.protein }
        if remainingCalories > 180,
           loggedMealProtein.count >= 2,
           loggedMealProtein.contains(where: { $0 < input.nutrition.targets.proteinGrams / 6 }) {
            let choices = safeChoices(["Greek yogurt", "eggs", "tofu", "beans", "chicken", "salmon"], profile: input.profile)
            if let choice = choices.first {
                candidates.append(recommendation(
                    key: "protein-distribution",
                    title: "Spread protein into your next meal with \(choice.lowercased()).",
                    reason: "At least one logged meal is light in protein relative to your daily target.",
                    improvement: 5,
                    nutrients: ["Protein"],
                    alternatives: Array(choices.dropFirst().prefix(3)),
                    data: ["Protein by logged meal", "Protein target", "Remaining configured calories"],
                    confidence: estimateConfidence(input)
                ))
            }
        }

        if remainingCalories > 120, input.nutrition.fiber < input.nutrition.fiberGoal * 0.75 {
            let choices = safeChoices(["berries", "an apple", "oats", "beans", "almonds", "roasted vegetables"], profile: input.profile)
            if let choice = choices.first {
                candidates.append(recommendation(
                    key: "fiber-under-75",
                    title: "Add \(choice) to a meal or snack.",
                    reason: "Your logged meals appear below three quarters of today’s fiber target. This suggestion may help close that estimated gap.",
                    improvement: 9,
                    nutrients: ["Fiber", "Potassium"],
                    alternatives: Array(choices.dropFirst().prefix(3)),
                    data: ["Logged fiber", "Fiber target"],
                    confidence: estimateConfidence(input)
                ))
            }
        }

        if remainingCalories > 180, input.nutrition.protein < input.nutrition.targets.proteinGrams * 0.7 {
            let choices = safeChoices(["Greek yogurt", "eggs", "chicken", "tofu", "beans", "salmon"], profile: input.profile)
            if let choice = choices.first {
                candidates.append(recommendation(
                    key: "protein-under-70",
                    title: "Consider \(choice.lowercased()) at your next meal.",
                    reason: "Your logged protein is below 70% of your current daily target.",
                    improvement: 6,
                    nutrients: ["Protein"],
                    alternatives: Array(choices.dropFirst().prefix(3)),
                    data: ["Logged protein", "Protein target"],
                    confidence: estimateConfidence(input)
                ))
            }
        }

        if remainingCalories > 120, input.nutrition.consumed.potassium < 2_000 {
            let choices = safeChoices(["potatoes", "beans", "yogurt", "leafy greens", "a banana"], profile: input.profile)
            if let choice = choices.first {
                candidates.append(recommendation(
                    key: "possible-potassium-gap",
                    title: "Add \(choice) for more food variety.",
                    reason: "Foods currently logged appear to provide limited potassium, though meal estimates may be incomplete.",
                    improvement: 3,
                    nutrients: ["Potassium"],
                    alternatives: Array(choices.dropFirst().prefix(3)),
                    data: ["Estimated potassium from logged foods"],
                    confidence: min(0.7, estimateConfidence(input))
                ))
            }
        }

        if let available = candidates.first(where: { !input.excludedRecommendationKeys.contains($0.key) }) {
            return available
        }
        if remainingCalories <= 0 {
            return recommendation(
                key: "target-reached-review",
                title: "Review today’s portions and finish logging when ready.",
                reason: "Logged energy has reached your configured target, so Fuel is not suggesting additional food.",
                improvement: 0,
                nutrients: [],
                alternatives: ["Log water", "Correct an estimated portion", "Plan tomorrow’s breakfast"],
                data: ["Logged energy", "Configured target"],
                confidence: estimateConfidence(input)
            )
        } else {
            return recommendation(
                key: "balanced-variety",
                title: "Keep your next meal colorful and balanced.",
                reason: "Small variety can support broader nutrient coverage.",
                improvement: 3,
                nutrients: ["Micronutrients"],
                alternatives: safeChoices(["vegetables", "fruit", "whole grains", "a protein food"], profile: input.profile),
                data: ["Today’s logged meals", "Remaining configured calories"],
                confidence: estimateConfidence(input)
            )
        }
    }

    private func recommendation(
        key: String,
        title: String,
        reason: String,
        improvement: Int,
        nutrients: [String],
        alternatives: [String],
        data: [String],
        confidence: Double
    ) -> NutritionRecommendation {
        .init(
            key: key,
            title: title,
            reason: reason,
            estimatedImprovement: improvement,
            nutrients: nutrients,
            alternatives: alternatives,
            dataUsed: data,
            limitation: "General wellness guidance based on logged estimates; not a diagnosis or treatment recommendation.",
            confidence: confidence
        )
    }

    private func estimateConfidence(_ input: DailyHealthInput) -> Double {
        input.nutrition.averageEstimateConfidence ?? (input.nutrition.mealCount > 0 ? 0.75 : 0.25)
    }

    private func suggestedMealName(for date: Date) -> String {
        switch Calendar.autoupdatingCurrent.component(.hour, from: date) {
        case 4..<11: "breakfast"
        case 11..<15: "lunch"
        case 15..<18: "a snack"
        default: "dinner"
        }
    }

    private func safeChoices(_ choices: [String], profile: UserProfile) -> [String] {
        let userExclusions = (profile.allergies + profile.foodsToAvoid).map { $0.lowercased() }
        return choices.filter { choice in
            let value = choice.lowercased()
            guard !userExclusions.contains(where: { exclusion in
                value.contains(exclusion) || exclusion.contains(value)
            }) else { return false }
            switch profile.dietaryPreference {
            case .vegan:
                return !["yogurt", "egg", "chicken", "salmon"].contains(where: value.contains)
            case .vegetarian:
                return !["chicken", "salmon"].contains(where: value.contains)
            case .pescatarian:
                return !["chicken"].contains(where: value.contains)
            case .glutenFree:
                return !["bread", "whole grains"].contains(where: value.contains)
            case .none:
                return true
            }
        }
    }
}

protocol GoalCalculationService {
    func calculate(profile: UserProfile) -> GoalCalculationResult
}

struct ConservativeGoalCalculationService: GoalCalculationService {
    func calculate(profile: UserProfile) -> GoalCalculationResult {
        let activityFactor: Double = switch profile.activityLevel.lowercased() {
        case let value where value.contains("very"): 1.15
        case let value where value.contains("moderate"): 1.05
        case let value where value.contains("light"): 0.98
        case let value where value.contains("sedentary"): 0.92
        default: 1
        }
        let goalAdjustment: Int = switch profile.goal {
        case .gradualLoss: -250
        case .gradualGain: 250
        default: 0
        }
        let maintenance = Int((profile.weightKG * 30 * activityFactor).rounded())
        let calories = min(4_500, max(1_400, maintenance + goalAdjustment))
        let proteinFactor = profile.goal == .increaseProtein || profile.goal == .athleticPerformance ? 1.6 : 1.2
        let protein = min(250, max(45, profile.weightKG * proteinFactor))
        let fat = max(45, Double(calories) * 0.28 / 9)
        let carbohydrates = max(100, (Double(calories) - protein * 4 - fat * 9) / 4)
        let fiber = min(50, max(20, Double(calories) / 1_000 * 14))
        let hydration = min(4_000, max(1_500, profile.weightKG * 30))
        return .init(
            targets: .init(
                calories: calories,
                proteinGrams: protein.rounded(),
                carbohydrateGrams: carbohydrates.rounded(),
                fatGrams: fat.rounded(),
                fiberGrams: fiber.rounded(),
                hydrationMilliliters: (hydration / 250).rounded() * 250,
                steps: 10_000,
                sleepMinutes: 480
            ),
            explanation: "A conservative starter target based on body weight, activity description, and your selected goal. You can change every value.",
            assumptions: [
                "Uses a broad weight-based estimate rather than a medical energy prescription.",
                "Gradual weight goals adjust energy by only 250 calories.",
                "Public release requires qualified nutrition review."
            ]
        )
    }
}

protocol CalorieBalanceService {
    func balance(nutrition: DailyNutritionSummary, activity: DailyActivitySummary) -> CalorieBalance
}

struct LocalCalorieBalanceService: CalorieBalanceService {
    func balance(nutrition: DailyNutritionSummary, activity: DailyActivitySummary) -> CalorieBalance {
        let remaining = nutrition.targetCalories - nutrition.calories
        let availability: CalorieBalanceAvailability
        switch (activity.basalCalories, activity.availability) {
        case (.some, .available): availability = .complete
        case (.some, _), (.none, .available), (.none, .stale): availability = .partial
        default: availability = .unavailable
        }
        let range: ClosedRange<Int>?
        if let basal = activity.basalCalories {
            let active = activity.activeCalories
            let uncertainty = max(75, Int(Double(active) * 0.20))
            range = max(0, basal + active - uncertainty)...(basal + active + uncertainty)
        } else {
            range = nil
        }
        let explanation = switch availability {
        case .complete: "Remaining calories use your configured food target. Apple Health expenditure is shown as an estimate range, not an exact burn value."
        case .partial: "Some Apple Health energy data is missing or stale, so expenditure is only a partial estimate."
        case .unavailable: "Remaining calories use your configured target because Apple Health energy data is unavailable."
        }
        return .init(
            consumedCalories: nutrition.calories,
            targetCalories: nutrition.targetCalories,
            activeCalories: activity.availability == .unavailable ? nil : activity.activeCalories,
            basalCalories: activity.basalCalories,
            estimatedRemaining: remaining,
            estimatedExpenditureRange: range,
            availability: availability,
            explanation: explanation
        )
    }
}

// MARK: - Food recognition

protocol FoodRecognitionService {
    func analyze(imageData: Data) async throws -> FoodRecognitionResult
}

struct MockFoodRecognitionService: FoodRecognitionService {
    func analyze(imageData: Data) async throws -> FoodRecognitionResult {
        try await Task.sleep(for: .seconds(1.2))
        let nutrition = NutritionEstimate(calories: 720, protein: 48, carbohydrates: 64, fat: 22, fiber: 11, sodium: 780, potassium: 980)
        let names = ["Chicken", "Rice", "Black beans", "Corn", "Salsa", "Avocado"]
        return .init(
            mealName: "Chicken burrito bowl",
            items: names.map { MealItem(name: $0, confidence: 0.88, nutrition: .zero, provenance: .aiEstimated) },
            nutrition: nutrition,
            confidence: 0.88
        )
    }
}

// MARK: - Health data boundary

enum HealthPermissionState: String { case notDetermined, requesting, authorized, denied, unavailable, noRecentData }

protocol HealthDataService {
    var isAvailable: Bool { get }
    func authorizationStatus() async -> HealthPermissionState
    func requestAuthorization() async -> HealthPermissionState
    func activity(for interval: DayInterval) async throws -> DailyActivitySummary
    func sleep(for interval: DayInterval) async throws -> SleepSummary
    func workouts(for interval: DayInterval) async throws -> [WorkoutSummary]
    func bodyMeasurements() async throws -> BodyMeasurementSummary
    func updates() -> AsyncStream<Void>
    func enableBackgroundDelivery() async throws
}

struct MockHealthDataService: HealthDataService {
    var isAvailable = false
    var activitySummary = DailyActivitySummary()
    var sleepSummary = SleepSummary()
    var workoutSummaries: [WorkoutSummary] = []
    var bodySummary = BodyMeasurementSummary()

    func authorizationStatus() async -> HealthPermissionState { isAvailable ? .authorized : .unavailable }
    func requestAuthorization() async -> HealthPermissionState { isAvailable ? .authorized : .unavailable }
    func activity(for interval: DayInterval) async throws -> DailyActivitySummary { activitySummary }
    func sleep(for interval: DayInterval) async throws -> SleepSummary { sleepSummary }
    func workouts(for interval: DayInterval) async throws -> [WorkoutSummary] { workoutSummaries }
    func bodyMeasurements() async throws -> BodyMeasurementSummary { bodySummary }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func enableBackgroundDelivery() async throws {}
}

struct LiveHealthKitService: HealthDataService {
    private let store = HKHealthStore()
    private let anchorStore = HealthKitAnchorStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func authorizationStatus() async -> HealthPermissionState {
        guard isAvailable else { return .unavailable }
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, _ in
                switch status {
                case .shouldRequest: continuation.resume(returning: .notDetermined)
                case .unnecessary: continuation.resume(returning: .authorized)
                case .unknown: continuation.resume(returning: .notDetermined)
                @unknown default: continuation.resume(returning: .notDetermined)
                }
            }
        }
    }

    func requestAuthorization() async -> HealthPermissionState {
        guard isAvailable else { return .unavailable }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return .authorized
        } catch {
            return .denied
        }
    }

    func activity(for interval: DayInterval) async throws -> DailyActivitySummary {
        guard isAvailable, await authorizationStatus() != .notDetermined else { return .init(availability: .unavailable) }
        async let steps = cumulative(.stepCount, interval: interval, unit: .count())
        async let active = cumulative(.activeEnergyBurned, interval: interval, unit: .kilocalorie())
        async let basal = cumulative(.basalEnergyBurned, interval: interval, unit: .kilocalorie())
        async let exercise = cumulative(.appleExerciseTime, interval: interval, unit: .minute())
        async let resting = average(.restingHeartRate, interval: interval, unit: .count().unitDivided(by: .minute()))
        async let heartRate = average(.heartRate, interval: interval, unit: .count().unitDivided(by: .minute()))
        let previous = DayBoundaryService().interval(containing: interval.start.addingTimeInterval(-1), timeZoneIdentifier: interval.timeZoneIdentifier)
        async let yesterdayActive = cumulative(.activeEnergyBurned, interval: previous, unit: .kilocalorie())
        let values = try await (steps, active, basal, exercise, resting, heartRate, yesterdayActive)
        let readings = [values.0, values.1, values.2, values.3, values.4, values.5]
        let lastUpdated = readings.compactMap(\.lastUpdated).max()
        let hasData = readings.contains { $0.value != nil }
        let availability: MetricAvailability
        if !hasData {
            availability = .unavailable
        } else if interval.contains(.now), let lastUpdated, Date.now.timeIntervalSince(lastUpdated) > 12 * 60 * 60 {
            availability = .stale
        } else {
            availability = .available
        }
        return .init(
            steps: Int((values.0.value ?? 0).rounded()),
            activeCalories: Int((values.1.value ?? 0).rounded()),
            yesterdayActiveCalories: values.6.value.map { Int($0.rounded()) },
            availability: availability,
            lastUpdated: lastUpdated,
            basalCalories: values.2.value.map { Int($0.rounded()) },
            exerciseMinutes: values.3.value.map { Int($0.rounded()) },
            restingHeartRate: values.4.value,
            averageHeartRate: values.5.value,
            sourceNames: Array(Set(readings.compactMap(\.sourceName))).sorted()
        )
    }

    func sleep(for interval: DayInterval) async throws -> SleepSummary {
        guard isAvailable,
              await authorizationStatus() != .notDetermined,
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return .init(availability: .unavailable)
        }
        let queryStart = interval.start.addingTimeInterval(-18 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: queryStart, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: nil
        )
        let samples: [HKCategorySample] = try await descriptor.result(for: store)
        let asleepValues: Set<Int> = [1, 3, 4, 5]
        let intervals = samples
            .filter { asleepValues.contains($0.value) && $0.endDate > interval.start && $0.startDate < interval.end }
            .map { DateInterval(start: max($0.startDate, queryStart), end: min($0.endDate, interval.end)) }
        let merged = HealthIntervalMerger.merge(intervals)
        let minutes = Int((merged.reduce(0) { $0 + $1.duration } / 60).rounded())
        guard minutes > 0 else { return .init(availability: .unavailable) }
        let quality: String = switch minutes {
        case 420...540: "Restorative range"
        case 360..<420: "A little short"
        case 541...: "Long sleep"
        default: "Limited sleep"
        }
        return .init(
            durationMinutes: minutes,
            quality: quality,
            availability: .available,
            lastUpdated: samples.map(\.endDate).max()
        )
    }

    func workouts(for interval: DayInterval) async throws -> [WorkoutSummary] {
        guard isAvailable, await authorizationStatus() != .notDetermined else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [.strictStartDate])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: nil
        )
        let workouts: [HKWorkout] = try await descriptor.result(for: store)
        let energyType = HKQuantityType(.activeEnergyBurned)
        var seenWorkoutIDs = Set<UUID>()
        return workouts.filter { seenWorkoutIDs.insert($0.uuid).inserted }.map { workout in
            let energy = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            return .init(
                id: workout.uuid,
                name: workoutName(workout.workoutActivityType),
                startDate: workout.startDate,
                minutes: Int((workout.duration / 60).rounded()),
                calories: Int(energy.rounded())
            )
        }
    }

    func bodyMeasurements() async throws -> BodyMeasurementSummary {
        guard isAvailable, await authorizationStatus() != .notDetermined else { return .init(availability: .unavailable) }
        async let mass = latest(.bodyMass, unit: .gramUnit(with: .kilo))
        async let height = latest(.height, unit: .meterUnit(with: .centi))
        let values = try await (mass, height)
        let hasData = values.0.value != nil || values.1.value != nil
        return .init(
            bodyMassKilograms: values.0.value,
            heightCentimeters: values.1.value,
            lastUpdated: [values.0.lastUpdated, values.1.lastUpdated].compactMap { $0 }.max(),
            availability: hasData ? .available : .unavailable
        )
    }

    func updates() -> AsyncStream<Void> {
        let store = store
        let anchorStore = anchorStore
        let types = observedTypes
        return AsyncStream { continuation in
            let queries = types.map { type in
                HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                    guard error == nil else {
                        completion()
                        return
                    }
                    let anchor = anchorStore.anchor(for: type.identifier)
                    let anchored = HKAnchoredObjectQuery(
                        type: type,
                        predicate: nil,
                        anchor: anchor,
                        limit: HKObjectQueryNoLimit
                    ) { _, _, _, newAnchor, anchoredError in
                        if anchoredError == nil, let newAnchor {
                            anchorStore.save(newAnchor, for: type.identifier)
                            continuation.yield()
                        }
                        completion()
                    }
                    store.execute(anchored)
                }
            }
            queries.forEach(store.execute)
            continuation.onTermination = { _ in queries.forEach(store.stop) }
        }
    }

    func enableBackgroundDelivery() async throws {
        for type in observedTypes {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.enableBackgroundDelivery(for: type, frequency: .hourly) { succeeded, error in
                    if let error { continuation.resume(throwing: error) }
                    else if succeeded { continuation.resume() }
                    else { continuation.resume(throwing: HealthKitServiceError.backgroundDeliveryFailed(type.identifier)) }
                }
            }
        }
    }

    private var readTypes: Set<HKObjectType> {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .stepCount, .activeEnergyBurned, .basalEnergyBurned, .bodyMass, .height,
            .restingHeartRate, .heartRate, .appleExerciseTime
        ]
        let quantities = identifiers.compactMap(HKObjectType.quantityType(forIdentifier:))
        return Set(quantities + [HKObjectType.workoutType()] + [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)].compactMap { $0 })
    }

    private var observedTypes: [HKSampleType] {
        readTypes.compactMap { $0 as? HKSampleType }
    }

    private struct Reading {
        var value: Double?
        var lastUpdated: Date?
        var sourceName: String?
    }

    private func cumulative(_ identifier: HKQuantityTypeIdentifier, interval: DayInterval, unit: HKUnit) async throws -> Reading {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return .init() }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [.strictStartDate])
        let samplePredicate = HKSamplePredicate.quantitySample(type: type, predicate: predicate)
        async let statistics = HKStatisticsQueryDescriptor(predicate: samplePredicate, options: .cumulativeSum).result(for: store)
        async let latestSample = latestSample(type: type, predicate: predicate)
        let result = try await (statistics, latestSample)
        return .init(
            value: result.0?.sumQuantity()?.doubleValue(for: unit),
            lastUpdated: result.1?.endDate,
            sourceName: result.1?.sourceRevision.source.name
        )
    }

    private func average(_ identifier: HKQuantityTypeIdentifier, interval: DayInterval, unit: HKUnit) async throws -> Reading {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return .init() }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [.strictStartDate])
        let samplePredicate = HKSamplePredicate.quantitySample(type: type, predicate: predicate)
        async let statistics = HKStatisticsQueryDescriptor(predicate: samplePredicate, options: .discreteAverage).result(for: store)
        async let latestSample = latestSample(type: type, predicate: predicate)
        let result = try await (statistics, latestSample)
        return .init(
            value: result.0?.averageQuantity()?.doubleValue(for: unit),
            lastUpdated: result.1?.endDate,
            sourceName: result.1?.sourceRevision.source.name
        )
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Reading {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return .init() }
        let sample = try await latestSample(type: type, predicate: nil)
        return .init(value: sample?.quantity.doubleValue(for: unit), lastUpdated: sample?.endDate, sourceName: sample?.sourceRevision.source.name)
    }

    private func latestSample(type: HKQuantityType, predicate: NSPredicate?) async throws -> HKQuantitySample? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let results: [HKQuantitySample] = try await descriptor.result(for: store)
        return results.first
    }

    private func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength Training"
        case .highIntensityIntervalTraining: "HIIT"
        case .yoga: "Yoga"
        case .hiking: "Hiking"
        default: "Workout"
        }
    }
}

struct HealthIntervalMerger {
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        intervals.sorted { $0.start < $1.start }.reduce(into: []) { merged, next in
            guard let last = merged.last else { merged.append(next); return }
            if next.start <= last.end {
                merged[merged.count - 1] = .init(start: last.start, end: max(last.end, next.end))
            } else {
                merged.append(next)
            }
        }
    }
}

private enum HealthKitServiceError: LocalizedError {
    case backgroundDeliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .backgroundDeliveryFailed(let identifier):
            "Apple Health background updates could not be enabled for \(identifier)."
        }
    }
}

private final class HealthKitAnchorStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let prefix = "fuel.healthkit.anchor."

    func anchor(for identifier: String) -> HKQueryAnchor? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: prefix + identifier) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor, for identifier: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        lock.lock()
        defaults.set(data, forKey: prefix + identifier)
        lock.unlock()
    }
}

// MARK: - Entitlements

protocol EntitlementService {
    var tier: SubscriptionTier { get }
    func canAccess(_ feature: PremiumFeature) -> Bool
}

enum PremiumFeature: String { case deepAnalysis, weeklyReports, mealPlanning, familyDashboard, aiChat }
struct MockEntitlementService: EntitlementService {
    var tier: SubscriptionTier = .free
    func canAccess(_ feature: PremiumFeature) -> Bool { tier == .premium }
}
