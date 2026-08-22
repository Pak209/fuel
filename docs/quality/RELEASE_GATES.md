# Fuel Release Gates

A consolidated checklist of the gates that **cannot be closed by source code
alone** — each one requires an external account, a deployed service, a human
reviewer, or a physical device. This document collects them from
`PHASES6_9_ROADMAP.md`'s "External configuration and review gates" section,
`Backend/README.md`'s "Operational release evidence" section,
`SECURITY.md`'s "Release gates" section, and
`docs/safety/PROFESSIONAL_REVIEW_CHECKLIST.md`, and states what evidence would
actually close each one. Nothing in this repository currently satisfies any of
these gates; this is a checklist to run through before external distribution,
not a record that they've been run.

## How to read this document

Each gate has:
- **What's missing** — the concrete external thing (account, deployment,
  human, device) that source code cannot substitute for.
- **What closes it** — the specific artifact/evidence that would let a
  reviewer sign off, per the source document it's drawn from.
- **Source** — the file where the requirement is defined, so this document
  never becomes the sole authority on a requirement it's just summarizing.

## Apple platform configuration

| Gate | What's missing | What closes it |
| --- | --- | --- |
| Apple Developer Team | `DEVELOPMENT_TEAM` is empty in every build configuration (`Fuel.xcodeproj/project.pbxproj:154,188,212,235`) | A real Apple Developer Program team ID assigned to the project's code signing settings |
| Production bundle identifier | Current identifier is `com.pak.fuel` (`Fuel.xcodeproj/project.pbxproj`), fine for development but needs to be the identifier actually registered for distribution | Confirmed App Store Connect app record under the production bundle ID, matching what ships |
| App Group | `Fuel/Fuel.entitlements` already declares `group.com.pak.fuel` — the entitlement exists in source, but a App Group must still be registered under the real team in the Apple Developer portal before it resolves for a signed build | App Group registered and visible under the assigned team in the Developer portal |
| Sign in with Apple capability | `Fuel/Fuel.entitlements` declares `com.apple.developer.applesignin` — again, present in source but not provisioned without a real team | Capability enabled for the app ID under the assigned team |
| iCloud/CloudKit | Not present in `Fuel/Fuel.entitlements` at all today — the SwiftData store is a plain local `ModelConfiguration` with no CloudKit database (`Fuel/App/FuelApp.swift:11-27`) | A deliberate decision on whether Fuel ever adopts CloudKit-backed SwiftData, and if so the entitlement, container, and schema work that implies — not currently planned or wired |
| Notification capabilities | Local notification scheduling exists in code (`Fuel/Services/NotificationService.swift`), but push/remote notification entitlements are not part of this review — confirm which are actually needed before submission | Whatever this project's actual notification design requires (local-only appears sufficient today, per the client-side scheduling code — the app has no server-push code path) |

## Backend deployment

| Gate | What's missing | What closes it |
| --- | --- | --- |
| A deployed backend | No backend exists in this repository at all — `Backend/README.md` is a contract specification, explicitly stating it "is not evidence that a production service has been deployed." `BackendConfiguration.isConfigured` requires `FUEL_BACKEND_BASE_URL` (`Fuel/Services/BackendServices.swift:18-33`), which has no default | A running development/staging/production deployment reachable at a validated HTTPS origin, matching the endpoint inventory in `Backend/README.md` |
| Server-held credentials | Provider keys, Apple private keys, database credentials, webhook secrets, model credentials — none of these belong in this repository and none are present | Server-side secret management (the app injects only `FUEL_BACKEND_ENVIRONMENT` and `FUEL_BACKEND_BASE_URL`, per `Backend/README.md`'s "Environments" section) |
| Contract conformance | The client's DTOs and validation limits (`Fuel/Services/BackendServices.swift`) are the canonical contract per `Backend/README.md`, but no server implementation to test against exists | An OpenAPI spec or contract tests generated from/validated against those DTOs, per `Backend/README.md`: "Any server OpenAPI specification must be generated from or contract-tested against those DTOs before enabling staging" |
| Authorization, rate limiting, abuse detection | Required controls are specified in `Backend/README.md`'s "Required controls" section but implemented server-side, outside this repo | Passing authorization tests and rate-limit tests, per `Backend/README.md`'s "Operational release evidence" list |
| Backups and restore drills | `Backend/README.md`: "Keep automated backups, perform restore drills, define RPO/RTO" | A documented, executed restore drill with recorded RPO/RTO, not a policy statement alone |
| Retention jobs | Photo retention, export/deletion retention windows (`docs/security/PRIVACY_DATA_MAP.md`) | Running retention jobs with evidence of execution (not just code that could implement one) |
| Secret scanning / vulnerability review | `Backend/README.md`'s evidence list | A completed scan/review report for the deployed service |
| Dashboards, alerts, on-call | `Backend/README.md`'s evidence list | Actual operational tooling pointed at the live deployment |
| Staging-to-production promotion approval | `Backend/README.md`'s evidence list | A recorded approval decision, not an automatic promotion |

Client-side behavior that is already correct and does not block on the above:
`CloudSyncEngine.synchronize` returns `.localOnly` whenever the backend isn't
configured (`Fuel/Services/SyncService.swift:59`), so the app degrades safely
in the absence of all of this — see `docs/sync/RESTORE_AND_MIGRATION.md` for
the full behavior of sync while unconfigured or partially configured.

## Human review

| Gate | What's missing | What closes it |
| --- | --- | --- |
| Qualified nutrition-professional review | No registered dietitian or licensed nutrition professional has reviewed the product per `docs/safety/PROFESSIONAL_REVIEW_CHECKLIST.md`'s scope (calorie targets, macro/hydration/step/sleep defaults, pregnancy/minors/medical-condition handling, allergy exclusion limits, health-score formulas, recommendation logic, wording review, escalation language) | The exact evidence list in `docs/safety/PROFESSIONAL_REVIEW_CHECKLIST.md`: reviewer name/qualification/jurisdiction/date, source version/commit reviewed, formula/rule inventory, findings with severity and disposition, explicit approval or remaining blockers, and a re-review trigger. That document states plainly: "It must not be marked complete based only on engineering tests." |
| Human security review before external TestFlight | `SECURITY.md`'s "Release gates" section requires this explicitly, and `docs/security/THREAT_MODEL.md` and this repository's own severity calibration are inputs to that review, not a substitute for a human doing it | A completed internal security review report with all critical/high findings resolved and medium findings explicitly dispositioned, dated before the first external TestFlight build |
| Human security review before public release | `SECURITY.md`: "Repeat the review before public release and after material changes to authentication, sync, image processing, export, or deletion" | A second, later review report, especially if any of those five areas changed since the TestFlight review |

## Physical-device validation

| Gate | What's missing | What closes it |
| --- | --- | --- |
| HealthKit on a real device | HealthKit authorization, background delivery (`com.apple.developer.healthkit.background-delivery` in `Fuel/Fuel.entitlements`), and real Health app data have simulator limitations (the simulator can seed synthetic HealthKit data but doesn't reproduce real authorization prompts, background delivery timing, or a real Health app history) | A test pass on a physical device signed into a real (or deliberately populated test) Health account |
| Notifications | Local notification delivery, actions (`Fuel/System/AppRouting.swift`'s notification categories), and quiet-hours/timezone scheduling behave differently under real device sleep/background states than in the simulator | A physical-device pass exercising scheduled, delivered, and actioned notifications across an app-backgrounded state |
| Widgets | WidgetKit timeline refresh behavior, especially battery-driven throttling, is not fully representative in the simulator | A physical-device pass observing widget refresh cadence over real time, not simulator-forced refreshes |
| Background behavior | Background App Refresh windows, background URL sessions, and iOS's actual scheduling of background work (as opposed to the simulator's more permissive behavior) | A physical-device pass with Background App Refresh in its default (not always-on developer) state |
| Battery | Any claim about the app's battery impact (relevant given HealthKit background delivery, MetricKit collection, and sync retry timers) | Real device battery measurement, not a simulator estimate |
| Data Protection | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` Keychain semantics (`Fuel/Services/BackendServices.swift:136`) and file protection levels (`Fuel/System/MetricsCollector.swift`'s `.completeUntilFirstUserAuthentication` directory attribute) behave identically in the simulator for most purposes, but lock-state transitions and first-unlock timing are only fully representative on a physical device | A physical-device pass confirming Keychain/file access behaves as expected across a lock/unlock cycle, ideally after a reboot |

See `docs/quality/PERFORMANCE_AUDIT.md`'s runbook for the closest available
simulator-based substitute (cold-launch and scrolling traces on the iPhone 16
simulator) — that runbook is explicit that it is not a replacement for this
physical-device gate, only a useful precursor to it.

## Cross-references

- `SECURITY.md` — security invariants, reporting process, and the release-gate
  policy summarized above.
- `docs/security/THREAT_MODEL.md` — the threat model and severity calibration
  that the human security review (above) evaluates against.
- `docs/safety/PROFESSIONAL_REVIEW_CHECKLIST.md` — the full scope and
  required evidence format for the nutrition-professional review gate.
- `Backend/README.md` — the backend contract, required controls, and
  operational release evidence list referenced throughout the "Backend
  deployment" section above.
- `docs/security/PRIVACY_DATA_MAP.md` — retention and data-transfer specifics
  that inform both the backend and physical-device gates.
- `docs/sync/RESTORE_AND_MIGRATION.md` — what sync/restore behavior is
  actually enabled by (or blocked on) the backend-deployment gate.
- `docs/quality/PERFORMANCE_AUDIT.md` and `docs/quality/ACCESSIBILITY_AUDIT.md`
  — code-first passes that reduce, but do not close, the physical-device
  validation gate.
- `PHASES6_9_ROADMAP.md` — the original source of the external-gate list this
  document expands on, plus the full Phase 6-9 feature checklist these gates
  sit alongside.

## Status

No gate in this document is closed as of this writing. This is expected at
this stage of the project — the roadmap and threat model were written
precisely to make that explicit rather than implying completeness. Treat this
document as a checklist to work through, not a report of work already done.
