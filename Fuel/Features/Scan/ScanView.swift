import ImageIO
import PhotosUI
import SwiftUI

struct ScanView: View {
    let state: AppState

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var phase: ScanPhase = .idle
    @State private var result: FoodRecognitionResult?
    @State private var editorDraft: IdentifiedMealDraft?
    @State private var analysisTask: Task<Void, Never>?

    /// Preview thumbnails are decoded well below the source resolution: the image
    /// preview renders at a fixed 245pt height, so ~2x that in pixels is already
    /// more detail than the eye can resolve, and decoding a small CGImage thumbnail
    /// off the main thread avoids the full-resolution `UIImage(data:)` decode this
    /// view used to perform synchronously on every body evaluation.
    private static let previewMaxPixelSize: CGFloat = 490

    private enum ScanPhase: Equatable {
        case idle
        case preparing
        case analyzing
        case failed(String)
    }

    var body: some View {
        ZStack {
            FuelTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    ScanIntroduction()
                    imagePreview
                    photoActions
                    phaseContent
                    if let result { RecognitionSummary(result: result, review: reviewResult) }
                    pendingScans
                    manualFallback
                }
                .padding()
            }
        }
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedPhoto) { _, item in startAnalysis(item) }
        .onDisappear { analysisTask?.cancel() }
        .task(id: imageData) { await refreshPreviewImage() }
        .sheet(item: $editorDraft) { identified in
            NavigationStack { MealEditorView(state: state, draft: identified.draft) }
        }
    }

    private var imagePreview: some View {
        Group {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 245)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button(action: reset) {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .padding(10)
                                .background(.black.opacity(0.7), in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("Remove meal photo")
                    }
            } else if imageData != nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 245)
                    .background(FuelTheme.panel, in: RoundedRectangle(cornerRadius: 20))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(FuelTheme.green)
                    Text("Choose a clear overhead or angled meal photo")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(FuelTheme.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(FuelTheme.panel, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(FuelTheme.border, style: .init(lineWidth: 1, dash: [7])))
            }
        }
    }

    private var photoActions: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Label(imageData == nil ? "Choose meal photo" : "Choose another photo", systemImage: "photo.on.rectangle")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(FuelTheme.green, in: RoundedRectangle(cornerRadius: 13))
                .foregroundStyle(.black)
        }
        .disabled(phase == .preparing || phase == .analyzing)
        .accessibilityIdentifier("scanPhotoPicker")
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparing:
            ProgressView("Preparing photo…").frame(maxWidth: .infinity).cardStyle(padding: 14)
        case .analyzing:
            VStack(spacing: 10) {
                ProgressView("Recognizing foods on device…")
                Button("Cancel", action: cancelAnalysis).font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .cardStyle(padding: 14)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label("Recognition needs your help", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).font(.subheadline).foregroundStyle(FuelTheme.secondary)
                HStack {
                    Button("Retry", action: retryAnalysis)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("scanRetryButton")
                    Button("Log manually", action: openManualEditor).buttonStyle(.borderedProminent)
                }
                if imageData != nil {
                    Button("Save scan for later") { Task { await saveForLater() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("scanSaveForLater")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 14)
        }
    }

    private var manualFallback: some View {
        Button(action: openManualEditor) {
            Label("Log without a photo", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(FuelTheme.secondary)
    }

    @ViewBuilder
    private var pendingScans: some View {
        if !state.pendingRecognitions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved scans").font(.headline)
                ForEach(state.pendingRecognitions) { job in
                    HStack(spacing: 10) {
                        Image(systemName: pendingIcon(job.state))
                            .foregroundStyle(job.state == .completed ? FuelTheme.green : FuelTheme.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pendingTitle(job.state)).font(.subheadline.weight(.semibold))
                            Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(FuelTheme.secondary)
                            if let error = job.lastError {
                                Text(error).font(.caption2).foregroundStyle(FuelTheme.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if job.state == .completed {
                            Button("Review") { Task { await review(job) } }.buttonStyle(.borderedProminent)
                        } else if job.state != .processing {
                            Button("Retry") { Task { await state.retryPendingRecognition(job) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("scanRetryButton")
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button(role: .destructive) { Task { try? await state.deletePendingRecognition(job) } } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete saved scan")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 14)
            .accessibilityIdentifier("scanPendingList")
        }
    }

    private func startAnalysis(_ item: PhotosPickerItem?) {
        guard let item else { return }
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                phase = .preparing
                guard let source = try await item.loadTransferable(type: Data.self) else {
                    throw FoodServiceError.invalidImage
                }
                let prepared = try await state.imageProcessor.prepareForRecognition(source)
                try Task.checkCancellation()
                imageData = prepared
                result = nil
                phase = .analyzing
                result = try await recognizeWithTimeout(prepared)
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func retryAnalysis() {
        guard let imageData else { return }
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                phase = .analyzing
                result = try await recognizeWithTimeout(imageData)
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func saveForLater() async {
        guard let imageData else { return }
        do {
            try await state.queueRecognitionForLater(imageData: imageData)
            reset()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func review(_ job: PendingRecognitionRecord) async {
        do {
            let draft = try await state.draftForPendingRecognition(job)
            editorDraft = IdentifiedMealDraft(draft: draft)
            try await state.deletePendingRecognition(job)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func pendingTitle(_ state: PendingWorkState) -> String {
        switch state {
        case .pending: "Waiting to retry"
        case .processing: "Recognizing…"
        case .failed: "Retry available"
        case .completed: "Ready to review"
        }
    }

    private func pendingIcon(_ state: PendingWorkState) -> String {
        switch state {
        case .pending: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        phase = .idle
    }

    private func recognizeWithTimeout(_ data: Data) async throws -> FoodRecognitionResult {
        try await withThrowingTaskGroup(of: FoodRecognitionResult.self) { group in
            group.addTask { try await state.recognitionService.analyze(imageData: data) }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw FoodServiceError.timedOut
            }
            guard let first = try await group.next() else { throw FoodServiceError.unavailable }
            group.cancelAll()
            return first
        }
    }

    private func reset() {
        cancelAnalysis()
        selectedPhoto = nil
        imageData = nil
        previewImage = nil
        result = nil
    }

    /// Regenerates the downsampled preview thumbnail whenever `imageData` changes.
    /// The decode happens off the main thread via `Task.detached`; only the final
    /// small `UIImage` is published back to state.
    private func refreshPreviewImage() async {
        guard let imageData else {
            previewImage = nil
            return
        }
        let maxPixelSize = Self.previewMaxPixelSize
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.downsampledImage(from: imageData, maxPixelSize: maxPixelSize)
        }.value
        guard !Task.isCancelled else { return }
        previewImage = decoded
    }

    /// Decodes a small, display-ready thumbnail directly from the image source
    /// rather than fully decoding the source image and scaling it down, matching
    /// the pattern used in `OnDeviceFoodRecognitionService.analyze` (FoodServices.swift).
    nonisolated private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func reviewResult() {
        guard let result else { return }
        editorDraft = IdentifiedMealDraft(draft: .init(
            name: result.mealName,
            type: suggestedMealType,
            date: .now,
            nutrition: result.nutrition,
            items: result.items,
            provenance: .aiEstimated,
            confidence: result.confidence,
            imageData: imageData,
            notes: result.warnings.joined(separator: " ")
        ))
    }

    private func openManualEditor() {
        editorDraft = IdentifiedMealDraft(draft: .init(
            name: "",
            type: suggestedMealType,
            date: .now,
            nutrition: .zero,
            items: [],
            provenance: .userEntered,
            confidence: nil,
            imageData: imageData
        ))
    }

    private var suggestedMealType: MealType {
        switch Calendar.autoupdatingCurrent.component(.hour, from: .now) {
        case 4..<11: .breakfast
        case 11..<15: .lunch
        case 15..<18: .snack
        default: .dinner
        }
    }
}

private struct IdentifiedMealDraft: Identifiable {
    var id = UUID()
    var draft: MealDraft
}

private struct ScanIntroduction: View {
    var body: some View {
        VStack(spacing: 5) {
            Text("Scan a meal").font(.title2.bold())
            Text("Fuel uses on-device image classification, then lets you review every food and portion before saving.")
                .font(.subheadline)
                .foregroundStyle(FuelTheme.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct RecognitionSummary: View {
    let result: FoodRecognitionResult
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.mealName).font(.headline)
                    Text("\(result.items.count) candidate foods · \(result.confidence.formatted(.percent.precision(.fractionLength(0)))) confidence")
                        .font(.caption)
                        .foregroundStyle(FuelTheme.secondary)
                }
                Spacer()
                if result.isPartial { Text("Review").font(.caption.bold()).foregroundStyle(FuelTheme.orange) }
            }
            Text(result.items.map(\.name).joined(separator: " • "))
                .font(.subheadline)
                .foregroundStyle(FuelTheme.secondary)
            HStack {
                nutrition("\(result.nutrition.calories)", "Calories")
                nutrition("\(Int(result.nutrition.protein))g", "Protein")
                nutrition("\(Int(result.nutrition.carbohydrates))g", "Carbs")
                nutrition("\(Int(result.nutrition.fiber))g", "Fiber")
            }
            ForEach(result.warnings, id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(FuelTheme.secondary)
            }
            Button("Review foods and portions", action: review)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .cardStyle(padding: 14)
    }

    private func nutrition(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundStyle(FuelTheme.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
