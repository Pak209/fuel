import SwiftUI

struct OnboardingView: View {
    let state: AppState

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step = 0
    @State private var profile: UserProfile
    @State private var preferences: UserPreferences
    @State private var targets: DailyTargets
    @State private var targetExplanation = ""
    @State private var allergiesText: String
    @State private var avoidedFoodsText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let activityLevels = ["Sedentary", "Lightly active", "Moderately active", "Very active"]
    private let totalSteps = 7

    init(state: AppState) {
        self.state = state
        let arguments = ProcessInfo.processInfo.arguments
        let requestedStep = arguments.firstIndex(of: "-FuelOnboardingStep")
            .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
            ?? 0
        _step = State(initialValue: min(max(requestedStep, 0), 6))
        _profile = State(initialValue: state.profile)
        // Seed the unit-system control from the device locale only when there's no
        // persisted choice yet (the value still sits at `UserPreferences`' built-in
        // default) so an already-saved preference is never silently overwritten.
        var initialPreferences = state.preferences
        if initialPreferences.unitSystem == UserPreferences().unitSystem {
            initialPreferences.unitSystem = Locale.current.measurementSystem == .us ? .imperial : .metric
        }
        _preferences = State(initialValue: initialPreferences)
        _targets = State(initialValue: state.targets)
        _allergiesText = State(initialValue: state.profile.allergies.joined(separator: ", "))
        _avoidedFoodsText = State(initialValue: state.profile.foodsToAvoid.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: Double(totalSteps))
                    .tint(FuelTheme.green)
                    .padding(.horizontal)
                    .padding(.top, 8)
                onboardingStep.id(step)
                controls
            }
            .background(FuelTheme.background.ignoresSafeArea())
            .navigationTitle("Set up Fuel")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .alert("Couldn’t finish setup", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var controls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) { continueButton; backButton }
            } else {
                HStack(spacing: 12) { backButton; continueButton }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var backButton: some View {
        if step > 0 {
            Button("Back") { step -= 1 }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("onboardingBack")
        }
    }

    private var continueButton: some View {
        Button {
            if step == totalSteps - 1 { finish() }
            else { advance() }
        } label: {
            Text(step == totalSteps - 1 ? (isSaving ? "Saving…" : "Finish") : "Continue")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isSaving || (step == 1 && profile.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .accessibilityIdentifier("onboardingContinue")
    }

    @ViewBuilder
    private var onboardingStep: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: ProfileStep(profile: $profile, preferences: $preferences)
        case 2: GoalStep(profile: $profile, activityLevels: activityLevels)
        case 3: DietaryStep(profile: $profile, allergiesText: $allergiesText, avoidedFoodsText: $avoidedFoodsText)
        case 4: TargetStep(targets: $targets, explanation: targetExplanation)
        case 5: HealthStep(state: state)
        default: ReminderStep(preferences: $preferences)
        }
    }

    private func advance() {
        profile.allergies = parseList(allergiesText)
        profile.foodsToAvoid = parseList(avoidedFoodsText)
        if step == 3 {
            let result = state.goalCalculationService.calculate(profile: profile)
            targets = result.targets
            targetExplanation = result.explanation + " " + result.assumptions.joined(separator: " ")
        }
        step = min(totalSteps - 1, step + 1)
    }

    private func finish() {
        isSaving = true
        profile.allergies = parseList(allergiesText)
        profile.foodsToAvoid = parseList(avoidedFoodsText)
        preferences.onboardingCompleted = true
        Task {
            defer { isSaving = false }
            do {
                try await state.updateProfile(profile)
                try await state.updateTargets(targets, explanation: "Starter targets confirmed during onboarding")
                try await state.updateNotificationPreferences(preferences)
            } catch {
                let message = error.localizedDescription
                errorMessage = message
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    private func parseList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        OnboardingPage(icon: "heart.text.square.fill", title: "Nutrition and activity, in one daily view") {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingPoint(icon: "camera.viewfinder", text: "Log meals from a photo or enter them manually.")
                OnboardingPoint(icon: "heart.fill", text: "Optionally combine meals with Apple Health activity and recovery data.")
                OnboardingPoint(icon: "sparkles", text: "Get small, explainable next-step suggestions instead of medical claims.")
                Text("Food and wearable values are estimates. Fuel provides general wellness guidance and does not diagnose deficiencies or replace qualified care.")
                    .font(.footnote)
                    .foregroundStyle(FuelTheme.secondary)
                    .padding(.top, 8)
            }
        }
    }
}

private struct ProfileStep: View {
    @Binding var profile: UserProfile
    @Binding var preferences: UserPreferences

    var body: some View {
        OnboardingPage(icon: "person.crop.circle", title: "About you") {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Unit system", selection: $preferences.unitSystem) {
                        Text("Metric").tag(UnitSystem.metric)
                        Text("US / Imperial").tag(UnitSystem.imperial)
                    }
                    .pickerStyle(.segmented)
                    Text("Fuel stores measurements in metric base units and converts them for display, so switching later does not change your underlying data.")
                        .font(.footnote)
                        .foregroundStyle(FuelTheme.secondary)
                }
                TextField("First name", text: $profile.firstName)
                    .textFieldStyle(.roundedBorder)
                TextField("Age range (optional)", text: $profile.ageRange)
                    .textFieldStyle(.roundedBorder)
                Stepper(value: $profile.heightCM, in: 120...230, step: 1) {
                    LabeledContent("Height", value: heightText)
                }
                Stepper(value: $profile.weightKG, in: 35...250, step: 0.5) {
                    LabeledContent("Weight", value: weightText)
                }
                Text("These values stay on this device and are used only to suggest editable starter targets.")
                    .font(.footnote)
                    .foregroundStyle(FuelTheme.secondary)
            }
        }
    }

    private var heightText: String {
        guard preferences.unitSystem == .imperial else { return "\(Int(profile.heightCM)) cm" }
        let inches = profile.heightCM / 2.54
        return "\(Int(inches / 12)) ft \(Int(inches) % 12) in"
    }

    private var weightText: String {
        preferences.unitSystem == .imperial
            ? "\((profile.weightKG * 2.20462).formatted(.number.precision(.fractionLength(1)))) lb"
            : "\(profile.weightKG.formatted(.number.precision(.fractionLength(1)))) kg"
    }
}

private struct GoalStep: View {
    @Binding var profile: UserProfile
    let activityLevels: [String]

    var body: some View {
        OnboardingPage(icon: "target", title: "Choose your direction") {
            VStack(spacing: 16) {
                LabeledContent("Primary goal") {
                    Picker("Primary goal", selection: $profile.goal) {
                        ForEach(UserGoal.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .cardStyle(padding: 12)
                LabeledContent("Usual activity") {
                    Picker("Usual activity", selection: $profile.activityLevel) {
                        ForEach(activityLevels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .cardStyle(padding: 12)
                Text("Fuel uses conservative defaults. Gradual weight goals never create an aggressive deficit, and every target can be changed before saving.")
                    .font(.footnote)
                    .foregroundStyle(FuelTheme.secondary)
                // Persistent, not conditional: the limitation applies to every goal, and a
                // note that only appears after a "risky" choice reads as a judgement.
                VStack(alignment: .leading, spacing: 8) {
                    Text(SafetyCopy.generalWellnessPositioning)
                    Text(SafetyCopy.professionalEscalation)
                }
                .font(.footnote)
                .foregroundStyle(FuelTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DietaryStep: View {
    @Binding var profile: UserProfile
    @Binding var allergiesText: String
    @Binding var avoidedFoodsText: String

    var body: some View {
        OnboardingPage(icon: "leaf", title: "Food preferences and safety") {
            VStack(spacing: 16) {
                Picker("Dietary preference", selection: $profile.dietaryPreference) {
                    ForEach(DietaryPreference.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                TextField("Allergies, separated by commas", text: $allergiesText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                TextField("Foods to avoid, separated by commas", text: $avoidedFoodsText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Text("Fuel excludes matching foods from suggestions, but it cannot verify that a photographed or database food is allergen-free. Always check ingredients yourself.")
                    .font(.footnote)
                    .foregroundStyle(FuelTheme.secondary)
            }
        }
    }
}

private struct TargetStep: View {
    @Binding var targets: DailyTargets
    let explanation: String

    var body: some View {
        OnboardingPage(icon: "slider.horizontal.3", title: "Confirm starter targets") {
            VStack(spacing: 12) {
                Stepper("Calories: \(targets.calories)", value: $targets.calories, in: 1_400...4_500, step: 50)
                Stepper("Protein: \(Int(targets.proteinGrams)) g", value: $targets.proteinGrams, in: 45...250, step: 5)
                Stepper("Carbohydrates: \(Int(targets.carbohydrateGrams)) g", value: $targets.carbohydrateGrams, in: 100...600, step: 5)
                Stepper("Fat: \(Int(targets.fatGrams)) g", value: $targets.fatGrams, in: 40...200, step: 5)
                Stepper("Fiber: \(Int(targets.fiberGrams)) g", value: $targets.fiberGrams, in: 20...60, step: 1)
                Stepper("Water: \(Int(targets.hydrationMilliliters)) ml", value: $targets.hydrationMilliliters, in: 1_000...4_000, step: 250)
                Text(explanation).font(.footnote).foregroundStyle(FuelTheme.secondary)
            }
        }
    }
}

private struct HealthStep: View {
    let state: AppState

    var body: some View {
        OnboardingPage(icon: "heart.fill", title: "Apple Health is optional") {
            VStack(spacing: 16) {
                Text("Fuel can read steps, energy, exercise, workouts, sleep, body measurements, and heart-rate summaries. It requests read-only access and remains useful if you decline any category.")
                    .foregroundStyle(FuelTheme.secondary)
                Button("Connect Apple Health") { Task { _ = await state.requestHealthAuthorization() } }
                    .buttonStyle(.borderedProminent)
                Text(connectionText).font(.footnote).foregroundStyle(FuelTheme.secondary)
            }
        }
    }

    private var connectionText: String {
        switch state.permissionState {
        case .authorized: "Authorization completed. Individual data types may still have no samples."
        case .denied: "Access was not granted. You can continue and reconnect later."
        case .unavailable: "Apple Health is unavailable on this device or simulator."
        case .noRecentData: "Connected, but no recent supported samples were found."
        case .requesting: "Waiting for Apple Health…"
        case .notDetermined: "Not connected yet. You can skip this step."
        }
    }
}

private struct ReminderStep: View {
    @Binding var preferences: UserPreferences

    var body: some View {
        OnboardingPage(icon: "bell", title: "Choose gentle reminders") {
            VStack(spacing: 14) {
                Toggle("Meal logging reminder", isOn: $preferences.mealRemindersEnabled)
                Toggle("Hydration reminder", isOn: $preferences.hydrationRemindersEnabled)
                Toggle("Daily review", isOn: $preferences.dailyReviewEnabled)
                Toggle("Weekly summary", isOn: $preferences.weeklySummaryEnabled)
                Text("Fuel asks for notification permission only after you finish with a reminder enabled. Reminders respect quiet hours and never use shame-based copy.")
                    .font(.footnote)
                    .foregroundStyle(FuelTheme.secondary)
            }
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 46))
                    .foregroundStyle(FuelTheme.green)
                    .accessibilityHidden(true)
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                content
                    .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(24)
        }
    }
}

private struct OnboardingPoint: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(FuelTheme.green).frame(width: 28)
            Text(text)
        }
    }
}
