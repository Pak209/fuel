# Fuel Repository Threat Model

The canonical repository-scoped threat model for the reviewed working-tree snapshot is cached at `/private/tmp/codex-security-scans/Fuel/threat_model.md` according to the Codex Security artifact contract. This durable project copy summarizes the same model for release work.

## Overview

Fuel is a local-first SwiftUI wellness app with a main app, WidgetKit extension, App Intents, local notifications, HealthKit reads, PhotosUI/on-device recognition, SwiftData/protected files, public food search, and an optional authenticated HTTPS backend. Sensitive assets include profiles, goals, allergies, meals, photos, notes, hydration, HealthKit-derived summaries, account tokens, exports, sync operations, and recommendation/scoring integrity.

## Threat Model, Trust Boundaries, and Assumptions

The material boundaries are person-to-UI input, Photos-to-decoder/recognition, HealthKit-to-aggregation, app-to-SwiftData/files/Keychain, main-app-to-App-Group/widget/intents, notification/deep-link routing, public nutrition search, optional backend authentication/sync/export/deletion, backend-to-AI/provider/webhook services, and runtime-to-diagnostics. Images, URLs, free text, shortcuts, backend/model output, remote config, and third-party food data are untrusted. Apple platform security is assumed to work as documented on a correctly signed non-compromised device.

Core invariants are defined in `SECURITY.md`: local-only use remains viable; credentials stay only in Keychain; HealthKit data is not synced; images and model output are validated; every remote object is account-authorized; commands and sync operations are idempotent; exports/deletion are scoped and complete; telemetry excludes health/account content; remote config cannot weaken security, privacy, allergy, calorie-floor, or safety controls.

## Attack Surface, Mitigations, and Attacker Stories

- Malformed images can target decode memory, metadata, upload cost, or model output. Bound bytes/pixels, strip metadata, isolate server decoding, rate-limit, validate schemas, and enforce retention.
- Forged routes, notification actions, widgets, or shortcuts can trigger narrow commands. Closed-enum routing, bounded parameters, App Group isolation, UUID commands, and atomic processed-command records mitigate replay and confused-deputy behavior.
- Replayed Apple tokens, stolen bearer tokens, object-ID enumeration, sync poisoning, and export/deletion abuse are realistic when cloud is enabled. Verify Apple tokens/nonces, store credentials in Keychain, authorize every object server-side, bind idempotency to account, validate payloads, and use short-lived exports.
- Provider/model/remote-config compromise can corrupt nutrients, entitlements, or safety behavior. Keep secrets/webhooks server-side, validate signed/versioned/expiring config, retain provenance, require review, and make hard safety invariants nonconfigurable.
- Logs, crashes, screenshots, or support artifacts can leak consolidated wellness data. Use allowlisted events and coarse metrics only; never log bodies, tokens, identifiers, meals, photos, notes, nutrients, allergies, or HealthKit values.
- Store corruption and migrations can threaten availability. Use versioned migrations, explicit errors, protected storage, no silent destructive reset, tested exports/deletion, and restore drills for backend deployments.

Web XSS/CSRF/SQL injection/SSRF are not current native-app surfaces but become in-scope for the deployed backend. Ad-tracking attacks are currently out of scope because no ad/tracking SDK exists. A fully compromised unlocked device is not preventable, but retention minimization and credential protection still apply.

## Severity Calibration (Critical, High, Medium, Low)

- **Critical:** bulk cross-account wellness/photo export or deletion; production signing/backend/config compromise; malicious-image server code execution with production secrets/data access.
- **High:** usable token leakage; complete single-account unauthorized access; destructive cross-account sync replay; scalable bypass of allergy/calorie hard safeguards; unauthorized App Group command access.
- **Medium:** bounded image denial of service; recoverable current-user sync loss; restricted diagnostic leakage of health content; route abuse that adds bounded hydration; undisclosed retention overrun.
- **Low:** stale widget/reminder state, public-food-search abuse under rate limits, or developer-only simulator/demo behavior with no production data path.

Repository: codex-security-target/v1:sha256:aba0dd8425ce955d8f7d411e796ac20996fc0198621f1cc81485a8368fb8549c
Version: codex-security-snapshot/v1:sha256:cdc0b21b9a2c4e9ed6adef31848550f1495b882f676f62e6aa62bd37ff93a837
