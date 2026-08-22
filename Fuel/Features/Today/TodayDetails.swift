import SwiftUI

struct HealthScoreDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let score: HealthScore

    var body: some View {
        List {
            Section {
                HStack(spacing: 18) {
                    HealthScoreRing(score: score.overall).frame(width: 92, height: 92)
                    VStack(alignment: .leading) {
                        Text("\(score.overall) / 100").font(.title.bold()).foregroundStyle(FuelTheme.green)
                        Text(score.message).foregroundStyle(FuelTheme.secondary)
                    }
                }
            }
            Section("Why this score") {
                ForEach(HealthScoreCategory.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(category.rawValue).font(.headline)
                            Spacer()
                            Text(score.unavailableCategories.contains(category) ? "Excluded" : "\(score.categories[category] ?? 0)")
                                .foregroundStyle(score.unavailableCategories.contains(category) ? FuelTheme.secondary : FuelTheme.green)
                        }
                        Text(score.categoryExplanations[category] ?? "No explanation available.")
                            .font(.subheadline)
                            .foregroundStyle(FuelTheme.secondary)
                    }
                }
            }
            Section("Evidence") {
                LabeledContent("Algorithm", value: "Version \(score.algorithmVersion)")
                LabeledContent("Available evidence", value: score.evidenceCompleteness.formatted(.percent.precision(.fractionLength(0))))
                Text("Unavailable sources are removed from the weighting instead of being counted as zero. Scores are wellness summaries, not medical ratings.")
                    .font(.caption)
                    .foregroundStyle(FuelTheme.secondary)
            }
        }
        .navigationTitle("Health score")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct RecommendationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let state: AppState
    let recommendation: NutritionRecommendation
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Label(recommendation.title, systemImage: "sparkles")
                    .font(.title3.bold())
                    .foregroundStyle(FuelTheme.green)
                Text(recommendation.reason)
            }
            if !recommendation.alternatives.isEmpty {
                Section("Alternatives") {
                    ForEach(recommendation.alternatives, id: \.self) { Label($0.capitalized, systemImage: "arrow.triangle.branch") }
                }
            }
            Section("Why you’re seeing this") {
                ForEach(recommendation.dataUsed, id: \.self) { Text($0) }
                LabeledContent("Confidence", value: recommendation.confidence.formatted(.percent.precision(.fractionLength(0))))
                Text(recommendation.limitation).font(.caption).foregroundStyle(FuelTheme.secondary)
            }
            Section("Was this useful?") {
                Button { record(.helpful) } label: { Label("Helpful", systemImage: "hand.thumbsup") }
                Button { record(.notRelevant) } label: { Label("Not relevant", systemImage: "hand.thumbsdown") }
                Button { record(.dismissed) } label: { Label("Don’t show this again this week", systemImage: "xmark.circle") }
            }
        }
        .navigationTitle("Recommendation")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .alert("Couldn’t save feedback", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func record(_ kind: RecommendationFeedbackKind) {
        do {
            try state.recordRecommendationFeedback(kind)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct WorkoutDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let workout: WorkoutSummary
    let activity: DailyActivitySummary

    var body: some View {
        List {
            Section {
                LabeledContent("Workout", value: workout.name)
                LabeledContent("Started", value: workout.startDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Duration", value: "\(workout.minutes) min")
                LabeledContent("Active energy", value: "\(workout.calories) cal estimated")
            }
            Section("Day context") {
                LabeledContent("Steps", value: activity.availability == .unavailable ? "Unavailable" : activity.steps.formatted())
                if let exercise = activity.exerciseMinutes { LabeledContent("Exercise", value: "\(exercise) min") }
                Text("Workout and energy values come from Apple Health and may vary by device and source.")
                    .font(.caption)
                    .foregroundStyle(FuelTheme.secondary)
            }
        }
        .navigationTitle(workout.name)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct SleepDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let sleep: SleepSummary

    var body: some View {
        List {
            Section {
                LabeledContent("Duration", value: duration)
                LabeledContent("Target", value: "\(sleep.targetMinutes / 60)h \(sleep.targetMinutes % 60)m")
                LabeledContent("Summary", value: sleep.quality)
                if let updated = sleep.lastUpdated { LabeledContent("Last sample", value: updated.formatted(date: .abbreviated, time: .shortened)) }
            }
            Section {
                Text("Fuel merges overlapping asleep-stage intervals to reduce double counting. Sleep values remain estimates from the connected source.")
                    .font(.caption)
                    .foregroundStyle(FuelTheme.secondary)
            }
        }
        .navigationTitle("Sleep")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var duration: String {
        sleep.availability == .available ? "\(sleep.durationMinutes / 60)h \(sleep.durationMinutes % 60)m" : "Unavailable"
    }
}

struct HydrationLogView: View {
    @Environment(\.dismiss) private var dismiss
    let state: AppState

    @State private var entries: [HydrationEntry] = []
    @State private var amount = 250.0
    @State private var editingEntry: HydrationEntry?
    @State private var pendingDelete: HydrationEntry?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Add water") {
                Stepper("\(Int(amount)) ml", value: $amount, in: 100...1_500, step: 50)
                Button("Add water") { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("hydrationAddButton")
            }
            Section("Entries") {
                if entries.isEmpty { Text("No water logged for this day.").foregroundStyle(FuelTheme.secondary) }
                ForEach(entries) { entry in
                    Button { editingEntry = entry } label: {
                        HStack {
                            Label("\(Int(entry.amountMilliliters)) ml", systemImage: "drop")
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(FuelTheme.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(FuelTheme.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = entry } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Water")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { load() }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                HydrationEntryEditor(entry: entry) { updatedAmount, updatedDate in
                    try await state.updateHydration(entry, amountMilliliters: updatedAmount, date: updatedDate)
                    load()
                }
            }
        }
        .confirmationDialog("Delete this water entry?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete water entry", role: .destructive) { Task { await deletePendingEntry() } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the entry from today’s hydration total.")
        }
        .alert("Couldn’t update water", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func load() {
        do { entries = try state.hydrationEntriesForSelectedDay() }
        catch { fail(error) }
    }

    private func add() async {
        do {
            let date = Calendar.autoupdatingCurrent.isDateInToday(state.selectedDate) ? Date.now : state.selectedDate.addingTimeInterval(12 * 60 * 60)
            try await state.addWater(milliliters: amount, at: date)
            load()
            AccessibilityNotification.Announcement("Added \(Int(amount)) milliliters of water").post()
        } catch { fail(error) }
    }

    private func deletePendingEntry() async {
        guard let entry = pendingDelete else { return }
        pendingDelete = nil
        do {
            try await state.deleteHydration(entry)
            load()
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }
}

private struct HydrationEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Double, Date) async throws -> Void
    @State private var amount: Double
    @State private var date: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(entry: HydrationEntry, onSave: @escaping (Double, Date) async throws -> Void) {
        self.onSave = onSave
        _amount = State(initialValue: entry.amountMilliliters)
        _date = State(initialValue: entry.date)
    }

    var body: some View {
        Form {
            Stepper("\(Int(amount)) ml", value: $amount, in: 50...2_000, step: 50)
            DatePicker("Time", selection: $date)
        }
        .navigationTitle("Edit water")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do { try await onSave(amount, date); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .disabled(isSaving)
            }
        }
        .alert("Couldn’t update water", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }
}

struct DayPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let state: AppState
    @State private var date: Date

    init(state: AppState) {
        self.state = state
        _date = State(initialValue: state.selectedDate)
    }

    var body: some View {
        DatePicker("Dashboard date", selection: $date, in: ...Date.now, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Choose a day")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        state.selectedDate = date
                        Task { await state.refresh() }
                        dismiss()
                    }
                }
            }
    }
}
