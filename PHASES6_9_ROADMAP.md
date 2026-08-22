# Fuel Phases 6–9 Acceptance Matrix

This document tracks the recovered product roadmap for daily engagement, backend/sync, privacy/security/safety, and quality/reliability. A checked item requires both implementation and verification. Items that depend on external accounts, deployed infrastructure, or qualified professional review are called out explicitly rather than represented as complete by a placeholder.

## Phase 6 — Daily engagement

### Notifications

- [ ] Contextual notification permission request
- [ ] Meal, hydration, daily-review, weekly-summary, HealthKit-issue, and restrained goal-progress reminders
- [ ] Per-reminder controls and editable schedules
- [ ] Quiet-hours enforcement and local time-zone scheduling
- [ ] Supportive, non-shaming copy
- [ ] Notification actions and deep links to the relevant app destination
- [ ] Deterministic scheduling tests

### Widgets, shortcuts, and quick actions

- [ ] Home/Lock Screen health-summary widget
- [ ] Remaining calorie/protein widget content
- [ ] Hydration quick-add action
- [ ] “Log meal” App Shortcut
- [ ] “Add water” App Intent
- [ ] Spotlight/Shortcuts discoverability
- [ ] Camera home-screen quick action
- [ ] Widget/App Intent runtime handoff verification

### Offline behavior

- [ ] Existing meals and summaries remain available offline
- [ ] Manual meal logging remains available offline
- [ ] Failed photo scans can be saved durably as pending work
- [ ] Pending recognition retries safely when connectivity returns
- [ ] Visible pending/failed/synchronized state
- [ ] Idempotency prevents duplicate processing
- [ ] Edits and queued work survive process termination

## Phase 7 — Backend and sync

### Backend service boundary

- [ ] Typed contracts for authentication, profile, recognition upload/status, nutrition proxy, meal sync, recommendations, export, deletion, and entitlement webhooks
- [ ] Authenticated transport, input/output validation, idempotency, bounded retry, cancellation, and request timeouts
- [ ] Client-side redacted structured logging with no bundled secrets
- [ ] Development, staging, and production environment configuration
- [ ] Server deployment requirements documented: authorization, rate limits, abuse controls, backups, retention, secret management, and observability

### Account and cloud continuity

- [ ] Local-only use remains available without an account
- [ ] Sign in with Apple client flow and secure credential storage
- [ ] Durable offline sync queue with operation state and retry metadata
- [ ] Conflict-resolution rules and source revision tracking
- [ ] Reinstall/restore and account-migration strategy documented
- [ ] Account export and deletion client flows
- [ ] Health data excluded from sync unless required and explicitly enabled
- [ ] Live cloud sync remains disabled until a reviewed backend/container and Apple credentials are configured

## Phase 8 — Privacy, safety, and security

### Privacy engineering

- [ ] Data inventory records purpose, storage, network transfer, retention, access, export, and deletion
- [ ] Privacy manifest included and validated
- [ ] Meal-photo retention controls documented and enforced
- [ ] Export covers user-created local records; deletion covers local and configured remote accounts
- [ ] Sensitive values are redacted from logs and analytics
- [ ] Health details are excluded from analytics
- [ ] Local files use Data Protection; credentials use Keychain
- [ ] No production secrets are embedded in the bundle

### Security review

- [ ] Repository-scoped threat model
- [ ] Security policy and reporting guidance
- [ ] Review of meal images, auth tokens, health data, authorization, malicious payloads, AI structured output, sync conflicts, exports, and deletion
- [ ] Security regression tests for URL validation, token storage boundaries, payload size/type validation, and idempotency
- [ ] External TestFlight security gate documented
- [ ] Pre-release security gate documented

### Health and nutrition safety

- [ ] General-wellness positioning and limitation language throughout product
- [ ] Hard allergy/dietary exclusions retained in recommendations
- [ ] Conservative goal constraints and eating-disorder-sensitive copy
- [ ] Pregnancy, specialized-diet, and medical-condition escalation language
- [ ] Professional-review checklist for targets, scoring, calorie deficit, allergy logic, and recommendation rules
- [ ] Qualified nutrition review remains a required external release gate

## Phase 9 — Quality and reliability

### Automated testing

- [ ] Expanded unit tests for notification scheduling, routing, sync/idempotency, configuration, security validation, and new migrations
- [ ] Integration tests for pending recognition retry, account sync, remote deletion/export, and shortcut hydration writes
- [ ] UI-test target covering onboarding, logging/editing, filtering, permission states, notifications, export/deletion, compact layouts, and Dynamic Type
- [ ] All existing and new tests pass in the iPhone 16 simulator

### Accessibility

- [ ] VoiceOver order and combined metric labels audited
- [ ] Charts retain nonvisual summaries and color-independent meaning
- [ ] Contrast, Dynamic Type, Reduce Motion, hit targets, keyboard/Switch Control, and validation announcements audited
- [ ] Accessibility-size layouts verified in simulator

### Performance and resilience

- [ ] Code-first SwiftUI performance audit completed
- [ ] Cold launch and representative scrolling/runtime trace captured
- [ ] Image decode/downsampling and memory behavior verified
- [ ] SwiftData query/recomputation and HealthKit refresh frequency reviewed
- [ ] Network retry and background work bounded
- [ ] Unified privacy-safe logging and signposts
- [ ] Crash/diagnostic collection boundary using Apple MetricKit
- [ ] Non-sensitive analytics event taxonomy
- [ ] Local feature flags and validated remote-configuration boundary
- [ ] Debug and Release simulator builds pass

## External configuration and review gates

These gates cannot be truthfully completed by source code alone:

- Apple Developer Team, production bundle ID, App Group, Sign in with Apple, iCloud/CloudKit, and notification capabilities
- A deployed backend with development/staging/production URLs and server-held credentials
- Backend database, backups, retention jobs, rate limits, abuse controls, and operational monitoring
- Qualified nutrition-professional review
- Human security review before external TestFlight and again before public release
- Physical-device validation for HealthKit, notifications, widgets, background behavior, battery, and Data Protection
