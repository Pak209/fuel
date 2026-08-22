import Foundation

/// Local feature-flag registry.
///
/// Privacy posture: flag values themselves carry no user data — they are booleans
/// describing which pieces of app behavior are turned on. Defaults are chosen to be
/// privacy-safe (cloud sync and remote configuration are off until something local
/// and explicit turns them on). This file makes no network calls; the only network
/// fetch of a `RemoteFeatureConfiguration` happens in `BackendServices`, and this
/// file's `RemoteFeatureConfigurationValidator` only *sanitizes* a value that was
/// already fetched elsewhere — it never fetches anything itself.
enum FeatureFlag: String, CaseIterable, Sendable {
    /// Whether the app is allowed to sync data to Fuel's backend at all.
    case cloudSyncAllowed
    /// Whether the app is allowed to fetch and apply `RemoteFeatureConfiguration`.
    case remoteConfigAllowed
    /// Whether audio-reactive/decorative graphs are enabled (purely cosmetic).
    case audioGraphsEnabled
    /// Whether MetricKit payloads are collected into local storage at all.
    case metricKitCollectionEnabled
    /// Whether local, non-sensitive usage counting (`Analytics`) is enabled.
    case analyticsCollectionEnabled
    /// Whether haptic feedback is enabled for interactive controls.
    case hapticsEnabled
    /// Whether pending scans are automatically retried in the background.
    case pendingScanAutoRetryEnabled

    /// The value the app ships with before any local override or remote
    /// configuration is applied.
    var defaultValue: Bool {
        switch self {
        case .cloudSyncAllowed: return false
        case .remoteConfigAllowed: return false
        case .audioGraphsEnabled: return true
        case .metricKitCollectionEnabled: return false
        case .analyticsCollectionEnabled: return false
        case .hapticsEnabled: return true
        case .pendingScanAutoRetryEnabled: return true
        }
    }

    /// How a remotely-fetched configuration is allowed to influence this flag.
    /// This is the enforcement point for "remote can only tighten or toggle known
    /// flags": flags that gate privacy-sensitive capability can only ever be
    /// *narrowed* by the network, never *widened*, and some can't be touched by
    /// the network at all.
    var remotePolicy: RemoteMutability {
        switch self {
        case .cloudSyncAllowed: return .tightenOnly(permissiveValue: true)
        case .remoteConfigAllowed: return .fixed
        case .metricKitCollectionEnabled: return .tightenOnly(permissiveValue: true)
        case .analyticsCollectionEnabled: return .tightenOnly(permissiveValue: true)
        case .audioGraphsEnabled, .hapticsEnabled, .pendingScanAutoRetryEnabled:
            return .freelyToggleable
        }
    }

    enum RemoteMutability: Equatable, Sendable {
        /// Remote configuration cannot change this flag under any circumstances;
        /// only the local default or a local debug override applies.
        case fixed
        /// Remote configuration may only move the flag away from `permissiveValue`
        /// (i.e. it can disable a capability, never enable one the app didn't
        /// already allow locally).
        case tightenOnly(permissiveValue: Bool)
        /// Remote configuration may set this flag to either value.
        case freelyToggleable
    }
}

/// Local, debug-only override store backed by a dedicated `UserDefaults` suite so
/// overrides never bleed into the app's standard defaults and are trivial to wipe.
final class FeatureFlagStore: @unchecked Sendable {
    static let shared = FeatureFlagStore()

    private static let suiteName = "com.pak.fuel.featureflags.debug"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    /// Explicit local override, if any (e.g. set from a hidden debug menu).
    /// Returns `nil` when no override has been set, in which case the flag's
    /// default (optionally narrowed by remote configuration) applies.
    func override(for flag: FeatureFlag) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let key = key(for: flag)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    func setOverride(_ value: Bool?, for flag: FeatureFlag) {
        lock.lock()
        defer { lock.unlock() }
        let key = key(for: flag)
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func clearAllOverrides() {
        lock.lock()
        defer { lock.unlock() }
        for flag in FeatureFlag.allCases {
            defaults.removeObject(forKey: key(for: flag))
        }
    }

    private func key(for flag: FeatureFlag) -> String { "override.\(flag.rawValue)" }

    /// Resolves a flag's effective value: local debug override wins if present,
    /// otherwise a validated remote value (if supplied and allowed by policy),
    /// otherwise the compiled-in default.
    func resolvedValue(for flag: FeatureFlag, remoteFlags: [FeatureFlag: Bool] = [:]) -> Bool {
        if let override = override(for: flag) { return override }
        if let remoteValue = remoteFlags[flag] {
            return RemoteFeatureConfigurationValidator.applying(remoteValue, to: flag)
        }
        return flag.defaultValue
    }
}

/// Validates and sanitizes a `RemoteFeatureConfiguration` (defined in
/// `BackendServices.swift`) before any of its values are allowed to influence
/// local behavior. This is a pure function over already-fetched data — it
/// performs no I/O of its own.
enum RemoteFeatureConfigurationValidator {
    /// Schema versions this build knows how to interpret. A remote payload with an
    /// unrecognized schema version is rejected outright rather than partially
    /// applied, since the meaning of its fields may have changed.
    static let supportedSchemaVersions: ClosedRange<Int> = 1...1

    /// Reasonable bounds for `scoringAlgorithmVersion`; anything outside this is
    /// treated as malformed rather than trusted.
    static let scoringAlgorithmVersionRange: ClosedRange<Int> = 1...1_000

    enum ValidationFailure: Equatable, Sendable {
        case unsupportedSchemaVersion(Int)
        case expired
        case appVersionTooOld(minimumRequired: String)
        case scoringAlgorithmVersionOutOfRange(Int)
    }

    /// Wraps every reason a payload was rejected wholesale. A plain `[ValidationFailure]`
    /// can't be used directly as `Result`'s failure type since arrays don't conform
    /// to `Error`.
    struct RejectionReasons: Error, Equatable, Sendable {
        let failures: [ValidationFailure]
    }

    struct ValidatedConfiguration: Sendable {
        /// Only flags that are (a) recognized locally and (b) permitted by that
        /// flag's `remotePolicy` to move in the requested direction. Unknown keys
        /// in the original payload are silently ignored.
        let flags: [FeatureFlag: Bool]
        let scoringAlgorithmVersion: Int
    }

    /// Validates `configuration` against the running app's version and this
    /// build's known schema/range bounds. Returns `.failure` with every reason the
    /// payload was rejected wholesale (expired, unsupported schema, app too old),
    /// or `.success` with a sanitized flag set (individual unknown or
    /// policy-violating flags are dropped rather than causing outright failure).
    static func validate(
        _ configuration: RemoteFeatureConfiguration,
        currentAppVersion: String = currentBundleShortVersion(),
        now: Date = .now
    ) -> Result<ValidatedConfiguration, RejectionReasons> {
        var failures: [ValidationFailure] = []

        guard supportedSchemaVersions.contains(configuration.schemaVersion) else {
            failures.append(.unsupportedSchemaVersion(configuration.schemaVersion))
            return .failure(RejectionReasons(failures: failures))
        }

        if configuration.expiresAt <= now {
            failures.append(.expired)
        }

        if compareVersions(currentAppVersion, isOlderThan: configuration.minimumAppVersion) {
            failures.append(.appVersionTooOld(minimumRequired: configuration.minimumAppVersion))
        }

        var scoringVersion = configuration.scoringAlgorithmVersion
        if !scoringAlgorithmVersionRange.contains(configuration.scoringAlgorithmVersion) {
            failures.append(.scoringAlgorithmVersionOutOfRange(configuration.scoringAlgorithmVersion))
            scoringVersion = scoringAlgorithmVersionRange.lowerBound
        }

        guard failures.isEmpty else { return .failure(RejectionReasons(failures: failures)) }

        var sanitizedFlags: [FeatureFlag: Bool] = [:]
        for (key, requestedValue) in configuration.enabledFlags {
            // Unknown keys are ignored rather than surfaced as an error: forward
            // compatibility with future flags a backend might send to older clients.
            guard let flag = FeatureFlag(rawValue: key) else { continue }
            switch flag.remotePolicy {
            case .fixed:
                continue
            case .freelyToggleable:
                sanitizedFlags[flag] = requestedValue
            case .tightenOnly(let permissiveValue):
                // Only accept the value if it narrows (or matches) the flag's
                // permitted state; never let remote data grant the permissive value.
                if requestedValue != permissiveValue {
                    sanitizedFlags[flag] = requestedValue
                }
            }
        }

        return .success(ValidatedConfiguration(flags: sanitizedFlags, scoringAlgorithmVersion: scoringVersion))
    }

    /// Applies a single already-fetched remote value to `flag`, re-checking the
    /// flag's policy so callers cannot accidentally bypass tighten-only semantics
    /// by constructing a `[FeatureFlag: Bool]` by hand.
    static func applying(_ remoteValue: Bool, to flag: FeatureFlag) -> Bool {
        switch flag.remotePolicy {
        case .fixed:
            return flag.defaultValue
        case .freelyToggleable:
            return remoteValue
        case .tightenOnly(let permissiveValue):
            return remoteValue == permissiveValue ? flag.defaultValue : remoteValue
        }
    }

    static func currentBundleShortVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Simple dotted-numeric version comparison (e.g. "1.4.2" vs "1.10.0").
    /// Missing components are treated as `0`. Non-numeric components compare as
    /// `0` so malformed strings fail closed (never mistaken for "new enough").
    static func compareVersions(_ current: String, isOlderThan minimum: String) -> Bool {
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        let minimumParts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(currentParts.count, minimumParts.count)
        for index in 0..<count {
            let currentValue = index < currentParts.count ? currentParts[index] : 0
            let minimumValue = index < minimumParts.count ? minimumParts[index] : 0
            if currentValue != minimumValue {
                return currentValue < minimumValue
            }
        }
        return false
    }
}
