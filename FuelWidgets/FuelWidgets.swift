import AppIntents
import SwiftUI
import WidgetKit

struct FuelWidgetEntry: TimelineEntry {
    var date: Date
    var summary: SharedDailySummary
}

struct FuelWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FuelWidgetEntry {
        .init(date: .now, summary: .init(
            healthScore: 82,
            caloriesRemaining: 640,
            proteinRemainingGrams: 34,
            hydrationMilliliters: 1_250,
            hydrationTargetMilliliters: 2_000,
            lastUpdated: .now
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (FuelWidgetEntry) -> Void) {
        completion(.init(date: .now, summary: FuelSharedStore.loadSummary()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FuelWidgetEntry>) -> Void) {
        let entry = FuelWidgetEntry(date: .now, summary: FuelSharedStore.loadSummary())
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1_800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct FuelSummaryWidget: Widget {
    let kind = "FuelSummaryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FuelWidgetProvider()) { entry in
            FuelWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.04, green: 0.07, blue: 0.06) }
                .widgetURL(URL(string: "fuel://today"))
        }
        .configurationDisplayName("Fuel Daily Summary")
        .description("See today’s wellness summary and quickly add water.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private struct FuelWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FuelWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: hydrationProgress) {
                Image(systemName: "drop.fill")
            } currentValueLabel: {
                Text("\(Int(hydrationProgress * 100))")
            }
            .gaugeStyle(.accessoryCircular)
            .privacySensitive()
            .accessibilityLabel("Hydration \(Int(hydrationProgress * 100)) percent")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Fuel", systemImage: "heart.fill")
                Text("\(entry.summary.proteinRemainingGrams) g protein remaining")
                Text("\(entry.summary.caloriesRemaining) calories remaining")
            }
            .privacySensitive()
            .accessibilityElement(children: .combine)
        case .systemMedium:
            HStack(spacing: 18) {
                score
                VStack(alignment: .leading, spacing: 8) {
                    metric("Calories", value: "\(entry.summary.caloriesRemaining) left", icon: "flame.fill")
                    metric("Protein", value: "\(entry.summary.proteinRemainingGrams) g left", icon: "figure.strengthtraining.traditional")
                    Button(intent: AddWaterIntent(amountMilliliters: 250)) {
                        Label("Add 250 ml", systemImage: "drop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .privacySensitive()
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Fuel", systemImage: "heart.fill").font(.headline)
                    Spacer()
                    score
                }
                Text("\(entry.summary.caloriesRemaining) cal left").font(.title3.bold())
                Text("\(entry.summary.proteinRemainingGrams) g protein left").font(.caption)
                Spacer(minLength: 0)
                Button(intent: AddWaterIntent(amountMilliliters: 250)) {
                    Label("Add water", systemImage: "drop.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .privacySensitive()
        }
    }

    private var score: some View {
        Group {
            if let score = entry.summary.healthScore {
                Text("\(score)")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                    .accessibilityLabel("Health score \(score) out of 100")
            } else {
                Image(systemName: "heart")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Health score unavailable")
            }
        }
    }

    private var hydrationProgress: Double {
        guard entry.summary.hydrationTargetMilliliters > 0 else { return 0 }
        return min(max(Double(entry.summary.hydrationMilliliters) / Double(entry.summary.hydrationTargetMilliliters), 0), 1)
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(.green).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@main
struct FuelWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FuelSummaryWidget()
    }
}
