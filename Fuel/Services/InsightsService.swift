import Foundation

struct DailyTrendPoint: Identifiable, Hashable {
    var id: Date { date }
    var date: Date
    var calories: Double
    var protein: Double
    var fiber: Double
    var hydration: Double
    var steps: Double?
}

struct ComputedInsight: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var supportingData: String
    var systemImage: String
}

struct InsightsReport: Hashable {
    var startDate: Date
    var endDate: Date
    var trends: [DailyTrendPoint]
    var insights: [ComputedInsight]
    var loggedDays: Int
    var requestedDays: Int
    var averageCalories: Int
    var averageProtein: Double
    var averageFiber: Double
    var hydrationGoalDays: Int
    var fiberGoalDays: Int
    var averageSteps: Int?
    var dataCompleteness: Double
    var includesEstimates: Bool

    var hasMinimumSample: Bool { loggedDays >= 3 }
    var accessibleSummary: String {
        "\(loggedDays) logged days out of \(requestedDays). Average \(averageCalories) calories, \(Int(averageProtein)) grams protein, and \(Int(averageFiber)) grams fiber on logged days."
    }
}

protocol InsightsService {
    func report(from snapshots: [DailyHealthSnapshot]) -> InsightsReport
}

struct LocalInsightsService: InsightsService {
    func report(from snapshots: [DailyHealthSnapshot]) -> InsightsReport {
        let logged = snapshots.filter { $0.nutrition.mealCount > 0 }
        let divisor = max(logged.count, 1)
        let averageCalories = logged.reduce(0) { $0 + $1.nutrition.calories } / divisor
        let averageProtein = logged.reduce(0) { $0 + $1.nutrition.protein } / Double(divisor)
        let averageFiber = logged.reduce(0) { $0 + $1.nutrition.fiber } / Double(divisor)
        let hydrationDays = logged.filter { $0.nutrition.hydrationMilliliters >= $0.nutrition.targets.hydrationMilliliters }.count
        let fiberDays = logged.filter { $0.nutrition.fiber >= $0.nutrition.targets.fiberGrams }.count
        let activityDays = snapshots.filter { $0.activity.availability == .available }
        let averageSteps = activityDays.isEmpty ? nil : activityDays.reduce(0) { $0 + $1.activity.steps } / activityDays.count
        let completeness = snapshots.isEmpty ? 0 : snapshots.reduce(0) { $0 + $1.dataCompleteness } / Double(snapshots.count)
        let estimates = logged.flatMap(\.meals).contains { $0.provenance == .aiEstimated }

        let trends = snapshots.map { snapshot in
            DailyTrendPoint(
                date: snapshot.interval.start,
                calories: Double(snapshot.nutrition.calories),
                protein: snapshot.nutrition.protein,
                fiber: snapshot.nutrition.fiber,
                hydration: snapshot.nutrition.hydrationMilliliters,
                steps: snapshot.activity.availability == .available ? Double(snapshot.activity.steps) : nil
            )
        }

        var insights: [ComputedInsight] = []
        if logged.count >= 3 {
            insights.append(.init(
                id: "protein-consistency",
                title: "Protein consistency",
                detail: "Average protein was \(Int(averageProtein)) grams across \(logged.count) logged days.",
                supportingData: "Daily target: \(Int(logged.last?.nutrition.targets.proteinGrams ?? 0)) g",
                systemImage: "figure.strengthtraining.traditional"
            ))
            insights.append(.init(
                id: "fiber-frequency",
                title: "Fiber goal frequency",
                detail: "Your fiber target was reached on \(fiberDays) of \(logged.count) logged days.",
                supportingData: "Average estimated fiber: \(Int(averageFiber)) g",
                systemImage: "leaf"
            ))
            insights.append(.init(
                id: "hydration-consistency",
                title: "Hydration consistency",
                detail: "Your logged water reached its target on \(hydrationDays) of \(logged.count) logged days.",
                supportingData: "Manual water entries only",
                systemImage: "drop"
            ))
            if let averageSteps {
                insights.append(.init(
                    id: "activity-average",
                    title: "Activity trend",
                    detail: "Apple Health recorded an average of \(averageSteps.formatted()) steps on \(activityDays.count) available days.",
                    supportingData: "Wearable values are estimates and can vary by source.",
                    systemImage: "figure.walk"
                ))
            }
            if let timing = mealTiming(logged) { insights.append(timing) }
            if let foods = commonFoods(logged) { insights.append(foods) }
            if let gap = possibleGap(logged) { insights.append(gap) }
        } else {
            insights.append(.init(
                id: "minimum-sample",
                title: "More days needed",
                detail: "Log meals on at least three days before Fuel describes a pattern.",
                supportingData: "\(logged.count) qualifying days currently available",
                systemImage: "calendar.badge.clock"
            ))
        }
        insights.append(.init(
            id: "completeness",
            title: "Data completeness",
            detail: "This range is \(Int(completeness * 100))% complete across meals, water, activity, and sleep sources.",
            supportingData: "Missing sources are excluded rather than treated as zero.",
            systemImage: "checkmark.circle"
        ))

        return .init(
            startDate: snapshots.first?.interval.start ?? .now,
            endDate: snapshots.last?.interval.end ?? .now,
            trends: trends,
            insights: insights,
            loggedDays: logged.count,
            requestedDays: snapshots.count,
            averageCalories: averageCalories,
            averageProtein: averageProtein,
            averageFiber: averageFiber,
            hydrationGoalDays: hydrationDays,
            fiberGoalDays: fiberDays,
            averageSteps: averageSteps,
            dataCompleteness: completeness,
            includesEstimates: estimates
        )
    }

    private func mealTiming(_ snapshots: [DailyHealthSnapshot]) -> ComputedInsight? {
        let meals = snapshots.flatMap(\.meals).filter { ($0.status ?? .logged) == .logged }
        guard meals.count >= 5 else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let hours = meals.map { calendar.component(.hour, from: $0.date) }
        let average = hours.reduce(0, +) / hours.count
        let displayTime = calendar.date(byAdding: .hour, value: average, to: calendar.startOfDay(for: .now))
        return .init(
            id: "meal-timing",
            title: "Meal timing",
            detail: "Your average logged meal time was around \(displayTime?.formatted(date: .omitted, time: .shortened) ?? "the same part of day").",
            supportingData: "Based on \(meals.count) meal timestamps",
            systemImage: "clock"
        )
    }

    private func commonFoods(_ snapshots: [DailyHealthSnapshot]) -> ComputedInsight? {
        let names = snapshots.flatMap(\.meals)
            .filter { ($0.status ?? .logged) == .logged }
            .flatMap { $0.itemNames ?? [] }
        guard names.count >= 5 else { return nil }
        let counts = Dictionary(grouping: names.map { $0.lowercased() }, by: { $0 }).mapValues(\.count)
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        guard !top.isEmpty else { return nil }
        return .init(
            id: "common-foods",
            title: "Commonly logged foods",
            detail: top.map(\.capitalized).joined(separator: ", "),
            supportingData: "Based on item names in reviewed meals",
            systemImage: "fork.knife"
        )
    }

    private func possibleGap(_ snapshots: [DailyHealthSnapshot]) -> ComputedInsight? {
        let count = Double(max(snapshots.count, 1))
        let potassium = Double(snapshots.reduce(0) { $0 + Int($1.nutrition.consumed.potassium) }) / count
        guard potassium < 2_000 else { return nil }
        return .init(
            id: "possible-potassium-gap",
            title: "Possible potassium gap",
            detail: "Logged foods average less than 2,000 mg of estimated potassium per day in this range.",
            supportingData: "Possible gap based on logged estimates—not a diagnosed deficiency.",
            systemImage: "exclamationmark.circle"
        )
    }
}
