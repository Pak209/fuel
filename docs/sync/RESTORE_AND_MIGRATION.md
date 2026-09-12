# Fuel Restore and Account Migration

Current client behavior, reviewed 2026-09-11. This is not evidence of a deployed
backend or a successful real-device restore. All backend URLs remain empty;
production cloud functionality must remain disabled until the gates below close.

Grounding: `Fuel/Services/SyncService.swift`, `BackendServices.swift`,
`RemoteSyncPayloadValidator.swift`, `DailySummaryService.swift`,
`Fuel/Persistence/Repositories.swift`, and `Backend/README.md`.

## Local storage and restore boundaries

- Meals, hydration, profiles, targets, preferences, and pending work live in the
  local SwiftData store. There is no configured CloudKit-backed store.
- Fuel does not implement a local JSON import/restore flow. Export is an
  inspectable copy, not a demonstrated round-trip backup mechanism.
- Keychain credentials are configured as
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Restored account metadata
  must not be treated as proof that valid credentials exist.
- Widgets use an App Group summary. Hydration commands use a protected,
  cross-process-locked App Group queue, consumed idempotently by the main app.
- Meal photos are local files and are absent from the meal sync/export DTO.
  Account restore therefore does not restore photos through this protocol.
- HealthKit samples are not uploaded in sync. Fuel reads them through HealthKit
  separately, subject to availability and permission.

Actual OS backup, reinstall, and device-migration behavior still needs a
physical-device test. Do not promise data recovery from a fresh reinstall while
the backend is unavailable.

## Pull and push behavior implemented in the client

1. A sync requires a configured backend, an enabled account, and a stored account
   identifier. These checks are necessary, not sufficient production identity
   validation; account/credential isolation remains unfinished.
2. Every batch sends `sinceRevision`, the last applied account cursor.
   **An empty upload queue still sends a request**, so fresh-install pull no
   longer depends on making a dummy local edit.
3. Uploads use immutable snapshots of the selected queue entries. The request
   contains at most 100 operations and must fit the actual 1 MB JSON/base64 body
   limit. Byte-limited batches leave later entries queued.
4. The HTTP client and engine both validate the complete response envelope.
   Every submitted operation must have exactly one accepted or conflicted
   outcome; foreign/duplicate outcomes, invalid identities, regressing cursors,
   out-of-order feed revisions, and oversized data are rejected.
5. Every remote payload and conflict is semantically validated before any
   response mutation is applied, including a conflict the client expects to win.
   Validation covers nested identifiers, dates, time zones, bounded text and
   collections, finite nutrition/serving arithmetic, and settings schedules.
   Incomplete preference snapshots cannot silently reset local settings.
6. Successful remote changes refresh the active profile, goals, preferences,
   notification schedules, and dashboard data. Remote meal creation/update
   preserves the remote creation time/time zone and server mutation timestamp.

Prevalidation prevents malformed later records from causing earlier records to
be partially accepted. It is **not** a single disk transaction: repository-save
failures during application still require stronger rollback/replay guarantees.

## Concurrent edits, cancellation, and retry

- Overlapping calls in the same coordinator/session share one transport.
- Canceling one waiter does not cancel another caller's upload. Canceling the
  last waiter cancels the transport and resets the submitted uploading rows to
  pending without spending retry attempts or changing their idempotency keys.
  Recovery storage errors remain visible.
- A session change invalidates the old response. Matching live upload rows are
  reset without resurrecting deleted rows or changing newer successors.
  This response guard does not yet bind transport credentials to an immutable
  account scope; it is not proof of safe account switching.
- Editing during upload creates a successor instead of mutating the submitted
  record. Accepted/conflicted predecessor responses cannot acknowledge or
  overwrite that newer edit.
- Same-entity queue creation times are assigned strictly after existing entries,
  including when the wall clock rolls back. Mutation timestamps remain separate
  from queue ordering and retry bookkeeping.
- An older nonterminal entry blocks its successor through backoff. Once the
  older entry exhausts its retries, a newer complete snapshot/tombstone can
  supersede it. Unsent create intent is preserved for an update successor.
- Pulled values never replace an unacknowledged local pending change.
- If no successor exists, conflicts use the newer mutation timestamp, then
  higher revision, with the server winning ties. A local win rebases and retries
  with a fresh key; a remote win applies the validated server value.
- Ordinary request failures keep queued values and stable keys with bounded
  attempts/backoff. Repeated conflict responses and authentication failures need
  additional lifecycle/retry policy before production enablement.

## Server obligations

The server must authorize each entity and idempotency key within the authenticated
account. Create/update carry a full entity snapshot; deletion carries a tombstone.
The exact client/server upsert and conflict rules must be contract-tested.

`response.serverRevision` is a **fully represented page cursor**, not necessarily
the latest global revision. The server must never advance it past omitted remote
changes. Revision gaps alone cannot prove feed completeness on the client.

Remote pages contain at most 500 unique entity snapshots/tombstones in strictly
increasing revision order above the request cursor. Conflicted entities must not
also appear in that page. Accepted writes may be echoed canonically; newer local
successors remain protected.

## Remaining production blockers

- Account-scoped datasets, queues, cursors, caches, and artifacts; legacy migration
  and explicit consent before attaching local records to an account.
- Atomic credentials bound to backend environment and server account identity;
  expiry/refresh, reauthentication, revocation, and startup reconciliation.
- Immutable account/session checks before every transport attempt, not only
  after the response; cancellation across sign-in, sign-out, export, and deletion.
- A deliberate policy for edits made while sync is disabled.
- Shared domain limits at local-save and outgoing boundaries, so one device
  cannot store values another device must reject.
- Consistent remote deletion/photo cleanup and transactional failure recovery.
- Bounded repeated-conflict recovery and non-destructive authentication failures.
- Complete restore coverage for any additional promised records. The current
  sync allowlist is meal, hydration, profile, targets, and preferences, not the
  entire local database (for example favorites and goal history).
- Deployed backend, pagination/contract conformance, backup recovery, retention,
  full account export/deletion, authorization tests, and operational monitoring.
- Real two-device tests for initial restore, offline edits, account switching,
  expired credentials, conflicts, deletion, and interrupted persistence.

## Verification

The focused sync suites passed 92 tests on the iPhone 16 simulator. After the
additional ordering and cleanup fixes, the final full suite passed **202 tests,
zero failed/skipped**, including the two new clock-ordering cases. Release build
and launch also passed. Artifact names are recorded in
`docs/quality/REMAINING_SCOPE.md`.

Suites: `SyncContinuityTests`, `SyncContractTests`,
`RemoteSyncPayloadTests`, and `SyncSecurityTests`. They exercise real local
persistence with in-memory/scripted transport. They do not prove a working live
backend, real Keychain migration, or two-device cloud continuity.
