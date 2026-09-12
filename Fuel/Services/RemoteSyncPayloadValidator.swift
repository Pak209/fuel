import Foundation

/// Validates remote values before any part of a sync response is persisted. These
/// are storage/math limits, not recommended nutrition or body-measurement targets.
enum RemoteSyncPayloadValidator {
    private static let maximumPayloadBytes = 1_000_000
    private static let supportedDateRange = -2_208_988_800.0...7_258_118_400.0 // 1900–2200
    private static let maximumRevision = 9_007_199_254_740_991 // Exact JSON integer across platforms.

    static func validate(_ change: SyncConflict) throws {
        do {
            guard (0...maximumRevision).contains(change.serverRevision),
                  change.serverPayload.count <= maximumPayloadBytes else { throw BackendError.invalidPayload }
            try validateDate(change.serverUpdatedAt)

            // Sync payloads are nested Data encoded with the domain JSONEncoder's
            // default date strategy, independently of the outer ISO-8601 envelope.
            let decoder = JSONDecoder()
            switch change.entityType {
            case "meal":
                guard let id = UUID(uuidString: change.entityIdentifier) else { throw BackendError.invalidPayload }
                if change.operation == .delete, change.serverPayload.isEmpty { return }
                let meal = try decoder.decode(ExportedMeal.self, from: change.serverPayload)
                guard meal.id == id else { throw BackendError.invalidPayload }
                try validateMeal(meal)
            case "hydration":
                guard let id = UUID(uuidString: change.entityIdentifier) else { throw BackendError.invalidPayload }
                if change.operation == .delete, change.serverPayload.isEmpty { return }
                let entry = try decoder.decode(ExportedHydration.self, from: change.serverPayload)
                guard entry.id == id else { throw BackendError.invalidPayload }
                try validateDate(entry.date)
                try validateNumber(entry.amountMilliliters, in: 0...20_000, strictlyPositive: true)
            case "profile":
                try validateSingleton(change, identifier: "primary")
                try validateProfile(decoder.decode(UserProfile.self, from: change.serverPayload))
            case "targets":
                try validateSingleton(change, identifier: "current")
                try validateTargets(decoder.decode(DailyTargets.self, from: change.serverPayload))
            case "preferences":
                try validateSingleton(change, identifier: "primary")
                try validatePreferences(decoder.decode(CompletePreferencesDocument.self, from: change.serverPayload).value)
            default:
                throw BackendError.invalidPayload
            }
        } catch {
            // Do not expose decoder paths, payload fragments, or arbitrary errors.
            throw BackendError.invalidPayload
        }
    }

    private static func validateSingleton(_ change: SyncConflict, identifier: String) throws {
        guard change.entityIdentifier == identifier, change.operation != .delete else { throw BackendError.invalidPayload }
    }

    private static func validateMeal(_ meal: ExportedMeal) throws {
        try validateText(meal.name, maximumCharacters: 300, permitsEmpty: false)
        try validateText(meal.notes, maximumCharacters: 10_000)
        try validateTimeZone(meal.timeZoneIdentifier)
        try validateDate(meal.date)
        try validateDate(meal.createdAt)
        try validateDate(meal.updatedAt)
        try validateConfidence(meal.confidence)
        try validateNutrition(meal.nutrition)
        guard meal.items.count <= 100,
              Set(meal.items.map(\.id)).count == meal.items.count else { throw BackendError.invalidPayload }
        for item in meal.items { try validateItem(item) }
    }

    private static func validateItem(_ item: MealItem) throws {
        try validateText(item.name, maximumCharacters: 300, permitsEmpty: false)
        try validateNumber(item.quantity, in: 0...100_000, strictlyPositive: true)
        try validateConfidence(item.confidence)
        try validateNutrition(item.nutrition)
        if let identifier = item.foodIdentifier { try validateText(identifier, maximumCharacters: 512) }
        if let source = item.sourceName { try validateText(source, maximumCharacters: 300) }
        if let date = item.correctedAt { try validateDate(date) }
        if let conversions = item.gramsPerUnit {
            guard conversions.count <= MeasurementUnit.allCases.count else { throw BackendError.invalidPayload }
            for grams in conversions.values { try validateNumber(grams, in: 0...100_000, strictlyPositive: true) }
        }
        if let per100Grams = item.nutritionPer100Grams {
            try validateNutrition(per100Grams)
            // The editor can switch units without changing quantity. Check every
            // selectable conversion, including the same fallback used by MealItem.
            for unit in MeasurementUnit.allCases {
                let gramsPerUnit = item.gramsPerUnit?[unit] ?? item.gramsPerUnit?[.serving] ?? 100
                let multiplier = item.quantity * gramsPerUnit / 100
                let scaledCalories = Double(per100Grams.calories) * multiplier
                guard multiplier.isFinite, multiplier > 0,
                      scaledCalories.isFinite,
                      scaledCalories < Double(Int.max / 1_000),
                      nutrientAmounts(per100Grams).allSatisfy({ ($0 * multiplier).isFinite && $0 * multiplier <= 1_000_000_000_000 }) else {
                    throw BackendError.invalidPayload
                }
            }
        }
    }

    private static func validateNutrition(_ value: NutritionEstimate) throws {
        guard (0...100_000).contains(value.calories) else { throw BackendError.invalidPayload }
        for grams in [value.protein, value.carbohydrates, value.fat, value.fiber, value.sugar] {
            try validateNumber(grams, in: 0...10_000)
        }
        for milligrams in [value.sodium, value.potassium, value.iron, value.calcium, value.vitaminC] {
            try validateNumber(milligrams, in: 0...1_000_000)
        }
    }

    private static func nutrientAmounts(_ value: NutritionEstimate) -> [Double] {
        [value.protein, value.carbohydrates, value.fat, value.fiber, value.sugar,
         value.sodium, value.potassium, value.iron, value.calcium, value.vitaminC]
    }

    private static func validateProfile(_ profile: UserProfile) throws {
        // A newly installed local profile has no first name or age range yet.
        try validateText(profile.firstName, maximumCharacters: 60)
        try validateText(profile.ageRange, maximumCharacters: 32)
        try validateText(profile.activityLevel, maximumCharacters: 40)
        try validateTimeZone(profile.timeZoneIdentifier)
        try validateNumber(profile.heightCM, in: 60...260)
        try validateNumber(profile.weightKG, in: 20...400)
        for list in [profile.allergies, profile.foodsToAvoid] {
            guard list.count <= 40 else { throw BackendError.invalidPayload }
            for item in list { try validateText(item, maximumCharacters: 80, permitsEmpty: false) }
        }
    }

    private static func validateTargets(_ targets: DailyTargets) throws {
        // Wider than the editor's stepper bounds to preserve previously stored
        // targets and the calculator's gradual-adjustment results.
        guard (1_000...6_000).contains(targets.calories),
              (0...100_000).contains(targets.steps),
              (60...1_440).contains(targets.sleepMinutes) else { throw BackendError.invalidPayload }
        try validateNumber(targets.proteinGrams, in: 1...1_000)
        try validateNumber(targets.carbohydrateGrams, in: 1...1_000)
        try validateNumber(targets.fatGrams, in: 1...1_000)
        try validateNumber(targets.fiberGrams, in: 1...250)
        try validateNumber(targets.hydrationMilliliters, in: 250...10_000)
    }

    private static func validatePreferences(_ preferences: UserPreferences) throws {
        guard preferences.mealReminderHours.count <= 3,
              preferences.mealReminderHours.allSatisfy({ (0...23).contains($0) }),
              (1...8).contains(preferences.hydrationReminderIntervalHours),
              (0...23).contains(preferences.dailyReviewHour),
              (1...7).contains(preferences.weeklySummaryWeekday),
              (0...23).contains(preferences.weeklySummaryHour),
              (0...23).contains(preferences.quietHoursStart),
              (0...23).contains(preferences.quietHoursEnd) else { throw BackendError.invalidPayload }
    }

    private static func validateText(_ value: String, maximumCharacters: Int, permitsEmpty: Bool = true) throws {
        // A visible character may contain multiple Unicode scalars (accented
        // letters or joined emoji). Bound bytes separately without assuming four
        // bytes is the maximum size of a user-perceived character.
        guard value.count <= maximumCharacters, value.utf8.count <= maximumCharacters * 32,
              permitsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendError.invalidPayload
        }
    }

    private static func validateNumber(_ value: Double, in range: ClosedRange<Double>, strictlyPositive: Bool = false) throws {
        guard value.isFinite, range.contains(value), !strictlyPositive || value > 0 else { throw BackendError.invalidPayload }
    }

    private static func validateConfidence(_ value: Double?) throws {
        if let value { try validateNumber(value, in: 0...1) }
    }

    private static func validateDate(_ date: Date) throws {
        try validateNumber(date.timeIntervalSince1970, in: supportedDateRange)
    }

    private static func validateTimeZone(_ identifier: String) throws {
        try validateText(identifier, maximumCharacters: 100, permitsEmpty: false)
        guard TimeZone(identifier: identifier) != nil else { throw BackendError.invalidPayload }
    }

    /// Local preference migration permits missing fields; a remote sync change
    /// replaces the entire document, so missing fields cannot silently reset it.
    /// The later-added photo-retention field alone may be absent, defaulting off.
    private struct CompletePreferencesDocument: Decodable {
        let value: UserPreferences

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case onboardingCompleted, unitSystem, appearance
            case mealRemindersEnabled, hydrationRemindersEnabled, dailyReviewEnabled
            case weeklySummaryEnabled, healthConnectionAlertsEnabled, goalProgressRemindersEnabled
            case mealReminderHours, hydrationReminderIntervalHours, dailyReviewHour
            case weeklySummaryWeekday, weeklySummaryHour, quietHoursStart, quietHoursEnd
            case mealPhotoRetentionConsent
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            for key in CodingKeys.allCases {
                if key == .mealPhotoRetentionConsent, !fields.contains(key) { continue }
                guard fields.contains(key), !(try fields.decodeNil(forKey: key)) else {
                    throw BackendError.invalidPayload
                }
            }
            value = try UserPreferences(from: decoder)
        }
    }
}
