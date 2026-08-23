import SwiftUI

struct HealthScoreRing: View {
    let score: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedScore: Int = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            Circle().trim(from: 0, to: Double(animatedScore) / 100).stroke(AngularGradient(colors: [FuelTheme.green, FuelTheme.green, FuelTheme.orange, FuelTheme.red], center: .center), style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: "heart.fill").font(.system(size: 28)).foregroundStyle(FuelTheme.green).overlay(Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .bold)).foregroundStyle(.white))
        }
        .padding(5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score \(score) out of 100")
        .onAppear {
            if reduceMotion {
                animatedScore = score
            } else {
                withAnimation(.easeOut(duration: 0.6)) { animatedScore = score }
            }
        }
        .onChange(of: score) { _, newValue in
            if reduceMotion {
                animatedScore = newValue
            } else {
                withAnimation(.easeOut(duration: 0.6)) { animatedScore = newValue }
            }
        }
    }
}

struct NutrientProgressRow: View {
    let category: HealthScoreCategory
    let score: Int?
    private var color: Color { switch category { case .nutrition, .protein: FuelTheme.green; case .hydration: FuelTheme.blue; case .fiber: FuelTheme.red; case .recovery: FuelTheme.purple } }
    private var icon: String { switch category { case .nutrition: "apple.logo"; case .protein: "figure.strengthtraining.traditional"; case .hydration: "drop"; case .fiber: "leaf"; case .recovery: "moon" } }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(color.opacity(0.15), in: Circle())
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(category.rawValue).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(score?.formatted() ?? "—").font(.system(size: 11, weight: .bold)).foregroundStyle(color)
                }
                ProgressView(value: Double(score ?? 0), total: 100).tint(color).scaleEffect(x: 1, y: 0.5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "\(category.rawValue), \($0) out of 100" } ?? "\(category.rawValue), unavailable")
    }
}

struct MetricCard: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    let color: Color
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            ViewThatFits(in: .horizontal) {
                Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
            }
            ViewThatFits(in: .horizontal) {
                Text(detail).font(.system(size: 10, weight: .semibold)).foregroundStyle(color).lineLimit(1)
                Text(detail).font(.system(size: 10, weight: .semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            }
            if let progress {
                ProgressView(value: min(1, max(0, progress))).tint(color).scaleEffect(x: 1, y: 0.7)
            } else {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}

struct EmptyStateView: View {
    let icon: String; let title: String; let message: String
    var body: some View { ContentUnavailableView(title, systemImage: icon, description: Text(message)) }
}

enum FuelLayout {
    /// Bottom clearance so scroll content doesn't sit under the tab bar.
    /// Mirrors the bottom clearance already used for the transient message
    /// banner in `FuelApp.swift` (`AppRootView`'s `.padding(.bottom, 74)`).
    static let tabBarClearance: CGFloat = 74
}
