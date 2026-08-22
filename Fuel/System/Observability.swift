import Foundation
import OSLog

/// Unified logging and signposting façade for Fuel.
///
/// Privacy posture: every logger in this file shares the `com.pak.fuel` subsystem so
/// logs can be filtered consistently in Console/sysdiagnose, but none of it ships
/// anywhere off-device — os_log output stays local unless a developer explicitly
/// collects a sysdiagnose. The public error-logging helper only ever emits the
/// *type name* of an error at `.public` privacy; the underlying description (which
/// may include user-entered text, URLs, or other free-form content) is always
/// logged at `.private` so it is redacted in release builds unless the device has
/// been explicitly unlocked for logging. Free-form string helpers default to
/// `.private` for the same reason. This file has no dependencies beyond
/// Foundation/OSLog so existing services can adopt it incrementally.
enum Observability {
    /// Logical categories used across the app. Keeping this as an enum (rather than
    /// ad hoc strings) prevents category-name drift between call sites.
    enum Category: String {
        case app
        case backend
        case sync
        case data
        case ui
    }

    private static let subsystem = "com.pak.fuel"

    /// Returns the shared `Logger` for a category. Cheap to call repeatedly —
    /// `Logger` is a lightweight value type over os_log.
    static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Logs an error while redacting anything that might be sensitive.
    ///
    /// Only the error's type name is logged at `.public` privacy. The full
    /// description is logged at `.private` privacy so it is redacted in release
    /// logs by default, while still being available for local on-device debugging.
    static func log(_ error: Error, category: Category, message: String = "", file: String = #fileID, line: Int = #line) {
        let log = logger(category)
        let typeName = String(describing: type(of: error))
        if message.isEmpty {
            log.error("[\(file, privacy: .public):\(line, privacy: .public)] error type=\(typeName, privacy: .public) detail=\(String(describing: error), privacy: .private)")
        } else {
            log.error("[\(file, privacy: .public):\(line, privacy: .public)] \(message, privacy: .private) type=\(typeName, privacy: .public) detail=\(String(describing: error), privacy: .private)")
        }
    }

    /// Logs a free-form debug/info string. Defaults to `.private` since the caller
    /// may pass user-entered content; pass pre-vetted, non-sensitive text only if
    /// you intend it to be readable in release logs, and prefer the `Logger` APIs
    /// directly with explicit privacy annotations in that case.
    static func log(_ message: String, category: Category, level: OSLogType = .debug) {
        logger(category).log(level: level, "\(message, privacy: .private)")
    }
}

/// Interval signposting for performance-sensitive code paths (cold launch, snapshot
/// rebuilds, image processing, etc). Wraps `OSSignposter` with named helpers so call
/// sites don't need to manage signpost IDs manually. No data collected here leaves
/// the device — signposts are consumed locally via Instruments.
enum FuelSignpost {
    /// Named signpost intervals used across the app. Add new cases here rather than
    /// constructing ad hoc name strings, so Instruments traces stay consistent.
    enum Interval: String {
        case coldLaunch = "ColdLaunch"
        case snapshotRebuild = "SnapshotRebuild"
        case imageProcessing = "ImageProcessing"
    }

    private static let signposter = OSSignposter(subsystem: "com.pak.fuel", category: "Performance")

    /// A handle returned by `begin` that must be passed to `end` to close the interval.
    struct Token {
        fileprivate let state: OSSignpostIntervalState
        fileprivate let name: StaticString
    }

    private static func staticName(for interval: Interval) -> StaticString {
        switch interval {
        case .coldLaunch: return "ColdLaunch"
        case .snapshotRebuild: return "SnapshotRebuild"
        case .imageProcessing: return "ImageProcessing"
        }
    }

    static func begin(_ interval: Interval) -> Token {
        let name = staticName(for: interval)
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        return Token(state: state, name: name)
    }

    static func end(_ token: Token) {
        signposter.endInterval(token.name, token.state)
    }

    /// Convenience wrapper that measures a synchronous block.
    @discardableResult
    static func measure<T>(_ interval: Interval, _ body: () throws -> T) rethrows -> T {
        let token = begin(interval)
        defer { end(token) }
        return try body()
    }

    /// Convenience wrapper that measures an asynchronous block.
    @discardableResult
    static func measure<T>(_ interval: Interval, _ body: () async throws -> T) async rethrows -> T {
        let token = begin(interval)
        defer { end(token) }
        return try await body()
    }
}
