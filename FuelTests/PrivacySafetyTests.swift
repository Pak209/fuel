import Foundation
import SwiftData
import Testing
@testable import Fuel

/// Covers the privacy and safety guarantees that are easy to regress silently:
/// the retention-consent column surviving migration, downward goal adjustments being
/// clamped, the profile wire contract, and the orphaned-photo sweep.
struct PrivacySafetyTests {

    // MARK: - Retention-consent persistence

    /// The flag lives inside `UserPreferencesRecord.payloadData`, so it needs no schema
    /// version of its own. This proves the round trip across a real on-disk store that is
    /// closed and reopened through `FuelMigrationPlan`.
    @Test func retentionConsentSurvivesAnOnDiskStoreReopenedThroughTheMigrationPlan() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Fuel.store")

        var stored = UserPreferences()
        stored.onboardingCompleted = true
        stored.dailyReviewHour = 21
        stored.mealReminderHours = [7, 13, 19]
        stored.mealPhotoRetentionConsent = true
        try seedPreferencesStore(at: storeURL, schema: FuelSchemaV3.self, preferences: stored)

        let schema = Schema(versionedSchema: FuelSchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: FuelMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<UserPreferencesRecord>())

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.domainValue.onboardingCompleted)
        #expect(record.domainValue.dailyReviewHour == 21)
        #expect(record.domainValue.mealReminderHours == [7, 13, 19])
        #expect(record.domainValue.mealPhotoRetentionConsent)
    }

    /// The compatibility guarantee that replaces a migration stage: a payload written before
    /// `mealPhotoRetentionConsent` existed must decode as opted out, never opted in.
    @Test func preferencesWrittenBeforeTheFlagExistedDecodeAsOptedOut() throws {
        let legacyJSON = """
        {"onboardingCompleted":true,"unitSystem":"metric","appearance":"dark","dailyReviewHour":21}
        """
        let record = UserPreferencesRecord()
        record.payloadData = try #require(legacyJSON.data(using: .utf8))

        #expect(record.domainValue.onboardingCompleted)
        #expect(record.domainValue.dailyReviewHour == 21)
        #expect(record.domainValue.mealPhotoRetentionConsent == false)
    }

    @Test func migrationPlanStagesStayConsistentWithItsSchemaList() {
        // Guards the crash this change hit: every schema in the plan must be structurally
        // distinct, and each consecutive pair needs exactly one stage.
        #expect(FuelMigrationPlan.stages.count == FuelMigrationPlan.schemas.count - 1)
        // Written as a loop rather than `map(\.models.count)`: a key path through an
        // existential metatype crashes SILGen in Swift 6.3.3.
        var entityCounts: [Int] = []
        for schema in FuelMigrationPlan.schemas {
            entityCounts.append(schema.models.count)
        }
        #expect(Set(entityCounts).count == entityCounts.count)
    }

    @Test func retentionConsentRoundTripsThroughTheStoredPreferencesRecord() {
        var preferences = UserPreferences()
        #expect(UserPreferencesRecord().domainValue.mealPhotoRetentionConsent == false)

        preferences.mealPhotoRetentionConsent = true
        let record = UserPreferencesRecord(preferences: preferences)
        #expect(record.domainValue.mealPhotoRetentionConsent)

        preferences.mealPhotoRetentionConsent = false
        record.update(with: preferences)
        #expect(record.domainValue.mealPhotoRetentionConsent == false)
    }

    // MARK: - Goal lowering

    @Test func recalculationClampsALargeCalorieDropAndExplainsWhy() {
        var profile = UserProfile()
        profile.weightKG = 55
        profile.goal = .gradualLoss
        profile.activityLevel = "Sedentary"
        let previous = DailyTargets(calories: 2_600)
        let service = ConservativeGoalCalculationService()

        let unclamped = service.calculate(profile: profile)
        let clamped = service.calculate(profile: profile, previousTargets: previous)

        // Without a previous target the calculator would drop far more than one step allows.
        #expect(unclamped.targets.calories < previous.calories - ConservativeGoalCalculationService.maximumSingleDecreaseKilocalories)
        #expect(unclamped.adjustmentNote == nil)

        #expect(clamped.targets.calories == previous.calories - ConservativeGoalCalculationService.maximumSingleDecreaseKilocalories)
        let note = try? #require(clamped.adjustmentNote)
        #expect(clamped.assumptions.contains(clamped.adjustmentNote ?? ""))
        #expect(note?.contains("qualified professional") == true)
        // Supportive, never shaming, and never framing the lower number as an achievement.
        let lowered = (note ?? "").lowercased()
        for word in ["should", "failed", "cheat", "bad", "well done", "great job"] {
            #expect(!lowered.contains(word))
        }
    }

    @Test func recalculationLeavesSmallAndUpwardAdjustmentsUntouched() {
        var profile = UserProfile()
        profile.weightKG = 80
        profile.goal = .gradualLoss
        profile.activityLevel = "Moderately active"
        let service = ConservativeGoalCalculationService()
        let baseline = service.calculate(profile: profile).targets.calories

        // A previous target only slightly above the computed one is applied as computed.
        let small = service.calculate(profile: profile, previousTargets: DailyTargets(calories: baseline + 100))
        #expect(small.targets.calories == baseline)
        #expect(small.adjustmentNote == nil)

        // An increase is never clamped.
        let increase = service.calculate(profile: profile, previousTargets: DailyTargets(calories: baseline - 500))
        #expect(increase.targets.calories == baseline)
        #expect(increase.adjustmentNote == nil)
    }

    @Test func safetyEscalationCopyNamesTheGroupsThatNeedAProfessional() {
        let copy = SafetyCopy.professionalEscalation.lowercased()
        for phrase in ["pregnant", "under 18", "medical condition", "eating disorder", "specialized diet", "qualified professional"] {
            #expect(copy.contains(phrase))
        }
        #expect(SafetyCopy.generalWellnessPositioning.lowercased().contains("general-wellness"))
    }

    // MARK: - Profile wire contract

    @Test func profileDTOsRoundTripThroughISO8601JSON() throws {
        var profile = UserProfile()
        profile.firstName = "Ada"
        profile.allergies = ["peanuts"]
        profile.foodsToAvoid = ["licorice"]
        var preferences = UserPreferences()
        preferences.mealPhotoRetentionConsent = true
        preferences.onboardingCompleted = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response = ProfileResponse(
            profile: profile,
            targets: DailyTargets(),
            preferences: preferences,
            serverRevision: 7,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decodedResponse = try decoder.decode(ProfileResponse.self, from: encoder.encode(response))
        #expect(decodedResponse == response)
        #expect(decodedResponse.preferences.mealPhotoRetentionConsent)

        let request = ProfileUpdateRequest(profile: profile, targets: DailyTargets(), preferences: preferences, clientRevision: 3)
        let decodedRequest = try decoder.decode(ProfileUpdateRequest.self, from: encoder.encode(request))
        #expect(decodedRequest == request)
        #expect(try request.validated() == request)
    }

    @Test func profileUpdateValidationRejectsUnsendableValues() {
        let valid = ProfileUpdateRequest(profile: .init(), targets: .init(), preferences: .init(), clientRevision: 0)

        var blankName = valid
        blankName.profile.firstName = "   "
        #expect(throws: BackendError.invalidPayload) { try blankName.validated() }

        var badTimeZone = valid
        badTimeZone.profile.timeZoneIdentifier = "Not/AZone"
        #expect(throws: BackendError.invalidPayload) { try badTimeZone.validated() }

        var oversizedList = valid
        oversizedList.profile.allergies = Array(repeating: "peanut", count: 41)
        #expect(throws: BackendError.invalidPayload) { try oversizedList.validated() }

        var negativeRevision = valid
        negativeRevision.clientRevision = -1
        #expect(throws: BackendError.invalidPayload) { try negativeRevision.validated() }

        var impossibleTarget = valid
        impossibleTarget.targets.calories = 50
        #expect(throws: BackendError.invalidPayload) { try impossibleTarget.validated() }
    }

    @Test func recognitionUploadTakesRetentionConsentFromStoredPreferences() throws {
        var preferences = UserPreferences()
        let optedOut = try PhotoAnalysisUploadRequest(imageData: Data([1, 2, 3]), preferences: preferences)
        #expect(optedOut.retentionConsent == false)

        preferences.mealPhotoRetentionConsent = true
        let optedIn = try PhotoAnalysisUploadRequest(imageData: Data([1, 2, 3]), preferences: preferences)
        #expect(optedIn.retentionConsent)
        #expect(optedIn.imageBase64 == Data([1, 2, 3]).base64EncodedString())

        #expect(throws: BackendError.invalidPayload) { try PhotoAnalysisUploadRequest(imageData: Data(), preferences: preferences) }
        #expect(throws: BackendError.invalidPayload) {
            try PhotoAnalysisUploadRequest(imageData: Data([1]), mediaType: "application/octet-stream", preferences: preferences)
        }
    }

    // MARK: - Photo retention sweep

    @Test @MainActor func purgeRemovesOnlyTheUnreferencedPhoto() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMealPhotoStore(directory: directory)
        let referenced = try await store.save(Data([1, 2, 3]), id: UUID())
        let orphan = try await store.save(Data([4, 5, 6]), id: UUID())

        // Freshly written files are inside the grace period, so the default sweep is a no-op.
        let untouched = try await DailyDataCoordinator.purgeOrphanedPhotos(in: store, referencedFileNames: [referenced])
        #expect(untouched.isEmpty)
        let beforeExpiry = try await store.storedPhotos()
        #expect(beforeExpiry.count == 2)

        let removed = try await DailyDataCoordinator.purgeOrphanedPhotos(in: store, referencedFileNames: [referenced], retention: 0)
        #expect(removed == [orphan])

        let remaining = try await store.storedPhotos()
        #expect(remaining.map(\.fileName) == [referenced])
        #expect(try await store.load(fileName: referenced) == Data([1, 2, 3]))
    }

    @Test @MainActor func purgeIsSafeOnAnEmptyStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMealPhotoStore(directory: directory)
        let removed = try await DailyDataCoordinator.purgeOrphanedPhotos(in: store, referencedFileNames: [], retention: 0)
        #expect(removed.isEmpty)
    }

    // MARK: - Helpers

    /// Mirrors the container helper in `FuelTests`, but on disk and at an explicit schema
    /// version so the migration plan has something real to migrate.
    private func seedPreferencesStore(at url: URL, schema versionedSchema: any VersionedSchema.Type, preferences: UserPreferences) throws {
        let schema = Schema(versionedSchema: versionedSchema)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)
        context.insert(UserPreferencesRecord(preferences: preferences))
        try context.save()
    }
}
