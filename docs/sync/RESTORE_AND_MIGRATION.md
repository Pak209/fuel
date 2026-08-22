# Fuel Restore and Account Migration

This document describes what actually happens today when Fuel is reinstalled or
moved to a new device, and how account/data migration behaves given the current
sync implementation. Where the codebase does not yet implement something implied
by the product goal, that gap is called out explicitly rather than described as
working.

Grounding files: `Fuel/App/FuelApp.swift`, `Fuel/Services/BackendServices.swift`,
`Fuel/Services/SyncService.swift`, `Fuel/Services/DailySummaryService.swift`,
`Fuel/Services/DataManagementService.swift`, `Backend/README.md`,
`docs/security/PRIVACY_DATA_MAP.md`.

## What survives an app reinstall today

Fuel's persistent state lives in three places, each with different reinstall
behavior:

| Store | What it holds | Survives a plain delete + reinstall? | Survives a device migration via encrypted backup/iCloud restore? |
| --- | --- | --- | --- |
| SwiftData store (`ModelContainer`) | Meals, hydration, profile, targets, favorites, goal history, recommendation feedback, `SyncOperationRecord` queue, `AccountMetadataRecord`, `RemoteConfigurationRecord` | No — a fresh install gets a fresh, empty container | Likely yes — see below |
| Keychain (`KeychainCredentialStore`) | Access token, refresh token, Apple opaque user identifier | Not guaranteed by app code either way | No |
| App Group `UserDefaults` (widget summary) | At-a-glance score/remaining targets for the widget | No | Likely yes, but is regenerated on next app run regardless |

- The SwiftData store is created with a plain `ModelConfiguration(schema:)` and
  `FuelMigrationPlan` — there is no CloudKit-backed configuration and no
  `isExcludedFromBackup`/file-protection override applied to the store files
  (`Fuel/App/FuelApp.swift:11-27`; confirmed by grepping the whole `Fuel/` tree
  for `isExcludedFromBackup` — no hits). A plain "delete app, reinstall from the
  App Store" wipes the app's container, so the store starts empty; nothing
  local survives that path today. This matches `docs/security/PRIVACY_DATA_MAP.md`,
  which lists all SwiftData-backed rows as living in "SwiftData, protected app
  container" with no mention of a durable off-device local backup channel.
- Because no backup-exclusion flag is set, an iOS system backup (encrypted
  local backup via Finder/iTunes, or an iCloud device backup) includes the
  app's container by default, per standard iOS behavior — Fuel does not opt in
  or out of this explicitly in code. Restoring such a backup onto a new device
  would typically bring the SwiftData store back, including the sync queue and
  `AccountMetadataRecord`.
- Keychain items saved via `KeychainCredentialStore` use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (`Fuel/Services/BackendServices.swift:136`). Per Apple's documented Keychain
  accessibility semantics, "ThisDeviceOnly" items are never migrated to a new
  device by any backup or restore mechanism — this is enforced by iOS, not by
  Fuel. So access token, refresh token, and Apple user identifier are always
  absent after a device-to-device migration. Whether they survive a same-device
  delete+reinstall is an iOS Keychain behavior outside this app's control; the
  app does not add any code that would preserve or clear them either way.

**Open item / inconsistency to watch for:** if a backup restores the SwiftData
store (so `AccountMetadataRecord.syncEnabled` and `appleUserIdentifierHash` are
still set) onto a device whose Keychain has no token, the app's local metadata
says "cloud connected" while the credential needed to actually talk to the
backend is missing. See "Open items" below for how the sync path currently
handles that state (it does not have a distinct recovery path for it).

## How a signed-in user with a configured backend restores

1. **Backend must be configured.** `BackendConfiguration.isConfigured` requires
   `FUEL_BACKEND_BASE_URL` to resolve to a validated HTTPS origin (Debug also
   allows `localhost`/`127.0.0.1`) — `Fuel/Services/BackendServices.swift:18-33`.
   If it isn't configured, `CloudSyncEngine.synchronize` returns `.localOnly`
   immediately (`Fuel/Services/SyncService.swift:59`) and nothing below applies.
2. **Sign-in.** `AccountSessionService.signIn` (`Fuel/Services/BackendServices.swift:453-476`)
   calls `POST /v1/auth/apple`, then saves the access token, refresh token, and
   Apple user identifier to Keychain. `AppState.completeAppleSignIn`
   (`Fuel/App/AppState.swift:331-338`) applies the resulting `AccountSessionResult`
   to the local `AccountMetadataRecord` and, if `cloudConnected` is true,
   immediately calls `synchronizeNow()`.
3. **The sync call itself only pushes what's locally queued.** `CloudSyncEngine.synchronize`
   reads the local pending-operation queue with `coordinator.readySyncOperations(at:)`
   and, critically, **returns `.current(now)` without ever calling the backend if
   that queue is empty**: `guard !operations.isEmpty else { return .current(now) }`
   (`Fuel/Services/SyncService.swift:62-66`). Only when there is at least one
   locally queued mutation does it call `POST /v1/sync`
   (`Fuel/Services/BackendServices.swift:325-327`), whose response can carry back
   `conflicts` and an optional `remoteChanges` array
   (`SyncBatchResponse`, `Fuel/Services/BackendServices.swift:247-251`). Those are
   applied locally through `coordinator.applyRemoteChange`
   (`Fuel/Services/DailySummaryService.swift:486-511`), which decodes typed
   payloads per entity type (`meal`, `profile`, `targets`, etc.) and writes them
   into the local SwiftData store.

**This is the central fact to document accurately:** as implemented, Fuel does
not have a "pull my existing cloud data" step that is independent of pushing a
local change. `Backend/README.md`'s endpoint inventory has only `POST /v1/sync`
— no `GET /v1/sync` or equivalent full-state fetch — and no code path calls
`backend.synchronize` with an empty local queue just to see what the server has.
So on the common "fresh install, sign in, queue is empty" path, a person's
existing cloud data does **not** come down automatically. It only arrives once
some local edit (a meal save, a target change, etc.) enqueues an operation and
the resulting round-trip happens to carry `remoteChanges` back with it. Any
documentation or support answer that says "sign in and your data comes back" is
describing the intended/planned behavior, not what the code guarantees today —
this is flagged as an open item below, not something this document should
paper over.

Meal photos are excluded from that round-trip regardless: the sync payload for
a meal reuses `ExportedMeal` (`Fuel/Services/DataManagementService.swift:12-39`),
which has no image field, and `applyRemoteChange`'s meal branch always
constructs the local draft with `imageData: nil`
(`Fuel/Services/DailySummaryService.swift:495`). This matches
`docs/security/PRIVACY_DATA_MAP.md`'s row for meal photos ("Not in JSON
export"). So even once meal data does sync, the original photo does not travel
with it.

HealthKit-derived data (activity, sleep, workouts, body measurements) is never
part of this at all — `Backend/README.md`'s "Sync semantics" section states
"HealthKit samples are not part of the sync entity set," and that history comes
back on a new device through Health's own iCloud sync, independent of Fuel.

## Conflict behavior on restore

Conflict resolution is deterministic and defined in
`SyncConflictResolver.resolve` (`Fuel/Services/SyncService.swift:18-24`):

```swift
func resolve(local: SyncOperationRecord, remote: SyncConflict) -> SyncConflictDecision {
    if local.updatedAt > remote.serverUpdatedAt { return .useLocal }
    if local.updatedAt < remote.serverUpdatedAt { return .useRemote }
    return local.clientRevision > remote.serverRevision ? .useLocal : .useRemote
}
```

- Newer `updatedAt` wins, matching the rule stated in `Backend/README.md`
  ("Sync semantics" — "Fuel chooses the newer `updatedAt`").
- Exactly equal timestamps fall back to comparing `clientRevision` against the
  server's `serverRevision`; the higher revision wins, and a tie (equal
  timestamp and equal revision) resolves to `.useRemote` — i.e., the server
  wins ties, per `Backend/README.md`'s "server winning ties" line.
- A local win (`.useLocal`) does not overwrite the server outright: it calls
  `coordinator.retrySyncOperation(local, serverRevision:)`
  (`Fuel/Services/SyncService.swift:101`), which re-queues the operation
  against the server's returned revision for a fresh push, consistent with
  `Backend/README.md`'s "A local win receives a new idempotency key and retries
  against the returned server revision."
- A remote win (`.useRemote`) applies the server's payload locally via
  `applyRemoteChange` and then marks the original local operation accepted
  (`Fuel/Services/SyncService.swift:102-104`), so it is not retried.
- This matters directly for restore: right after a migration, if a locally
  queued edit collides with something the server already has (e.g., a meal
  edited offline before the migration, now conflicting with a newer edit made
  from another device), the newer-timestamp-then-revision-then-server-wins-ties
  rule above is what decides which copy survives — not a manual merge prompt.

## Account migration between devices

Two realistic paths, both grounded in the mechanics above:

1. **Sign in with Apple ID on a brand-new install, no backup restore.** The
   local SwiftData store starts empty, so the sync queue is empty, so — per the
   "How a signed-in user restores" section above — the first `synchronize()`
   call after sign-in is a no-op unless the person immediately makes an edit.
   Today, the practical way to pull existing cloud data onto a new device is to
   make some local change (even a trivial one) so a real `POST /v1/sync`
   round-trip happens and `remoteChanges` can come back. This is a real
   usability gap, not a documented feature — see "Open items."
2. **Restore an encrypted backup or iCloud backup onto a new device, then sign
   in again.** The SwiftData store (meals, hydration, targets, profile,
   `AccountMetadataRecord`, sync queue) likely comes back with the backup
   (no exclusion flags are set — see above), but Keychain tokens do not
   (ThisDeviceOnly). The person must sign in again;
   `AccountSessionService.signIn` overwrites the Keychain credentials and
   `completeAppleSignIn` triggers `synchronizeNow()`. Whether that call does
   anything meaningful depends on whether the restored sync queue still has
   pending entries — if it's empty, the same "no-op sync" behavior in path 1
   applies.

In both cases, local-only use (no sign-in) is unaffected: a person who never
enables cloud sync keeps using the app exactly as before, per
`SECURITY.md`'s invariant that "a person can use the core app without creating
an account or enabling cloud transfer."

## Live cloud sync is disabled until backend + Apple credentials are configured

This is a hard, code-enforced gate, not a policy statement alone:

- `BackendConfiguration.isConfigured`/`validatedBaseURL` require a real HTTPS
  origin from `FUEL_BACKEND_BASE_URL` (Debug-only `localhost` exception)
  (`Fuel/Services/BackendServices.swift:18-33`). With no value configured, the
  app runs in local-only mode by construction.
- `CloudSyncEngine.synchronize` returns `.localOnly` whenever
  `backend.isConfigured` is false (`Fuel/Services/SyncService.swift:59`), and
  `AppState.synchronizeNow()` short-circuits to `.localOnly` if the account
  isn't `cloudConnected` (`Fuel/App/AppState.swift:365-366`).
- `Backend/README.md` states this directly: "`BackendAPIClient` is inert until
  `FUEL_BACKEND_BASE_URL` resolves to a validated HTTPS URL... this directory
  specifies the service that must exist before cloud sync or remote recognition
  is enabled for users; it is not evidence that a production service has been
  deployed."
- `PHASES6_9_ROADMAP.md` lists this as an explicit, currently-unchecked gate:
  "Live cloud sync remains disabled until a reviewed backend/container and
  Apple credentials are configured," alongside "A deployed backend with
  development/staging/production URLs and server-held credentials" under
  "External configuration and review gates."

No backend deployment exists in this repository. Everything above describes
client behavior against a hypothetical correctly configured backend; it is not
evidence that one has been stood up.

## Open items

- **No independent "pull my cloud data" step.** As detailed above,
  `CloudSyncEngine.synchronize` never calls the backend when the local sync
  queue is empty (`Fuel/Services/SyncService.swift:62-66`), so restoring an
  account's existing cloud data onto a fresh install/new device is not
  guaranteed to happen on sign-in alone. Closing this requires either an
  explicit initial-pull request (not in `Backend/README.md`'s endpoint
  inventory today) or a deliberate design decision to keep push-triggered pull
  and document the workaround (make a local edit) as expected behavior.
- **No recovery path for "local metadata says connected, Keychain has no
  token."** This state can occur after a backup restores the SwiftData store
  onto a device whose Keychain doesn't carry the ThisDeviceOnly token (new
  device migration) or after any other event that clears Keychain without
  clearing `AccountMetadataRecord`. A sync attempt in this state fails
  authentication inside `send(...)` with `BackendError.missingCredential`
  (`Fuel/Services/BackendServices.swift:369`), which — if there happen to be
  queued operations — is treated like any other transient failure:
  `markSyncFailed` increments `attempts` and schedules bounded exponential
  backoff (`Fuel/Services/DailySummaryService.swift:455-465`) up to
  `maxRetryAttempts` (8, `Fuel/Services/DailySummaryService.swift:73`), then
  gives up silently rather than surfacing a distinct "sign in again" prompt
  tied to that specific cause.
- **Meal photos never migrate through sync**, only through whatever backup
  mechanism (if any) covers the local `Application Support` photo files — see
  the "Meal photos" row in `docs/security/PRIVACY_DATA_MAP.md`.
- **Backend deployment, retention, and restore-drill requirements are an
  external gate**, not something this client codebase can satisfy alone — see
  `Backend/README.md`'s "Operational release evidence" section and
  `docs/quality/RELEASE_GATES.md`.
- **No automated test** in the repository currently exercises the "empty
  queue on sign-in" no-op path or the conflict-resolution tie-break rules
  end-to-end against a real backend contract (contract tests are described as
  a prerequisite in `Backend/README.md`, not as already existing).
