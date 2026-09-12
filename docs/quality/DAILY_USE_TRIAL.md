# One-week physical-iPhone trial

Status: not yet verified. Do not infer completion from simulator results or from
calendar time since installation. The user must actually use the app and record
the results below. Use the latest verified build when beginning the trial.

The `c4cb152` development-signed iPhone build is prepared and signature-verified;
see [DEVICE_INSTALLATION.md](DEVICE_INSTALLATION.md). This preparation does not
start the trial or establish that the build is installed on the phone.

Record device model, iOS version, Fuel version/build, source commit, installation
date, trial dates, and enabled Health/notification permissions. Keep personal
meal and Health data out of this shared report; totals are unnecessary.

## Daily use

Each day, log normal meals and water, check Today and Insights, and note any
missing entries, duplicate entries, wrong dates, stuck saves, unexpected setup
screens, slow interactions, crashes, or battery concerns. Verify yesterday's
entries remain available the next morning.

| Day | Date | Meals and water persist | Today/Health refresh | Notifications/widgets | Problems or observations |
| --- | --- | --- | --- | --- | --- |
| 1 | Pending | Pending | Pending | Pending | |
| 2 | Pending | Pending | Pending | Pending | |
| 3 | Pending | Pending | Pending | Pending | |
| 4 | Pending | Pending | Pending | Pending | |
| 5 | Pending | Pending | Pending | Pending | |
| 6 | Pending | Pending | Pending | Pending | |
| 7 | Pending | Pending | Pending | Pending | |

## Checks to cover during the week

- Meal logging: manual entry and photo selection, correction, edit, duplicate,
  delete, Undo, and relaunch. Photo estimates must remain editable.
- Offline: log a meal and water with networking unavailable, quit/reopen Fuel,
  then reconnect and verify entries are retained without duplication.
- Apple Health: approve selected categories, compare source availability with
  Health, revoke a category, and reconnect. Missing permission/data must be clear.
- Widget/Shortcuts: add water with Fuel closed, then open Fuel and confirm the
  entry appears exactly once. Repeat with Fuel backgrounded and with several taps.
- Notifications: deliver a scheduled reminder in the background, open its
  destination, and use the hydration action. Check quiet hours and a schedule edit.
- Device state: lock/unlock, background/foreground, and a restart followed by
  first unlock. Confirm the next app launch works and pending entries persist.
- Day boundary: check previous-day entries after midnight. If traveling, note
  time-zone behavior without changing the phone clock merely to create evidence.
- Accessibility: try larger text and VoiceOver; critical controls must be reachable.
- Export: export and inspect the structure using test data where possible. Verify
  the in-app temporary share artifact expires; copies saved elsewhere remain yours.
- Deletion: use disposable data or a separate test installation. Do not erase
  the user's real log as part of an unattended validation pass.
- Battery: inspect the phone's battery report after ordinary use and note any
  unexpected background activity. Simulator measurements do not close this check.

## Issue record and acceptance

For each issue, record the action, expected result, actual result, whether it
repeats, device/build, and a screenshot or diagnostic only if it is safe to share.
Fix blocking issues, install the corrected build, and repeat the affected checks.
Close the trial only after seven recorded days and all blocking issues are resolved.

This trial does not claim the cloud backend, purchases, family sharing, or public
distribution work is complete. Those remain tracked in `REMAINING_SCOPE.md`.
