import Foundation
import Testing
@testable import Fuel

@MainActor
struct RemoteSyncPayloadTests {
    @Test func acceptsLocalEncoderRoundTripsForEverySupportedEntity() throws {
        let meal = makeMeal()
        let water = ExportedHydration(id: UUID(), date: .now, amountMilliliters: 250, provenance: .userEntered)
        let changes = [
            try change("meal", id: meal.id.uuidString, value: meal),
            try change("hydration", id: water.id.uuidString, value: water),
            try change("profile", id: "primary", value: UserProfile()),
            try change("targets", id: "current", value: DailyTargets()),
            try change("preferences", id: "primary", value: UserPreferences())
        ]
        for change in changes { try RemoteSyncPayloadValidator.validate(change) }
    }

    @Test func acceptsFractionalGramPortionsAndEveryUnitConversion() throws {
        var meal = makeMeal()
        meal.items = [MealItem(
            name: "Almonds", quantity: 28.5, unit: .gram,
            nutrition: .init(calories: 165, protein: 6, carbohydrates: 6, fat: 14, fiber: 3),
            provenance: .nutritionDatabase,
            foodIdentifier: "almonds", sourceName: "Fuel common foods",
            nutritionPer100Grams: .init(calories: 579, protein: 21, carbohydrates: 22, fat: 50, fiber: 12),
            gramsPerUnit: [.gram: 1, .ounce: 28.3495, .serving: 28, .cup: 143, .piece: 1.2]
        )]
        try RemoteSyncPayloadValidator.validate(change("meal", id: meal.id.uuidString, value: meal))
    }

    @Test func acceptsCalculatorTargetsIncludingGradualAdjustmentOutsideStepperRange() throws {
        var profile = UserProfile()
        profile.weightKG = 35
        profile.activityLevel = "Sedentary"
        let result = ConservativeGoalCalculationService().calculate(profile: profile, previousTargets: DailyTargets(calories: 4_500))
        #expect(result.targets.carbohydrateGrams > 600)
        try RemoteSyncPayloadValidator.validate(change("targets", id: "current", value: result.targets))
    }

    @Test func acceptsLegacyPreferencesDefaultsAndValidEdgeSchedules() throws {
        var legacyDocument = try object(UserPreferences())
        legacyDocument.removeValue(forKey: "mealPhotoRetentionConsent")
        let legacy = rawChange("preferences", id: "primary", data: try JSONSerialization.data(withJSONObject: legacyDocument))
        try RemoteSyncPayloadValidator.validate(legacy)
        var preferences = UserPreferences()
        preferences.mealReminderHours = [0, 12, 23]
        preferences.hydrationReminderIntervalHours = 8
        preferences.weeklySummaryWeekday = 7
        preferences.quietHoursStart = 0
        preferences.quietHoursEnd = 0
        try RemoteSyncPayloadValidator.validate(change("preferences", id: "primary", value: preferences))
    }

    @Test func rejectsIncompletePreferencesInsteadOfSilentlyResettingLocalSettings() throws {
        expectRejected(rawChange("preferences", id: "primary", data: Data("{}".utf8)))
        let complete = try object(UserPreferences())
        for key in complete.keys {
            var document = complete
            document[key] = NSNull()
            expectRejected(rawChange("preferences", id: "primary", data: try JSONSerialization.data(withJSONObject: document)))
            if key != "mealPhotoRetentionConsent" {
                document.removeValue(forKey: key)
                expectRejected(rawChange("preferences", id: "primary", data: try JSONSerialization.data(withJSONObject: document)))
            }
        }
    }

    @Test func rejectsMissingRequiredFieldsInOtherDomainSnapshots() throws {
        let meal = makeMeal()
        let water = ExportedHydration(id: UUID(), date: .now, amountMilliliters: 250, provenance: .userEntered)
        let examples: [(String, String, [String: Any], String)] = [
            ("meal", meal.id.uuidString, try object(meal), "date"),
            ("meal", meal.id.uuidString, try object(meal), "nutrition"),
            ("hydration", water.id.uuidString, try object(water), "amountMilliliters"),
            ("profile", "primary", try object(UserProfile()), "firstName"),
            ("profile", "primary", try object(UserProfile()), "allergies"),
            ("targets", "current", try object(DailyTargets()), "calories")
        ]
        for (entity, id, original, key) in examples {
            var document = original
            document.removeValue(forKey: key)
            expectRejected(rawChange(entity, id: id, data: try JSONSerialization.data(withJSONObject: document)))
            document[key] = NSNull()
            expectRejected(rawChange(entity, id: id, data: try JSONSerialization.data(withJSONObject: document)))
        }
    }

    @Test func acceptsUnicodeNamesWithoutTreatingJoinedEmojiAsFourByteCharacters() throws {
        var profile = UserProfile()
        profile.firstName = String(repeating: "👨‍👩‍👧‍👦", count: 30)
        #expect(profile.firstName.count == 30)
        try RemoteSyncPayloadValidator.validate(change("profile", id: "primary", value: profile))
    }

    @Test func acceptsEmptyTombstonesOnlyForMealsAndHydration() throws {
        for entity in ["meal", "hydration"] {
            let deletion = rawChange(entity, id: UUID().uuidString, operation: .delete, data: Data())
            try RemoteSyncPayloadValidator.validate(deletion)
        }
        for (entity, id) in [("profile", "primary"), ("targets", "current"), ("preferences", "primary")] {
            expectRejected(rawChange(entity, id: id, operation: .delete, data: Data()))
        }
    }

    @Test func validatesPayloadWhenTombstoneContainsOne() throws {
        let meal = makeMeal()
        var deletion = try change("meal", id: meal.id.uuidString, value: meal)
        deletion.operation = .delete
        try RemoteSyncPayloadValidator.validate(deletion)
        deletion.entityIdentifier = UUID().uuidString
        expectRejected(deletion)
        deletion.entityIdentifier = meal.id.uuidString
        deletion.serverPayload = Data("malformed".utf8)
        expectRejected(deletion)
    }

    @Test func rejectsUnknownEntitiesAndWrongSingletonIdentifiers() throws {
        expectRejected(rawChange("healthKit", id: "primary", data: Data("{}".utf8)))
        expectRejected(try change("profile", id: "another-account", value: UserProfile()))
        expectRejected(try change("targets", id: "primary", value: DailyTargets()))
        expectRejected(try change("preferences", id: "other", value: UserPreferences()))
        expectRejected(rawChange("meal", id: "not-a-uuid", operation: .delete, data: Data()))
    }

    @Test func rejectsEnvelopeAndEmbeddedIdentifierDisagreement() throws {
        let meal = makeMeal()
        expectRejected(try change("meal", id: UUID().uuidString, value: meal))
        let water = ExportedHydration(id: UUID(), date: .now, amountMilliliters: 250, provenance: .userEntered)
        expectRejected(try change("hydration", id: UUID().uuidString, value: water))
    }

    @Test func rejectsMalformedOversizedAndWrongDateEncodingPayloads() throws {
        expectRejected(rawChange("profile", id: "primary", data: Data("not-json".utf8)))
        expectRejected(rawChange("preferences", id: "primary", data: Data(repeating: 32, count: 1_000_001)))
        let meal = makeMeal()
        let isoEncoder = JSONEncoder()
        isoEncoder.dateEncodingStrategy = .iso8601
        expectRejected(rawChange("meal", id: meal.id.uuidString, data: try isoEncoder.encode(meal)))
    }

    @Test func rejectsInvalidEnvelopeDatesAndRevisions() throws {
        var candidate = try change("profile", id: "primary", value: UserProfile())
        for revision in [-1, Int.max] {
            candidate.serverRevision = revision
            expectRejected(candidate)
        }
        candidate.serverRevision = 1
        for seconds in [-1e100, 1e100, Double.infinity, Double.nan] {
            candidate.serverUpdatedAt = Date(timeIntervalSince1970: seconds)
            expectRejected(candidate)
        }
    }

    @Test func rejectsHydrationThatWouldCorruptTotalsOrIntegerFormatting() throws {
        var water = ExportedHydration(id: UUID(), date: .now, amountMilliliters: 250, provenance: .userEntered)
        for amount in [0, -1, 20_001, Double.greatestFiniteMagnitude] {
            water.amountMilliliters = amount
            expectRejected(try change("hydration", id: water.id.uuidString, value: water))
        }
        // Input JSON can overflow floating-point decoding even though the local
        // JSONEncoder correctly refuses to emit non-finite doubles itself.
        let overflow = "{\"id\":\"\(water.id.uuidString)\",\"date\":0,\"amountMilliliters\":1e309,\"provenance\":\"userEntered\"}"
        expectRejected(rawChange("hydration", id: water.id.uuidString, data: Data(overflow.utf8)))
    }

    @Test func rejectsInvalidNestedMealDatesConfidenceAndTimeZone() throws {
        let original = makeMeal()
        var meal = original
        meal.date = Date(timeIntervalSince1970: 1e100)
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        meal = original
        meal.createdAt = Date(timeIntervalSince1970: -1e100)
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        meal = original
        meal.updatedAt = Date(timeIntervalSince1970: 1e100)
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        meal = original
        meal.timeZoneIdentifier = "Mars/Olympus"
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        for confidence in [-0.1, 1.1, Double.greatestFiniteMagnitude] {
            meal = original
            meal.confidence = confidence
            expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        }
    }

    @Test func rejectsUnboundedMealTextAndDuplicateOrExcessItems() throws {
        let original = makeMeal()
        var meal = original
        meal.name = String(repeating: "x", count: 301)
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        meal = original
        meal.notes = String(repeating: "x", count: 10_001)
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        meal = original
        let item = MealItem(name: "Rice")
        meal.items = [item, item]
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        meal.items = (0..<101).map { MealItem(name: "Item \($0)") }
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
    }

    @Test func rejectsNegativeOrOverflowingNutritionAtEveryNestingLevel() throws {
        let invalidValues: [NutritionEstimate] = [
            .init(calories: Int.max, protein: 0, carbohydrates: 0, fat: 0, fiber: 0),
            .init(calories: 0, protein: -1, carbohydrates: 0, fat: 0, fiber: 0),
            .init(calories: 0, protein: 0, carbohydrates: Double.greatestFiniteMagnitude, fat: 0, fiber: 0),
            .init(calories: 0, protein: 0, carbohydrates: 0, fat: 0, fiber: 0, sodium: 1_000_001)
        ]
        for nutrition in invalidValues {
            var meal = makeMeal()
            meal.nutrition = nutrition
            expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
            meal = makeMeal()
            meal.items = [MealItem(name: "Rice", nutrition: nutrition)]
            expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
            meal.items = [MealItem(name: "Rice", nutritionPer100Grams: nutrition)]
            expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        }
    }

    @Test func rejectsUnsafeQuantitiesConversionWeightsAndDerivedServingMath() throws {
        let per100 = NutritionEstimate(calories: 300, protein: 1, carbohydrates: 1, fat: 1, fiber: 1)
        for quantity in [0, -1, 100_001, Double.greatestFiniteMagnitude] {
            var meal = makeMeal()
            meal.items = [MealItem(name: "Rice", quantity: quantity, nutritionPer100Grams: per100)]
            expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        }
        for grams in [0, -1, 100_001, Double.greatestFiniteMagnitude] {
            var meal = makeMeal()
            meal.items = [MealItem(name: "Rice", nutritionPer100Grams: per100, gramsPerUnit: [.cup: grams])]
            expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
        }
        var meal = makeMeal()
        // Each stored number is bounded but the combined serving product is not.
        let concentrated = NutritionEstimate(calories: 300, protein: 1, carbohydrates: 1, fat: 1, fiber: 1, sodium: 1_000_000)
        meal.items = [MealItem(name: "Salt", quantity: 100_000, nutritionPer100Grams: concentrated, gramsPerUnit: [.serving: 100_000])]
        expectRejected(try change("meal", id: meal.id.uuidString, value: meal))
    }

    @Test func rejectsProfileMeasurementsListsAndInvalidTimeZone() throws {
        for weight in [0, 401, Double.greatestFiniteMagnitude] {
            var profile = UserProfile()
            profile.weightKG = weight
            expectRejected(try change("profile", id: "primary", value: profile))
        }
        var profile = UserProfile()
        profile.heightCM = -1
        expectRejected(try change("profile", id: "primary", value: profile))
        profile = UserProfile()
        profile.timeZoneIdentifier = "No/SuchZone"
        expectRejected(try change("profile", id: "primary", value: profile))
        profile = UserProfile()
        profile.allergies = Array(repeating: "Peanuts", count: 41)
        expectRejected(try change("profile", id: "primary", value: profile))
        profile = UserProfile()
        profile.foodsToAvoid = ["   "]
        expectRejected(try change("profile", id: "primary", value: profile))
    }

    @Test func rejectsTargetsThatWouldBreakProgressAndNumericConversions() throws {
        let original = DailyTargets()
        var targets = original
        targets.calories = Int.max
        expectRejected(try change("targets", id: "current", value: targets))
        targets = original
        targets.proteinGrams = 0
        expectRejected(try change("targets", id: "current", value: targets))
        targets = original
        targets.fatGrams = -1
        expectRejected(try change("targets", id: "current", value: targets))
        targets = original
        targets.hydrationMilliliters = Double.greatestFiniteMagnitude
        expectRejected(try change("targets", id: "current", value: targets))
        targets = original
        targets.steps = Int.max
        expectRejected(try change("targets", id: "current", value: targets))
        targets = original
        targets.sleepMinutes = 0
        expectRejected(try change("targets", id: "current", value: targets))
    }

    @Test func rejectsInvalidReminderSchedulesEvenWhenRemindersAreDisabled() throws {
        let original = UserPreferences()
        var preferences = original
        preferences.mealReminderHours = [8, 12, 18, 22]
        expectRejected(try change("preferences", id: "primary", value: preferences))
        preferences = original
        preferences.mealReminderHours = [-1, 12, 24]
        expectRejected(try change("preferences", id: "primary", value: preferences))
        preferences = original
        preferences.hydrationReminderIntervalHours = 0
        expectRejected(try change("preferences", id: "primary", value: preferences))
        preferences = original
        preferences.weeklySummaryWeekday = 0
        expectRejected(try change("preferences", id: "primary", value: preferences))
        preferences = original
        preferences.dailyReviewHour = Int.max
        expectRejected(try change("preferences", id: "primary", value: preferences))
        preferences = original
        preferences.weeklySummaryHour = -1
        expectRejected(try change("preferences", id: "primary", value: preferences))
        preferences = original
        preferences.quietHoursStart = 24
        expectRejected(try change("preferences", id: "primary", value: preferences))
        preferences = original
        preferences.quietHoursEnd = -1
        expectRejected(try change("preferences", id: "primary", value: preferences))
    }

    private func makeMeal() -> ExportedMeal {
        ExportedMeal(meal: Meal(
            name: "Rice bowl", type: .lunch, date: .now,
            nutrition: .init(calories: 420, protein: 20, carbohydrates: 60, fat: 11, fiber: 5),
            items: [MealItem(name: "Rice", quantity: 1, nutrition: .init(calories: 210, protein: 4, carbohydrates: 45, fat: 1, fiber: 1))],
            provenance: .userEntered
        ))
    }

    private func change<Value: Encodable>(_ entity: String, id: String, value: Value) throws -> SyncConflict {
        rawChange(entity, id: id, data: try JSONEncoder().encode(value))
    }

    private func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try #require(decoded as? [String: Any])
    }

    private func rawChange(_ entity: String, id: String, operation: SyncOperationKind = .update, data: Data) -> SyncConflict {
        .init(entityType: entity, entityIdentifier: id, operation: operation, serverRevision: 1, serverUpdatedAt: .now, serverPayload: data)
    }

    private func expectRejected(_ change: SyncConflict, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: BackendError.invalidPayload, sourceLocation: sourceLocation) {
            try RemoteSyncPayloadValidator.validate(change)
        }
    }
}
