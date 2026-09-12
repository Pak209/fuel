# Fuel Release Gates

A consolidated checklist of the gates that **cannot be closed by source code
alone** — each one requires an external account, a deployed service, a human
reviewer, or a physical device. This document collects them from
`PHASES6_9_ROADMAP.md`'s "External configuration and review gates" section,
`Backend/README.md`'s "Operational release evidence" section,
`SECURITY.md`'s "Release gates" section, and
`docs/safety/PROFESSIONAL_REVIEW_CHECKLIST.md`, and states what evidence would
actually close each one. Source configuration, simulator checks, signed device
builds, and distribution each establish different evidence. Some source
configuration is already complete, including the assigned Apple team. Use
[REMAINING_SCOPE.md](REMAINING_SCOPE.md) as the authoritative current work list;
this checklist defines the evidence still needed for external distribution.

## How to read this document

Each gate has:

- **Current status / what's missing** — the concrete external thing (account, deployment,
  human, device) that source code cannot substitute for.
- **What closes it** — the specific artifact/evidence that would let a
  reviewer sign off, per the source document it's drawn from.
- **Source** — the file where the requirement is defined, so this document
  never becomes the sole authority on a requirement it's just summarizing.

## Apple platform configuration

| Gate | Current status / remaining evidence | What closes it |
| --- | --- | --- |
| Apple Developer Team and distribution signing | Team `5YJJCSFSQM` is already assigned in all app/widget Debug, Staging, and Release configurations in `Fuel.xcodeproj/project.pbxproj`; the team-setting task is complete. This alone does not establish distribution certificate/profile availability or App Store upload readiness. | Verify current team access and the required distribution identity/profiles with a signed distribution archive and successful validation/upload. |
| Production bundle identifier | Current identifier is `com.pak.fuel` (`Fuel.xcodeproj/project.pbxproj`), fine for development but needs to be the identifier actually registered for distribution | Confirmed App Store Connect app record under the production bundle ID, matching what ships |
| App Group and HealthKit | `Fuel/Fuel.entitlements` declares `group.com.pak.fuel`, HealthKit, and HealthKit background delivery. `FuelWidgets/FuelWidgets.entitlements` declares the same App Group. Verify the distribution profiles and signed products match these capabilities; source declarations alone are not that evidence. | Matching registered app IDs/group, distribution provisioning, signed entitlements, and the physical-device HealthKit/widget checks below. |
| Sign in with Apple capability | `com.apple.developer.applesignin` is absent from the current `Fuel/Fuel.entitlements`; it was removed for the local-only v1. It is not an unused capability that still needs registering for that build. | Before the planned cloud Apple sign-in ships, restore the entitlement, enable/provision it for the app ID under team `5YJJCSFSQM`, and verify the client/server sign-in flow. |
| iCloud/CloudKit | Not applicable to the chosen custom-backend sync architecture. SwiftData remains local and `Fuel/Fuel.entitlements` has no CloudKit entitlement. | No CloudKit configuration is required by the current plan. Revisit only if the storage architecture changes. |
| Notification capabilities | The current implementation uses local notifications in `Fuel/Services/NotificationService.swift`; it has no server-push path or `aps-environment` entitlement. | Complete the physical-device notification checks below. APNs provisioning becomes a separate gate only if remote push is introduced. |

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

The local-only build can operate while the cloud gates remain open:
`CloudSyncEngine.synchronize` returns `.localOnly` whenever the backend isn't
configured (`Fuel/Services/SyncService.swift`). This is not evidence that account,
sync, or server behavior is production-ready. See
[REMAINING_SCOPE.md](REMAINING_SCOPE.md) for the outstanding account/sync work and
`docs/sync/RESTORE_AND_MIGRATION.md` for the restore design.

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

The Apple team setting is complete and the current source includes the app/widget
capability declarations described above. These establish part of the signing setup;
distribution readiness still needs its external evidence. CloudKit is not a gate
for the selected architecture; Sign in with Apple provisioning applies when the
cloud account feature is enabled. Backend deployment, human reviews, sustained
physical-device validation, and distribution acceptance still need their required
evidence. Track current completion in [REMAINING_SCOPE.md](REMAINING_SCOPE.md).
