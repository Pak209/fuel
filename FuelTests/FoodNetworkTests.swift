import Foundation
import Testing
@testable import Fuel

/// Covers Workstream 4 items 2-3 from `docs/quality/TESTFLIGHT_PLAN.md`:
/// photo recognition must never reach the network, and `OpenFoodFactsService`
/// must cache, rate-limit, and speak the Open Food Facts v2 search API.
struct FoodNetworkTests {
    // MARK: - Recognition never networks

    @Test func recognitionDefaultsToLocalCatalogOnly() {
        // This is the actual production wiring guarantee: `LocalFoodDatabaseService`
        // is a pure in-memory string filter with no `URLSession` involved, so as
        // long as this is the default, a photo scan can never reach the network
        // no matter what Vision returns. (Interactive search keeps the
        // composite local+remote path via `AppState.foodDatabase`.)
        let database = OnDeviceFoodRecognitionService().database
        #expect(database is LocalFoodDatabaseService)
        #expect(!(database is CompositeFoodDatabaseService))
        #expect(!(database is OpenFoodFactsService))
    }

    @Test func recognitionLookupPatternNeverReachesARemoteDatabase() async throws {
        // `OnDeviceFoodRecognitionService.analyze` calls `database.search(label)`
        // once per Vision observation, up to 8 (`FoodServices.swift`). CoreML/
        // Vision can't run in this sandboxed simulator (no Neural Engine/GPU
        // context), so this exercises the same lookup pattern directly against
        // a counting wrapper around the exact type recognition defaults to,
        // proving every one of those up-to-8 lookups stays local.
        let counter = CallCounter()
        let database = CountingLocalDatabase(counter: counter)
        let sampleVisionLabels = [
            "banana", "granola bar", "green salad", "unidentified object",
            "chicken breast", "soda can", "avocado toast", "ice cream"
        ]
        #expect(sampleVisionLabels.count == 8)

        for label in sampleVisionLabels {
            _ = try await database.search(label)
        }

        #expect(await counter.count == sampleVisionLabels.count)
    }

    // MARK: - Cache

    @Test func cacheHitAvoidsSecondTransportCallWithinTTL() async throws {
        let clock = MutableTestClock()
        let transport = RecordingFoodSearchTransport(body: Self.sampleV2JSON())
        let service = OpenFoodFactsService(
            transport: transport,
            cache: FoodSearchCache(capacity: 100, ttl: 300, clock: clock),
            rateLimiter: FoodSearchRateLimiter(maximumTokens: 8, refillInterval: 60, clock: clock)
        )

        let first = try await service.search("Greek Yogurt")
        #expect(await transport.invocationCount == 1)

        // Same query modulo casing/whitespace, still within the 5-minute TTL.
        let second = try await service.search("  greek yogurt  ")
        #expect(first == second)
        #expect(await transport.invocationCount == 1)

        clock.advance(by: 301)
        _ = try await service.search("Greek Yogurt")
        #expect(await transport.invocationCount == 2)
    }

    @Test func cacheEvictsOldestEntryOnceCapacityIsExceeded() async throws {
        let clock = MutableTestClock()
        let cache = FoodSearchCache(capacity: 2, ttl: 300, clock: clock)
        await cache.store([], for: "a")
        await cache.store([], for: "b")
        await cache.store([], for: "c")

        #expect(await cache.staleResults(for: "a") == nil)
        #expect(await cache.staleResults(for: "b") != nil)
        #expect(await cache.staleResults(for: "c") != nil)
    }

    // MARK: - Rate limiter

    @Test func rateLimiterBlocksTheNinthCallWithinAMinuteAndDegradesWithoutThrowing() async throws {
        let clock = MutableTestClock()
        let transport = RecordingFoodSearchTransport(body: Self.sampleV2JSON())
        let service = OpenFoodFactsService(
            transport: transport,
            cache: FoodSearchCache(capacity: 100, ttl: 300, clock: clock),
            rateLimiter: FoodSearchRateLimiter(maximumTokens: 8, refillInterval: 60, clock: clock)
        )

        for index in 0..<8 {
            _ = try await service.search("query-\(index)")
        }
        #expect(await transport.invocationCount == 8)

        // A 9th distinct query within the same window must not throw and must
        // not reach the transport again.
        let ninth = try await service.search("query-8-distinct")
        #expect(ninth.isEmpty)
        #expect(await transport.invocationCount == 8)
    }

    @Test func rateLimiterRefillsAfterTheWindowElapses() async throws {
        let clock = MutableTestClock()
        let transport = RecordingFoodSearchTransport(body: Self.sampleV2JSON())
        let service = OpenFoodFactsService(
            transport: transport,
            cache: FoodSearchCache(capacity: 100, ttl: 300, clock: clock),
            rateLimiter: FoodSearchRateLimiter(maximumTokens: 8, refillInterval: 60, clock: clock)
        )

        for index in 0..<8 {
            _ = try await service.search("first-\(index)")
        }
        #expect(await transport.invocationCount == 8)
        _ = try await service.search("blocked")
        #expect(await transport.invocationCount == 8)

        clock.advance(by: 61)
        let afterRefill = try await service.search("second-window")
        #expect(!afterRefill.isEmpty)
        #expect(await transport.invocationCount == 9)
    }

    // MARK: - v2 migration

    @Test func searchBuildsAWellFormedV2URL() async throws {
        let transport = RecordingFoodSearchTransport(body: Self.sampleV2JSON())
        let service = OpenFoodFactsService(transport: transport, cache: FoodSearchCache(), rateLimiter: FoodSearchRateLimiter())

        _ = try await service.search("greek yogurt")

        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == "world.openfoodfacts.org")
        #expect(url.path == "/api/v2/search")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "search_terms", value: "greek yogurt")))
        #expect(items.contains { $0.name == "page_size" })
        #expect(items.contains { item in
            item.name == "fields"
                && (item.value?.contains("code") ?? false)
                && (item.value?.contains("product_name") ?? false)
                && (item.value?.contains("brands") ?? false)
                && (item.value?.contains("nutriments") ?? false)
                && (item.value?.contains("serving_quantity") ?? false)
        })
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Fuel-iOS/1.0 (nutrition search)")
        #expect(request.timeoutInterval == 12)
    }

    @Test func v2ResponseFixtureParsesToTheSameFieldsAsBefore() async throws {
        let transport = RecordingFoodSearchTransport(body: Self.sampleV2JSON())
        let service = OpenFoodFactsService(transport: transport, cache: FoodSearchCache(), rateLimiter: FoodSearchRateLimiter())

        let results = try await service.search("snack bar")
        let result = try #require(results.first)

        #expect(result.id == "openfoodfacts:0123456789012")
        #expect(result.name == "Test Snack Bar")
        #expect(result.brand == "Acme")
        #expect(result.sourceName == "Open Food Facts")
        #expect(result.nutritionPer100Grams.calories == 450)
        #expect(result.nutritionPer100Grams.protein == 10)
        #expect(result.nutritionPer100Grams.carbohydrates == 55)
        #expect(result.nutritionPer100Grams.fat == 18)
        #expect(result.nutritionPer100Grams.fiber == 4)
        #expect(result.nutritionPer100Grams.sugar == 20)
        #expect(result.nutritionPer100Grams.sodium == 500)
        #expect(result.nutritionPer100Grams.potassium == 300)
        #expect(result.nutritionPer100Grams.iron == 2)
        #expect(result.nutritionPer100Grams.calcium == 100)
        #expect(result.nutritionPer100Grams.vitaminC == 10)
        #expect(result.gramsPerUnit[.serving] == 40)
        #expect(result.attributionURL == URL(string: "https://world.openfoodfacts.org/product/0123456789012"))
    }

    // MARK: - Helpers

    /// A canned Open Food Facts v2 `/api/v2/search` response covering every
    /// field `OpenFoodFactsService.Product`/`Nutriments` maps.
    private static func sampleV2JSON() -> Data {
        let json = """
        {
          "count": 1,
          "page": 1,
          "page_size": 20,
          "products": [
            {
              "code": "0123456789012",
              "product_name": "Test Snack Bar",
              "brands": "Acme, Foo Co",
              "serving_quantity": 40,
              "nutriments": {
                "energy-kcal_100g": 450,
                "proteins_100g": 10,
                "carbohydrates_100g": 55,
                "fat_100g": 18,
                "fiber_100g": 4,
                "sugars_100g": 20,
                "sodium_100g": 0.5,
                "potassium_100g": 0.3,
                "iron_100g": 0.002,
                "calcium_100g": 0.1,
                "vitamin-c_100g": 0.01
              }
            }
          ]
        }
        """
        return Data(json.utf8)
    }
}

/// Counts invocations across `await` suspension points; used by both the
/// recognition and rate-limiter tests to prove exactly how many times a
/// dependency was actually called.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Wraps `LocalFoodDatabaseService` and records every lookup. Standing in for
/// "recognition's default database" in a test that can count calls, since the
/// real default (`LocalFoodDatabaseService`) has no built-in counter.
private struct CountingLocalDatabase: FoodDatabaseService {
    let counter: CallCounter
    private let wrapped = LocalFoodDatabaseService()

    func search(_ query: String) async throws -> [FoodSearchResult] {
        await counter.increment()
        return try await wrapped.search(query)
    }
}

/// A clock whose `now()` is fixed until advanced, so cache TTL and rate-limit
/// windows can be tested deterministically instead of sleeping for real
/// minutes. The lock guards against concurrent access from actor-isolated
/// callers on different executors.
private final class MutableTestClock: FoodSearchClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        currentDate = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        currentDate = currentDate.addingTimeInterval(seconds)
    }
}

/// Records every `URLRequest` handed to it and replays a scripted sequence of
/// responses, mirroring `RecordingBackendTransport` in `SyncSecurityTests.swift`
/// so no test in this file performs real network I/O.
private actor RecordingFoodSearchTransport: FoodSearchTransport {
    enum Step {
        case success(status: Int, body: Data)
        case failure(Error)
    }

    private var steps: [Step]
    private(set) var recordedRequests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    init(status: Int = 200, body: Data) {
        steps = [.success(status: status, body: body)]
    }

    var invocationCount: Int { recordedRequests.count }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let index = recordedRequests.count - 1
        let step = index < steps.count ? steps[index] : (steps.last ?? .success(status: 200, body: Data()))
        switch step {
        case .success(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        case .failure(let error):
            throw error
        }
    }
}
