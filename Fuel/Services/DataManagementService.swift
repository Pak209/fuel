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

struct LocalExportArtifact: Identifiable, Hashable, Sendable {
    var url: URL
    var createdAt: Date
    var expiresAt: Date

    var id: URL { url }
    func isAvailable(at date: Date = .now) -> Bool {
        date < expiresAt && FileManager.default.fileExists(atPath: url.path())
    }
}

protocol DataExportService: Sendable {
    func write(_ payload: FuelExportPayload) async throws -> LocalExportArtifact
    func cleanupExpired() async throws
    func remove(_ artifact: LocalExportArtifact) async throws
    func removeAll() async throws
}

actor LocalDataExportService: DataExportService {
    nonisolated static let defaultTimeToLive: TimeInterval = 60 * 60

    private let directory: URL
    private let fileManager: FileManager
    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        timeToLive: TimeInterval = defaultTimeToLive,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.temporaryDirectory
            .appending(path: "FuelExports", directoryHint: .isDirectory)
        self.timeToLive = max(1, timeToLive)
        self.now = now
    }

    func write(_ payload: FuelExportPayload) throws -> LocalExportArtifact {
        try cleanupExpired()
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let createdAt = now()
        let artifact = LocalExportArtifact(
            url: directory.appending(path: "Fuel-Export-\(UUID().uuidString).json"),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(timeToLive)
        )
        try data.write(to: artifact.url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.modificationDate: createdAt], ofItemAtPath: artifact.url.path())
        scheduleExpiry(for: artifact)
        return artifact
    }

    func cleanupExpired() throws {
        guard fileManager.fileExists(atPath: directory.path()) else { return }
        let cutoff = now().addingTimeInterval(-timeToLive)
        for url in try exportURLs() {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard (values.contentModificationDate ?? .distantPast) <= cutoff else { continue }
            try fileManager.removeItem(at: url)
        }
        try removeDirectoryIfEmpty()
    }

    func remove(_ artifact: LocalExportArtifact) throws {
        let target = artifact.url.standardizedFileURL
        guard target.deletingLastPathComponent() == directory.standardizedFileURL else { return }
        if fileManager.fileExists(atPath: target.path()) { try fileManager.removeItem(at: target) }
        try removeDirectoryIfEmpty()
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func scheduleExpiry(for artifact: LocalExportArtifact) {
        Task { [weak self] in
            guard let self else { return }
            let delay = max(0, artifact.expiresAt.timeIntervalSince(self.now()))
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? await self.remove(artifact)
        }
    }

    private func prepareDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path()
        )
    }

    private func exportURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.pathExtension == "json" }
    }

    private func removeDirectoryIfEmpty() throws {
        guard fileManager.fileExists(atPath: directory.path()), try exportURLs().isEmpty else { return }
        try fileManager.removeItem(at: directory)
    }
}
