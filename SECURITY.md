# Fuel Security Policy

Fuel handles nutrition logs, optional meal photos, Apple Health summaries, and optional account credentials. Treat these as sensitive wellness information even when a particular platform policy does not classify every field as medical data.

## Security invariants

- A person can use the core app without creating an account or enabling cloud transfer.
- HealthKit data stays on device unless a future feature explicitly requires a minimal field and the person opts in. The current sync payload does not include HealthKit samples.
- Apple identity, access, and refresh tokens belong only in Keychain and must never be logged, stored in SwiftData, written to exports, or placed in widget data.
- Production network requests use HTTPS, bounded payloads, authenticated object access, idempotency, schema validation, and redacted logs.
- Every server-side object lookup must be authorized against the authenticated account; knowing an identifier is never authorization.
- Meal images are untrusted binary input. Validate type and size, isolate decoding, strip unnecessary metadata, and apply an explicit retention policy.
- AI and nutrition-provider output is untrusted data. Validate structured responses and never execute returned text or treat it as authoritative medical advice.
- Local and remote deletion must be explicit, complete, and independently testable. Export links must be short-lived and scoped to one account.
- Widgets and App Intents receive only the minimum summary or command data needed for their action.
- Analytics and diagnostics must exclude meal names, photos, nutrients, HealthKit values, account identifiers, tokens, and free-form notes.

## Reporting

Do not include real user data, credentials, meal photos, or HealthKit exports in a report. Provide a minimal reproduction using synthetic data and identify the affected build. Until a public security contact is configured, report privately to the project owner rather than opening a public issue containing sensitive evidence.

## Release gates

- Run an internal security review before any external TestFlight distribution.
- Repeat the review before public release and after material changes to authentication, sync, image processing, export, or deletion.
- Resolve all critical/high findings and explicitly disposition medium findings before release.
- Keep the repository threat model in `docs/security/THREAT_MODEL.md`; this policy is reporting and invariant guidance, not a substitute for that threat model.
