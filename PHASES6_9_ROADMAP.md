# Fuel Phases 6–9 Acceptance Matrix

This document tracks the recovered product roadmap for daily engagement, backend/sync, privacy/security/safety, and quality/reliability. A checked item requires both implementation and verification. Items that depend on external accounts, deployed infrastructure, or qualified professional review are called out explicitly rather than represented as complete by a placeholder.

> Historical phase acceptance matrix. Checks below describe client implementation
> and earlier simulator evidence, not production completeness. Current defects,
> verification, and remaining backend/account/device/release work are tracked in
> `docs/quality/REMAINING_SCOPE.md`. Do not treat a documented strategy or a mock
> transport test as proof of cloud restore, safe account switching, or deployment.

Verification evidence for checked items: unit suite (115 tests, 7 suites) and UI-test suite passing on the iPhone 16 simulator (iOS 26.5), Debug/Staging/Release builds, and an unsigned Release archive whose bundle was inspected for icon, launch screen, URL scheme, privacy manifest, and compliance keys. See `docs/quality/APP_STORE_READINESS.md` and `docs/quality/TESTFLIGHT_PLAN.md` for the path from here to TestFlight.

## Phase 6 — Daily engagement

### Notifications

- [x] Contextual notification permission request
- [x] Meal, hydration, daily-review, weekly-summary, HealthKit-issue, and restrained goal-progress reminders
- [x] Per-reminder controls and editable schedules (per-meal hours, daily-review hour, weekly-summary day and hour, hydration interval; goal-progress time is a fixed quiet-hours-clamped default)
- [x] Quiet-hours enforcement and local time-zone scheduling (HealthKit-issue alerts defer past quiet hours; reschedules on system time-zone change)
- [x] Supportive, non-shaming copy (asserted by tests)
- [x] Notification actions and deep links to the relevant app destination (`fuel://` scheme registered in Info.plist)
- [x] Deterministic scheduling tests

### Widgets, shortcuts, and quick actions

- [x] Home/Lock Screen health-summary widget
- [x] Remaining calorie/protein widget content
- [x] Hydration quick-add action
- [x] “Log meal” App Shortcut
- [x] “Add water” App Intent
- [x] Spotlight/Shortcuts discoverability (App Shortcuts provider plus Core Spotlight indexing of meals with deep-link handoff)
- [x] Photo-scan home-screen quick action (static Info.plist item; ships as photo picker — no live camera in v1, and all copy says so)
- [x] Widget/App Intent runtime handoff verification (app-group queue drained on cold start, refresh, and warm foreground; idempotent by command ID)

### Offline behavior

- [x] Existing meals and summaries remain available offline
- [x] Manual meal logging remains available offline
- [x] Failed photo scans can be saved durably as pending work
- [x] Pending recognition retries safely when connectivity returns
- [x] Visible pending/failed/synchronized state
- [x] Idempotency prevents duplicate processing
- [x] Edits and queued work survive process termination (interrupted `.processing`/`.uploading` records reconciled to `.pending` on launch)

## Phase 7 — Backend and sync

### Backend service boundary

- [x] Typed contracts for authentication, profile, recognition upload/status, nutrition proxy, meal sync, recommendations, export, deletion, and entitlement webhooks (entitlement webhooks are server-side by design and specified in `Backend/README.md`)
- [x] Authenticated transport, input/output validation, idempotency, bounded retry, cancellation, and request timeouts
- [x] Client-side redacted structured logging with no bundled secrets
- [x] Development, staging, and production environment configuration (`Config/*.xcconfig` wired to Debug/Staging/Release; environment lands in the built Info.plist)
- [x] Server deployment requirements documented: authorization, rate limits, abuse controls, backups, retention, secret management, and observability

### Account and cloud continuity

- [x] Local-only use remains available without an account
- [x] Sign in with Apple client flow and secure credential storage (implemented; hidden in v1 builds until a backend is configured, and the entitlement is removed until then — see `docs/quality/TESTFLIGHT_PLAN.md`)
- [x] Durable offline sync queue with operation state and retry metadata (bounded attempts with terminal failure state)
- [x] Conflict-resolution rules and source revision tracking
- [x] Reinstall/restore and account-migration strategy documented (`docs/sync/RESTORE_AND_MIGRATION.md`; empty-queue pull is now implemented client-side, but account isolation and live restore remain open)
- [x] Account export and deletion client flows
- [x] Health data excluded from sync unless required and explicitly enabled (never synced; entity-type allowlist asserted by tests)
- [x] Live cloud sync remains disabled until a reviewed backend/container and Apple credentials are configured

## Phase 8 — Privacy, safety, and security

### Privacy engineering

- [x] Data inventory records purpose, storage, network transfer, retention, access, export, and deletion
- [x] Privacy manifest included and validated (ships in app and widget bundles; declares UserDefaults and file-timestamp API use; collected-data types empty, matching local-only v1)
- [x] Meal-photo retention controls documented and enforced (consent preference, deletion with the owning meal, and an orphan purge with a grace window)
- [x] Export covers user-created local records; deletion covers local and configured remote accounts
- [x] Sensitive values are redacted from logs and analytics
- [x] Health details are excluded from analytics (closed event taxonomy cannot represent health values or free text)
- [x] Local files use Data Protection; credentials use Keychain
- [x] No production secrets are embedded in the bundle

### Security review

- [x] Repository-scoped threat model
- [x] Security policy and reporting guidance
- [x] Review of meal images, auth tokens, health data, authorization, malicious payloads, AI structured output, sync conflicts, exports, and deletion
- [x] Security regression tests for URL validation, token storage boundaries, payload size/type validation, and idempotency
- [x] External TestFlight security gate documented (the human review itself remains outstanding — see `docs/quality/RELEASE_GATES.md`)
- [x] Pre-release security gate documented (the human review itself remains outstanding)

### Health and nutrition safety

- [x] General-wellness positioning and limitation language throughout product
- [x] Hard allergy/dietary exclusions retained in recommendations
- [x] Conservative goal constraints and eating-disorder-sensitive copy (including a clamp on rapid calorie-target lowering)
- [x] Pregnancy, specialized-diet, and medical-condition escalation language (onboarding goals step, plus state-aware escalation next to weight-loss goal controls)
- [x] Professional-review checklist for targets, scoring, calorie deficit, allergy logic, and recommendation rules
- [ ] Qualified nutrition review remains a required external release gate — **not performed; requires a qualified professional** (`docs/safety/PROFESSIONAL_REVIEW_CHECKLIST.md`)

## Phase 9 — Quality and reliability

### Automated testing

- [x] Expanded unit tests for notification scheduling, routing, sync/idempotency, configuration, security validation, and new migrations
- [x] Integration tests for pending recognition retry, account sync, remote deletion/export, and shortcut hydration writes (mock-transport integration in the unit suite)
- [x] UI-test target covering onboarding, logging/editing, filtering, permission states, notifications, export/deletion, compact layouts, and Dynamic Type (accessibility-size runs stand in for compact layouts; iPhone-only app)
- [x] All existing and new tests pass in the iPhone 16 simulator

### Accessibility

- [x] VoiceOver order and combined metric labels audited (`docs/quality/ACCESSIBILITY_AUDIT.md`)
- [x] Charts retain nonvisual summaries and color-independent meaning (including an Audio Graph chart descriptor)
- [x] Contrast, Dynamic Type, Reduce Motion, hit targets, keyboard/Switch Control, and validation announcements audited (Switch Control/keyboard verified by code audit only; on-device pass remains an external gate)
- [x] Accessibility-size layouts verified in simulator (automated accessibility-size UI tests)

### Performance and resilience

- [x] Code-first SwiftUI performance audit completed (`docs/quality/PERFORMANCE_AUDIT.md`)
- [ ] Cold launch and representative scrolling/runtime trace captured (simulator capture in progress at time of writing; runbook in `docs/quality/PERFORMANCE_AUDIT.md`, device traces remain an external gate)
- [x] Image decode/downsampling and memory behavior verified (Core Graphics thumbnail paths on both recognition and display; verified in code and covered by tests)
- [x] SwiftData query/recomputation and HealthKit refresh frequency reviewed
- [x] Network retry and background work bounded (attempt caps and backoff ceilings on both queues; bounded HTTP retry)
- [x] Unified privacy-safe logging and signposts
- [x] Crash/diagnostic collection boundary using Apple MetricKit (local-only, capped storage, no network)
- [x] Non-sensitive analytics event taxonomy (closed enum, local counting sink only, off by default)
- [x] Local feature flags and validated remote-configuration boundary
- [x] Debug and Release simulator builds pass (plus Staging, and an unsigned Release archive)

## External configuration and review gates

These gates cannot be truthfully completed by source code alone:

- Apple Developer Team, production bundle ID, App Group, Sign in with Apple, iCloud/CloudKit, and notification capabilities
- A deployed backend with development/staging/production URLs and server-held credentials
- Backend database, backups, retention jobs, rate limits, abuse controls, and operational monitoring
- Qualified nutrition-professional review
- Human security review before external TestFlight and again before public release
- Physical-device validation for HealthKit, notifications, widgets, background behavior, battery, and Data Protection

See `docs/quality/RELEASE_GATES.md` for what evidence closes each gate, and `docs/quality/TESTFLIGHT_PLAN.md` for the ordered path to a TestFlight build.
