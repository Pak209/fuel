import Foundation
import SwiftData

enum LocalDataError: LocalizedError {
    case notConfigured
    case missingRecord(String)
    case persistenceFailed(String)
    case invalidAmount
    case invalidExternalCommand

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Local data is still starting. Please try again."
        case .missingRecord(let name): "The saved \(name) could not be found."
        case .persistenceFailed(let reason): "Fuel could not save your data. \(reason)"
        case .invalidAmount: "Enter an amount greater than zero."
        case .invalidExternalCommand: "A shortcut entry was invalid and was not imported."
        }
    }
}

@MainActor
protocol MealRepository {
    func meals(in interval: DayInterval) throws -> [Meal]
    func allMeals() throws -> [Meal]
    func meal(id: UUID) throws -> Meal?
    func save(_ meal: Meal) throws
    func saveRemote(_ meal: Meal) throws
    func delete(_ meal: Meal) throws
    func restore(_ meal: Meal) throws
}

@MainActor
protocol ProfileRepository {
    func profile() throws -> UserProfile
    func save(_ profile: UserProfile) throws
}

@MainActor
protocol TargetRepository {
    func currentTargets() throws -> DailyTargets
    func save(_ targets: DailyTargets) throws
}

@MainActor
protocol HydrationRepository {
    func entries(in interval: DayInterval) throws -> [HydrationEntry]
    func allEntries() throws -> [HydrationEntry]
    func entry(id: UUID) throws -> HydrationEntry?
    @discardableResult func add(amountMilliliters: Double, at date: Date, provenance: DataProvenance) throws -> HydrationEntry
    func save(_ entry: HydrationEntry) throws
    func update(_ entry: HydrationEntry, amountMilliliters: Double, date: Date) throws
    func delete(_ entry: HydrationEntry) throws
}

@MainActor
protocol SettingsRepository {
    func settings() throws -> AppSettingsRecord
    func save() throws
}

@MainActor
protocol DailySummaryCacheRepository {
    func snapshot(for dayKey: String) throws -> DailyHealthSnapshot?
    func save(_ snapshot: DailyHealthSnapshot, dayKey: String, sourceRevision: Int) throws
    func remove(for dayKey: String) throws
    func removeAll() throws
}

@MainActor
protocol PreferencesRepository {
    func preferences() throws -> UserPreferences
    func save(_ preferences: UserPreferences) throws
}

@MainActor
protocol FavoriteMealRepository {
    func favorites() throws -> [MealTemplate]
    func save(_ template: MealTemplate) throws
    func delete(id: UUID) throws
}

@MainActor
protocol GoalHistoryRepository {
    func history() throws -> [GoalHistoryRecord]
    func append(targets: DailyTargets, explanation: String, effectiveDate: Date) throws
}

@MainActor
protocol RecommendationFeedbackRepository {
    func recent(since date: Date) throws -> [RecommendationFeedbackRecord]
    func save(recommendationKey: String, kind: RecommendationFeedbackKind) throws
}

@MainActor
protocol PendingRecognitionRepository {
    func all() throws -> [PendingRecognitionRecord]
    func save(_ record: PendingRecognitionRecord) throws
    func delete(_ record: PendingRecognitionRecord) throws
}

@MainActor
protocol SyncQueueRepository {
    func ready(at date: Date) throws -> [SyncOperationRecord]
    func all() throws -> [SyncOperationRecord]
    func save(_ operation: SyncOperationRecord) throws
    func delete(_ operation: SyncOperationRecord) throws
}

@MainActor
protocol AccountMetadataRepository {
    func account() throws -> AccountMetadataRecord
    func save() throws
}

@MainActor
final class SwiftDataMealRepository: MealRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func meals(in interval: DayInterval) throws -> [Meal] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<Meal>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        )
        return try context.fetch(descriptor).filter { $0.status != .deleted }
    }

    func allMeals() throws -> [Meal] {
        try context.fetch(FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
            .filter { $0.status != .deleted }
    }

    func meal(id: UUID) throws -> Meal? {
        let value = id
        return try context.fetch(FetchDescriptor<Meal>(predicate: #Predicate { $0.id == value })).first
    }

    func save(_ meal: Meal) throws {
        if meal.modelContext == nil { context.insert(meal) }
        meal.updatedAt = .now
        try saveContext()
    }

    func saveRemote(_ meal: Meal) throws {
        if meal.modelContext == nil { context.insert(meal) }
        try saveContext()
    }

    func delete(_ meal: Meal) throws {
        meal.status = .deleted
        meal.updatedAt = .now
        try saveContext()
    }

    func restore(_ meal: Meal) throws {
        meal.status = .logged
        meal.updatedAt = .now
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataProfileRepository: ProfileRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func profile() throws -> UserProfile {
        if let record = try context.fetch(FetchDescriptor<UserProfileRecord>()).first {
            return record.domainValue
        }
        let record = UserProfileRecord()
        context.insert(record)
        try saveContext()
        return record.domainValue
    }

    func save(_ profile: UserProfile) throws {
        if let record = try context.fetch(FetchDescriptor<UserProfileRecord>()).first {
            record.update(with: profile)
        } else {
            context.insert(UserProfileRecord(profile: profile))
        }
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataTargetRepository: TargetRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func currentTargets() throws -> DailyTargets {
        if let record = try context.fetch(FetchDescriptor<DailyTargetRecord>()).first { return record.domainValue }
        let record = DailyTargetRecord()
        context.insert(record)
        try saveContext()
        return record.domainValue
    }

    func save(_ targets: DailyTargets) throws {
        if let old = try context.fetch(FetchDescriptor<DailyTargetRecord>()).first { context.delete(old) }
        context.insert(DailyTargetRecord(targets: targets))
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataHydrationRepository: HydrationRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func entries(in interval: DayInterval) throws -> [HydrationEntry] {
        let start = interval.start
        let end = interval.end
        return try context.fetch(FetchDescriptor<HydrationEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        ))
    }

    func allEntries() throws -> [HydrationEntry] {
        try context.fetch(FetchDescriptor<HydrationEntry>(sortBy: [SortDescriptor(\.date)]))
    }

    func entry(id: UUID) throws -> HydrationEntry? {
        let value = id
        return try context.fetch(FetchDescriptor<HydrationEntry>(predicate: #Predicate { $0.id == value })).first
    }

    @discardableResult
    func add(amountMilliliters: Double, at date: Date, provenance: DataProvenance = .userEntered) throws -> HydrationEntry {
        guard amountMilliliters > 0 else { throw LocalDataError.invalidAmount }
        let entry = HydrationEntry(date: date, amountMilliliters: amountMilliliters, provenance: provenance)
        context.insert(entry)
        try saveContext()
        return entry
    }

    func save(_ entry: HydrationEntry) throws {
        if entry.modelContext == nil { context.insert(entry) }
        try saveContext()
    }

    func update(_ entry: HydrationEntry, amountMilliliters: Double, date: Date) throws {
        guard amountMilliliters > 0 else { throw LocalDataError.invalidAmount }
        entry.amountMilliliters = amountMilliliters
        entry.date = date
        try saveContext()
    }

    func delete(_ entry: HydrationEntry) throws {
        context.delete(entry)
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataSettingsRepository: SettingsRepository {
    private let context: ModelContext
    private(set) var record: AppSettingsRecord?

    init(context: ModelContext) { self.context = context }

    func settings() throws -> AppSettingsRecord {
        if let record { return record }
        if let existing = try context.fetch(FetchDescriptor<AppSettingsRecord>()).first {
            record = existing
            return existing
        }
        let created = AppSettingsRecord()
        context.insert(created)
        record = created
        try save()
        return created
    }

    func save() throws {
        record?.updatedAt = .now
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataDailySummaryCacheRepository: DailySummaryCacheRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func snapshot(for dayKey: String) throws -> DailyHealthSnapshot? {
        let key = dayKey
        let record = try context.fetch(FetchDescriptor<DailySummaryCacheRecord>(predicate: #Predicate { $0.dayKey == key })).first
        return record?.snapshot
    }

    func save(_ snapshot: DailyHealthSnapshot, dayKey: String, sourceRevision: Int) throws {
        let key = dayKey
        if let record = try context.fetch(FetchDescriptor<DailySummaryCacheRecord>(predicate: #Predicate { $0.dayKey == key })).first {
            record.update(snapshot: snapshot, sourceRevision: sourceRevision)
        } else {
            context.insert(DailySummaryCacheRecord(dayKey: key, snapshot: snapshot, sourceRevision: sourceRevision))
        }
        try saveContext()
    }

    func remove(for dayKey: String) throws {
        let key = dayKey
        let records = try context.fetch(FetchDescriptor<DailySummaryCacheRecord>(predicate: #Predicate { $0.dayKey == key }))
        records.forEach(context.delete)
        try saveContext()
    }

    func removeAll() throws {
        try context.delete(model: DailySummaryCacheRecord.self)
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataPreferencesRepository: PreferencesRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func preferences() throws -> UserPreferences {
        if let record = try context.fetch(FetchDescriptor<UserPreferencesRecord>()).first {
            return record.domainValue
        }
        let record = UserPreferencesRecord()
        context.insert(record)
        try saveContext()
        return record.domainValue
    }

    func save(_ preferences: UserPreferences) throws {
        if let record = try context.fetch(FetchDescriptor<UserPreferencesRecord>()).first {
            record.update(with: preferences)
        } else {
            context.insert(UserPreferencesRecord(preferences: preferences))
        }
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataFavoriteMealRepository: FavoriteMealRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func favorites() throws -> [MealTemplate] {
        try context.fetch(FetchDescriptor<FavoriteMealRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .compactMap(\.template)
    }

    func save(_ template: MealTemplate) throws {
        let payload = try JSONEncoder().encode(template)
        if let existing = try context.fetch(FetchDescriptor<FavoriteMealRecord>()).first(where: { $0.id == template.id }) {
            existing.name = template.name
            existing.payloadData = payload
            existing.updatedAt = .now
        } else {
            context.insert(FavoriteMealRecord(template: template))
        }
        try saveContext()
    }

    func delete(id: UUID) throws {
        let records = try context.fetch(FetchDescriptor<FavoriteMealRecord>())
        records.filter { $0.id == id }.forEach(context.delete)
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataGoalHistoryRepository: GoalHistoryRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func history() throws -> [GoalHistoryRecord] {
        try context.fetch(FetchDescriptor<GoalHistoryRecord>(sortBy: [SortDescriptor(\.effectiveDate, order: .reverse)]))
    }

    func append(targets: DailyTargets, explanation: String, effectiveDate: Date = .now) throws {
        context.insert(GoalHistoryRecord(targets: targets, effectiveDate: effectiveDate, explanation: explanation))
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataRecommendationFeedbackRepository: RecommendationFeedbackRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func recent(since date: Date) throws -> [RecommendationFeedbackRecord] {
        let cutoff = date
        return try context.fetch(FetchDescriptor<RecommendationFeedbackRecord>(
            predicate: #Predicate { $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
    }

    func save(recommendationKey: String, kind: RecommendationFeedbackKind) throws {
        context.insert(RecommendationFeedbackRecord(recommendationKey: recommendationKey, kind: kind))
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataPendingRecognitionRepository: PendingRecognitionRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func all() throws -> [PendingRecognitionRecord] {
        try context.fetch(FetchDescriptor<PendingRecognitionRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func save(_ record: PendingRecognitionRecord) throws {
        if record.modelContext == nil { context.insert(record) }
        record.updatedAt = .now
        try saveContext()
    }

    func delete(_ record: PendingRecognitionRecord) throws {
        context.delete(record)
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataSyncQueueRepository: SyncQueueRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func ready(at date: Date) throws -> [SyncOperationRecord] {
        try all().filter {
            ($0.state == .pending || $0.state == .failed)
                && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= date)
        }
    }

    func all() throws -> [SyncOperationRecord] {
        try context.fetch(FetchDescriptor<SyncOperationRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func save(_ operation: SyncOperationRecord) throws {
        if operation.modelContext == nil { context.insert(operation) }
        // updatedAt describes the user mutation, not upload/retry bookkeeping.
        try saveContext()
    }

    func delete(_ operation: SyncOperationRecord) throws {
        context.delete(operation)
        try saveContext()
    }

    private func saveContext() throws {
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
final class SwiftDataAccountMetadataRepository: AccountMetadataRepository {
    private let context: ModelContext
    private var record: AccountMetadataRecord?

    init(context: ModelContext) { self.context = context }

    func account() throws -> AccountMetadataRecord {
        if let record { return record }
        if let existing = try context.fetch(FetchDescriptor<AccountMetadataRecord>()).first {
            record = existing
            return existing
        }
        let created = AccountMetadataRecord()
        context.insert(created)
        record = created
        try save()
        return created
    }

    func save() throws {
        record?.updatedAt = .now
        do { try context.save() }
        catch { throw LocalDataError.persistenceFailed(error.localizedDescription) }
    }
}

@MainActor
struct LocalRepositoryContainer {
    private let context: ModelContext
    let meals: any MealRepository
    let profiles: any ProfileRepository
    let targets: any TargetRepository
    let hydration: any HydrationRepository
    let settings: any SettingsRepository
    let summaryCache: any DailySummaryCacheRepository
    let preferences: any PreferencesRepository
    let favorites: any FavoriteMealRepository
    let goalHistory: any GoalHistoryRepository
    let recommendationFeedback: any RecommendationFeedbackRepository
    let pendingRecognition: any PendingRecognitionRepository
    let syncQueue: any SyncQueueRepository
    let accountMetadata: any AccountMetadataRepository

    init(context: ModelContext) {
        self.context = context
        meals = SwiftDataMealRepository(context: context)
        profiles = SwiftDataProfileRepository(context: context)
        targets = SwiftDataTargetRepository(context: context)
        hydration = SwiftDataHydrationRepository(context: context)
        settings = SwiftDataSettingsRepository(context: context)
        summaryCache = SwiftDataDailySummaryCacheRepository(context: context)
        preferences = SwiftDataPreferencesRepository(context: context)
        favorites = SwiftDataFavoriteMealRepository(context: context)
        goalHistory = SwiftDataGoalHistoryRepository(context: context)
        recommendationFeedback = SwiftDataRecommendationFeedbackRepository(context: context)
        pendingRecognition = SwiftDataPendingRecognitionRepository(context: context)
        syncQueue = SwiftDataSyncQueueRepository(context: context)
        accountMetadata = SwiftDataAccountMetadataRepository(context: context)
    }

    @discardableResult
    func consumeHydrationCommand(
        _ command: PendingHydrationCommand,
        dayKey: String,
        now: Date = .now
    ) throws -> HydrationEntry? {
        guard (FuelSharedStore.minimumHydrationAmount...FuelSharedStore.maximumHydrationAmount)
            .contains(command.amountMilliliters),
              command.createdAt >= now.addingTimeInterval(-30 * 24 * 60 * 60),
              command.createdAt <= now.addingTimeInterval(5 * 60) else {
            throw LocalDataError.invalidExternalCommand
        }
        let commandID = command.id
        if try context.fetch(FetchDescriptor<ProcessedExternalCommandRecord>(
            predicate: #Predicate { $0.id == commandID }
        )).first != nil {
            return nil
        }
        let entry = HydrationEntry(
            date: command.createdAt,
            amountMilliliters: Double(command.amountMilliliters),
            provenance: .imported
        )
        context.insert(entry)
        context.insert(ProcessedExternalCommandRecord(id: command.id, kind: "hydration"))
        let cacheKey = dayKey
        let caches = try context.fetch(FetchDescriptor<DailySummaryCacheRecord>(
            predicate: #Predicate { $0.dayKey == cacheKey }
        ))
        caches.forEach(context.delete)
        do {
            try context.save()
            return entry
        } catch {
            throw LocalDataError.persistenceFailed(error.localizedDescription)
        }
    }

    func deleteAllData() throws {
        do {
            try context.delete(model: Meal.self)
            try context.delete(model: UserProfileRecord.self)
            try context.delete(model: DailyTargetRecord.self)
            try context.delete(model: HydrationEntry.self)
            try context.delete(model: AppSettingsRecord.self)
            try context.delete(model: DailySummaryCacheRecord.self)
            try context.delete(model: UserPreferencesRecord.self)
            try context.delete(model: FavoriteMealRecord.self)
            try context.delete(model: GoalHistoryRecord.self)
            try context.delete(model: RecommendationFeedbackRecord.self)
            try context.delete(model: ProcessedExternalCommandRecord.self)
            try context.delete(model: PendingRecognitionRecord.self)
            try context.delete(model: SyncOperationRecord.self)
            try context.delete(model: AccountMetadataRecord.self)
            try context.delete(model: RemoteConfigurationRecord.self)
            try context.save()
        } catch {
            throw LocalDataError.persistenceFailed(error.localizedDescription)
        }
    }
}
