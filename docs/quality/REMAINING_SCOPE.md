# Remaining scope — 2026-09-11

This is the current execution order for the full daily-use and production goal.
Earlier phase matrices describe implemented client features, not proof of a deployed
service or a completed public release. Check source, test results, and deployment
evidence before closing an item.

## 1. Finish local reliability and device validation

- Full regression checkpoint: 142 tests passed, zero failed/skipped on iPhone 16
  (2026-09-11 local date). Result bundle:
  `test_sim_2026-09-12T05-56-11-054Z_pid35601_3b7c8b70.xcresult` in the local
  XcodeBuildMCP Fuel workspace.
- Release simulator build passed after the privacy/reliability changes:
  `build_sim_2026-09-12T05-59-03-898Z_pid35601_91b6a253.log`.
- Commit and synchronize the verified checkpoint to the authorized GitHub repo.
- Verify real-device HealthKit permissions and refresh, notification actions,
  widget writes, offline/relaunch behavior, lock/unlock, battery, and accessibility.
- Complete a daily-use trial; simulator tests do not substitute for elapsed use.

Latest implementation: public water URLs only navigate; trusted notification actions
perform the write. Image validation/downsampling, temporary export cleanup, photo
deletion with a short Undo window, and queue bounds have been strengthened. The
hydration queue now uses a protected App Group file and cross-process locking;
acknowledgements preserve concurrently enqueued commands and migration preserves IDs.
The queue waits at most half a second for its lock and reports busy/storage errors
without accepting an entry. Spotlight requests no longer hold meal saves or startup
open while waiting for system callbacks. The app startup task now has a stable
container, and UI tests require the editor to dismiss before tapping a saved meal.
Seven queue-specific tests and the full nine-test UI suite are included in the 142
passing tests. Real cross-process widget behavior and lock-state transitions still
need the physical-device trial described in `DAILY_USE_TRIAL.md`.

## 2. Complete account and sync correctness

- Pull existing records on sign-in even when the local mutation queue is empty.
- Bind pending data and credentials to the correct account; define account-switch
  and legacy queue migration behavior without sending one account's data to another.
- Serialize overlapping sync calls and protect newer local edits while older
  requests are in flight.
- Validate complete batch outcomes, remote payload semantics, revision ordering,
  and cursor advancement before accepting results.
- Refresh active profile, goals, preferences, meals, and summaries after remote writes.
- Handle restored metadata without credentials, expired sessions, cancellation,
  incomplete responses, retries, and remote deletion/photo cleanup.
- Prove fresh-install restore and two-device conflict behavior against the backend.

## 3. Build and deploy the production backend

`Backend/README.md` currently contains a specification, not a runnable service.
All three backend URL settings are empty.

- Implement the documented authentication, profile, sync, recognition, nutrition,
  recommendation, configuration, export, and deletion endpoints.
- Establish isolated development, staging, and production infrastructure,
  account authorization, persistent storage, and server-held credentials.
- Add limits for request volume, image processing, model usage, retries, and spending.
- Exercise backups/restore, retention, full deletion/export, monitoring, and alerts.
- Verify client/server contracts and staging workflows before enabling production.

## 4. Improve recognition and nutrition quality

- Evaluate real meal photos and portions against a representative labeled set.
- Improve food coverage, nutrient/source completeness, confidence, alternatives,
  and correction handling; preserve manual entry when estimates are uncertain.
- Validate recommendation quality and any AI provider's structured output.
- Complete the qualified nutrition review defined in the existing safety checklist.

## 5. Subscriptions and premium features

- Replace the mock entitlement service with real purchase, restore, expiry,
  revocation, and server-verified entitlement handling.
- Implement the promised premium experiences and test their access boundaries.
- Configure products and validate purchases in the appropriate Apple environments.

## 6. Family and sharing

- Define household roles, invitations, consent, sharing boundaries, and removal.
- Implement account-scoped shared features and separation of private health data.
- Test access changes and account deletion across members and devices.

## 7. Distribution and final acceptance

- Confirm the App Store Connect record, distribution identity, and required capabilities.
  Team `5YJJCSFSQM` is already present in app/widget build settings; this does not
  alone prove App Store distribution readiness.
- Complete the required human security and nutrition reviews with dated evidence.
- Finish performance/device checks, privacy disclosures, support material,
  screenshots, release archive, TestFlight testing, and submission preparation.
- Audit every original requirement against current evidence before closing the goal.

The full goal remains open. See `RELEASE_GATES.md` for evidence requirements;
some statements in that older document predate the current Apple signing setup.
