import AuthenticationServices
import SwiftUI
import UIKit

struct ProfileView: View {
    let state: AppState
    @State private var showsHealthKit = false

    var body: some View {
        ZStack {
            FuelTheme.background.ignoresSafeArea()
            List {
                profileHeader
                Section("Profile and goals") {
                    NavigationLink("Personal details") { ProfileEditorView(state: state) }
                    NavigationLink("Daily targets") { TargetEditorView(state: state) }
                    LabeledContent("Activity", value: state.profile.activityLevel)
                    LabeledContent("Diet", value: state.profile.dietaryPreference.rawValue)
                }
                Section("Preferences") {
                    NavigationLink("Units") { AppPreferencesView(state: state) }
                    NavigationLink("Notifications") { NotificationPreferencesView(state: state) }
                }
                Section("Connections") {
                    NavigationLink("Account and sync") { AccountAndSyncView(state: state) }
                    Button { showsHealthKit = true } label: {
                        LabeledContent {
                            Text(healthConnectionText).foregroundStyle(FuelTheme.secondary)
                        } label: {
                            Label("Apple Health", systemImage: "heart.fill")
                        }
                    }
                    NavigationLink("Data sources") { DataSourcesView(state: state) }
                }
                Section("Privacy and data") {
                    NavigationLink("Export or delete data") { PrivacyDataView(state: state) }
                    NavigationLink("Privacy information") { PrivacyInformationView() }
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    NavigationLink("Support") { SupportView() }
                    NavigationLink("Privacy policy") { PrivacyPolicyView() }
                    NavigationLink("Safety and limitations") { SafetyInformationView() }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Profile")
        .sheet(isPresented: $showsHealthKit) { HealthPermissionView(state: state) }
    }

    private var profileHeader: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 56)).foregroundStyle(FuelTheme.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.profile.firstName).font(.title2.bold())
                    Text(state.profile.goal.rawValue).foregroundStyle(FuelTheme.secondary)
                }
            }
        }
    }

    private var healthConnectionText: String {
        switch state.permissionState {
        case .authorized: "Connected"
        case .noRecentData: "Connected · no recent data"
        case .denied: "Not allowed"
        case .unavailable: "Unavailable"
        case .requesting: "Requesting…"
        case .notDetermined: "Not connected"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct AccountAndSyncView: View {
    let state: AppState
    @State private var rawNonce = ""
    @State private var exportURL: URL?
    @State private var confirmsRemoteDeletion = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Mode") {
                LabeledContent("Storage", value: state.accountSummary.cloudConnected ? "Local + cloud" : "Local only")
                LabeledContent("Backend", value: state.accountSummary.backendConfigured ? "Configured" : "Not configured")
                if !state.accountSummary.backendConfigured {
                    Text("Fuel works fully on this iPhone without an account. Cloud sync stays off until a reviewed HTTPS backend is configured in the build environment.")
                        .font(.caption)
                        .foregroundStyle(FuelTheme.secondary)
                }
            }

            if state.accountSummary.isSignedIn {
                Section("Apple account") {
                    if let name = state.accountSummary.displayName { LabeledContent("Name", value: name) }
                    if let email = state.accountSummary.emailHint { LabeledContent("Email", value: email) }
                    Toggle("Cloud sync", isOn: Binding(
                        get: { state.accountSummary.cloudConnected },
                        set: { enabled in
                            do { try state.setCloudSyncEnabled(enabled) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    ))
                    .disabled(!state.accountSummary.backendConfigured)
                    LabeledContent("Queued changes", value: state.accountSummary.pendingOperationCount.formatted())
                    if let date = state.accountSummary.lastSyncAt {
                        LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Status", value: syncStatus)
                    Button("Sync now") { Task { await state.synchronizeNow() } }
                        .disabled(!state.accountSummary.cloudConnected)
                }
                Section("Cloud data") {
                    Button("Request cloud export") { Task { await requestExport() } }
                        .disabled(!state.accountSummary.cloudConnected || isWorking)
                    if let exportURL { ShareLink(item: exportURL, label: { Label("Share cloud export", systemImage: "square.and.arrow.up") }) }
                    Button("Sign out", role: .destructive) { Task { await signOut() } }
                    Button("Delete cloud account", role: .destructive) { confirmsRemoteDeletion = true }
                        .disabled(!state.accountSummary.cloudConnected)
                }
            } else if state.accountSummary.backendConfigured {
                Section("Optional account") {
                    SignInWithAppleButton(.continue) { request in
                        do {
                            rawNonce = try SignInNonce.generate()
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = SignInNonce.hashed(rawNonce)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } onCompletion: { result in
                        handleAuthorization(result)
                    }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 48)
                    Text("Apple provides an opaque account identifier. Fuel stores it in Keychain and keeps only a one-way hash in the local database. Identity and authorization tokens are never logged.")
                        .font(.caption)
                        .foregroundStyle(FuelTheme.secondary)
                }
            }
        }
        .navigationTitle("Account and sync")
        .confirmationDialog("Delete your cloud account?", isPresented: $confirmsRemoteDeletion, titleVisibility: .visible) {
            Button("Delete cloud account", role: .destructive) { Task { await deleteRemoteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The configured service will delete the remote account. Data stored only on this iPhone is kept until you delete it separately.")
        }
        .alert("Account operation failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var syncStatus: String {
        switch state.syncState {
        case .localOnly: "Local only"
        case .idle: "Ready"
        case .syncing(let count): "Syncing \(count)"
        case .current: "Up to date"
        case .waiting(let count): "Waiting to retry \(count)"
        case .conflict(let count): "Resolving \(count) conflict\(count == 1 ? "" : "s")"
        case .failed: "Retry needed"
        }
    }

    private func handleAuthorization(_ result: Result<ASAuthorization, Error>) {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken,
                  let authorizationCode = credential.authorizationCode,
                  !rawNonce.isEmpty else { throw BackendError.invalidResponse }
            let payload = AppleSignInPayload(
                userIdentifier: credential.user,
                fullName: credential.fullName,
                email: credential.email,
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: rawNonce
            )
            isWorking = true
            Task {
                defer { isWorking = false; rawNonce = "" }
                do { try await state.completeAppleSignIn(payload) }
                catch { errorMessage = error.localizedDescription }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestExport() async {
        isWorking = true
        defer { isWorking = false }
        do { exportURL = try await state.requestRemoteAccountExport() }
        catch { errorMessage = error.localizedDescription }
    }

    private func signOut() async {
        isWorking = true
        defer { isWorking = false }
        do { try await state.signOutAccount() }
        catch { errorMessage = error.localizedDescription }
    }

    private func deleteRemoteAccount() async {
        isWorking = true
        defer { isWorking = false }
        do { try await state.deleteRemoteAccount() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let state: AppState

    @State private var draft: UserProfile
    @State private var allergies: String
    @State private var avoidedFoods: String
    @State private var errorMessage: String?

    init(state: AppState) {
        self.state = state
        _draft = State(initialValue: state.profile)
        _allergies = State(initialValue: state.profile.allergies.joined(separator: ", "))
        _avoidedFoods = State(initialValue: state.profile.foodsToAvoid.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("First name", text: $draft.firstName)
                TextField("Age range", text: $draft.ageRange)
                Stepper("Height: \(heightText)", value: $draft.heightCM, in: 120...230)
                Stepper("Weight: \(weightText)", value: $draft.weightKG, in: 35...250, step: state.preferences.unitSystem == .imperial ? 0.45 : 0.5)
            }
            Section("Goals and activity") {
                Picker("Primary goal", selection: $draft.goal) { ForEach(UserGoal.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Activity", selection: $draft.activityLevel) {
                    ForEach(["Sedentary", "Lightly active", "Moderately active", "Very active"], id: \.self) { Text($0).tag($0) }
                }
                if draft.goal == .gradualLoss {
                    Text(SafetyCopy.professionalEscalation)
                        .font(.caption)
                        .foregroundStyle(FuelTheme.secondary)
                }
            }
            Section("Food preferences") {
                Picker("Diet", selection: $draft.dietaryPreference) { ForEach(DietaryPreference.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Allergies, comma separated", text: $allergies, axis: .vertical)
                TextField("Foods to avoid, comma separated", text: $avoidedFoods, axis: .vertical)
            }
        }
        .navigationTitle("Personal details")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(draft.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        .alert("Couldn’t save profile", isPresented: errorBinding) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var errorBinding: Binding<Bool> { Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }) }

    private var heightText: String {
        guard state.preferences.unitSystem == .imperial else { return "\(Int(draft.heightCM)) cm" }
        let inches = draft.heightCM / 2.54
        return "\(Int(inches / 12)) ft \(Int(inches) % 12) in"
    }

    private var weightText: String {
        state.preferences.unitSystem == .imperial
            ? "\((draft.weightKG * 2.20462).formatted(.number.precision(.fractionLength(1)))) lb"
            : "\(draft.weightKG.formatted(.number.precision(.fractionLength(1)))) kg"
    }

    private func save() {
        draft.allergies = parse(allergies)
        draft.foodsToAvoid = parse(avoidedFoods)
        Task {
            do { try await state.updateProfile(draft); dismiss() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func parse(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

struct TargetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let state: AppState
    @State private var targets: DailyTargets
    @State private var errorMessage: String?
    @State private var recalculationNote: String?

    init(state: AppState) {
        self.state = state
        _targets = State(initialValue: state.targets)
    }

    var body: some View {
        Form {
            Section("Nutrition") {
                Stepper("Calories: \(targets.calories)", value: $targets.calories, in: 1_400...4_500, step: 50)
                Stepper("Protein: \(Int(targets.proteinGrams)) g", value: $targets.proteinGrams, in: 45...250, step: 5)
                Stepper("Carbohydrates: \(Int(targets.carbohydrateGrams)) g", value: $targets.carbohydrateGrams, in: 100...600, step: 5)
                Stepper("Fat: \(Int(targets.fatGrams)) g", value: $targets.fatGrams, in: 40...200, step: 5)
                Stepper("Fiber: \(Int(targets.fiberGrams)) g", value: $targets.fiberGrams, in: 20...60)
                Stepper("Water: \(Int(targets.hydrationMilliliters)) ml", value: $targets.hydrationMilliliters, in: 1_000...4_000, step: 250)
                if state.profile.goal == .gradualLoss {
                    Text(SafetyCopy.professionalEscalation)
                        .font(.caption)
                        .foregroundStyle(FuelTheme.secondary)
                }
            }
            Section("Activity and recovery") {
                Stepper("Steps: \(targets.steps)", value: $targets.steps, in: 1_000...30_000, step: 500)
                Stepper("Sleep: \(targets.sleepMinutes / 60)h \(targets.sleepMinutes % 60)m", value: $targets.sleepMinutes, in: 240...720, step: 15)
            }
            Section {
                Button("Recalculate conservative starter targets") {
                    // Passing the stored target lets the calculator clamp a large single drop
                    // and explain the clamp instead of silently applying it.
                    let result = state.goalCalculationService.calculate(profile: state.profile, previousTargets: state.targets)
                    targets = result.targets
                    recalculationNote = result.adjustmentNote
                }
                if let recalculationNote {
                    Text(recalculationNote)
                        .font(.caption)
                        .foregroundStyle(FuelTheme.secondary)
                }
                Text("Changes are added to local goal history. \(SafetyCopy.generalWellnessPositioning)")
                    .font(.caption)
                    .foregroundStyle(FuelTheme.secondary)
            }
        }
        .navigationTitle("Daily targets")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) } }
        .alert("Couldn’t save targets", isPresented: errorBinding) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var errorBinding: Binding<Bool> { Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }) }
    private func save() {
        Task {
            do { try await state.updateTargets(targets); dismiss() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct AppPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    let state: AppState
    @State private var preferences: UserPreferences
    @State private var errorMessage: String?

    init(state: AppState) {
        self.state = state
        _preferences = State(initialValue: state.preferences)
    }

    var body: some View {
        Form {
            Picker("Unit system", selection: $preferences.unitSystem) {
                Text("Metric").tag(UnitSystem.metric)
                Text("US / Imperial").tag(UnitSystem.imperial)
            }
        }
        .navigationTitle("Units")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) } }
        .alert("Couldn’t save preferences", isPresented: errorBinding) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var errorBinding: Binding<Bool> { Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }) }
    private func save() {
        do { try state.updatePreferences(preferences); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct NotificationPreferencesView: View {
    let state: AppState
    @State private var preferences: UserPreferences
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(state: AppState) {
        self.state = state
        _preferences = State(initialValue: state.preferences)
    }

    var body: some View {
        Form {
            Section("Reminders") {
                Toggle("Meal logging", isOn: $preferences.mealRemindersEnabled)
                Toggle("Hydration", isOn: $preferences.hydrationRemindersEnabled)
                Toggle("Daily review", isOn: $preferences.dailyReviewEnabled)
                Toggle("Weekly summary", isOn: $preferences.weeklySummaryEnabled)
                Toggle("Apple Health connection issues", isOn: $preferences.healthConnectionAlertsEnabled)
                Toggle("Goal progress", isOn: $preferences.goalProgressRemindersEnabled)
            }
            Section("Schedule") {
                ForEach(Array(mealLabels.enumerated()), id: \.offset) { index, label in
                    Stepper(
                        "\(label): \(mealReminderHour(at: index)):00",
                        value: mealReminderHourBinding(at: index),
                        in: 0...23
                    )
                    .accessibilityLabel("\(label) reminder time")
                }
                Stepper("Hydration: every \(preferences.hydrationReminderIntervalHours) hours", value: $preferences.hydrationReminderIntervalHours, in: 1...8)
                Stepper("Daily review: \(preferences.dailyReviewHour):00", value: $preferences.dailyReviewHour, in: 0...23)
                Picker("Weekly summary day", selection: $preferences.weeklySummaryWeekday) {
                    ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index + 1)
                    }
                }
                Stepper("Weekly summary time: \(preferences.weeklySummaryHour):00", value: $preferences.weeklySummaryHour, in: 0...23)
                    .accessibilityLabel("Weekly summary reminder time")
            }
            Section("Quiet hours") {
                Stepper("Start: \(preferences.quietHoursStart):00", value: $preferences.quietHoursStart, in: 0...23)
                Stepper("End: \(preferences.quietHoursEnd):00", value: $preferences.quietHoursEnd, in: 0...23)
            }
            Section {
                LabeledContent("iOS permission", value: authorizationLabel)
                if state.notificationAuthorizationState == .denied {
                    Button("Open iOS notification settings") {
                        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
                Text("Fuel asks for permission when you first enable a reminder. Schedules follow your current time zone, avoid quiet hours, and use supportive copy only.")
                    .font(.caption).foregroundStyle(FuelTheme.secondary)
            }
        }
        .navigationTitle("Notifications")
        .onChange(of: preferences) { _, value in
            isSaving = true
            Task {
                defer { isSaving = false }
                do { try await state.updateNotificationPreferences(value) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("Couldn’t save notification settings", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private let mealLabels = ["Breakfast", "Lunch", "Dinner"]

    private func mealReminderHour(at index: Int) -> Int {
        guard preferences.mealReminderHours.indices.contains(index) else { return 8 }
        return preferences.mealReminderHours[index]
    }

    private func mealReminderHourBinding(at index: Int) -> Binding<Int> {
        Binding(
            get: { mealReminderHour(at: index) },
            set: { newValue in
                var hours = preferences.mealReminderHours
                while hours.count <= index { hours.append(0) }
                hours[index] = newValue
                preferences.mealReminderHours = hours
            }
        )
    }

    private var authorizationLabel: String {
        switch state.notificationAuthorizationState {
        case .notDetermined: "Not requested"
        case .denied: "Off"
        case .authorized: "Allowed"
        case .provisional: "Quiet delivery"
        }
    }
}

struct HealthPermissionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let state: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "heart.text.square.fill").font(.system(size: 64)).foregroundStyle(FuelTheme.green)
                Text("Connect Apple Health").font(.title.bold())
                Text("Fuel requests read-only access to activity, energy, workouts, sleep, body measurements, and heart-rate summaries. You can allow only the categories you want, and the app remains usable without them.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(FuelTheme.secondary)
                Text("Current state: \(state.permissionState.rawValue)").font(.caption)
                Button("Continue") { Task { _ = await state.requestHealthAuthorization() } }.buttonStyle(.borderedProminent)
                Button("Refresh data") { Task { await state.refresh() } }.buttonStyle(.bordered)
                if state.permissionState == .denied || state.permissionState == .noRecentData {
                    Button("Open Fuel Settings") {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done") { dismiss() }.foregroundStyle(FuelTheme.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Health Access")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct DataSourcesView: View {
    let state: AppState
    var body: some View {
        List {
            Section("Health") {
                LabeledContent("Apple Health", value: state.permissionState.rawValue)
                ForEach(state.snapshot.activity.sourceNames, id: \.self) { Label($0, systemImage: "applewatch") }
            }
            Section("Nutrition") {
                Label("Fuel common foods · offline", systemImage: "internaldrive")
                Label("Open Food Facts · branded search", systemImage: "network")
                Label("On-device Vision · photo candidates", systemImage: "eye")
                Link(destination: URL(string: "https://world.openfoodfacts.org")!) {
                    Text("Food data from Open Food Facts, licensed under ODbL")
                }
                .font(.caption)
            }
            Section { Text("Every saved food item retains its source and any user correction metadata.").font(.caption).foregroundStyle(FuelTheme.secondary) }
        }
        .navigationTitle("Data sources")
    }
}

private struct PrivacyDataView: View {
    let state: AppState
    @State private var exportURL: URL?
    @State private var preparesExport = false
    @State private var confirmsDeletion = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Export") {
                Button(preparesExport ? "Preparing…" : "Prepare JSON export", action: prepareExport).disabled(preparesExport)
                if let exportURL { ShareLink(item: exportURL) { Label("Share Fuel export", systemImage: "square.and.arrow.up") } }
                Text("Exports include profile settings, targets, meals, food items, provenance, and hydration logs. Meal photos are not included.")
                    .font(.caption).foregroundStyle(FuelTheme.secondary)
            }
            Section("Meal photos") {
                Toggle("Allow keeping meal photos for recognition improvement", isOn: retentionConsentBinding)
                Text("Meal photos are saved on this iPhone only. If a reviewed cloud backend is configured for this build and this setting is on, a photo you send for recognition may be kept by that service to improve recognition quality. With this off, photos are never retained beyond the recognition attempt. Either way, photos no meal or pending scan still uses are deleted automatically.")
                    .font(.caption).foregroundStyle(FuelTheme.secondary)
            }
            Section("Delete") {
                Button("Delete all local data", role: .destructive) { confirmsDeletion = true }
                Text("This permanently deletes local meals, photos, water logs, profile, goals, preferences, caches, favorites, and feedback.")
                    .font(.caption).foregroundStyle(FuelTheme.secondary)
            }
        }
        .navigationTitle("Your data")
        .confirmationDialog("Delete all Fuel data?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { Task { await deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This action cannot be undone. Export first if you want a copy.") }
        .alert("Data operation failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var retentionConsentBinding: Binding<Bool> {
        Binding(
            get: { state.preferences.mealPhotoRetentionConsent },
            set: { newValue in
                var preferences = state.preferences
                preferences.mealPhotoRetentionConsent = newValue
                do { try state.updatePreferences(preferences) }
                catch { errorMessage = error.localizedDescription }
            }
        )
    }

    private func prepareExport() {
        preparesExport = true
        Task {
            defer { preparesExport = false }
            do { exportURL = try await state.exportData() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteAll() async {
        do { try await state.deleteAllLocalData() }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct PrivacyInformationView: View {
    var body: some View {
        List {
            Section("On device") { Text("Profiles, targets, meals, hydration, recommendations, and cached summaries are stored locally with SwiftData. Meal photos use protected application-support files.") }
            Section("Network") { Text("Branded food searches may contact Open Food Facts. On-device meal classification does not upload photos. Fuel does not include advertising analytics or embedded provider secrets.") }
            Section("Apple Health") { Text("Apple Health data is read directly on device after permission. Fuel does not write HealthKit samples or upload them to a server in this build.") }
        }
        .navigationTitle("Privacy")
    }
}

private struct SafetyInformationView: View {
    var body: some View {
        List {
            Text("Food-photo portions and nutrient values may be inaccurate.")
            Text("Fuel does not diagnose nutrient deficiencies or medical conditions.")
            Text("Wearable calorie and recovery values are estimates, not exact measurements.")
            Text("Recommendations are general wellness guidance and apply allergy and dietary filters only to known labels.")
            Text("People with medical conditions, eating disorders, allergies, pregnancy, or specialized dietary needs should consult a qualified professional.")
        }
        .navigationTitle("Safety")
    }
}

private struct SupportView: View {
    var body: some View {
        List {
            Section("Troubleshooting") {
                Text("If Apple Health values are missing, review Fuel’s permissions in Settings, then return and tap Refresh data.")
                Text("If food recognition is uncertain, use Review foods and portions or log the meal manually.")
                Text("Export your JSON data before deleting the app or clearing local data.")
            }
            Section("App information") {
                Text("Fuel is an on-device wellness prototype. No remote support account is configured in this build.")
            }
        }
        .navigationTitle("Support")
    }
}
