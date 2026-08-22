import Foundation

struct FuelExportPayload: Codable {
    var exportVersion = 1
    var exportedAt = Date.now
    var profile: UserProfile
    var targets: DailyTargets
    var preferences: UserPreferences
    var meals: [ExportedMeal]
    var hydration: [ExportedHydration]
}

struct ExportedMeal: Codable {
    var id: UUID
    var name: String
    var type: MealType
    var date: Date
    var timeZoneIdentifier: String
    var nutrition: NutritionEstimate
    var items: [MealItem]
    var provenance: DataProvenance
    var status: MealStatus
    var confidence: Double?
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(meal: Meal) {
        id = meal.id
        name = meal.name
        type = meal.type
        date = meal.date
        timeZoneIdentifier = meal.timeZoneIdentifier
        nutrition = meal.nutrition
        items = meal.items
        provenance = meal.provenance
        status = meal.status
        confidence = meal.confidence
        notes = meal.notes
        createdAt = meal.createdAt
        updatedAt = meal.updatedAt
    }
}

struct ExportedHydration: Codable {
    var id: UUID
    var date: Date
    var amountMilliliters: Double
    var provenance: DataProvenance
}

protocol DataExportService: Sendable {
    func write(_ payload: FuelExportPayload) async throws -> URL
}

actor LocalDataExportService: DataExportService {
    func write(_ payload: FuelExportPayload) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Fuel-Export-\(formatter.string(from: .now)).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
}
