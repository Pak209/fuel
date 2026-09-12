import SwiftData
import SwiftUI

struct MealsView: View {
    let state: AppState
    @Query(sort: \Meal.date, order: .reverse) private var storedMeals: [Meal]

    @State private var filter: MealHistoryFilter = .today
    @State private var searchText = ""
    @State private var showsNewMeal = false
    @State private var showsCalendar = false
    @State private var pendingDelete: Meal?
    @State private var pendingFavoriteDelete: MealTemplate?
    @State private var lastDeleted: Meal?
    @State private var errorMessage: String?

    private var calendar: Calendar {
        var value = Calendar.autoupdatingCurrent
        value.timeZone = TimeZone(identifier: state.profile.timeZoneIdentifier) ?? .autoupdatingCurrent
        return value
    }

    private var filteredMeals: [Meal] {
        let active = storedMeals.filter { $0.status != .deleted }
        let scoped: [Meal]
        switch filter {
        case .today:
            scoped = active.filter { state.snapshot.interval.contains($0.date) }
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: state.selectedDate)
            scoped = interval.map { range in active.filter { range.contains($0.date) } } ?? active
        case .breakfast:
            scoped = active.filter { $0.type == .breakfast }
        case .lunch:
            scoped = active.filter { $0.type == .lunch }
        case .dinner:
            scoped = active.filter { $0.type == .dinner }
        case .snacks:
            scoped = active.filter { $0.type == .snack }
        case .all:
            scoped = active
        }
        guard !searchText.isEmpty else { return scoped }
        return scoped.filter { meal in
            meal.name.localizedStandardContains(searchText)
                || meal.items.contains { $0.name.localizedStandardContains(searchText) }
        }
    }

    private var dayGroups: [(Date, [Meal])] {
        Dictionary(grouping: filteredMeals) { calendar.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        ZStack {
            FuelTheme.background.ignoresSafeArea()
            VStack(spacing: 8) {
                filters
                if !state.favorites.isEmpty { favorites }
                mealHistory
            }
        }
        .navigationTitle("Meals")
        .searchable(text: $searchText, prompt: "Search meals and foods")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showsCalendar = true } label: { Image(systemName: "calendar") }
                    .accessibilityLabel("Choose a day to view")
                    .accessibilityIdentifier("mealsCalendarButton")
                Button { showsNewMeal = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Log meal manually")
                    .accessibilityIdentifier("mealsAddButton")
            }
        }
        .sheet(isPresented: $showsNewMeal) {
            NavigationStack { MealEditorView(state: state) }
        }
        .sheet(isPresented: $showsCalendar) {
            NavigationStack {
                DatePicker("History date", selection: Binding(
                    get: { state.selectedDate },
                    set: { state.selectedDate = $0; Task { await state.refresh() } }
                ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Choose a day")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsCalendar = false } } }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("Delete this meal?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete meal", role: .destructive, action: confirmDelete)
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The meal will be removed from summaries. You can undo immediately afterward.")
        }
        .confirmationDialog("Remove this favorite?", isPresented: Binding(
            get: { pendingFavoriteDelete != nil },
            set: { if !$0 { pendingFavoriteDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Remove favorite", role: .destructive, action: removeFavorite)
            Button("Cancel", role: .cancel) { pendingFavoriteDelete = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if let lastDeleted {
                HStack {
                    Text("\(lastDeleted.name) deleted").font(.subheadline)
                    Spacer()
                    Button("Undo", action: undoDelete).fontWeight(.semibold)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            }
        }
        .alert("Couldn’t update meals", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MealHistoryFilter.allCases) { value in
                    Button(value.title) { filter = value }
                        .buttonStyle(.bordered)
                        .tint(filter == value ? FuelTheme.green : FuelTheme.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(filter == value ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
        .accessibilityIdentifier("mealsFilterMenu")
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Favorites").font(.caption.bold()).foregroundStyle(FuelTheme.secondary).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(state.favorites) { template in
                        Button {
                            Task {
                                do { try await state.saveMeal(template.draft()) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        } label: {
                            Label(template.name, systemImage: "star.fill")
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(FuelTheme.panelRaised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Log favorite meal, \(template.name)")
                        .contextMenu {
                            Button(role: .destructive) { pendingFavoriteDelete = template } label: {
                                Label("Remove favorite", systemImage: "star.slash")
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var mealHistory: some View {
        if dayGroups.isEmpty {
            EmptyStateView(
                icon: "fork.knife",
                title: "No meals found",
                message: searchText.isEmpty ? "Log a meal manually or scan a photo to begin." : "Try a different search or filter."
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(dayGroups, id: \.0) { day, meals in
                    Section(day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(meals) { meal in
                            NavigationLink {
                                MealEditorView(state: state, meal: meal)
                            } label: {
                                MealHistoryRow(meal: meal)
                            }
                            .listRowBackground(FuelTheme.panel)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = meal } label: { Label("Delete", systemImage: "trash") }
                                Button { duplicate(meal) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                    .tint(FuelTheme.blue)
                            }
                            .contextMenu {
                                Button { duplicate(meal) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                Button { favorite(meal) } label: { Label("Save as favorite", systemImage: "star") }
                                Button(role: .destructive) { pendingDelete = meal } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("mealsList")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func duplicate(_ meal: Meal) {
        Task {
            do { try await state.duplicateMeal(meal) }
            catch { fail(error) }
        }
    }

    private func favorite(_ meal: Meal) {
        do { try state.saveFavorite(from: meal) }
        catch { fail(error) }
    }

    private func removeFavorite() {
        guard let favorite = pendingFavoriteDelete else { return }
        pendingFavoriteDelete = nil
        do { try state.deleteFavorite(id: favorite.id) }
        catch { fail(error) }
    }

    private func confirmDelete() {
        guard let meal = pendingDelete else { return }
        pendingDelete = nil
        Task {
            do {
                try await state.deleteMeal(meal)
                lastDeleted = meal
                AccessibilityNotification.Announcement("\(meal.name) deleted").post()
                try? await Task.sleep(for: .seconds(DailyDataCoordinator.mealDeletionUndoRetention))
                if lastDeleted?.id == meal.id { lastDeleted = nil }
            } catch {
                fail(error)
            }
        }
    }

    private func undoDelete() {
        guard let meal = lastDeleted else { return }
        Task {
            do {
                try await state.restoreMeal(meal)
                lastDeleted = nil
                AccessibilityNotification.Announcement("\(meal.name) restored").post()
            } catch {
                fail(error)
            }
        }
    }
}

private enum MealHistoryFilter: String, CaseIterable, Identifiable {
    // Put the broadest scope first so it remains immediately reachable instead of
    // being stranded beyond every meal-type chip on compact iPhones.
    case all, today, week, breakfast, lunch, dinner, snacks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Selected day"
        case .week: "This week"
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snacks: "Snacks"
        case .all: "All"
        }
    }
}

private struct MealHistoryRow: View {
    let meal: Meal
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 11) {
            MealPhotoThumbnail(fileName: meal.imageFileName, fallback: icon)
            if dynamicTypeSize.isAccessibilitySize {
                detail(truncating: false)
            } else {
                detail(truncating: true)
            }
            Spacer(minLength: 6)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combinedLabel)
    }

    private func detail(truncating: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(meal.name).font(.headline).lineLimit(truncating ? 1 : nil)
                if meal.status == .planned {
                    Text("Planned").font(.caption2.bold()).foregroundStyle(FuelTheme.orange)
                }
            }
            Text("\(meal.type.rawValue) · \(meal.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(FuelTheme.secondary)
            Text("\(meal.calories) cal · \(Int(meal.protein))g protein")
                .font(.caption)
                .foregroundStyle(FuelTheme.secondary)
            if !meal.items.isEmpty {
                Text(meal.items.prefix(3).map(\.name).joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(FuelTheme.secondary)
                    .lineLimit(truncating ? 1 : nil)
            }
        }
    }

    private var combinedLabel: String {
        var parts = [meal.name]
        if meal.status == .planned { parts.append("Planned") }
        parts.append("\(meal.type.rawValue) at \(meal.date.formatted(date: .omitted, time: .shortened))")
        parts.append("\(meal.calories) calories, \(Int(meal.protein)) grams protein")
        let items = meal.items.prefix(3).map(\.name).joined(separator: ", ")
        if !items.isEmpty { parts.append("Includes \(items)") }
        return parts.joined(separator: ". ")
    }

    private var icon: String { meal.type == .breakfast ? "sun.max.fill" : "fork.knife" }
}

private struct MealPhotoThumbnail: View {
    let fileName: String?
    let fallback: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: fallback).foregroundStyle(FuelTheme.green)
            }
        }
        .frame(width: 46, height: 46)
        .background(FuelTheme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .task(id: fileName) {
            guard let fileName else { return }
            do { image = UIImage(data: try await LocalMealPhotoStore().load(fileName: fileName)) }
            catch { image = nil }
        }
    }
}
