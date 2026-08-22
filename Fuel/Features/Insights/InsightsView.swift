import Charts
import SwiftUI

struct InsightsView: View {
    let state: AppState

    @State private var range = InsightRange.sevenDays
    @State private var report: InsightsReport?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            FuelTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 14) {
                    Picker("Range", selection: $range) {
                        ForEach(InsightRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if isLoading { ProgressView("Building local insights…").padding(32) }
                    if let errorMessage { errorState(errorMessage) }
                    if let report {
                        summary(report)
                        trendChart(report)
                        ForEach(report.insights) { insight in InsightCard(insight: insight) }
                        disclosure(report)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Insights")
        .task(id: range) { await load() }
        .refreshable { await load() }
    }

    private func summary(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                summaryMetric("\(report.loggedDays)/\(report.requestedDays)", "Logged days")
                summaryMetric(report.averageCalories.formatted(), "Avg calories")
                summaryMetric("\(Int(report.averageProtein))g", "Avg protein")
            }
            ProgressView(value: report.dataCompleteness)
                .tint(FuelTheme.green)
            Text("\(Int(report.dataCompleteness * 100))% data completeness")
                .font(.caption)
                .foregroundStyle(FuelTheme.secondary)
        }
        .cardStyle(padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.accessibleSummary)
    }

    private func trendChart(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Logged energy").font(.headline)
            Text(dateRange(report)).font(.caption).foregroundStyle(FuelTheme.secondary)
            Chart(report.trends) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Calories", point.calories)
                )
                .foregroundStyle(point.calories > 0 ? FuelTheme.green.gradient : FuelTheme.panelRaised.gradient)
                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue("\(Int(point.calories)) logged calories")
            }
            .chartYAxisLabel("Calories")
            .frame(height: 190)
            Text("Days without meals remain visible as missing logs rather than being removed from the range.")
                .font(.caption)
                .foregroundStyle(FuelTheme.secondary)
        }
        .cardStyle(padding: 14)
    }

    private func disclosure(_ report: InsightsReport) -> some View {
        Text(report.includesEstimates
             ? "This report includes AI-estimated meal values. Patterns require at least three logged days and are not diagnoses of nutrient deficiency."
             : "Patterns require at least three logged days and are not diagnoses of nutrient deficiency.")
            .font(.caption)
            .foregroundStyle(FuelTheme.secondary)
            .padding(.horizontal, 4)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Insights unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await load() } }
        }
    }

    private func summaryMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(FuelTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dateRange(_ report: InsightsReport) -> String {
        "\(report.startDate.formatted(date: .abbreviated, time: .omitted)) – \(report.endDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let snapshots = try await state.historicalSnapshots(days: range.days)
            try Task.checkCancellation()
            report = state.insightsService.report(from: snapshots)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private enum InsightRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case thirtyDays = 30
    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { rawValue == 7 ? "7 days" : "30 days" }
}

private struct InsightCard: View {
    let insight: ComputedInsight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.systemImage)
                .foregroundStyle(FuelTheme.green)
                .frame(width: 36, height: 36)
                .background(FuelTheme.green.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(insight.title).font(.headline)
                Text(insight.detail).font(.subheadline).foregroundStyle(FuelTheme.secondary)
                Text(insight.supportingData).font(.caption).foregroundStyle(FuelTheme.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
        .accessibilityElement(children: .combine)
    }
}
