import Foundation
import SwiftData

// MARK: - Domain values

enum UserGoal: String, Codable, CaseIterable {
    case maintain = "Maintain weight"
    case gradualLoss = "Lose weight gradually"
    case gradualGain = "Gain weight gradually"
    case improveNutrition = "Improve nutrition"
    case increaseProtein = "Increase protein"
    case improveEnergy = "Improve energy"
    case athleticPerformance = "Support athletic performance"
}

enum DietaryPreference: String, Codable, CaseIterable {
    case none = "No preference"
    case vegetarian = "Vegetarian"
    case vegan = "Vegan"
    case pescatarian = "Pescatarian"
    case glutenFree = "Gluten-free"
}

enum SubscriptionTier: String, Codable { case free, premium }
enum MealType: String, Codable, CaseIterable { case breakfast = "Breakfast", lunch = "Lunch", snack = "Snack", dinner = "Dinner" }
enum DataProvenance: String, Codable, CaseIterable { case userEntered, aiEstimated, nutritionDatabase, healthKit, imported }
enum MealStatus: String, Codable, CaseIterable { case logged, planned, deleted }
enum MeasurementUnit: String, Codable, CaseIterable { case serving, gram, ounce, cup, milliliter, piece }
enum MetricAvailability: String, Codable, Hashable { case available, unavailable, stale }
enum UnitSystem: String, Codable, CaseIterable { case metric, imperial }
enum AppAppearance: String, Codable, CaseIterable { case system, dark, light }
enum RecommendationFeedbackKind: String, Codable, CaseIterable { case dismissed, notRelevant, helpful }
enum PendingWorkState: String, Codable, CaseIterable { case pending, processing, failed, completed }
enum SyncOperationKind: String, Codable, CaseIterable { case create, update, delete }
enum SyncOperationState: String, Codable, CaseIterable { case pending, uploading, failed, completed }

struct UserProfile: Codable, Hashable {
    var firstName = ""
    var ageRange = ""
    var heightCM = 175.0
    var weightKG = 72.0
    var goal: UserGoal = .improveNutrition
    var activityLevel = "Moderately active"
    var dietaryPreference: DietaryPreference = .none
    var allergies: [String] = []
    var foodsToAvoid: [String] = []
    var timeZoneIdentifier = TimeZone.current.identifier
}

struct DailyTargets: Codable, Hashable {
    var calories = 2_450
    var proteinGrams = 120.0
    var carbohydrateGrams = 275.0
    var fatGrams = 80.0
    var fiberGrams = 30.0
    var hydrationMilliliters = 2_000.0
    var steps = 10_000
    var sleepMinutes = 480
}

struct NutrientValue: Codable, Hashable {
    var name: String
    var amount: Double
    var unit: String
    var provenance: DataProvenance = .aiEstimated
}

struct NutritionEstimate: Codable, Hashable {
    var calories: Int
    var protein: Double
    var carbohydrates: Double
    var fat: Double
    var fiber: Double
    var sugar: Double = 0
    var sodium: Double = 0
    var potassium: Double = 0
    var iron: Double = 0
    var calcium: Double = 0
    var vitaminC: Double = 0

    static let zero = NutritionEstimate(calories: 0, protein: 0, carbohydrates: 0, fat: 0, fiber: 0)

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbohydrates: lhs.carbohydrates + rhs.carbohydrates,
            fat: lhs.fat + rhs.fat,
            fiber: lhs.fiber + rhs.fiber,
            sugar: lhs.sugar + rhs.sugar,
            sodium: lhs.sodium + rhs.sodium,
            potassium: lhs.potassium + rhs.potassium,
            iron: lhs.iron + rhs.iron,
            calcium: lhs.calcium + rhs.calcium,
            vitaminC: lhs.vitaminC + rhs.vitaminC
        )
    }

    static func * (lhs: Self, rhs: Double) -> Self {
        .init(
            calories: Int((Double(lhs.calories) * rhs).rounded()),
            protein: lhs.protein * rhs,
            carbohydrates: lhs.carbohydrates * rhs,
            fat: lhs.fat * rhs,
            fiber: lhs.fiber * rhs,
            sugar: lhs.sugar * rhs,
            sodium: lhs.sodium * rhs,
            potassium: lhs.potassium * rhs,
            iron: lhs.iron * rhs,
            calcium: lhs.calcium * rhs,
            vitaminC: lhs.vitaminC * rhs
        )
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        .init(
            calories: lhs.calories - rhs.calories,
            protein: lhs.protein - rhs.protein,
            carbohydrates: lhs.carbohydrates - rhs.carbohydrates,
            fat: lhs.fat - rhs.fat,
            fiber: lhs.fiber - rhs.fiber,
            sugar: lhs.sugar - rhs.sugar,
            sodium: lhs.sodium - rhs.sodium,
            potassium: lhs.potassium - rhs.potassium,
            iron: lhs.iron - rhs.iron,
            calcium: lhs.calcium - rhs.calcium,
            vitaminC: lhs.vitaminC - rhs.vitaminC
        )
    }
}

struct MealItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var quantity: Double = 1
    var unit: MeasurementUnit = .serving
    var confidence: Double?
    var nutrition: NutritionEstimate = .zero
    var provenance: DataProvenance = .aiEstimated
    var foodIdentifier: String?
    var sourceName: String?
    var correctedAt: Date?
    var nutritionPer100Grams: NutritionEstimate?
    var gramsPerUnit: [MeasurementUnit: Double]?

    var serving: String { "\(quantity.formatted()) \(unit.rawValue)" }
    var isUserCorrected: Bool { correctedAt != nil || provenance == .userEntered }

    mutating func recalculateNutrition() {
        guard let nutritionPer100Grams else { return }
        let grams = quantity * (gramsPerUnit?[unit] ?? gramsPerUnit?[.serving] ?? 100)
        nutrition = nutritionPer100Grams * (grams / 100)
    }
}

struct FoodSearchResult: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var brand: String?
    var sourceName: String
    var nutritionPer100Grams: NutritionEstimate
    var gramsPerUnit: [MeasurementUnit: Double]
    var attributionURL: URL?

    var displayName: String { brand.map { "\(name) · \($0)" } ?? name }

    func nutrition(quantity: Double, unit: MeasurementUnit) -> NutritionEstimate {
        let grams = quantity * (gramsPerUnit[unit] ?? gramsPerUnit[.serving] ?? 100)
        return nutritionPer100Grams * (grams / 100)
    }
}

struct MealDraft: Hashable {
    var name: String
    var type: MealType
    var date: Date
    var nutrition: NutritionEstimate
    var items: [MealItem]
    var provenance: DataProvenance
    var confidence: Double?
    var imageData: Data?
    var notes: String = ""
    var status: MealStatus = .logged
    var removeExistingImage = false
}

struct MealTemplate: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var type: MealType
    var nutrition: NutritionEstimate
    var items: [MealItem]
    var notes: String
    var createdAt = Date.now

    init(meal: Meal) {
        name = meal.name
        type = meal.type
        nutrition = meal.nutrition
        items = meal.items
        notes = meal.notes
    }

    func draft(date: Date = .now) -> MealDraft {
        .init(name: name, type: type, date: date, nutrition: nutrition, items: items, provenance: .userEntered, confidence: nil, imageData: nil, notes: notes)
    }
}

struct UserPreferences: Codable, Hashable {
    var onboardingCompleted = false
    var unitSystem: UnitSystem = .metric
    var appearance: AppAppearance = .dark
    var mealRemindersEnabled = false
    var hydrationRemindersEnabled = false
    var dailyReviewEnabled = false
    var weeklySummaryEnabled = false
    var healthConnectionAlertsEnabled = true
    var goalProgressRemindersEnabled = false
    var mealReminderHours = [8, 12, 18]
    var hydrationReminderIntervalHours = 3
    var dailyReviewHour = 20
    var weeklySummaryWeekday = 1
    var weeklySummaryHour = 18
    var quietHoursStart = 21
    var quietHoursEnd = 7
    /// Opt-in, default off. Meal photos always stay on this device; this only allows a
    /// configured backend to keep an uploaded photo to improve recognition quality.
    var mealPhotoRetentionConsent = false

    var hasEnabledReminders: Bool {
        mealRemindersEnabled
            || hydrationRemindersEnabled
            || dailyReviewEnabled
            || weeklySummaryEnabled
            || goalProgressRemindersEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted, unitSystem, appearance
        case mealRemindersEnabled, hydrationRemindersEnabled, dailyReviewEnabled
        case weeklySummaryEnabled, healthConnectionAlertsEnabled, goalProgressRemindersEnabled
        case mealReminderHours, hydrationReminderIntervalHours, dailyReviewHour
        case weeklySummaryWeekday, weeklySummaryHour, quietHoursStart, quietHoursEnd
        case mealPhotoRetentionConsent
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        onboardingCompleted = try values.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        unitSystem = try values.decodeIfPresent(UnitSystem.self, forKey: .unitSystem) ?? .metric
        appearance = try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .dark
        mealRemindersEnabled = try values.decodeIfPresent(Bool.self, forKey: .mealRemindersEnabled) ?? false
        hydrationRemindersEnabled = try values.decodeIfPresent(Bool.self, forKey: .hydrationRemindersEnabled) ?? false
        dailyReviewEnabled = try values.decodeIfPresent(Bool.self, forKey: .dailyReviewEnabled) ?? false
        weeklySummaryEnabled = try values.decodeIfPresent(Bool.self, forKey: .weeklySummaryEnabled) ?? false
        healthConnectionAlertsEnabled = try values.decodeIfPresent(Bool.self, forKey: .healthConnectionAlertsEnabled) ?? true
        goalProgressRemindersEnabled = try values.decodeIfPresent(Bool.self, forKey: .goalProgressRemindersEnabled) ?? false
        mealReminderHours = try values.decodeIfPresent([Int].self, forKey: .mealReminderHours) ?? [8, 12, 18]
        hydrationReminderIntervalHours = try values.decodeIfPresent(Int.self, forKey: .hydrationReminderIntervalHours) ?? 3
        dailyReviewHour = try values.decodeIfPresent(Int.self, forKey: .dailyReviewHour) ?? 20
        weeklySummaryWeekday = try values.decodeIfPresent(Int.self, forKey: .weeklySummaryWeekday) ?? 1
        weeklySummaryHour = try values.decodeIfPresent(Int.self, forKey: .weeklySummaryHour) ?? 18
        quietHoursStart = try values.decodeIfPresent(Int.self, forKey: .quietHoursStart) ?? 21
        quietHoursEnd = try values.decodeIfPresent(Int.self, forKey: .quietHoursEnd) ?? 7
        mealPhotoRetentionConsent = try values.decodeIfPresent(Bool.self, forKey: .mealPhotoRetentionConsent) ?? false
    }
}

struct MealSummary: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var type: MealType
    var date: Date
    var nutrition: NutritionEstimate
    var provenance: DataProvenance
    var imageFileName: String?
    var itemNames: [String]?
    var status: MealStatus?
}

struct DailyNutritionSummary: Codable, Hashable {
    var consumed: NutritionEstimate = .zero
    var targets = DailyTargets()
    var hydrationMilliliters = 0.0
    var mealCount = 0
    var averageEstimateConfidence: Double?
    var verifiedMealCount: Int?

    var calories: Int { consumed.calories }
    var targetCalories: Int { targets.calories }
    var protein: Double { consumed.protein }
    var fiber: Double { consumed.fiber }
    var fiberGoal: Double { targets.fiberGrams }
    var hydrationCups: Int { Int((hydrationMilliliters / 250).rounded(.down)) }
    var hydrationGoal: Int { Int((targets.hydrationMilliliters / 250).rounded(.up)) }
}

struct DailyActivitySummary: Codable, Hashable {
    var steps = 0
    var stepGoal = 10_000
    var activeCalories = 0
    var yesterdayActiveCalories: Int?
    var availability: MetricAvailability = .unavailable
    var lastUpdated: Date?
    var basalCalories: Int?
    var exerciseMinutes: Int?
    var restingHeartRate: Double?
    var averageHeartRate: Double?
    var sourceNames: [String] = []
}

struct BodyMeasurementSummary: Codable, Hashable {
    var bodyMassKilograms: Double?
    var heightCentimeters: Double?
    var lastUpdated: Date?
    var availability: MetricAvailability = .unavailable
}

struct SleepSummary: Codable, Hashable {
    var durationMinutes = 0
    var targetMinutes = 480
    var quality = "No data"
    var availability: MetricAvailability = .unavailable
    var lastUpdated: Date?

    var durationHours: Double { Double(durationMinutes) / 60 }
}

struct WorkoutSummary: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var startDate: Date
    var minutes: Int
    var calories: Int
}

struct DayInterval: Codable, Hashable {
    var start: Date
    var end: Date
    var timeZoneIdentifier: String

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

struct DailyHealthSnapshot: Codable, Hashable {
    var interval: DayInterval
    var nutrition: DailyNutritionSummary
    var activity: DailyActivitySummary
    var sleep: SleepSummary
    var meals: [MealSummary]
    var workouts: [WorkoutSummary]
    var lastUpdated: Date
    var isFromCache: Bool
    var body: BodyMeasurementSummary? = nil

    var dataCompleteness: Double {
        var available = nutrition.mealCount > 0 ? 2.0 : 0
        available += nutrition.hydrationMilliliters > 0 ? 1 : 0
        available += activity.availability == .available ? 1 : 0
        available += sleep.availability == .available ? 1 : 0
        return available / 5
    }

    static func empty(for interval: DayInterval, targets: DailyTargets = .init()) -> Self {
        .init(
            interval: interval,
            nutrition: .init(targets: targets),
            activity: .init(stepGoal: targets.steps),
            sleep: .init(targetMinutes: targets.sleepMinutes),
            meals: [],
            workouts: [],
            lastUpdated: .now,
            isFromCache: false,
            body: nil
        )
    }
}

enum CalorieBalanceAvailability: String, Codable, Hashable { case complete, partial, unavailable }

struct CalorieBalance: Codable, Hashable {
    var consumedCalories: Int
    var targetCalories: Int
    var activeCalories: Int?
    var basalCalories: Int?
    var estimatedRemaining: Int
    var estimatedExpenditureRange: ClosedRange<Int>?
    var availability: CalorieBalanceAvailability
    var explanation: String
}

enum HealthScoreCategory: String, Codable, CaseIterable { case nutrition = "Nutrition", protein = "Protein", hydration = "Hydration", fiber = "Fiber", recovery = "Recovery" }
struct HealthScore: Codable, Hashable {
    var overall: Int
    var categories: [HealthScoreCategory: Int]
    var unavailableCategories: Set<HealthScoreCategory> = []
    var message: String
    var algorithmVersion = 2
    var evidenceCompleteness = 0.0
    var categoryExplanations: [HealthScoreCategory: String] = [:]
}
struct NutritionRecommendation: Codable, Hashable {
    var key = UUID().uuidString
    var title: String
    var reason: String
    var estimatedImprovement: Int
    var nutrients: [String]
    var alternatives: [String] = []
    var dataUsed: [String] = []
    var limitation = "Based on currently logged estimates."
    var confidence = 0.5
}
struct FoodRecognitionResult: Codable, Hashable {
    var mealName: String
    var items: [MealItem]
    var nutrition: NutritionEstimate
    var confidence: Double
    var alternatives: [FoodSearchResult] = []
    var warnings: [String] = []
    var isPartial = false
}
struct Insight: Identifiable, Hashable { var id = UUID(); var title: String; var detail: String; var systemImage: String; var isPremium = false }
struct DailyHealthInput {
    var nutrition: DailyNutritionSummary
    var activity: DailyActivitySummary
    var sleep: SleepSummary
    var workouts: [WorkoutSummary] = []
    var meals: [MealSummary] = []
    var profile = UserProfile()
    var date = Date.now
    var excludedRecommendationKeys: Set<String> = []
}

struct GoalCalculationResult: Hashable {
    var targets: DailyTargets
    var explanation: String
    var assumptions: [String]
    /// Set when the calculator had to soften an adjustment (rather than apply it as computed).
    /// Also present in `assumptions`; surfaced separately so UI can show it next to the control.
    var adjustmentNote: String? = nil
}

// MARK: - SwiftData records

@Model
final class Meal {
    @Attribute(.unique) var id: UUID
    var name: String
    var typeRaw: String
    var date: Date
    var timeZoneIdentifier: String
    var calories: Int
    var protein: Double
    var carbohydrates: Double
    var fat: Double
    var fiber: Double
    var sugar: Double
    var sodium: Double
    var potassium: Double
    var iron: Double
    var calcium: Double
    var vitaminC: Double
    var itemsData: Data
    var sourceRaw: String
    var statusRaw: String
    var confidence: Double?
    var imageFileName: String?
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    var type: MealType { get { MealType(rawValue: typeRaw) ?? .snack } set { typeRaw = newValue.rawValue } }
    var provenance: DataProvenance { get { DataProvenance(rawValue: sourceRaw) ?? .userEntered } set { sourceRaw = newValue.rawValue } }
    var status: MealStatus { get { MealStatus(rawValue: statusRaw) ?? .logged } set { statusRaw = newValue.rawValue } }
    var nutrition: NutritionEstimate {
        .init(calories: calories, protein: protein, carbohydrates: carbohydrates, fat: fat, fiber: fiber, sugar: sugar, sodium: sodium, potassium: potassium, iron: iron, calcium: calcium, vitaminC: vitaminC)
    }
    var items: [MealItem] { (try? JSONDecoder().decode([MealItem].self, from: itemsData)) ?? [] }
    var summary: MealSummary { .init(id: id, name: name, type: type, date: date, nutrition: nutrition, provenance: provenance, imageFileName: imageFileName, itemNames: items.map(\.name), status: status) }

    init(id: UUID = UUID(), name: String, type: MealType, date: Date, nutrition: NutritionEstimate, items: [MealItem] = [], provenance: DataProvenance = .userEntered, confidence: Double? = nil, imageFileName: String? = nil, notes: String = "", status: MealStatus = .logged) {
        self.id = id
        self.name = name
        typeRaw = type.rawValue
        self.date = date
        timeZoneIdentifier = TimeZone.current.identifier
        calories = nutrition.calories
        protein = nutrition.protein
        carbohydrates = nutrition.carbohydrates
        fat = nutrition.fat
        fiber = nutrition.fiber
        sugar = nutrition.sugar
        sodium = nutrition.sodium
        potassium = nutrition.potassium
        iron = nutrition.iron
        calcium = nutrition.calcium
        vitaminC = nutrition.vitaminC
        itemsData = (try? JSONEncoder().encode(items)) ?? Data()
        sourceRaw = provenance.rawValue
        statusRaw = status.rawValue
        self.confidence = confidence
        self.imageFileName = imageFileName
        self.notes = notes
        createdAt = .now
        updatedAt = .now
    }

    convenience init(id: UUID = UUID(), name: String, type: MealType, date: Date, nutrition: NutritionEstimate, itemNames: [String]) {
        self.init(id: id, name: name, type: type, date: date, nutrition: nutrition, items: itemNames.map { MealItem(name: $0) })
    }

    func update(with draft: MealDraft, imageFileName: String? = nil) {
        name = draft.name
        type = draft.type
        date = draft.date
        timeZoneIdentifier = TimeZone.current.identifier
        calories = draft.nutrition.calories
        protein = draft.nutrition.protein
        carbohydrates = draft.nutrition.carbohydrates
        fat = draft.nutrition.fat
        fiber = draft.nutrition.fiber
        sugar = draft.nutrition.sugar
        sodium = draft.nutrition.sodium
        potassium = draft.nutrition.potassium
        iron = draft.nutrition.iron
        calcium = draft.nutrition.calcium
        vitaminC = draft.nutrition.vitaminC
        itemsData = (try? JSONEncoder().encode(draft.items)) ?? itemsData
        provenance = draft.provenance
        status = draft.status
        confidence = draft.confidence
        notes = draft.notes
        if let imageFileName { self.imageFileName = imageFileName }
        updatedAt = .now
    }
}

@Model
final class UserProfileRecord {
    @Attribute(.unique) var key: String
    var firstName: String
    var ageRange: String
    var heightCM: Double
    var weightKG: Double
    var goalRaw: String
    var activityLevel: String
    var dietaryPreferenceRaw: String
    var allergies: [String]
    var foodsToAvoid: [String]
    var timeZoneIdentifier: String
    var updatedAt: Date

    var domainValue: UserProfile {
        .init(firstName: firstName, ageRange: ageRange, heightCM: heightCM, weightKG: weightKG, goal: UserGoal(rawValue: goalRaw) ?? .improveNutrition, activityLevel: activityLevel, dietaryPreference: DietaryPreference(rawValue: dietaryPreferenceRaw) ?? .none, allergies: allergies, foodsToAvoid: foodsToAvoid, timeZoneIdentifier: timeZoneIdentifier)
    }

    init(key: String = "primary", profile: UserProfile = .init()) {
        self.key = key
        firstName = profile.firstName
        ageRange = profile.ageRange
        heightCM = profile.heightCM
        weightKG = profile.weightKG
        goalRaw = profile.goal.rawValue
        activityLevel = profile.activityLevel
        dietaryPreferenceRaw = profile.dietaryPreference.rawValue
        allergies = profile.allergies
        foodsToAvoid = profile.foodsToAvoid
        timeZoneIdentifier = profile.timeZoneIdentifier
        updatedAt = .now
    }

    func update(with profile: UserProfile) {
        firstName = profile.firstName
        ageRange = profile.ageRange
        heightCM = profile.heightCM
        weightKG = profile.weightKG
        goalRaw = profile.goal.rawValue
        activityLevel = profile.activityLevel
        dietaryPreferenceRaw = profile.dietaryPreference.rawValue
        allergies = profile.allergies
        foodsToAvoid = profile.foodsToAvoid
        timeZoneIdentifier = profile.timeZoneIdentifier
        updatedAt = .now
    }
}

@Model
final class DailyTargetRecord {
    @Attribute(.unique) var key: String
    var calories: Int
    var proteinGrams: Double
    var carbohydrateGrams: Double
    var fatGrams: Double
    var fiberGrams: Double
    var hydrationMilliliters: Double
    var steps: Int
    var sleepMinutes: Int
    var effectiveDate: Date
    var updatedAt: Date

    var domainValue: DailyTargets { .init(calories: calories, proteinGrams: proteinGrams, carbohydrateGrams: carbohydrateGrams, fatGrams: fatGrams, fiberGrams: fiberGrams, hydrationMilliliters: hydrationMilliliters, steps: steps, sleepMinutes: sleepMinutes) }

    init(key: String = "current", targets: DailyTargets = .init(), effectiveDate: Date = .now) {
        self.key = key
        calories = targets.calories
        proteinGrams = targets.proteinGrams
        carbohydrateGrams = targets.carbohydrateGrams
        fatGrams = targets.fatGrams
        fiberGrams = targets.fiberGrams
        hydrationMilliliters = targets.hydrationMilliliters
        steps = targets.steps
        sleepMinutes = targets.sleepMinutes
        self.effectiveDate = effectiveDate
        updatedAt = .now
    }
}

@Model
final class HydrationEntry {
    @Attribute(.unique) var id: UUID
    var date: Date
    var amountMilliliters: Double
    var sourceRaw: String
    var createdAt: Date

    var provenance: DataProvenance { DataProvenance(rawValue: sourceRaw) ?? .userEntered }

    init(id: UUID = UUID(), date: Date = .now, amountMilliliters: Double, provenance: DataProvenance = .userEntered) {
        self.id = id
        self.date = date
        self.amountMilliliters = amountMilliliters
        sourceRaw = provenance.rawValue
        createdAt = .now
    }
}

@Model
final class AppSettingsRecord {
    @Attribute(.unique) var key: String
    var unitSystem: String
    var healthKitEnabled: Bool
    var notificationsEnabled: Bool
    var schemaVersion: Int
    var updatedAt: Date

    init(key: String = "settings", unitSystem: String = "metric", healthKitEnabled: Bool = false, notificationsEnabled: Bool = false, schemaVersion: Int = 1) {
        self.key = key
        self.unitSystem = unitSystem
        self.healthKitEnabled = healthKitEnabled
        self.notificationsEnabled = notificationsEnabled
        self.schemaVersion = schemaVersion
        updatedAt = .now
    }
}

@Model
final class DailySummaryCacheRecord {
    @Attribute(.unique) var dayKey: String
    var payloadData: Data
    var sourceRevision: Int
    var updatedAt: Date

    var snapshot: DailyHealthSnapshot? { try? JSONDecoder().decode(DailyHealthSnapshot.self, from: payloadData) }

    init(dayKey: String, snapshot: DailyHealthSnapshot, sourceRevision: Int) {
        self.dayKey = dayKey
        payloadData = (try? JSONEncoder().encode(snapshot)) ?? Data()
        self.sourceRevision = sourceRevision
        updatedAt = .now
    }

    func update(snapshot: DailyHealthSnapshot, sourceRevision: Int) {
        payloadData = (try? JSONEncoder().encode(snapshot)) ?? Data()
        self.sourceRevision = sourceRevision
        updatedAt = .now
    }
}

@Model
final class UserPreferencesRecord {
    @Attribute(.unique) var key: String
    /// Every `UserPreferences` field, including `mealPhotoRetentionConsent`, lives in this blob.
    /// Adding a field is therefore schema-neutral: no column, no version bump, and a payload
    /// written before the field existed decodes it as `false` via `decodeIfPresent`.
    var payloadData: Data
    var updatedAt: Date

    var domainValue: UserPreferences {
        (try? JSONDecoder().decode(UserPreferences.self, from: payloadData)) ?? .init()
    }

    init(key: String = "preferences", preferences: UserPreferences = .init()) {
        self.key = key
        payloadData = (try? JSONEncoder().encode(preferences)) ?? Data()
        updatedAt = .now
    }

    func update(with preferences: UserPreferences) {
        payloadData = (try? JSONEncoder().encode(preferences)) ?? payloadData
        updatedAt = .now
    }
}

@Model
final class FavoriteMealRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var payloadData: Data
    var createdAt: Date
    var updatedAt: Date

    var template: MealTemplate? { try? JSONDecoder().decode(MealTemplate.self, from: payloadData) }

    init(template: MealTemplate) {
        id = template.id
        name = template.name
        payloadData = (try? JSONEncoder().encode(template)) ?? Data()
        createdAt = .now
        updatedAt = .now
    }
}

@Model
final class GoalHistoryRecord {
    @Attribute(.unique) var id: UUID
    var payloadData: Data
    var effectiveDate: Date
    var explanation: String
    var createdAt: Date

    var targets: DailyTargets? { try? JSONDecoder().decode(DailyTargets.self, from: payloadData) }

    init(id: UUID = UUID(), targets: DailyTargets, effectiveDate: Date = .now, explanation: String) {
        self.id = id
        payloadData = (try? JSONEncoder().encode(targets)) ?? Data()
        self.effectiveDate = effectiveDate
        self.explanation = explanation
        createdAt = .now
    }
}

@Model
final class RecommendationFeedbackRecord {
    @Attribute(.unique) var id: UUID
    var recommendationKey: String
    var kindRaw: String
    var createdAt: Date

    var kind: RecommendationFeedbackKind { RecommendationFeedbackKind(rawValue: kindRaw) ?? .dismissed }

    init(id: UUID = UUID(), recommendationKey: String, kind: RecommendationFeedbackKind, createdAt: Date = .now) {
        self.id = id
        self.recommendationKey = recommendationKey
        kindRaw = kind.rawValue
        self.createdAt = createdAt
    }
}

@Model
final class ProcessedExternalCommandRecord {
    @Attribute(.unique) var id: UUID
    var kind: String
    var processedAt: Date

    init(id: UUID, kind: String, processedAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.processedAt = processedAt
    }
}

@Model
final class PendingRecognitionRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var idempotencyKey: String
    var photoFileName: String
    var stateRaw: String
    var attempts: Int
    var createdAt: Date
    var updatedAt: Date
    var nextAttemptAt: Date?
    var lastError: String?
    var resultData: Data?

    var state: PendingWorkState {
        get { PendingWorkState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        idempotencyKey: String = UUID().uuidString,
        photoFileName: String,
        state: PendingWorkState = .pending,
        attempts: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.photoFileName = photoFileName
        stateRaw = state.rawValue
        self.attempts = attempts
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}

@Model
final class SyncOperationRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var idempotencyKey: String
    var entityType: String
    var entityIdentifier: String
    var operationRaw: String
    var stateRaw: String
    var payloadData: Data
    var clientRevision: Int
    var attempts: Int
    var createdAt: Date
    var updatedAt: Date
    var nextAttemptAt: Date?
    var lastError: String?

    var operation: SyncOperationKind {
        get { SyncOperationKind(rawValue: operationRaw) ?? .update }
        set { operationRaw = newValue.rawValue }
    }

    var state: SyncOperationState {
        get { SyncOperationState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        idempotencyKey: String = UUID().uuidString,
        entityType: String,
        entityIdentifier: String,
        operation: SyncOperationKind,
        payloadData: Data,
        clientRevision: Int,
        state: SyncOperationState = .pending
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.entityType = entityType
        self.entityIdentifier = entityIdentifier
        operationRaw = operation.rawValue
        stateRaw = state.rawValue
        self.payloadData = payloadData
        self.clientRevision = clientRevision
        attempts = 0
        createdAt = .now
        updatedAt = .now
    }
}

@Model
final class AccountMetadataRecord {
    @Attribute(.unique) var key: String
    var appleUserIdentifierHash: String?
    var displayName: String?
    var emailHint: String?
    var syncEnabled: Bool
    var lastSyncAt: Date?
    var serverRevision: Int
    var updatedAt: Date

    init(
        key: String = "primary",
        appleUserIdentifierHash: String? = nil,
        displayName: String? = nil,
        emailHint: String? = nil,
        syncEnabled: Bool = false,
        lastSyncAt: Date? = nil,
        serverRevision: Int = 0
    ) {
        self.key = key
        self.appleUserIdentifierHash = appleUserIdentifierHash
        self.displayName = displayName
        self.emailHint = emailHint
        self.syncEnabled = syncEnabled
        self.lastSyncAt = lastSyncAt
        self.serverRevision = serverRevision
        updatedAt = .now
    }
}

@Model
final class RemoteConfigurationRecord {
    @Attribute(.unique) var environment: String
    var payloadData: Data
    var signature: String?
    var fetchedAt: Date
    var expiresAt: Date

    init(environment: String, payloadData: Data, signature: String? = nil, fetchedAt: Date = .now, expiresAt: Date) {
        self.environment = environment
        self.payloadData = payloadData
        self.signature = signature
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
    }
}

enum FuelSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Meal.self, UserProfileRecord.self, DailyTargetRecord.self, HydrationEntry.self, AppSettingsRecord.self, DailySummaryCacheRecord.self]
    }
}

enum FuelSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Meal.self,
            UserProfileRecord.self,
            DailyTargetRecord.self,
            HydrationEntry.self,
            AppSettingsRecord.self,
            DailySummaryCacheRecord.self,
            UserPreferencesRecord.self,
            FavoriteMealRecord.self,
            GoalHistoryRecord.self,
            RecommendationFeedbackRecord.self
        ]
    }
}

enum FuelSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        FuelSchemaV2.models + [
            ProcessedExternalCommandRecord.self,
            PendingRecognitionRecord.self,
            SyncOperationRecord.self,
            AccountMetadataRecord.self,
            RemoteConfigurationRecord.self
        ]
    }
}

// NOTE: `mealPhotoRetentionConsent` deliberately did NOT get a V4 schema version.
//
// Every version above lists the same live `@Model` types, so a V4 whose `models` array
// equals V3's produces an identical entity checksum, and `ModelContainer(migrationPlan:)`
// aborts with an uncatchable `NSInvalidArgumentException: Duplicate version checksums
// detected` — the app hard-crashes in `FuelApp.init`, before its `do/catch` fallback.
//
// The documented fix is to snapshot the old `UserPreferencesRecord` shape inside
// `FuelSchemaV3` so V3 and V4 differ. That requires `FuelApp.swift` to open its container
// at V4 (it pins `FuelSchemaV3`), because a snapshotted V3 no longer registers the live
// class that `Repositories.swift` fetches. Until the app entry point moves to V4, storing
// the flag in `payloadData` keeps the change schema-neutral and needs no migration at all.
enum FuelMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [FuelSchemaV1.self, FuelSchemaV2.self, FuelSchemaV3.self] }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: FuelSchemaV1.self, toVersion: FuelSchemaV2.self),
            .lightweight(fromVersion: FuelSchemaV2.self, toVersion: FuelSchemaV3.self)
        ]
    }
}
