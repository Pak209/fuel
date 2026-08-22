# Fuel Analytics Event Taxonomy

Fuel ships with **zero analytics by design** — the in-app copy in
`Fuel/Features/Profile/ProfileView.swift:575` states this directly: "Fuel does
not include advertising analytics or embedded provider secrets." This document
describes the local, non-sensitive counting mechanism defined in
`Fuel/System/Analytics.swift`, which exists so that *if* on-device usage
counting is ever turned on (for self-diagnosis or a hidden debug screen), it is
architecturally incapable of carrying anything sensitive — and describes
exactly how far that mechanism is wired into the app today.

## Current wiring status

The `AnalyticsEvent` enum, `AnalyticsSink` protocol, `LocalCountingSink`, and
the `Analytics` façade all exist in `Fuel/System/Analytics.swift`. As of this
writing, no other file in the app calls `Analytics.record(...)` or
`Analytics.configure(sink:)` — a repository-wide search for those call sites
turns up only their own definitions. `PHASES6_9_ROADMAP.md:115` still lists
"Non-sensitive analytics event taxonomy" as unchecked. So the accurate
description is: **the taxonomy and its enforcement mechanism are implemented,
but no call site in the app currently records an event.** Wiring call sites in
(Scan, meal logging, sync, etc.) and checking that roadmap item off are
separate follow-up work, not something this document should claim is already
done.

The feature is also gated off by default independent of wiring: `FeatureFlag.analyticsCollectionEnabled`
(`Fuel/System/FeatureFlags.swift:22`) defaults to `false`
(`Fuel/System/FeatureFlags.swift:36`), and its `remotePolicy` is `.tightenOnly(permissiveValue: true)`
(`Fuel/System/FeatureFlags.swift:52`) — a remote configuration can only turn it
further off, never on; only a local, explicit opt-in (a debug override via
`FeatureFlagStore`, per `Fuel/System/FeatureFlags.swift:86-92`) can enable it.

## Principles

These are enforced by the type system, not just by convention, per the header
comment in `Fuel/System/Analytics.swift:1-13`:

- **No health values.** `AnalyticsEvent` cases never carry nutrition amounts,
  meal names, weights, HealthKit values, or any other wellness content — only
  counts, small closed enums, and booleans.
- **No free text.** There is no `String`-typed associated value anywhere in
  the enum (`AnalyticsEvent.Source` is a closed `String`-backed enum used only
  for its fixed cases, never as free text passed through). This makes leaking
  arbitrary text through this pipe a compile error, not a review miss.
- **Local-only.** `AnalyticsSink` is a protocol with no network-capable
  implementation in the codebase; the only shipped conformer,
  `LocalCountingSink` (`Fuel/System/Analytics.swift:71-102`), writes integer
  counters to a dedicated `UserDefaults` suite
  (`com.pak.fuel.analytics.counters`) and nowhere else. The protocol doc
  comment is explicit that this is enforced by review, not by the compiler,
  for future sink implementations: "Implementations MUST NOT perform network
  I/O; the type system only prevents *sensitive payloads*, not sinks."
- **Default off.** Gated behind `FeatureFlag.analyticsCollectionEnabled`,
  defaulting to `false` and tighten-only remotely (see above) — no build ships
  with this silently turned on by a server-side flag flip.
- **Unrepresentable by construction.** The associated-value types allowed in
  `AnalyticsEvent` are restricted to other closed enums (`Source`), `Bool`,
  and `Int` (`Fuel/System/Analytics.swift:26-37`). A future contributor cannot
  accidentally add a case that carries a meal name or note without changing
  the enum's shape in a way code review would have to see.

## Event list

| Event | Associated data | Allowed metadata types | Purpose |
| --- | --- | --- | --- |
| `appLaunched` | none | — | Coarse usage cadence |
| `mealLogged(source:)` | `Source` | closed enum (`photoScan`, `manualEntry`, `pendingRetry`, `quickAdd`, `widget`, `siriShortcut`) | Which entry point produced a logged meal, for funnel counting — never the meal itself |
| `waterLogged(source:)` | `Source` | closed enum (same `Source` cases) | Same, for hydration entries |
| `scanQueued` | none | — | A photo scan was queued for recognition |
| `scanRetried(attempt:)` | `Int` | bounded integer (retry attempt number) | Retry funnel visibility |
| `scanSucceeded` | none | — | Recognition completed |
| `scanFailed` | none | — | Recognition failed (no error text, no image data) |
| `syncCompleted(operationCount:)` | `Int` | count of operations in the batch | Sync health, not content |
| `syncFailed` | none | — | Sync attempt failed (no error text carried) |
| `exportRequested` | none | — | A person requested a data export |
| `notificationOpened` | none | — | A local notification was tapped |
| `remoteConfigurationApplied(flagCount:)` | `Int` | count of flags applied | Remote-config adoption visibility, not which flags |

Each case maps to a stable `countingKey` string
(`Fuel/System/Analytics.swift:42-57`) used as the counter dictionary key.
Associated numeric/enum values are deliberately excluded from the key itself
(e.g. `scanRetried` always keys as `"scanRetried"` regardless of attempt
number) "so the counter dictionary stays small and bounded regardless of
magnitude" (`Fuel/System/Analytics.swift:39-41`) — this also means an
attacker or bug cannot use unbounded attempt numbers to grow the key space.

`LocalCountingSink.counters()` exposes a read-only snapshot for a future
debug/self-diagnosis screen; `resetAll()` clears everything. Neither method is
currently wired to any UI in the app.

## Review rule for adding events

Anyone proposing a new `AnalyticsEvent` case must satisfy all of the following
before it merges, mirroring `SECURITY.md`'s invariant that "Analytics and
diagnostics must exclude meal names, photos, nutrients, HealthKit values,
account identifiers, tokens, and free-form notes":

1. **No `String` associated value**, ever — not even a "short reason code" or
   "category name" typed as `String`. If a case needs a fixed small set of
   labels, add a closed `enum` (like `Source`) with explicit, reviewed cases,
   the same way `mealLogged`/`waterLogged` do.
2. **No identifiers.** No UUIDs, account hashes, Apple user identifiers, or
   anything that could correlate a specific person's events across sessions
   beyond the on-device counters themselves.
3. **No amounts derived from health/nutrition content** (calories, grams,
   milliliters, HealthKit values, scores). Counting an *action having
   happened* is fine; carrying *what the action was about* is not.
4. **Justify the associated value's bound.** Any `Int` case must have an
   obviously bounded, reviewer-checkable range (e.g. a retry-attempt counter
   capped by `DailyDataCoordinator.maxRetryAttempts`,
   `Fuel/Services/DailySummaryService.swift:73`) — unbounded integers are a
   smell even though they can't carry free text.
5. **Confirm the event is reachable only through `Analytics.record`**, never
   logged directly to `OSLog`/`Observability` with additional context spliced
   in at the call site — the enforcement in this file only holds if call
   sites don't route around it.
6. **Confirm no sink implementation added alongside the event performs network
   I/O.** `AnalyticsSink` conformers are reviewed by eye, not the compiler —
   a new sink is exactly the place a well-meaning "let's also send this to our
   backend for product analytics" regression would land, and it must not.
7. **Update this document** (event table above) in the same change that adds
   the case, so the table never drifts from `Fuel/System/Analytics.swift`.

Cross-reference: `docs/security/PRIVACY_DATA_MAP.md`'s "Diagnostic events and
MetricKit payload summaries" row makes the same no-health-content promise for
the separate `MetricsCollector` (`Fuel/System/MetricsCollector.swift`)
MetricKit boundary, which is unrelated code but held to an equivalent
standard — MetricKit payloads are Apple-aggregated device metrics
(battery, hangs, launch time, crash diagnostics), never app-defined events,
and are never transmitted off-device by that file either.
