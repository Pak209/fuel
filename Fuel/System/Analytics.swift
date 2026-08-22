import Foundation

/// A compile-time-closed, non-sensitive event taxonomy for local counting only.
///
/// Privacy posture: Fuel ships with zero analytics by design (see the promise in
/// ProfileView). This file exists so that *if* local, on-device usage counting is
/// ever turned on for debugging or self-diagnosis, it is architecturally
/// incapable of carrying anything sensitive. `AnalyticsEvent` is a closed enum
/// whose associated values are restricted to other enums, `Bool`, and `Int` —
/// there is no `String` case anywhere in this taxonomy, so health details,
/// nutrition amounts, food names, or any other free text are unrepresentable by
/// construction, not merely by convention. There is no network sink in this file
/// (or anywhere in the app) — the only sink shipped here, `LocalCountingSink`,
/// increments in-memory/UserDefaults counters and goes nowhere else.
enum AnalyticsEvent: Equatable, Sendable {
    /// Where a logging/scan action originated from, for UX funnel counting only.
    enum Source: String, Equatable, Sendable {
        case photoScan
        case manualEntry
        case pendingRetry
        case quickAdd
        case widget
        case siriShortcut
    }

    case appLaunched
    case mealLogged(source: Source)
    case waterLogged(source: Source)
    case scanQueued
    case scanRetried(attempt: Int)
    case scanSucceeded
    case scanFailed
    case syncCompleted(operationCount: Int)
    case syncFailed
    case exportRequested
    case notificationOpened
    case remoteConfigurationApplied(flagCount: Int)

    /// Stable, non-sensitive identifier used as a counter key. Associated
    /// numeric/enum values are intentionally excluded from the key itself so the
    /// counter dictionary stays small and bounded regardless of magnitude.
    var countingKey: String {
        switch self {
        case .appLaunched: return "appLaunched"
        case .mealLogged(let source): return "mealLogged.\(source.rawValue)"
        case .waterLogged(let source): return "waterLogged.\(source.rawValue)"
        case .scanQueued: return "scanQueued"
        case .scanRetried: return "scanRetried"
        case .scanSucceeded: return "scanSucceeded"
        case .scanFailed: return "scanFailed"
        case .syncCompleted: return "syncCompleted"
        case .syncFailed: return "syncFailed"
        case .exportRequested: return "exportRequested"
        case .notificationOpened: return "notificationOpened"
        case .remoteConfigurationApplied: return "remoteConfigurationApplied"
        }
    }
}

/// A destination for analytics events. Implementations MUST NOT perform network
/// I/O; the type system only prevents *sensitive payloads*, not sinks, so this
/// contract is enforced by review rather than the compiler.
protocol AnalyticsSink: Sendable {
    func record(_ event: AnalyticsEvent)
}

/// Default sink: increments an in-memory + UserDefaults-backed counter per event
/// kind. Never performs network I/O. Intended for local self-diagnosis only
/// (e.g. a hidden debug screen), and is default-off — nothing in the app calls
/// into analytics unless a later wiring task opts a call site in explicitly.
final class LocalCountingSink: AnalyticsSink, @unchecked Sendable {
    static let shared = LocalCountingSink()

    private let defaults: UserDefaults
    private let suiteName = "com.pak.fuel.analytics.counters"
    private let lock = NSLock()
    private var inMemoryCounters: [String: Int] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
    }

    func record(_ event: AnalyticsEvent) {
        let key = event.countingKey
        lock.lock()
        defer { lock.unlock() }
        let next = (inMemoryCounters[key] ?? defaults.integer(forKey: key)) + 1
        inMemoryCounters[key] = next
        defaults.set(next, forKey: key)
    }

    /// Returns a snapshot of all counters recorded so far. Read-only, local-only.
    func counters() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return inMemoryCounters
    }

    /// Resets all counters, e.g. from a debug/reset-analytics control.
    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        for key in inMemoryCounters.keys {
            defaults.removeObject(forKey: key)
        }
        inMemoryCounters.removeAll()
    }
}

/// Thin façade so call sites can log through one name (`Analytics.record`) without
/// reaching for a concrete sink. Defaults to `LocalCountingSink.shared`; a later
/// wiring task may inject a different sink (still local-only) via `configure`.
enum Analytics {
    private static var sink: any AnalyticsSink = LocalCountingSink.shared

    static func configure(sink: any AnalyticsSink) {
        self.sink = sink
    }

    static func record(_ event: AnalyticsEvent) {
        sink.record(event)
    }
}
