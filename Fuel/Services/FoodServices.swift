import Foundation
import ImageIO
import UIKit
import Vision

enum FoodServiceError: LocalizedError {
    case invalidImage
    case noFoodDetected
    case invalidResponse
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidImage: "Fuel could not decode that image. Try another photo or log the meal manually."
        case .noFoodDetected: "No supported food was recognized. You can still log this meal manually."
        case .invalidResponse: "The nutrition provider returned an incomplete result."
        case .unavailable: "Food search is temporarily unavailable. Common foods and manual entry still work offline."
        case .timedOut: "Recognition took too long. Try again or review the meal manually."
        }
    }
}

protocol FoodDatabaseService {
    func search(_ query: String) async throws -> [FoodSearchResult]
}

struct LocalFoodDatabaseService: FoodDatabaseService {
    let foods: [FoodSearchResult]

    init(foods: [FoodSearchResult] = Self.catalog) { self.foods = foods }

    func search(_ query: String) async throws -> [FoodSearchResult] {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return Array(foods.prefix(12)) }
        return foods.filter { food in
            let value = food.displayName.lowercased()
            return terms.allSatisfy(value.contains)
        }
    }

    static let catalog: [FoodSearchResult] = [
        food("apple", "Apple", 52, 0.3, 14, 0.2, 2.4, serving: 182, piece: 182),
        food("banana", "Banana", 89, 1.1, 23, 0.3, 2.6, serving: 118, piece: 118),
        food("blueberries", "Blueberries", 57, 0.7, 14.5, 0.3, 2.4, serving: 148, cup: 148),
        food("strawberries", "Strawberries", 32, 0.7, 7.7, 0.3, 2, serving: 152, cup: 152),
        food("avocado", "Avocado", 160, 2, 8.5, 14.7, 6.7, serving: 100, piece: 150),
        food("chicken-breast", "Chicken breast, cooked", 165, 31, 0, 3.6, 0, serving: 120),
        food("salmon", "Salmon, cooked", 206, 22, 0, 12, 0, serving: 120),
        food("egg", "Egg, cooked", 155, 13, 1.1, 11, 0, serving: 50, piece: 50),
        food("greek-yogurt", "Greek yogurt, plain", 97, 9, 3.9, 5, 0, serving: 170, cup: 245),
        food("tofu", "Tofu, firm", 144, 17, 2.8, 8.7, 2.3, serving: 126),
        food("black-beans", "Black beans, cooked", 132, 8.9, 24, 0.5, 8.7, serving: 172, cup: 172),
        food("chickpeas", "Chickpeas, cooked", 164, 8.9, 27, 2.6, 7.6, serving: 164, cup: 164),
        food("brown-rice", "Brown rice, cooked", 123, 2.7, 25.6, 1, 1.6, serving: 195, cup: 195),
        food("white-rice", "White rice, cooked", 130, 2.7, 28, 0.3, 0.4, serving: 186, cup: 186),
        food("oatmeal", "Oatmeal, cooked", 71, 2.5, 12, 1.5, 1.7, serving: 234, cup: 234),
        food("quinoa", "Quinoa, cooked", 120, 4.4, 21.3, 1.9, 2.8, serving: 185, cup: 185),
        food("broccoli", "Broccoli, cooked", 35, 2.4, 7.2, 0.4, 3.3, serving: 156, cup: 156),
        food("spinach", "Spinach, cooked", 23, 3, 3.8, 0.3, 2.4, serving: 180, cup: 180),
        food("sweet-potato", "Sweet potato, cooked", 90, 2, 20.7, 0.2, 3.3, serving: 130, piece: 130),
        food("almonds", "Almonds", 579, 21, 22, 50, 12.5, serving: 28),
        food("peanut-butter", "Peanut butter", 588, 25, 20, 50, 6, serving: 32),
        food("whole-wheat-bread", "Whole-wheat bread", 247, 13, 41, 3.4, 6.8, serving: 43, piece: 43),
        food("milk", "Milk, 2%", 50, 3.4, 4.8, 2, 0, serving: 244, cup: 244, milliliter: 1)
    ]

    private static func food(
        _ id: String,
        _ name: String,
        _ calories: Int,
        _ protein: Double,
        _ carbs: Double,
        _ fat: Double,
        _ fiber: Double,
        serving: Double,
        piece: Double? = nil,
        cup: Double? = nil,
        milliliter: Double? = nil
    ) -> FoodSearchResult {
        var units: [MeasurementUnit: Double] = [.gram: 1, .ounce: 28.3495, .serving: serving]
        if let piece { units[.piece] = piece }
        if let cup { units[.cup] = cup }
        if let milliliter { units[.milliliter] = milliliter }
        return .init(
            id: "fuel-common:\(id)",
            name: name,
            sourceName: "Fuel common foods",
            nutritionPer100Grams: .init(calories: calories, protein: protein, carbohydrates: carbs, fat: fat, fiber: fiber),
            gramsPerUnit: units
        )
    }
}

/// Monotonic time source for `FoodSearchCache`/`FoodSearchRateLimiter` so tests
/// can control TTL expiry and rate-limit windows deterministically instead of
/// sleeping for real minutes.
protocol FoodSearchClock: Sendable {
    func now() -> Date
}

struct SystemFoodSearchClock: FoodSearchClock {
    func now() -> Date { .now }
}

/// Transport seam for `OpenFoodFactsService`, mirroring `BackendTransport`
/// (`BackendServices.swift`) so tests can substitute a recording/scripted
/// double instead of performing real network I/O.
protocol FoodSearchTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionFoodSearchTransport: FoodSearchTransport {
    var session: URLSession = .shared

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FoodServiceError.invalidResponse }
        return (data, http)
    }
}

/// Small in-memory cache of recent Open Food Facts queries (normalized
/// lowercase/trimmed key). Keeps repeated/duplicate searches (retyping,
/// debounce edge cases, revisiting a query) from re-hitting the network within
/// the TTL window. An actor because it's shared, mutable state accessed from
/// concurrent search calls.
actor FoodSearchCache {
    private struct Entry {
        var results: [FoodSearchResult]
        var expiresAt: Date
    }

    private var entriesByKey: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let capacity: Int
    private let ttl: TimeInterval
    private let clock: any FoodSearchClock

    init(capacity: Int = 100, ttl: TimeInterval = 300, clock: any FoodSearchClock = SystemFoodSearchClock()) {
        self.capacity = capacity
        self.ttl = ttl
        self.clock = clock
    }

    static func normalizedKey(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A live (non-expired) cached value, or `nil` on miss/expiry.
    func results(for key: String) -> [FoodSearchResult]? {
        guard let entry = entriesByKey[key] else { return nil }
        guard entry.expiresAt > clock.now() else {
            remove(key)
            return nil
        }
        return entry.results
    }

    /// The last known value for `key` even if expired, used to degrade
    /// gracefully when the rate limiter is exhausted rather than erroring.
    func staleResults(for key: String) -> [FoodSearchResult]? {
        entriesByKey[key]?.results
    }

    func store(_ results: [FoodSearchResult], for key: String) {
        if entriesByKey[key] == nil {
            insertionOrder.append(key)
        }
        entriesByKey[key] = Entry(results: results, expiresAt: clock.now().addingTimeInterval(ttl))
        while insertionOrder.count > capacity {
            let oldest = insertionOrder.removeFirst()
            entriesByKey.removeValue(forKey: oldest)
        }
    }

    private func remove(_ key: String) {
        entriesByKey.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }
}

/// Token-bucket limiter capping remote Open Food Facts searches at
/// `maximumTokens` per `refillInterval` (default 8/min, under OFF's documented
/// 10/min). An actor so concurrent callers see a consistent token count.
actor FoodSearchRateLimiter {
    private let maximumTokens: Double
    private let refillInterval: TimeInterval
    private var availableTokens: Double
    private var lastRefillAt: Date
    private let clock: any FoodSearchClock

    init(maximumTokens: Int = 8, refillInterval: TimeInterval = 60, clock: any FoodSearchClock = SystemFoodSearchClock()) {
        self.maximumTokens = Double(maximumTokens)
        self.refillInterval = refillInterval
        availableTokens = Double(maximumTokens)
        lastRefillAt = clock.now()
        self.clock = clock
    }

    /// Attempts to consume one token. Returns `false` when the caller should
    /// degrade (cached/local results) instead of making a remote request.
    func tryConsume() -> Bool {
        refill()
        guard availableTokens >= 1 else { return false }
        availableTokens -= 1
        return true
    }

    private func refill() {
        let now = clock.now()
        let elapsed = now.timeIntervalSince(lastRefillAt)
        guard elapsed > 0 else { return }
        let refillRatePerSecond = maximumTokens / refillInterval
        availableTokens = min(maximumTokens, availableTokens + elapsed * refillRatePerSecond)
        lastRefillAt = now
    }
}

struct OpenFoodFactsService: FoodDatabaseService {
    var transport: any FoodSearchTransport = URLSessionFoodSearchTransport()
    var cache = FoodSearchCache()
    var rateLimiter = FoodSearchRateLimiter()

    func search(_ query: String) async throws -> [FoodSearchResult] {
        let key = FoodSearchCache.normalizedKey(query)
        if let cached = await cache.results(for: key) {
            return cached
        }
        guard await rateLimiter.tryConsume() else {
            // Rate limit exhausted: degrade to the last known results for this
            // query (even if stale) instead of erroring. `CompositeFoodDatabaseService`
            // still has local-catalog results to fall back on when this is empty.
            return await cache.staleResults(for: key) ?? []
        }
        let results = try await performRemoteSearch(query)
        await cache.store(results, for: key)
        return results
    }

    private func performRemoteSearch(_ query: String) async throws -> [FoodSearchResult] {
        guard var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/search") else {
            throw FoodServiceError.unavailable
        }
        components.queryItems = [
            .init(name: "search_terms", value: query),
            .init(name: "page_size", value: "20"),
            .init(name: "fields", value: "code,product_name,brands,nutriments,serving_quantity")
        ]
        guard let url = components.url else { throw FoodServiceError.unavailable }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Fuel-iOS/1.0 (nutrition search)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else { throw FoodServiceError.unavailable }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        return payload.products.compactMap(\.domainValue)
    }

    private struct Response: Decodable { var products: [Product] }
    private struct Product: Decodable {
        var code: String?
        var productName: String?
        var brands: String?
        var servingQuantity: Double?
        var nutriments: Nutriments?

        enum CodingKeys: String, CodingKey {
            case code, brands, nutriments
            case productName = "product_name"
            case servingQuantity = "serving_quantity"
        }

        var domainValue: FoodSearchResult? {
            guard let code, let name = productName, !name.isEmpty, let nutrients = nutriments else { return nil }
            let per100 = NutritionEstimate(
                calories: Int((nutrients.energyKcal ?? 0).rounded()),
                protein: nutrients.proteins ?? 0,
                carbohydrates: nutrients.carbohydrates ?? 0,
                fat: nutrients.fat ?? 0,
                fiber: nutrients.fiber ?? 0,
                sugar: nutrients.sugars ?? 0,
                sodium: (nutrients.sodium ?? 0) * 1_000,
                potassium: (nutrients.potassium ?? 0) * 1_000,
                iron: (nutrients.iron ?? 0) * 1_000,
                calcium: (nutrients.calcium ?? 0) * 1_000,
                vitaminC: (nutrients.vitaminC ?? 0) * 1_000
            )
            let serving = servingQuantity.flatMap { $0 > 0 ? $0 : nil } ?? 100
            return .init(
                id: "openfoodfacts:\(code)",
                name: name,
                brand: brands?.split(separator: ",").first.map(String.init),
                sourceName: "Open Food Facts",
                nutritionPer100Grams: per100,
                gramsPerUnit: [.gram: 1, .ounce: 28.3495, .serving: serving],
                attributionURL: URL(string: "https://world.openfoodfacts.org/product/\(code)")
            )
        }
    }

    private struct Nutriments: Decodable {
        var energyKcal: Double?
        var proteins: Double?
        var carbohydrates: Double?
        var fat: Double?
        var fiber: Double?
        var sugars: Double?
        var sodium: Double?
        var potassium: Double?
        var iron: Double?
        var calcium: Double?
        var vitaminC: Double?

        enum CodingKeys: String, CodingKey {
            case proteins = "proteins_100g"
            case carbohydrates = "carbohydrates_100g"
            case fat = "fat_100g"
            case fiber = "fiber_100g"
            case sugars = "sugars_100g"
            case sodium = "sodium_100g"
            case potassium = "potassium_100g"
            case iron = "iron_100g"
            case calcium = "calcium_100g"
            case vitaminC = "vitamin-c_100g"
            case energyKcal = "energy-kcal_100g"
        }
    }
}

struct CompositeFoodDatabaseService: FoodDatabaseService {
    var local = LocalFoodDatabaseService()
    var remote = OpenFoodFactsService()

    func search(_ query: String) async throws -> [FoodSearchResult] {
        let localResults = try await local.search(query)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return localResults }
        do {
            let remoteResults = try await remote.search(query)
            let combined = localResults + remoteResults
            return Array(combined.uniqued(on: \.id).prefix(25))
        } catch {
            guard !localResults.isEmpty else { throw error }
            return localResults
        }
    }
}

protocol MealImageProcessing {
    func prepareForRecognition(_ data: Data) async throws -> Data
}

struct MealImageProcessor: MealImageProcessing {
    var maximumDimension: CGFloat = 1_600
    var compressionQuality: CGFloat = 0.82
    var maximumSourceBytes = 32_000_000

    func prepareForRecognition(_ data: Data) async throws -> Data {
        guard MealImageValidator.isValid(data, maximumBytes: maximumSourceBytes),
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw FoodServiceError.invalidImage }
        let rendered = UIImage(cgImage: thumbnail)
        guard let output = rendered.jpegData(compressionQuality: compressionQuality),
              MealImageValidator.isValid(output) else { throw FoodServiceError.invalidImage }
        return output
    }
}

struct OnDeviceFoodRecognitionService: FoodRecognitionService {
    // Recognition matches Vision labels against the bundled catalog only —
    // never remote. Up to 8 Vision observations can each trigger a lookup, and
    // routing those through `CompositeFoodDatabaseService` (as before) meant a
    // single photo could fire up to 8 Open Food Facts requests. Interactive
    // search still uses the composite (local + remote) path.
    var database: any FoodDatabaseService = LocalFoodDatabaseService()

    func analyze(imageData: Data) async throws -> FoodRecognitionResult {
        try Task.checkCancellation()
        guard MealImageValidator.isValid(imageData) else { throw FoodServiceError.invalidImage }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_200,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw FoodServiceError.invalidImage }

        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).filter { $0.confidence >= 0.05 }
        var matches: [(FoodSearchResult, Float)] = []
        for observation in observations.prefix(8) {
            try Task.checkCancellation()
            let labels = observation.identifier.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for label in labels {
                if let food = try await database.search(label).first,
                   !matches.contains(where: { $0.0.id == food.id }) {
                    matches.append((food, observation.confidence))
                    break
                }
            }
            if matches.count == 4 { break }
        }
        guard !matches.isEmpty else { throw FoodServiceError.noFoodDetected }
        let items = matches.map { food, confidence in
            MealItem(
                name: food.name,
                quantity: 1,
                unit: .serving,
                confidence: Double(confidence),
                nutrition: food.nutrition(quantity: 1, unit: .serving),
                provenance: .aiEstimated,
                foodIdentifier: food.id,
                sourceName: food.sourceName,
                nutritionPer100Grams: food.nutritionPer100Grams,
                gramsPerUnit: food.gramsPerUnit
            )
        }
        let nutrition = items.reduce(.zero) { $0 + $1.nutrition }
        let confidence = matches.map { Double($0.1) }.reduce(0, +) / Double(matches.count)
        return .init(
            mealName: matches.map { $0.0.name }.joined(separator: " + "),
            items: items,
            nutrition: nutrition,
            confidence: confidence,
            alternatives: matches.map(\.0),
            warnings: ["On-device recognition cannot reliably infer portions. Review every serving before saving."],
            isPartial: true
        )
    }
}

private extension Array {
    func uniqued<Key: Hashable>(on keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
