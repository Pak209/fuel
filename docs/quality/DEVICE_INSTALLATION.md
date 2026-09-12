# Physical-iPhone installation checkpoint

## Verified preparation — 2026-09-11

- Source: `c4cb152e10d8216444332d12baa6ca5ad45f67c8`.
- Fuel version `1.0`, build `2`, minimum iOS `18.0`.
- A Release-configuration **development-signed** arm64 iPhone build succeeded
  using Xcode 26.4.1 and the existing local signing setup. This is not an App
  Store distribution archive or a TestFlight upload.
- Team `5YJJCSFSQM` signs both `com.pak.fuel` and `com.pak.fuel.widgets`.
- Strict/deep signature verification passed using the system trust service.
  The initial sandbox-only trust/entitlement checks were inconclusive; the
  subsequent system-service checks verified the signatures and decoded the
  signed entitlements successfully.
- Signed app and embedded profile include HealthKit, HealthKit background
  delivery, and `group.com.pak.fuel`. Signed widget and embedded profile include
  that same App Group. The profile expiry dates are 2027-08-31 (UTC).
- Built Info.plist contains the Health read/update and photo-library usage
  descriptions, launch screen, app icon, and an **empty backend URL**. The trial
  remains local-only. No camera capture, Apple sign-in, CloudKit, or APNs is
  being enabled by this build.

Local installable artifact (ignored by Git, not uploaded):

`/Users/danielpak/Documents/Fuel/build/device-checkpoints/c4cb152.ObMGbz/Fuel.app`

Build result:

`/private/tmp/fuel-device-c4cb152.cHY7z5/DeviceBuild.xcresult`

The app copy was independently signature-verified after preservation. These
artifacts may be removed by local cleanup; if absent, rebuild the recorded source
instead of substituting an unknown older binary. Provisioning/device-specific
files and signing material must remain outside the repository.

## Installation gate — not completed

The latest device listing still reports the paired iPhone 14 Pro **unavailable**.
The latest checkpoint has not been installed or launched on that phone by this
verification pass. Build/signing success does not prove that the device accepts
the installation or that HealthKit/App Group access works at runtime.

1. Connect and unlock the iPhone. Complete any required trust/developer prompts
   on the device. Re-list devices and use the actual available identifier.
2. Check for existing Fuel data before changing the installation. Do not uninstall,
   reset, seed demo data, or erase logs to get past an installation problem.
3. Verify the selected artifact/source, then install the app bundle and launch
   `com.pak.fuel` without demo or UI-test arguments.
4. Confirm ordinary startup, local persistence, Health permissions, and shared
   widget hydration writes before starting the week-long trial.
5. Record device/iOS, source commit, version/build, installation date, and chosen
   permissions in the trial record without including personal health details.

Command forms were checked against the installed `devicectl --help`; replace
the placeholders only with verified current values:

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device "<available device identifier>" "<verified Fuel.app path>"
xcrun devicectl device process launch --device "<available device identifier>" com.pak.fuel
```

Do not pass `-FuelDemoData` or `--uitest-*` flags: those paths are unsuitable for
the user's daily-use data. Do not change trust settings or provisioning to bypass
a device error; diagnose the exact failure first.

## Acceptance after installation

Follow [DAILY_USE_TRIAL.md](DAILY_USE_TRIAL.md). Seven recorded days and resolution
of blocking issues are required; neither a signed build nor elapsed calendar time
alone completes the trial. Backend, recognition upgrades, subscriptions/advanced
features, and professional/security/distribution reviews remain in the full goal.
