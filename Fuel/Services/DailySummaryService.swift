import Foundation
import OSLog

struct DayBoundaryService {
    func interval(containing date: Date, timeZoneIdentifier: String, calendar baseCalendar: Calendar = .autoupdatingCurrent) -> DayInterval {
        var calendar = baseCalendar
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return .init(start: start, end: end, timeZoneIdentifier: calendar.timeZone.identifier)
    }

    func cacheKey(for interval: DayInterval) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(identifier: interval.timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(interval.timeZoneIdentifier)|\(formatter.string(from: interval.start))"
    }
}

struct DailySummaryService {
    func build(
        interval: DayInterval,
        targets: DailyTargets,
        meals: [Meal],
        hydrationEntries: [HydrationEntry],
        activity: DailyActivitySummary,
        sleep: SleepSummary,
        workouts: [WorkoutSummary],
        body: BodyMeasurementSummary? = nil,
        now: Date = .now
    ) -> DailyHealthSnapshot {
        let dayMeals = meals.filter { $0.status != .deleted && interval.contains($0.date) }
        let loggedMeals = dayMeals.filter { $0.status == .logged }
        let consumed = loggedMeals.reduce(NutritionEstimate.zero) { $0 + $1.nutrition }
        let hydration = hydrationEntries
            .filter { interval.contains($0.date) }
            .reduce(0) { $0 + $1.amountMilliliters }
        var adjustedActivity = activity
        adjustedActivity.stepGoal = targets.steps
        var adjustedSleep = sleep
        adjustedSleep.targetMinutes = targets.sleepMinutes
        let confidences = loggedMeals.map { meal -> Double in
            switch meal.provenance {
            case .userEntered, .nutritionDatabase: 1
            case .aiEstimated: meal.confidence ?? 0.5
            case .healthKit, .imported: 0.85
            }
        }
        let averageConfidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        let verifiedCount = loggedMeals.filter { $0.provenance == .userEntered || $0.provenance == .nutritionDatabase }.count

        return .init(
            interval: interval,
            nutrition: .init(consumed: consumed, targets: targets, hydrationMilliliters: hydration, mealCount: loggedMeals.count, averageEstimateConfidence: averageConfidence, verifiedMealCount: verifiedCount),
            activity: adjustedActivity,
            sleep: adjustedSleep,
            meals: dayMeals.sorted { $0.date < $1.date }.map(\.summary),
            workouts: workouts.sorted { $0.startDate < $1.startDate },
            lastUpdated: now,
            isFromCache: false,
            body: body
        )
    }
}

@MainActor
final class DailyDataCoordinator {
    /// Retry budget shared by the pending-recognition queue and the sync queue.
    /// Once `attempts` reaches this value the record stops being offered for automatic
    /// retry; `lastError` is preserved so the UI can surface why it stopped.
    static let maxRetryAttempts = 8
    nonisolated static let mealDeletionUndoRetention: TimeInterval = 15

    /// Grace period before an unreferenced meal photo is deleted. Long enough that an
    /// in-flight save or a just-undone deletion is never caught, short enough that photos
    /// do not outlive the records that justified keeping them.
    nonisolated static let orphanedPhotoRetention: TimeInterval = 7 * 24 * 60 * 60

    private let logger = Logger(subsystem: "com.pak.fuel", category: "DailyDataCoordinator")
    private let repositories: LocalRepositoryContainer
    private let summaryService: DailySummaryService
    private let boundaryService: DayBoundaryService
    private let healthService: any HealthDataService
    private let mealPhotoStore: any MealPhotoStore

    init(
        repositories: LocalRepositoryContainer,
        healthService: any HealthDataService,
        summaryService: DailySummaryService = .init(),
        boundaryService: DayBoundaryService = .init(),
        mealPhotoStore: any MealPhotoStore = LocalMealPhotoStore()
    ) {
        self.repositories = repositories
        self.healthService = healthService
        self.summaryService = summaryService
        self.boundaryService = boundaryService
        self.mealPhotoStore = mealPhotoStore
    }

    func bootstrap() throws -> (UserProfile, DailyTargets) {
        var profile = try repositories.profiles.profile()
        if profile.timeZoneIdentifier != TimeZone.current.identifier {
            profile.timeZoneIdentifier = TimeZone.current.identifier
            try repositories.profiles.save(profile)
            try repositories.summaryCache.removeAll()
        }
        let targets = try repositories.targets.currentTargets()
        _ = try repositories.settings.settings()
        return (profile, targets)
    }

    func snapshot(for date: Date, profile: UserProfile, targets: DailyTargets) async throws -> DailyHealthSnapshot {
        let interval = boundaryService.interval(containing: date, timeZoneIdentifier: profile.timeZoneIdentifier)
        let dayKey = boundaryService.cacheKey(for: interval)

        do {
            async let activity = healthService.activity(for: interval)
            async let sleep = healthService.sleep(for: interval)
            async let workouts = healthService.workouts(for: interval)
            async let body = healthService.bodyMeasurements()
            let meals = try repositories.meals.meals(in: interval)
            let hydration = try repositories.hydration.entries(in: interval)
            let snapshot = try await summaryService.build(
                interval: interval,
                targets: targets,
                meals: meals,
                hydrationEntries: hydration,
                activity: activity,
                sleep: sleep,
                workouts: workouts,
                body: body
            )
            do {
                try repositories.summaryCache.save(snapshot, dayKey: dayKey, sourceRevision: sourceRevision(meals: meals, hydration: hydration))
            } catch {
                logger.error("Daily summary cache save failed: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
            return snapshot
        } catch {
            do {
                if var cached = try repositories.summaryCache.snapshot(for: dayKey) {
                    cached.isFromCache = true
                    return cached
                }
            } catch let cacheError {
                logger.error("Daily summary cache read failed: \(String(describing: type(of: cacheError)), privacy: .public) \(cacheError.localizedDescription, privacy: .private)")
            }
            throw error
        }
    }

    func snapshots(ending date: Date, days: Int, profile: UserProfile, targets: DailyTargets) async throws -> [DailyHealthSnapshot] {
        guard days > 0 else { return [] }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: profile.timeZoneIdentifier) ?? .autoupdatingCurrent
        let endDay = calendar.startOfDay(for: date)
        var values: [DailyHealthSnapshot] = []
        for offset in (0..<days).reversed() {
            try Task.checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDay) else { continue }
            values.append(try await snapshot(for: day, profile: profile, targets: targets))
        }
        return values
    }

    func saveMeal(_ draft: MealDraft) async throws -> Meal {
        let id = UUID()
        var imageFileName: String?
        if let imageData = draft.imageData {
            imageFileName = try await mealPhotoStore.save(imageData, id: id)
        }
        let meal = Meal(id: id, name: draft.name, type: draft.type, date: draft.date, nutrition: draft.nutrition, items: draft.items, provenance: draft.provenance, confidence: draft.confidence, imageFileName: imageFileName, notes: draft.notes, status: draft.status)
        do {
            try repositories.meals.save(meal)
            try invalidate(date: draft.date, timeZoneIdentifier: TimeZone.current.identifier)
            enqueueSyncBestEffort(entityType: "meal", identifier: meal.id.uuidString, operation: .create, value: ExportedMeal(meal: meal), revisionDate: meal.updatedAt)
            return meal
        } catch {
            if let imageFileName {
                await deletePhotoBestEffort(fileName: imageFileName, reason: "meal save rollback")
            }
            throw error
        }
    }

    func deleteMeal(_ meal: Meal) async throws {
        let date = meal.date
        let timeZoneIdentifier = meal.timeZoneIdentifier
        try repositories.meals.delete(meal)
        do {
            if let imageFileName = meal.imageFileName {
                try await mealPhotoStore.stageForDeletion(fileName: imageFileName)
            }
            try invalidate(date: date, timeZoneIdentifier: timeZoneIdentifier)
        } catch {
            try? repositories.meals.restore(meal)
            if let imageFileName = meal.imageFileName {
                try? await mealPhotoStore.restoreStaged(fileName: imageFileName)
            }
            throw error
        }
        enqueueSyncBestEffort(entityType: "meal", identifier: meal.id.uuidString, operation: .delete, value: ExportedMeal(meal: meal), revisionDate: meal.updatedAt)
        scheduleDeletedPhotoExpiry(mealID: meal.id, fileName: meal.imageFileName)
    }

    func restoreMeal(_ meal: Meal) async throws {
        if let imageFileName = meal.imageFileName {
            try await mealPhotoStore.restoreStaged(fileName: imageFileName)
        }
        do {
            try repositories.meals.restore(meal)
            try invalidate(date: meal.date, timeZoneIdentifier: meal.timeZoneIdentifier)
        } catch {
            if let imageFileName = meal.imageFileName {
                try? await mealPhotoStore.stageForDeletion(fileName: imageFileName)
            }
            throw error
        }
    }

    func duplicateMeal(_ meal: Meal, at date: Date = .now) async throws -> Meal {
        try await saveMeal(MealTemplate(meal: meal).draft(date: date))
    }

    func allMeals() throws -> [Meal] { try repositories.meals.allMeals() }

    func meal(id: UUID) throws -> Meal? { try repositories.meals.allMeals().first { $0.id == id } }

    func recentFoodItems(limit: Int = 12) throws -> [MealItem] {
        var seen = Set<String>()
        var result: [MealItem] = []
        for meal in try repositories.meals.allMeals() {
            for item in meal.items {
                let key = item.foodIdentifier ?? item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append(item)
                if result.count == limit { return result }
            }
        }
        return result
    }

    func hydrationEntries(for date: Date, timeZoneIdentifier: String) throws -> [HydrationEntry] {
        let interval = boundaryService.interval(containing: date, timeZoneIdentifier: timeZoneIdentifier)
        return try repositories.hydration.entries(in: interval)
    }

    func updateHydration(_ entry: HydrationEntry, amountMilliliters: Double, date: Date, timeZoneIdentifier: String) throws {
        let oldDate = entry.date
        try repositories.hydration.update(entry, amountMilliliters: amountMilliliters, date: date)
        try invalidate(date: oldDate, timeZoneIdentifier: timeZoneIdentifier)
        if !Calendar.autoupdatingCurrent.isDate(oldDate, inSameDayAs: date) {
            try invalidate(date: date, timeZoneIdentifier: timeZoneIdentifier)
        }
        enqueueSyncBestEffort(entityType: "hydration", identifier: entry.id.uuidString, operation: .update, value: exportedHydration(entry), revisionDate: .now)
    }

    func deleteHydration(_ entry: HydrationEntry, timeZoneIdentifier: String) throws {
        try repositories.hydration.delete(entry)
        try invalidate(date: entry.date, timeZoneIdentifier: timeZoneIdentifier)
        enqueueSyncBestEffort(entityType: "hydration", identifier: entry.id.uuidString, operation: .delete, value: exportedHydration(entry), revisionDate: .now)
    }

    func favorites() throws -> [MealTemplate] { try repositories.favorites.favorites() }

    func saveFavorite(from meal: Meal) throws {
        try repositories.favorites.save(MealTemplate(meal: meal))
    }

    func deleteFavorite(id: UUID) throws { try repositories.favorites.delete(id: id) }

    func exportPayload(profile: UserProfile, targets: DailyTargets, preferences: UserPreferences) throws -> FuelExportPayload {
        .init(
            profile: profile,
            targets: targets,
            preferences: preferences,
            meals: try repositories.meals.allMeals().map(ExportedMeal.init),
            hydration: try repositories.hydration.allEntries().map {
                .init(id: $0.id, date: $0.date, amountMilliliters: $0.amountMilliliters, provenance: $0.provenance)
            }
        )
    }

    func deleteAllLocalData() async throws {
        try repositories.deleteAllData()
        try await mealPhotoStore.deleteAll()
    }

    func preferences() throws -> UserPreferences { try repositories.preferences.preferences() }

    func savePreferences(_ preferences: UserPreferences) throws {
        try repositories.preferences.save(preferences)
        enqueueSyncBestEffort(entityType: "preferences", identifier: "primary", operation: .update, value: preferences, revisionDate: .now)
    }

    func recommendationFeedback(for key: String, kind: RecommendationFeedbackKind) throws {
        try repositories.recommendationFeedback.save(recommendationKey: key, kind: kind)
    }

    func recentRecommendationFeedback(since date: Date) throws -> [RecommendationFeedbackRecord] {
        try repositories.recommendationFeedback.recent(since: date)
    }

    func updateMeal(_ meal: Meal, with draft: MealDraft) async throws {
        let oldDate = meal.date
        let oldTimeZoneIdentifier = meal.timeZoneIdentifier
        let oldImageFileName = meal.imageFileName
        var replacementImageFileName: String?
        if let imageData = draft.imageData {
            replacementImageFileName = try await mealPhotoStore.save(imageData, id: meal.id)
        }
        meal.update(with: draft, imageFileName: replacementImageFileName)
        if draft.removeExistingImage { meal.imageFileName = nil }
        do {
            try repositories.meals.save(meal)
            try invalidate(date: oldDate, timeZoneIdentifier: oldTimeZoneIdentifier)
            try invalidate(date: draft.date, timeZoneIdentifier: TimeZone.current.identifier)
            if (replacementImageFileName != nil || draft.removeExistingImage), let oldImageFileName, oldImageFileName != replacementImageFileName {
                await deletePhotoBestEffort(fileName: oldImageFileName, reason: "meal photo replacement")
            }
            enqueueSyncBestEffort(entityType: "meal", identifier: meal.id.uuidString, operation: .update, value: ExportedMeal(meal: meal), revisionDate: meal.updatedAt)
        } catch {
            if let replacementImageFileName {
                await deletePhotoBestEffort(fileName: replacementImageFileName, reason: "meal update rollback")
            }
            throw error
        }
    }

    func addWater(milliliters: Double, at date: Date, timeZoneIdentifier: String) throws {
        let entry = try repositories.hydration.add(amountMilliliters: milliliters, at: date, provenance: .userEntered)
        try invalidate(date: date, timeZoneIdentifier: timeZoneIdentifier)
        enqueueSyncBestEffort(entityType: "hydration", identifier: entry.id.uuidString, operation: .create, value: exportedHydration(entry), revisionDate: entry.createdAt)
    }

    @discardableResult
    func consumeHydrationCommand(_ command: PendingHydrationCommand, timeZoneIdentifier: String) throws -> Bool {
        let interval = boundaryService.interval(containing: command.createdAt, timeZoneIdentifier: timeZoneIdentifier)
        guard let entry = try repositories.consumeHydrationCommand(command, dayKey: boundaryService.cacheKey(for: interval)) else { return false }
        enqueueSyncBestEffort(entityType: "hydration", identifier: entry.id.uuidString, operation: .create, value: exportedHydration(entry), revisionDate: entry.createdAt)
        return true
    }

    func pendingRecognitionJobs() throws -> [PendingRecognitionRecord] {
        try repositories.pendingRecognition.all()
    }

    func queueRecognition(imageData: Data) async throws -> PendingRecognitionRecord {
        let id = UUID()
        let fileName = try await mealPhotoStore.save(imageData, id: id)
        let record = PendingRecognitionRecord(id: id, idempotencyKey: id.uuidString, photoFileName: fileName)
        do {
            try repositories.pendingRecognition.save(record)
            return record
        } catch {
            await deletePhotoBestEffort(fileName: fileName, reason: "pending recognition rollback")
            throw error
        }
    }

    func pendingRecognitionImageData(_ record: PendingRecognitionRecord) async throws -> Data {
        try await mealPhotoStore.load(fileName: record.photoFileName)
    }

    /// `attempts` is incremented in exactly one place per queue: when an attempt *fails*
    /// (`markRecognitionFailed` / `markSyncFailed`). Starting work never increments, so a
    /// process kill mid-attempt cannot inflate the retry budget.
    func markRecognitionProcessing(_ record: PendingRecognitionRecord) throws {
        record.state = .processing
        record.lastError = nil
        try repositories.pendingRecognition.save(record)
    }

    /// Manual (user-initiated) retry: clears the retry budget so an exhausted record
    /// can re-enter the automatic queue.
    func resetRecognitionForRetry(_ record: PendingRecognitionRecord) throws {
        record.state = .pending
        record.attempts = 0
        record.nextAttemptAt = nil
        try repositories.pendingRecognition.save(record)
    }

    func markRecognitionCompleted(_ record: PendingRecognitionRecord, result: FoodRecognitionResult) throws {
        record.state = .completed
        record.resultData = try JSONEncoder().encode(result)
        record.nextAttemptAt = nil
        record.lastError = nil
        try repositories.pendingRecognition.save(record)
    }

    func markRecognitionFailed(_ record: PendingRecognitionRecord, error: Error, now: Date = .now) throws {
        record.state = .failed
        record.attempts += 1
        record.lastError = String(error.localizedDescription.prefix(240))
        if record.attempts >= Self.maxRetryAttempts {
            // Terminal: excluded from automatic retry until the user retries manually.
            record.nextAttemptAt = nil
        } else {
            let delay = min(pow(2, Double(max(record.attempts, 1))) * 30, 6 * 60 * 60)
            record.nextAttemptAt = now.addingTimeInterval(delay)
        }
        try repositories.pendingRecognition.save(record)
    }

    func isRetryExhausted(_ record: PendingRecognitionRecord) -> Bool {
        record.attempts >= Self.maxRetryAttempts
    }

    /// Resets work interrupted by a process kill so it re-enters its queue.
    /// Retry metadata (`attempts`, `lastError`) is preserved.
    func reconcileInterruptedWork() throws {
        for record in try repositories.pendingRecognition.all() where record.state == .processing {
            record.state = .pending
            record.nextAttemptAt = nil
            try repositories.pendingRecognition.save(record)
        }
        for operation in try repositories.syncQueue.all() where operation.state == .uploading {
            operation.state = .pending
            operation.nextAttemptAt = nil
            try repositories.syncQueue.save(operation)
        }
        // Retention sweep. The reference set is read here, synchronously, while the model
        // context is known to be alive; the async part below only touches the filesystem, so
        // it can safely outlive this call and can never fail the queue reconciliation.
        var referenced = Set(try repositories.meals.allMeals().compactMap(\.imageFileName))
        referenced.formUnion(try repositories.pendingRecognition.all().map(\.photoFileName))
        let names = referenced
        let logger = logger
        let store = mealPhotoStore
        Task {
            do {
                let removed = try await Self.purgeOrphanedPhotos(in: store, referencedFileNames: names)
                let staged = try await Self.purgeStagedPhotos(in: store, retention: 0)
                if !removed.isEmpty || !staged.isEmpty {
                    logger.info("Purged \(removed.count + staged.count, privacy: .public) orphaned meal photo(s)")
                }
            } catch {
                logger.error("Orphaned photo purge failed: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Deletes photos no meal and no queued recognition still points at, returning the file
    /// names it removed. A photo whose meal was soft-deleted becomes unreferenced immediately
    /// but survives `retention` first, so undo keeps working.
    @discardableResult
    nonisolated static func purgeOrphanedPhotos(
        in store: any MealPhotoStore,
        referencedFileNames: Set<String>,
        retention: TimeInterval = orphanedPhotoRetention,
        now: Date = .now
    ) async throws -> [String] {
        var removed: [String] = []
        for photo in try await store.storedPhotos() where !referencedFileNames.contains(photo.fileName) {
            guard now.timeIntervalSince(photo.modifiedAt) >= retention else { continue }
            try await store.delete(fileName: photo.fileName)
            removed.append(photo.fileName)
        }
        return removed
    }

    @discardableResult
    nonisolated static func purgeStagedPhotos(
        in store: any MealPhotoStore,
        retention: TimeInterval = mealDeletionUndoRetention,
        now: Date = .now
    ) async throws -> [String] {
        var removed: [String] = []
        for photo in try await store.stagedPhotos() {
            guard now.timeIntervalSince(photo.modifiedAt) >= retention else { continue }
            try await store.deleteStaged(fileName: photo.fileName)
            removed.append(photo.fileName)
        }
        return removed
    }

    func deletePendingRecognition(_ record: PendingRecognitionRecord) async throws {
        let fileName = record.photoFileName
        try repositories.pendingRecognition.delete(record)
        try await mealPhotoStore.delete(fileName: fileName)
    }

    func saveProfile(_ profile: UserProfile) throws {
        try repositories.profiles.save(profile)
        try repositories.summaryCache.removeAll()
        enqueueSyncBestEffort(entityType: "profile", identifier: "primary", operation: .update, value: profile, revisionDate: .now)
    }

    func saveTargets(_ targets: DailyTargets, explanation: String = "Targets updated manually") throws {
        try repositories.targets.save(targets)
        try repositories.goalHistory.append(targets: targets, explanation: explanation, effectiveDate: .now)
        try repositories.summaryCache.removeAll()
        enqueueSyncBestEffort(entityType: "targets", identifier: "current", operation: .update, value: targets, revisionDate: .now)
    }

    func setHealthKitEnabled(_ isEnabled: Bool) throws {
        let settings = try repositories.settings.settings()
        settings.healthKitEnabled = isEnabled
        try repositories.settings.save()
    }

    func accountMetadata() throws -> AccountMetadataRecord { try repositories.accountMetadata.account() }

    func applyAccountSession(_ result: AccountSessionResult) throws {
        let account = try repositories.accountMetadata.account()
        account.appleUserIdentifierHash = result.userIdentifierHash
        account.displayName = result.displayName
        account.emailHint = result.emailHint
        account.syncEnabled = result.cloudConnected
        try repositories.accountMetadata.save()
    }

    func signOutAccount() throws {
        let account = try repositories.accountMetadata.account()
        account.appleUserIdentifierHash = nil
        account.displayName = nil
        account.emailHint = nil
        account.syncEnabled = false
        account.lastSyncAt = nil
        account.serverRevision = 0
        try repositories.accountMetadata.save()
    }

    func setSyncEnabled(_ enabled: Bool) throws {
        let account = try repositories.accountMetadata.account()
        account.syncEnabled = enabled && account.appleUserIdentifierHash != nil
        try repositories.accountMetadata.save()
    }

    func readySyncOperations(at date: Date = .now) throws -> [SyncOperationRecord] {
        try repositories.syncQueue.ready(at: date).filter { $0.attempts < Self.maxRetryAttempts }
    }

    func allSyncOperations() throws -> [SyncOperationRecord] { try repositories.syncQueue.all() }

    func markSyncUploading(_ operation: SyncOperationRecord) throws {
        operation.state = .uploading
        operation.lastError = nil
        try repositories.syncQueue.save(operation)
    }

    func markSyncFailed(_ operation: SyncOperationRecord, error: Error, now: Date = .now) throws {
        operation.state = .failed
        operation.attempts += 1
        operation.lastError = String(error.localizedDescription.prefix(240))
        if operation.attempts >= Self.maxRetryAttempts {
            operation.nextAttemptAt = nil
        } else {
            operation.nextAttemptAt = now.addingTimeInterval(min(pow(2, Double(max(operation.attempts, 1))) * 30, 6 * 60 * 60))
        }
        try repositories.syncQueue.save(operation)
    }

    func acceptSyncOperation(_ operation: SyncOperationRecord) throws {
        try repositories.syncQueue.delete(operation)
    }

    func retrySyncOperation(_ operation: SyncOperationRecord, serverRevision: Int) throws {
        operation.state = .pending
        operation.clientRevision = max(operation.clientRevision, serverRevision)
        operation.idempotencyKey = UUID().uuidString
        operation.nextAttemptAt = nil
        try repositories.syncQueue.save(operation)
    }

    func updateServerRevision(_ revision: Int) throws {
        let account = try repositories.accountMetadata.account()
        account.serverRevision = max(account.serverRevision, revision)
        account.lastSyncAt = .now
        try repositories.accountMetadata.save()
    }

    func applyRemoteChange(_ change: SyncConflict) throws {
        switch change.entityType {
        case "meal":
            guard change.operation != .delete || UUID(uuidString: change.entityIdentifier) != nil else { throw BackendError.invalidPayload }
            guard let id = UUID(uuidString: change.entityIdentifier) else { throw BackendError.invalidPayload }
            if change.operation == .delete {
                if let meal = try repositories.meals.meal(id: id) { try repositories.meals.delete(meal) }
            } else {
                let remote = try JSONDecoder().decode(ExportedMeal.self, from: change.serverPayload)
                let draft = MealDraft(name: remote.name, type: remote.type, date: remote.date, nutrition: remote.nutrition, items: remote.items, provenance: remote.provenance, confidence: remote.confidence, imageData: nil, notes: remote.notes, status: remote.status)
                if let meal = try repositories.meals.meal(id: id) {
                    meal.update(with: draft)
                    try repositories.meals.save(meal)
                } else {
                    try repositories.meals.save(Meal(id: id, name: remote.name, type: remote.type, date: remote.date, nutrition: remote.nutrition, items: remote.items, provenance: remote.provenance, confidence: remote.confidence, notes: remote.notes, status: remote.status))
                }
            }
        case "profile":
            try repositories.profiles.save(JSONDecoder().decode(UserProfile.self, from: change.serverPayload))
        case "targets":
            try repositories.targets.save(JSONDecoder().decode(DailyTargets.self, from: change.serverPayload))
        case "preferences":
            try repositories.preferences.save(JSONDecoder().decode(UserPreferences.self, from: change.serverPayload))
        case "hydration":
            guard let id = UUID(uuidString: change.entityIdentifier) else { throw BackendError.invalidPayload }
            if change.operation == .delete {
                if let entry = try repositories.hydration.entry(id: id) { try repositories.hydration.delete(entry) }
            } else {
                let remote = try JSONDecoder().decode(ExportedHydration.self, from: change.serverPayload)
                if let entry = try repositories.hydration.entry(id: id) {
                    try repositories.hydration.update(entry, amountMilliliters: remote.amountMilliliters, date: remote.date)
                } else {
                    try repositories.hydration.save(HydrationEntry(id: id, date: remote.date, amountMilliliters: remote.amountMilliliters, provenance: .imported))
                }
            }
        default:
            throw BackendError.invalidPayload
        }
        try repositories.summaryCache.removeAll()
    }

    private func invalidate(date: Date, timeZoneIdentifier: String) throws {
        let interval = boundaryService.interval(containing: date, timeZoneIdentifier: timeZoneIdentifier)
        try repositories.summaryCache.remove(for: boundaryService.cacheKey(for: interval))
    }

    private func sourceRevision(meals: [Meal], hydration: [HydrationEntry]) -> Int {
        let mealRevision = meals.map { Int($0.updatedAt.timeIntervalSinceReferenceDate) }.max() ?? 0
        let waterRevision = hydration.map { Int($0.createdAt.timeIntervalSinceReferenceDate) }.max() ?? 0
        return max(mealRevision, waterRevision)
    }

    private func enqueueSyncBestEffort<Value: Encodable>(
        entityType: String,
        identifier: String,
        operation: SyncOperationKind,
        value: Value,
        revisionDate: Date
    ) {
        do {
            let account = try repositories.accountMetadata.account()
            guard account.syncEnabled else { return }
            let payload = try JSONEncoder().encode(value)
            let existing = try repositories.syncQueue.all().last {
                $0.entityType == entityType
                    && $0.entityIdentifier == identifier
                    && $0.state != .completed
            }
            if let existing {
                existing.operation = existing.operation == .create && operation == .update ? .create : operation
                existing.payloadData = payload
                existing.clientRevision = Int(revisionDate.timeIntervalSince1970 * 1_000)
                existing.idempotencyKey = UUID().uuidString
                existing.state = .pending
                existing.nextAttemptAt = nil
                try repositories.syncQueue.save(existing)
            } else {
                try repositories.syncQueue.save(SyncOperationRecord(
                    entityType: entityType,
                    entityIdentifier: identifier,
                    operation: operation,
                    payloadData: payload,
                    clientRevision: Int(revisionDate.timeIntervalSince1970 * 1_000)
                ))
            }
        } catch {
            logger.error("Sync enqueue failed entity=\(entityType, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func exportedHydration(_ entry: HydrationEntry) -> ExportedHydration {
        .init(id: entry.id, date: entry.date, amountMilliliters: entry.amountMilliliters, provenance: entry.provenance)
    }

    private func deletePhotoBestEffort(fileName: String, reason: String) async {
        do {
            try await mealPhotoStore.delete(fileName: fileName)
        } catch {
            logger.error("Photo cleanup failed during \(reason, privacy: .public): \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func scheduleDeletedPhotoExpiry(mealID: UUID, fileName: String?) {
        guard let fileName else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.mealDeletionUndoRetention))
            guard !Task.isCancelled, let self,
                  (try? self.repositories.meals.meal(id: mealID)?.status) == .deleted else { return }
            do { try await self.mealPhotoStore.deleteStaged(fileName: fileName) }
            catch {
                self.logger.error("Deleted meal photo cleanup failed: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
