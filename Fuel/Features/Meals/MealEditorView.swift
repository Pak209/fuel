import PhotosUI
import SwiftUI

struct MealEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let state: AppState
    private let meal: Meal?
    private let initialProvenance: DataProvenance
    private let initialConfidence: Double?

    @State private var name: String
    @State private var type: MealType
    @State private var date: Date
    @State private var notes: String
    @State private var status: MealStatus
    @State private var items: [MealItem]
    @State private var manualNutrition: NutritionEstimate
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var removeExistingImage = false
    @State private var editingItem: MealItem?
    @State private var showsFoodSearch = false
    @State private var recentItems: [MealItem] = []
    @State private var confirmsDelete = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var itemNutrition: NutritionEstimate { items.reduce(.zero) { $0 + $1.nutrition } }
    private var totalNutrition: NutritionEstimate { itemNutrition + manualNutrition }

    init(state: AppState, meal: Meal? = nil, draft: MealDraft? = nil) {
        self.state = state
        self.meal = meal
        let resolvedName = draft?.name ?? meal?.name ?? ""
        let resolvedType = draft?.type ?? meal?.type ?? .lunch
        let resolvedDate = draft?.date ?? meal?.date ?? .now
        let resolvedNotes = draft?.notes ?? meal?.notes ?? ""
        let resolvedStatus = draft?.status ?? meal?.status ?? .logged
        let resolvedItems = draft?.items ?? meal?.items ?? []
        let resolvedNutrition = draft?.nutrition ?? meal?.nutrition ?? .zero
        let itemsTotal = resolvedItems.reduce(.zero) { $0 + $1.nutrition }
        initialProvenance = draft?.provenance ?? meal?.provenance ?? .userEntered
        initialConfidence = draft?.confidence ?? meal?.confidence
        _name = State(initialValue: resolvedName)
        _type = State(initialValue: resolvedType)
        _date = State(initialValue: resolvedDate)
        _notes = State(initialValue: resolvedNotes)
        _status = State(initialValue: resolvedStatus)
        _items = State(initialValue: resolvedItems)
        _manualNutrition = State(initialValue: resolvedNutrition - itemsTotal)
        _imageData = State(initialValue: draft?.imageData)
    }

    var body: some View {
        Form {
            mealSection
            foodsSection
            totalsSection
            photoSection
            notesSection
            safetySection
        }
        .navigationTitle(meal == nil ? "Log meal" : "Edit meal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("mealEditorCancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("mealEditorSave")
            }
        }
        .sheet(isPresented: $showsFoodSearch) {
            NavigationStack {
                FoodSearchView(
                    database: state.foodDatabase,
                    recentItems: recentItems,
                    onSelect: addFood,
                    onSelectRecent: addRecentFood
                )
            }
        }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                MealItemEditorView(item: item, onSave: replaceItem)
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in loadPhoto(newValue) }
        .task {
            do { recentItems = try state.recentFoodItems() }
            catch { fail(error) }
        }
        .confirmationDialog("Delete this meal?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete meal", role: .destructive, action: deleteMeal)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The meal will be removed from daily summaries.")
        }
        .alert("Couldn’t save meal", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var mealSection: some View {
        Section("Meal") {
            TextField("Meal name", text: $name)
                .accessibilityIdentifier("mealEditorName")
            Picker("Type", selection: $type) {
                ForEach(MealType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Date and time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("Date and time", selection: $date)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            Toggle("Planned meal", isOn: Binding(
                get: { status == .planned },
                set: { status = $0 ? .planned : .logged }
            ))
        }
    }

    private var foodsSection: some View {
        Section {
            if items.isEmpty {
                Text("Add foods from search, or use quick nutrition below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button { editingItem = item } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).foregroundStyle(.primary)
                            Text("\(item.serving) · \(item.nutrition.calories) cal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.isUserCorrected {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(FuelTheme.green)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(item.name), \(item.serving), \(item.nutrition.calories) calories"
                        + (item.isUserCorrected ? ", user corrected" : "")
                    )
                    .accessibilityHint("Double tap to edit this food")
                }
            }
            .onDelete { items.remove(atOffsets: $0) }
            Button { showsFoodSearch = true } label: { Label("Add food", systemImage: "plus") }
                .accessibilityIdentifier("mealEditorAddFood")
            Button(action: addManualFood) { Label("Add custom food", systemImage: "square.and.pencil") }
                .accessibilityIdentifier("mealEditorAddCustomFood")
        } header: {
            Text("Foods")
        } footer: {
            Text("Database values retain their source. Portion changes are marked as user corrections.")
        }
    }

    private var totalsSection: some View {
        Section {
            NutritionFields(nutrition: $manualNutrition)
            LabeledContent("Calculated total", value: "\(totalNutrition.calories) cal")
            LabeledContent("Protein", value: "\(totalNutrition.protein.formatted(.number.precision(.fractionLength(0...1)))) g")
            LabeledContent("Carbohydrates", value: "\(totalNutrition.carbohydrates.formatted(.number.precision(.fractionLength(0...1)))) g")
            LabeledContent("Fat", value: "\(totalNutrition.fat.formatted(.number.precision(.fractionLength(0...1)))) g")
            LabeledContent("Fiber", value: "\(totalNutrition.fiber.formatted(.number.precision(.fractionLength(0...1)))) g")
        } header: {
            Text("Quick nutrition adjustment")
        } footer: {
            Text("Use these fields for a quick-add or to correct the database total. The calculated total updates immediately.")
        }
    }

    private var photoSection: some View {
        Section("Photo") {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if meal?.imageFileName != nil, !removeExistingImage {
                Label("Existing meal photo will be kept", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label(imageData == nil ? "Attach photo" : "Replace photo", systemImage: "photo.on.rectangle")
            }
            if imageData != nil {
                Button("Remove selected photo", role: .destructive) {
                    imageData = nil
                    selectedPhoto = nil
                }
            } else if meal?.imageFileName != nil, !removeExistingImage {
                Button("Remove existing photo", role: .destructive) {
                    removeExistingImage = true
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Optional notes", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var safetySection: some View {
        Section {
            Text("Nutrition values and photo recognition are estimates for general wellness use. Review portions and ingredients, especially when allergies or specialized dietary needs apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if meal != nil {
                Button("Delete meal", role: .destructive) { confirmsDelete = true }
                    .accessibilityIdentifier("mealEditorDelete")
            }
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

    private func addFood(_ food: FoodSearchResult) {
        let item = MealItem(
            name: food.name,
            quantity: 1,
            unit: .serving,
            nutrition: food.nutrition(quantity: 1, unit: .serving),
            provenance: .nutritionDatabase,
            foodIdentifier: food.id,
            sourceName: food.sourceName,
            nutritionPer100Grams: food.nutritionPer100Grams,
            gramsPerUnit: food.gramsPerUnit
        )
        items.append(item)
        showsFoodSearch = false
        editingItem = item
    }

    private func addRecentFood(_ recent: MealItem) {
        var copy = recent
        copy.id = UUID()
        items.append(copy)
        showsFoodSearch = false
        editingItem = copy
    }

    private func addManualFood() {
        let item = MealItem(name: "Custom food", provenance: .userEntered, correctedAt: .now)
        items.append(item)
        editingItem = item
    }

    private func replaceItem(_ item: MealItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
        editingItem = nil
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw FoodServiceError.invalidImage
                }
                imageData = try await state.imageProcessor.prepareForRecognition(data)
                removeExistingImage = false
            } catch {
                fail(error)
            }
        }
    }

    private func save() {
        isSaving = true
        let draft = MealDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            date: date,
            nutrition: totalNutrition,
            items: items,
            provenance: initialProvenance,
            confidence: initialConfidence,
            imageData: imageData,
            notes: notes,
            status: status,
            removeExistingImage: removeExistingImage
        )
        Task {
            defer { isSaving = false }
            do {
                if let meal { try await state.updateMeal(meal, with: draft) }
                else { try await state.saveMeal(draft) }
                dismiss()
            } catch {
                fail(error)
            }
        }
    }

    private func deleteMeal() {
        guard let meal else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await state.deleteMeal(meal); dismiss() }
            catch { fail(error) }
        }
    }
}

private struct NutritionFields: View {
    @Binding var nutrition: NutritionEstimate

    var body: some View {
        Group {
            LabeledContent("Calories") {
                TextField("0", value: $nutrition.calories, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            nutrientField("Protein", unit: "g", value: $nutrition.protein)
            nutrientField("Carbohydrates", unit: "g", value: $nutrition.carbohydrates)
            nutrientField("Fat", unit: "g", value: $nutrition.fat)
            nutrientField("Fiber", unit: "g", value: $nutrition.fiber)
            DisclosureGroup("Micronutrient adjustments") {
                nutrientField("Sugar", unit: "g", value: $nutrition.sugar)
                nutrientField("Sodium", unit: "mg", value: $nutrition.sodium)
                nutrientField("Potassium", unit: "mg", value: $nutrition.potassium)
                nutrientField("Calcium", unit: "mg", value: $nutrition.calcium)
                nutrientField("Iron", unit: "mg", value: $nutrition.iron)
                nutrientField("Vitamin C", unit: "mg", value: $nutrition.vitaminC)
            }
        }
    }

    private func nutrientField(_ label: String, unit: String, value: Binding<Double>) -> some View {
        LabeledContent("\(label) (\(unit))") {
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct MealItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (MealItem) -> Void
    @State private var item: MealItem

    init(item: MealItem, onSave: @escaping (MealItem) -> Void) {
        self.onSave = onSave
        _item = State(initialValue: item)
    }

    var body: some View {
        Form {
            Section("Food") {
                TextField("Name", text: $item.name)
                TextField("Quantity", value: $item.quantity, format: .number)
                    .keyboardType(.decimalPad)
                Picker("Unit", selection: $item.unit) {
                    ForEach(MeasurementUnit.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                if let source = item.sourceName { LabeledContent("Nutrition source", value: source) }
                if let confidence = item.confidence {
                    LabeledContent("Recognition confidence", value: confidence.formatted(.percent.precision(.fractionLength(0))))
                }
            }
            Section("Nutrition for this amount") { NutritionFields(nutrition: $item.nutrition) }
            Section {
                Text("Changing a portion or nutrient value records this item as user-corrected. Your correction is saved instead of being replaced by the original estimate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit food")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: item.quantity) { _, _ in recalculate() }
        .onChange(of: item.unit) { _, _ in recalculate() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    item.correctedAt = .now
                    onSave(item)
                    dismiss()
                }
                .disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.quantity <= 0)
            }
        }
    }

    private func recalculate() {
        item.recalculateNutrition()
        item.correctedAt = .now
    }
}

private struct FoodSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let database: any FoodDatabaseService
    let recentItems: [MealItem]
    let onSelect: (FoodSearchResult) -> Void
    let onSelectRecent: (MealItem) -> Void

    @State private var query = ""
    @State private var results: [FoodSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if query.isEmpty, !recentItems.isEmpty {
                Section("Recent foods") {
                    ForEach(recentItems) { item in
                        Button { onSelectRecent(item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).foregroundStyle(.primary)
                                Text("\(item.serving) · \(item.nutrition.calories) cal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            }
            if isLoading { ProgressView("Searching…") }
            ForEach(results) { food in
                Button { onSelect(food) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(food.displayName).foregroundStyle(.primary)
                        Text("\(food.nutritionPer100Grams.calories) cal per 100 g · \(food.sourceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Add food")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search foods or brands")
        .task(id: query) { await search() }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func search() async {
        do {
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            try Task.checkCancellation()
            isLoading = true
            defer { isLoading = false }
            results = try await database.search(query)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
