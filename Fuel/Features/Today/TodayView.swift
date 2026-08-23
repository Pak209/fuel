import SwiftUI

struct TodayView: View {
    let state: AppState

    @State private var sheet: TodaySheet?
    @State private var errorMessage: String?

    private var greeting: String { Calendar.current.component(.hour, from: .now) < 12 ? "Good morning" : Calendar.current.component(.hour, from: .now) < 18 ? "Good afternoon" : "Good evening" }

    var body: some View {
        ZStack {
            FuelTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 10) {
                    DashboardHeader(
                        greeting: greeting,
                        firstName: state.profile.firstName,
                        selectedDate: state.selectedDate,
                        previousDay: { changeDay(-1) },
                        nextDay: { changeDay(1) },
                        chooseDate: { sheet = .datePicker },
                        notifications: { sheet = .notifications },
                        profile: { state.selectedTab = .profile }
                    )
                    Button { sheet = .score } label: { CompactHealthScoreCard(score: state.healthScore) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("todayHealthScoreButton")
                    DailyMetricsRow(snapshot: state.snapshot, balance: state.calorieBalance)
                    RecommendationCard(recommendation: state.recommendation) { sheet = .recommendation }
                        .accessibilityIdentifier("todayRecommendationButton")
                    TodayTimeline(
                        snapshot: state.snapshot,
                        onMeal: openMeal,
                        onWorkout: { sheet = .workout($0) },
                        onAddWater: { sheet = .hydration },
                        onSleep: { sheet = .sleep },
                        onAddEvent: { sheet = .newMeal },
                        onCompleteMeal: completeMeal
                    )
                    HStack {
                        Text(state.snapshot.isFromCache ? "Cached summary" : "Updated \(state.snapshot.lastUpdated.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        if !state.snapshot.activity.sourceNames.isEmpty {
                            Text(state.snapshot.activity.sourceNames.joined(separator: ", ")).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(FuelTheme.secondary)
                    Text("Nutrition estimates may be incomplete. Fuel provides general wellness guidance and does not diagnose nutrient deficiencies.")
                        .font(.caption).foregroundStyle(FuelTheme.secondary).padding(.horizontal, 6).padding(.bottom, 12)
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: FuelLayout.tabBarClearance)
            }
            .refreshable { await state.refresh() }
            .redacted(reason: state.dataPhase == .loading ? .placeholder : [])
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarHidden(true)
        .overlay(alignment: .top) {
            if case .failed(let message) = state.dataPhase {
                DataErrorBanner(message: message) { Task { await state.refresh() } }
                    .padding(.horizontal, 12)
            }
        }
        .sheet(item: $sheet) { route in
            destination(for: route)
        }
        .alert("Couldn’t update today", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    @ViewBuilder
    private func destination(for route: TodaySheet) -> some View {
        switch route {
        case .score:
            NavigationStack { HealthScoreDetailView(score: state.healthScore) }
        case .recommendation:
            NavigationStack { RecommendationDetailView(state: state, recommendation: state.recommendation) }
        case .meal(let meal):
            NavigationStack { MealEditorView(state: state, meal: meal) }
        case .workout(let workout):
            NavigationStack { WorkoutDetailView(workout: workout, activity: state.snapshot.activity) }
        case .hydration:
            NavigationStack { HydrationLogView(state: state) }
        case .sleep:
            NavigationStack { SleepDetailView(sleep: state.snapshot.sleep) }
        case .newMeal:
            NavigationStack { MealEditorView(state: state, draft: .init(name: "", type: .lunch, date: state.selectedDate, nutrition: .zero, items: [], provenance: .userEntered, confidence: nil, imageData: nil)) }
        case .datePicker:
            NavigationStack { DayPickerView(state: state) }
                .presentationDetents([.medium])
        case .notifications:
            NavigationStack { NotificationPreferencesView(state: state) }
        }
    }

    private func changeDay(_ value: Int) {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: state.profile.timeZoneIdentifier) ?? .autoupdatingCurrent
        guard let date = calendar.date(byAdding: .day, value: value, to: state.selectedDate),
              date <= Date.now else { return }
        state.selectedDate = date
        Task { await state.refresh() }
    }

    private func openMeal(_ summary: MealSummary) {
        do {
            if let meal = try state.meal(id: summary.id) { sheet = .meal(meal) }
        } catch { fail(error) }
    }

    private func completeMeal(_ summary: MealSummary) {
        Task {
            do {
                guard let meal = try state.meal(id: summary.id) else { return }
                try await state.completePlannedMeal(meal)
            } catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }
}

private enum TodaySheet: Identifiable {
    case score, recommendation, meal(Meal), workout(WorkoutSummary), hydration, sleep, newMeal, datePicker, notifications
    var id: String {
        switch self {
        case .score: "score"
        case .recommendation: "recommendation"
        case .meal(let meal): "meal-\(meal.id)"
        case .workout(let workout): "workout-\(workout.id)"
        case .hydration: "hydration"
        case .sleep: "sleep"
        case .newMeal: "new-meal"
        case .datePicker: "date-picker"
        case .notifications: "notifications"
        }
    }
}

private struct DashboardHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let greeting: String
    let firstName: String
    let selectedDate: Date
    let previousDay: () -> Void
    let nextDay: () -> Void
    let chooseDate: () -> Void
    let notifications: () -> Void
    let profile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack { Spacer(); headerActions }
                Text("\(greeting), \(firstName) 👋")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text("Here’s your dashboard")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            } else {
                HStack {
                    Text("\(greeting), \(firstName) 👋")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer()
                    headerActions
                }
                Text("Here’s your dashboard")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            HStack(spacing: 8) {
                Button(action: previousDay) { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Previous day")
                    .accessibilityIdentifier("todayPreviousDayButton")
                Button(action: chooseDate) {
                    Text(dateLabel)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("todayDatePickerButton")
                Button(action: nextDay) { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .disabled(Calendar.autoupdatingCurrent.isDateInToday(selectedDate))
                    .accessibilityLabel("Next day")
                    .accessibilityIdentifier("todayNextDayButton")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button(action: notifications) {
                Image(systemName: "bell")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(FuelTheme.panel, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Notifications")
            .accessibilityIdentifier("todayNotificationsButton")
            Button(action: profile) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 35))
                    .foregroundStyle(.orange)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(firstName)’s profile")
            .accessibilityIdentifier("todayProfileButton")
        }
    }

    private var dateLabel: String {
        if Calendar.autoupdatingCurrent.isDateInToday(selectedDate) { return "Today" }
        return selectedDate.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct CompactHealthScoreCard: View {
    let score: HealthScore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize { accessibilityContent }
            else { compactContent }
        }
        .cardStyle(padding: 10)
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            title.lineLimit(1)
            HStack(alignment: .center, spacing: 8) {
                scoreValue
                HealthScoreRing(score: score.overall).frame(width: 64, height: 64)
                nutrientList
            }
            message.lineLimit(2)
        }
    }

    private var accessibilityContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
            HStack(spacing: 12) {
                scoreValue
                HealthScoreRing(score: score.overall).frame(width: 72, height: 72)
            }
            nutrientList
            message
        }
    }

    private var title: some View {
        Label("Your Health Score", systemImage: "info.circle")
            .font(.system(.headline, design: .rounded, weight: .bold))
    }

    private var message: some View {
        Text(score.message)
            .font(.caption)
            .foregroundStyle(FuelTheme.secondary)
    }

    private var scoreValue: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text("\(score.overall)")
                .font(.system(size: 37, weight: .bold, design: .rounded))
                .foregroundStyle(FuelTheme.green)
            Text("/100")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(FuelTheme.secondary)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var nutrientList: some View {
        VStack(spacing: 2) {
            ForEach(HealthScoreCategory.allCases, id: \.self) {
                NutrientProgressRow(category: $0, score: score.unavailableCategories.contains($0) ? nil : score.categories[$0])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DailyMetricsRow: View {
    let snapshot: DailyHealthSnapshot
    let balance: CalorieBalance

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { metricCards }
            VStack(spacing: 8) { metricCards }
        }
    }

    @ViewBuilder private var metricCards: some View {
            MetricCard(
                title: "Calories",
                icon: "flame.fill",
                value: snapshot.nutrition.calories.formatted(),
                detail: calorieDetail,
                color: FuelTheme.green,
                progress: calorieProgress
            )
            MetricCard(
                title: "Activity",
                icon: "shoeprints.fill",
                value: activityValue,
                detail: activityDetail,
                color: FuelTheme.green,
                progress: activityProgress
            )
            MetricCard(
                title: "Active",
                icon: "bolt.fill",
                value: activeEnergyValue,
                detail: activeEnergyDetail,
                color: FuelTheme.green,
                progress: activityProgress
            )
    }

    private var calorieProgress: Double { Double(snapshot.nutrition.calories) / Double(max(1, snapshot.nutrition.targetCalories)) }
    private var calorieDetail: String {
        let remaining = balance.estimatedRemaining
        return remaining >= 0 ? "\(remaining.formatted()) left" : "\((-remaining).formatted()) over"
    }
    private var activityValue: String { snapshot.activity.availability == .available ? snapshot.activity.steps.formatted() : "—" }
    private var activityDetail: String { snapshot.activity.availability == .available ? "\(Int(activityProgress * 100))% of goal" : "No Health data" }
    private var activityProgress: Double { Double(snapshot.activity.steps) / Double(max(1, snapshot.activity.stepGoal)) }
    private var activeEnergyValue: String { snapshot.activity.availability == .available ? snapshot.activity.activeCalories.formatted() : "—" }
    private var activeEnergyDetail: String {
        guard snapshot.activity.availability == .available else { return "No Health data" }
        guard let yesterday = snapshot.activity.yesterdayActiveCalories else { return "Active calories" }
        let difference = snapshot.activity.activeCalories - yesterday
        return difference >= 0 ? "+\(difference) vs yesterday" : "\(difference) vs yesterday"
    }
}

private struct RecommendationCard: View {
    let recommendation: NutritionRecommendation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("AI Recommendation", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(FuelTheme.green)
                    Text(recommendation.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(recommendation.estimatedImprovement > 0 ? "+\(recommendation.estimatedImprovement) potential score points" : "Build your daily summary")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FuelTheme.green)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(FuelTheme.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityHint(recommendation.reason)
    }
}

private struct TodayTimeline: View {
    let snapshot: DailyHealthSnapshot
    let onMeal: (MealSummary) -> Void
    let onWorkout: (WorkoutSummary) -> Void
    let onAddWater: () -> Void
    let onSleep: () -> Void
    let onAddEvent: () -> Void
    let onCompleteMeal: (MealSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Today’s Timeline").font(.headline)
                Spacer()
                Button("Add event", action: onAddEvent)
                    .font(.caption.bold())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("todayAddMealButton")
            }
            .padding(.bottom, 4)
            if snapshot.meals.isEmpty {
                Text("No meals logged today")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FuelTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
            }
            ForEach(snapshot.meals) { meal in
                HStack(spacing: 4) {
                    Button { onMeal(meal) } label: {
                        TimelineRow(icon: mealIcon(for: meal.type), color: mealColor(for: meal.type), title: meal.type.rawValue, time: meal.date.formatted(date: .omitted, time: .shortened), item: meal.name, detail: "\(meal.nutrition.calories) cal • \(Int(meal.nutrition.protein))g protein", complete: meal.status == .planned ? nil : true)
                    }
                    .buttonStyle(.plain)
                    if meal.status == .planned {
                        Button { onCompleteMeal(meal) } label: { Image(systemName: "circle").foregroundStyle(FuelTheme.orange) }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Mark \(meal.name) completed")
                    }
                }
            }
            ForEach(snapshot.workouts) { workout in
                Button { onWorkout(workout) } label: {
                    TimelineRow(icon: "dumbbell", color: FuelTheme.green, title: "Workout", time: workout.startDate.formatted(date: .omitted, time: .shortened), item: workout.name, detail: "\(workout.minutes) min • \(workout.calories) cal", complete: true)
                }
                .buttonStyle(.plain)
            }
            Button(action: onAddWater) {
                TimelineRow(icon: "drop", color: FuelTheme.blue, title: "Water", time: "All day", item: "\(Int(snapshot.nutrition.hydrationMilliliters).formatted()) ml", detail: "Tap to add 250 ml", complete: nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("todayAddWaterButton")
            Button(action: onSleep) {
                TimelineRow(icon: "moon", color: FuelTheme.purple, title: "Sleep", time: "Last night", item: sleepValue, detail: snapshot.sleep.quality, complete: nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("todaySleepButton")
        }.cardStyle(padding: 12)
    }

    private var sleepValue: String {
        guard snapshot.sleep.availability == .available else { return "No sleep data" }
        return "\(snapshot.sleep.durationMinutes / 60)h \(snapshot.sleep.durationMinutes % 60)m"
    }
    private func mealIcon(for type: MealType) -> String { type == .breakfast ? "sun.max" : type == .snack ? "seal" : "fork.knife" }
    private func mealColor(for type: MealType) -> Color { type == .snack ? FuelTheme.orange : FuelTheme.green }
}

private struct DataErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            Button("Retry", action: retry).font(.caption.bold())
        }
        .padding(10)
        .background(FuelTheme.red.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TimelineRow: View {
    let icon: String; let color: Color; let title: String; let time: String; let item: String; let detail: String; let complete: Bool?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize { accessibilityLayout }
            else { compactLayout }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 38) }
    }

    private var compactLayout: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).frame(width: 30, height: 30).background(color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.subheadline.bold()); Text(time).font(.caption2).foregroundStyle(FuelTheme.secondary) }.frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) { Text(item).font(.subheadline.weight(.semibold)); Text(detail).font(.caption2).foregroundStyle(detail == "Good" ? FuelTheme.purple : FuelTheme.secondary) }
            Spacer()
            if let complete { Image(systemName: complete ? "checkmark.circle" : "circle").foregroundStyle(complete ? FuelTheme.green : FuelTheme.secondary) } else { Image(systemName: "chevron.right").foregroundStyle(FuelTheme.secondary) }
        }
    }

    private var accessibilityLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 30, height: 30).background(color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(time).font(.caption).foregroundStyle(FuelTheme.secondary)
                Text(item).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(detail == "Good" ? FuelTheme.purple : FuelTheme.secondary)
            }
            Spacer()
            if let complete { Image(systemName: complete ? "checkmark.circle" : "circle").foregroundStyle(complete ? FuelTheme.green : FuelTheme.secondary) }
            else { Image(systemName: "chevron.right").foregroundStyle(FuelTheme.secondary) }
        }
    }
}

#Preview("Today dashboard") {
    NavigationStack { TodayView(state: AppState(healthService: MockHealthDataService())) }
        .preferredColorScheme(.dark)
}
