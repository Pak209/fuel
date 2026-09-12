# Fuel — TestFlight Implementation Plan

> **Historical implementation plan — based on the 2026-08-22 audit.** This document
> preserves the earlier local-only beta plan. Its workstream lists, account-state
> claims, example commands, and estimates do not describe what remains today.
> [REMAINING_SCOPE.md](REMAINING_SCOPE.md) is the authoritative current work list;
> use [RELEASE_GATES.md](RELEASE_GATES.md) for current release-evidence requirements.

Several listed implementation tasks are already present in source: the app/widget
team is `5YJJCSFSQM`, the icon catalog maps `AppIcon.png`, and `Fuel/Info.plist`
contains the launch-screen declaration, backend URL mapping, and encryption
declaration. The privacy policy screen and hostable policy files exist. The current
app entitlement file declares HealthKit/background delivery and the App Group;
Sign in with Apple is absent for the local-only build. Recheck source and recorded
tests before repeating any workstream below. Distribution provisioning, App Store
Connect acceptance, published policy, and the sustained device trial still require
their own evidence.

The old v1/v2 split below does not remove backend, recognition, subscriptions, or
family/sharing work from the current full-app goal. Its short code-work estimate
applies only to that historical beta plan. Examples also retain old paths and build
numbers and must be resolved against the current project before use.

Sources for this correction: `Fuel.xcodeproj/project.pbxproj`,
`Fuel/Assets.xcassets/AppIcon.appiconset/Contents.json`, `Fuel/Info.plist`,
`Fuel/Fuel.entitlements`, `Fuel/Features/Profile/PrivacyPolicyView.swift`, and
`docs/legal/privacy-policy.md`.

Goal: take Fuel from its current state (clean unsigned Release archive, working local app, empty icon set, no team) to **a build uploaded to App Store Connect and available to internal TestFlight testers**.

Derived from `docs/quality/APP_STORE_READINESS.md` (2026-08-22) and direct inspection of the repo. Source of truth for build settings: `Fuel.xcodeproj/project.pbxproj` (configurations `Debug`/`Staging`/`Release`; app-target blocks at lines ~184, ~212 (Staging), ~211 (Release); widget-target blocks at ~218/~242/~265). Archive scheme: `Fuel.xcodeproj/xcshareddata/xcschemes/Fuel.xcscheme` (ArchiveAction = Release, which pulls `Config/Production.xcconfig`).

---

## Scope decision (make this first)

**v1 ships local-only. No backend, no accounts, no purchases.** Concretely:

- **No backend deployment for v1.** `Backend/` is a spec, not a service. `FUEL_BACKEND_BASE_URL` stays empty in all three `Config/*.xcconfig` files; `BackendAPIClient.isConfigured` stays false; the app's existing local-only degradation (disabled sync toggle, "Local only" storage label, explanatory copy in `ProfileView.swift:96-101`) is already honest and correct.
- **Sign in with Apple is hidden in v1**, not removed. The button currently renders unconditionally when signed out (`Fuel/Features/Profile/ProfileView.swift:133-152`) but can only store a local identifier hash — a dead end for testers. Gate the section on `state.accountSummary.backendConfigured`. Keep the `com.apple.developer.applesignin` entitlement in place only if the human wants the capability pre-registered for v2; otherwise **remove it from `Fuel/Fuel.entitlements` for v1** (recommended — fewer capabilities to register, no App Review questions about an invisible feature).
- **The Fuel+ premium card is deleted for v1.** No StoreKit exists; App Review flags advertised-but-unpurchasable content. Delete the section, keep the `EntitlementService` plumbing (it's inert at `.free` and blocks nothing).
- **No camera in v1.** `ScanView` stays `PhotosPicker`-based; all "camera" copy is reworded.
- **Recognition ships as-is** (honest, weak, flagged `isPartial`) but resolves labels **locally only** so a photo scan can never burst Open Food Facts' rate limit.

Everything below assumes this scope. If the human overrides it (wants SIWA/backend/StoreKit in v1), Workstreams 3 and 4 change materially and the timeline stops being "about a day of code."

---

## Workstream overview and order

| # | Workstream | Owner | Gated on |
|---|-----------|-------|----------|
| 1 | Submission blockers (icon, launch screen, encryption key) | Agent — now | Nothing |
| 2 | Crash safety: SwiftData store-open shim | Agent — now | Nothing |
| 3 | v1 scope cuts (Fuel+ card, SIWA gating, privacy-manifest alignment) | Agent — now | Scope decision above |
| 4 | Honesty + network hygiene (camera copy, OFF rate limiting, badge, insets, attribution, latent plist/pbxproj fixes) | Agent — now | Nothing |
| 5 | Privacy policy (in-app screen + hostable document) | Agent drafts; human hosts | Human picks hosting/URL |
| 6 | Apple Developer Program + signing | **Human** | Apple enrollment (~24-48h) |
| 7 | App Store Connect record + compliance | **Human** | WS6 complete |
| 8 | Team ID into repo + physical-device validation | Agent (config) + **Human** (device) | WS6 |
| 9 | Archive, export, upload, TestFlight distribution | Agent runs commands; human watches ASC | WS1-8 |

WS1-5 are fully parallelizable and need no Apple account. WS6-7 are pure human console work and can start immediately in parallel. WS8-9 are the merge point.

---

## Workstream 1 — Submission blockers (agent, now)

### 1.1 App icon

The set is empty: `Fuel/Assets.xcassets/AppIcon.appiconset/Contents.json` is `{"images":[],...}` with no PNGs. ASC rejects uploads without the 1024×1024 marketing icon.

- Generate a **1024×1024 opaque PNG, no alpha channel** placeholder (flat `FuelTheme.green` — `Color(red: 0.30, green: 0.82, blue: 0.31)` ≈ `#4DD14F` — on dark `#0B110F`, with a simple glyph, e.g. a bolt or leaf). A small Swift/CoreGraphics or Python script is fine; verify with `sips -g hasAlpha Fuel/Assets.xcassets/AppIcon.appiconset/AppIcon.png` → `hasAlpha: no`.
- Save as `Fuel/Assets.xcassets/AppIcon.appiconset/AppIcon.png` and replace `Contents.json` with the Xcode 16 single-size universal format:

  ```json
  {
    "images" : [
      { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
    ],
    "info" : { "author" : "xcode", "version" : 1 }
  }
  ```

- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` already exists in all app configs (`project.pbxproj:185` etc.) — no build-setting change needed.
- **Human decision (non-blocking):** final artwork. The placeholder unblocks upload; real branding can land in any later build. Optional: add dark/tinted appearance variants later.

### 1.2 Launch screen

No `UILaunchScreen`/`INFOPLIST_KEY_UILaunchScreen_Generation` anywhere → the app runs letterboxed in legacy compatibility mode on every modern iPhone.

- **Single edit, covers all configurations:** add to `Fuel/Info.plist`:

  ```xml
  <key>UILaunchScreen</key>
  <dict/>
  ```

  (An empty dict opts into modern launch behavior with the system background. Optionally add `UIColorName` pointing at a launch background color asset later.) This is preferable to editing `INFOPLIST_KEY_UILaunchScreen_Generation` into three separate pbxproj config blocks — one file, one edit, merged into the generated Info.plist because `GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_FILE = Fuel/Info.plist` are both set.

### 1.3 Export compliance

- Add to `Fuel/Info.plist`:

  ```xml
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  ```

  The app uses only HTTPS/system crypto, so `false` is accurate — but this is a legal attestation; **flag it to the human in the PR description** so the owner has seen it.

### Acceptance criteria (WS1)

- `xcodebuild -project Fuel.xcodeproj -scheme Fuel -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO archive -archivePath /tmp/fuel-ws1.xcarchive` succeeds; the archived app contains `Assets.car`, and its `Info.plist` contains `CFBundleIcons`/`CFBundleIconName`, `UILaunchScreen`, and `ITSAppUsesNonExemptEncryption`.
- Simulator install shows the icon on the home screen (not the gray grid) and the app fills the full screen with no black bars (compare against `launch-t0.png`/`clean-t4.png` from the readiness audit).

---

## Workstream 2 — SwiftData crash-loop fix (agent, now)

`ModelContainer(for:migrationPlan:)` in `Fuel/App/FuelApp.swift:37-49` is wrapped in a Swift `do/catch`, but the observed failure (8 SIGABRT crash logs, `Fuel-2026-08-22-1251*.ips`) is an **ObjC exception** thrown inside `-[NSPersistentStoreCoordinator addPersistentStoreWithDescription:]` — Swift `catch` never sees it, so the in-memory fallback and `StartupFailureView` never engage and the user crash-loops.

Tasks:

1. **Add an ObjC exception-catching shim.** SwiftPM/Xcode target is pure Swift with synchronized groups; the cheapest correct approach is a tiny ObjC file pair added to the `Fuel` target:
   - `Fuel/System/ObjCExceptionCatcher.h` / `.m`: `+ (BOOL)catchException:(void(NS_NOESCAPE ^)(void))block error:(NSError **)error;` wrapping `@try/@catch(NSException *)` and converting to `NSError`.
   - Bridging: because the app target uses `PBXFileSystemSynchronizedRootGroup`, the `.m` compiles automatically; add `SWIFT_OBJC_BRIDGING_HEADER = Fuel/System/Fuel-Bridging-Header.h` to the three app-target config blocks in `project.pbxproj` (lines ~184 Debug, ~211 Release, ~212 Staging), with the bridging header importing `ObjCExceptionCatcher.h`.
2. **Pre-validate the store before constructing the on-disk container** in `FuelApp.init` (`Fuel/App/FuelApp.swift`): locate the default store URL (`URL.applicationSupportDirectory.appending(path: "default.store")`), and if it exists, call `NSPersistentStoreCoordinator.metadataForPersistentStore(type:at:)` **inside the shim**. Also wrap the `try ModelContainer(...)` construction itself in the shim (belt and suspenders — construction is where the crash was observed).
3. On shim-caught failure: set `startupError` with a user-readable message and fall through to the existing in-memory fallback path so `StartupFailureView` renders — same behavior the Swift-error path already has. Do **not** silently delete the store; `StartupFailureView` is the designed surface for recovery choices.
4. **Test:** add a unit test in `FuelTests/FuelTests.swift` that plants a garbage `default.store` file (or a store with incompatible metadata) in a temp application-support directory and asserts the shim reports failure instead of the process dying. (Full end-to-end verification that a corrupted store shows `StartupFailureView` belongs in the WS8 device pass.)

### Acceptance criteria (WS2)

- A deliberately corrupted `default.store` produces `StartupFailureView` on next launch (verified on simulator by copying garbage into the app container via `xcrun simctl get_app_container ... data`), not a SIGABRT loop.
- Existing tests still pass: `xcodebuild test -project Fuel.xcodeproj -scheme Fuel -destination 'platform=iOS Simulator,name=iPhone 16'`.

---

## Workstream 3 — v1 scope cuts (agent, after scope sign-off)

1. **Delete the Fuel+ section**: remove the `Section("Fuel+") { LockedFeatureCard(...) }` block at `Fuel/Features/Profile/ProfileView.swift:44-46`. Keep `LockedFeatureCard` (`Fuel/UI/Components.swift:115-120`) only if v2 premium is planned; otherwise delete it and its now-dead references. `MockEntitlementService`/`AppState.swift:70` stay — inert and harmless.
2. **Gate the "Optional account" section** in `Fuel/Features/Profile/ProfileView.swift` (the `else` branch at ~line 132): wrap it in `if state.accountSummary.backendConfigured { ... }` so the SIWA button cannot render in a build with no backend. The signed-in branch already self-gates via disabled controls; leave it (it's unreachable when sign-in is hidden).
3. **Remove the Sign in with Apple entitlement for v1** (recommended): delete the `com.apple.developer.applesignin` key from `Fuel/Fuel.entitlements:9-12`. Keeps the App ID capability surface minimal. (If the human prefers to pre-register it for v2, skip this and register the capability in WS6 instead — either is fine; just be consistent.)
4. **Align the privacy manifest with local-only reality**: `Fuel/PrivacyInfo.xcprivacy:28-36` declares *collected* (i.e., transmitted off-device) data types — Name, Email, UserID, Health, Photos, OtherUserContent, all "Linked". In a local-only build nothing is transmitted except anonymous Open Food Facts search terms; these declarations are false and will contradict the ASC App Privacy answers ("Data Not Collected"). Empty the `NSPrivacyCollectedDataTypes` array for v1 (restore per-type when the backend ships). While in the file, add `CA92.1` to the UserDefaults reasons array (line 15-17) alongside `1C8F.1` — the app uses `UserDefaults.standard` directly (`AppServices.swift:782`, `Analytics.swift:80`, `FeatureFlags.swift:81`). Mirror the reason fix in `FuelWidgets/PrivacyInfo.xcprivacy` if it declares UserDefaults too.

### Acceptance criteria (WS3)

- Signed-out Profile → Account and sync shows only the "Mode" section (Storage: Local only) — no SIWA button, no Fuel+ card anywhere.
- `grep -rn "applesignin" Fuel/Fuel.entitlements` empty (if option 3 taken).
- `Fuel/PrivacyInfo.xcprivacy` has empty `NSPrivacyCollectedDataTypes` and both `1C8F.1` and `CA92.1` UserDefaults reasons.
- App builds and all tests pass.

---

## Workstream 4 — Honesty and network hygiene (agent, now)

Ordered by user impact; all are independent.

1. **Fix camera copy** (minutes):
   - `Fuel/Info.plist:20-32` (`UIApplicationShortcutItems`): title "Scan a meal" → keep; subtitle "Open the meal camera" → "Choose a meal photo"; icon `camera.viewfinder` → `photo.on.rectangle`.
   - `Fuel/System/AppRouting.swift:51-57`: same strings in the programmatic `UIApplicationShortcutItem`.
   - `FuelShared/SharedEngagement.swift:128`: `IntentDescription("Open Fuel's meal camera and editor.")` → "Open Fuel's meal photo picker and editor."
2. **Stop photo recognition from hitting Open Food Facts.** In `Fuel/Services/FoodServices.swift`, `OnDeviceFoodRecognitionService` (line ~227) defaults to `database: CompositeFoodDatabaseService()`, so up to 8 Vision labels each trigger a remote `cgi/search.pl` call. Change the default to `LocalFoodDatabaseService()` (recognition resolves against the bundled catalog only; interactive search keeps the composite path). This alone removes the rate-limit burst.
3. **Rate-limit and cache interactive search.** In `FoodServices.swift`:
   - Add a small in-memory query→results cache (normalized query key, ~5-minute TTL, cap ~100 entries) inside `OpenFoodFactsService` or a wrapper.
   - Add a client-side limiter (token bucket, ≤8 remote searches/min to stay under OFF's documented 10/min) that returns local-only results when exhausted rather than erroring.
   - Migrate `OpenFoodFactsService.search` (line ~98) from legacy `cgi/search.pl` to the v2 search API (`https://world.openfoodfacts.org/api/v2/search?...&fields=code,product_name,brands,nutriments,serving_quantity,...`), keeping the identifiable User-Agent (line ~111). Keep the 300ms debounce in `Fuel/Features/Meals/MealEditorView.swift:478` (it's fine once the limiter exists).
4. **Latent-but-cheap plist/pbxproj fixes:**
   - `Fuel/Info.plist`: add `<key>FUEL_BACKEND_BASE_URL</key><string>$(FUEL_BACKEND_BASE_URL)</string>` so `BackendConfiguration.load` (`BackendServices.swift:23-25`) can ever see a URL from a device build (latent until v2, trivial now).
   - `Fuel.xcodeproj/project.pbxproj:83-86`: exception set `FF0000000000000000000002` excepts only `Info.plist` — add `Fuel.entitlements` to `membershipExceptions` so the entitlements file stops shipping inside the app bundle as a stray resource (the widget group already does this correctly at `:79`).
5. **AccentColor**: add `Fuel/Assets.xcassets/AccentColor.colorset/Contents.json` with the FuelTheme green (`{"red":"0.300","green":"0.820","blue":"0.310","alpha":"1.000"}`, sRGB) and add `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;` to the three app-target config blocks in `project.pbxproj`. System-drawn UI (alerts, untinted toggles) stops rendering iOS blue.
6. **Fake notification badge**: remove the unconditional red-dot `overlay` on the bell in `Fuel/Features/Today/TodayView.swift:211-216` (or bind it to a real "has pending permission prompt" condition — removal is simpler and honest).
7. **Tab-bar clipping**: on the Today dashboard scroll content, add bottom padding / `.safeAreaInset(edge: .bottom)` matching the floating tab bar height (`Fuel/Features/Today/TodayView.swift`; find the floating bar's height constant in `AppRootView`/`Components.swift` and reference it, don't hardcode twice). Verify "2,450 left" / "No Health data" cards are fully visible above the bar.
8. **ODbL attribution**: in the data-sources UI (`Fuel/Features/Profile/ProfileView.swift:~536`, `DataSourcesView`), add an Open Food Facts line: "Food data from Open Food Facts, licensed under ODbL" with a `Link` to `https://world.openfoodfacts.org`, and surface the per-product `attributionURL` (`DomainModels.swift:163`, populated at `FoodServices.swift:155`) as a tappable link in the food-detail context where source is shown.
9. **Dead-code sweep (optional, lowest priority)**: delete `SectionHeader` (`Fuel/UI/Components.swift:93-107`); leave backend-client dead capabilities and unused analytics events with a `// v2` comment — they're inert and documented in the readiness report.

### Acceptance criteria (WS4)

- No user-visible string or SF Symbol promises a camera; `grep -rn "camera" Fuel/ FuelShared/ --include="*.swift" --include="*.plist"` returns no user-facing copy (the `camera.viewfinder` symbol and "meal camera" strings are gone).
- A photo scan performs **zero** network requests (verify via Instruments/Network or a debug log counter in `OpenFoodFactsService`).
- Typing rapidly in food search never exceeds 8 OFF requests/min; repeated identical queries hit the cache.
- Simulator screenshots: no red dot on the bell; Today cards fully visible above the tab bar; accent-colored system controls are green.

---

## Workstream 5 — Privacy policy (agent drafts, human hosts)

HealthKit apps **must** have a privacy policy URL in ASC and an accessible in-app policy (App Review 5.1.1/5.1.3). Nothing exists in the repo today.

1. **Agent, now:** write the policy content — accurate for local-only v1: all nutrition/hydration/Health data stored on-device; HealthKit read-only, never written, never transmitted; food search queries sent to Open Food Facts (no account data attached); no analytics collection (`analyticsCollectionEnabled` defaults false), no tracking, no accounts; export/delete-all available in-app; contact email. Produce two artifacts:
   - `Fuel/Features/Profile/PrivacyPolicyView.swift` — a static SwiftUI screen; add `NavigationLink("Privacy policy") { PrivacyPolicyView() }` in the About section of `Fuel/Features/Profile/ProfileView.swift` (next to "Support" at line ~41).
   - `docs/legal/privacy-policy.md` (plus a plain `privacy-policy.html`) — the hostable copy of the same text.
2. **Human:** choose hosting and publish (GitHub Pages, a personal site, or any static host — the URL must be publicly reachable before App Review; TestFlight beta review also asks for it). Give the final URL back so it can be recorded in ASC (WS7) and optionally shown in the in-app screen.

### Acceptance criteria (WS5)

- In-app: Profile → About → Privacy policy renders the full policy offline.
- A public URL serves the same policy text (human confirms).

---

## Workstream 6 — Apple Developer Program + signing (HUMAN)

No code can substitute for this. Current state: `DEVELOPMENT_TEAM = ""` in all six app/widget config blocks; only an Apple Development cert (team `TQ2X6D6PVH`) and a macOS Developer ID cert on the machine; no Apple Distribution identity; App IDs/app group unregistered.

Exact console steps:

1. **Enroll**: [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/) → sign in with the Apple ID that will own the app → Individual (or Organization + D-U-N-S) → pay $99/yr. Approval is usually minutes-to-48h.
2. **Xcode account**: Xcode → Settings → Accounts → add that Apple ID → confirm the paid team appears (note the **Team ID**, a 10-char string — everything downstream needs it).
3. **Bundle ID availability check**: [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers/list) → try to register `com.pak.fuel`. If taken (registered globally, not per-team), pick a replacement (e.g. reverse-DNS on a domain you own) and tell the agent — it's a 3-line change (`PRODUCT_BUNDLE_IDENTIFIER` in app configs, `com.pak.fuel.widgets`, and `group.com.pak.fuel` + `FuelShared` store constants + `CFBundleURLName`).
4. **Register identifiers and capabilities** (Xcode's automatic signing can do this implicitly on first device build, but doing it explicitly avoids surprises):
   - Identifiers → **+** → App ID → `com.pak.fuel` → enable capabilities: **HealthKit** (check "Background Delivery" if listed), **App Groups**, and **Sign in with Apple** *only if WS3 kept the entitlement*.
   - Identifiers → **+** → App ID → `com.pak.fuel.widgets` → enable **App Groups**.
   - Identifiers → App Groups → **+** → register `group.com.pak.fuel` → then edit both App IDs and assign the group.
5. **Certificates**: nothing manual needed — automatic signing + `-allowProvisioningUpdates` (WS9) creates the **Apple Distribution** certificate and App Store provisioning profiles on demand. If you prefer explicit: Certificates → **+** → Apple Distribution → follow CSR flow.
6. **App Store Connect API key** (lets the agent archive/upload from the CLI without your password): [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api) → Team Keys → **+** → name "Fuel CI", role **App Manager** → download the `.p8` **once**, note the **Key ID** and **Issuer ID**. Store the `.p8` at `~/private_keys/AuthKey_<KEYID>.p8` on this Mac (that path is one of the default lookup locations).

### Acceptance criteria (WS6)

- Team ID, final bundle ID decision, and API key (path + Key ID + Issuer ID) handed to the agent.
- `security find-identity -p codesigning -v` eventually shows an "Apple Distribution" identity (may only appear after the first `-allowProvisioningUpdates` archive — that's fine).

---

## Workstream 7 — App Store Connect record + compliance (HUMAN)

Do after WS6 (the bundle ID must be registered first).

1. **Create the app record**: [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → My Apps → **+** → New App → Platform iOS; Name **"Fuel"** (app names are globally unique — have fallbacks ready, e.g. "Fuel — Nutrition & Recovery"); Primary language; Bundle ID `com.pak.fuel` (from the dropdown); SKU e.g. `fuel-ios-001`.
2. **App Information**: Primary category **Health & Fitness**; Privacy Policy URL = the WS5 URL.
3. **App Privacy questionnaire** (required before any build is testable by external testers, and before submission): with the WS3 manifest alignment, answer **"Data Not Collected"** — Health data never leaves the device and OFF queries carry no identity. (If SIWA/backend ship later, this must be redone truthfully.)
4. **TestFlight tab**: fill Beta App Description, Feedback Email; **Test Information → Beta App Review notes**: state clearly "Local-only app. HealthKit is read-only. No account required. Photo recognition is on-device + local catalog." Add License Agreement only if desired.
5. **Internal testing**: TestFlight → Internal Testing → **+** create a group ("Core"), add yourself (and any Users-and-Access members). Internal testers need no beta review; builds appear as soon as processing finishes.
6. **Export compliance**: with `ITSAppUsesNonExemptEncryption=false` in the build (WS1.3), no per-build compliance prompt appears. Nothing to do — just don't be surprised it's absent.

### Acceptance criteria (WS7)

- App record exists with privacy policy URL and App Privacy published; an internal tester group exists with at least one member.

---

## Workstream 8 — Team into repo + device validation

### 8.1 Repo signing config (agent, once the human supplies the Team ID)

- Set `DEVELOPMENT_TEAM = <TEAMID>;` in **all six** app/widget config blocks in `Fuel.xcodeproj/project.pbxproj` (app: lines ~189 Debug, and the inline `DEVELOPMENT_TEAM = ""` in the Release/Staging blocks at ~211-212; widget: ~223, ~247, ~270). `CODE_SIGN_STYLE = Automatic` is already correct everywhere — leave it.
- If the bundle ID changed in WS6 step 3, update `PRODUCT_BUNDLE_IDENTIFIER` (both targets, all configs), `Fuel/Fuel.entitlements` + `FuelWidgets/FuelWidgets.entitlements` app-group string, the app-group constant in `FuelShared` (grep `group.com.pak.fuel`), and `CFBundleURLName` in `Fuel/Info.plist`.
- Create `Config/ExportOptions.plist` (see WS9).

### 8.2 Physical-device validation (HUMAN, with agent support)

TestFlight-critical behaviors that simulators can't validate: HealthKit authorization UX + real data + background delivery, local notification delivery/deep links, widget install + interactive App-Group queue, photo picker with a real library.

Steps for the human (agent can drive the build):

1. Plug in the iPhone, enable Developer Mode (Settings → Privacy & Security → Developer Mode).
2. Build to device: `xcodebuild -project Fuel.xcodeproj -scheme Fuel -configuration Debug -destination 'platform=iOS,name=<device name>' -allowProvisioningUpdates build` (first run registers the device and mints profiles), or just Run from Xcode.
3. Manual pass: complete onboarding; grant HealthKit read access and confirm real steps/energy appear on Today; log a meal from a real photo; add the widget to the home screen and tap its interactive controls; schedule a notification and tap it from the lock screen (deep link should land correctly); relaunch and confirm persistence; toggle airplane mode and confirm search degrades to local catalog gracefully.

### Acceptance criteria (WS8)

- Release-config build installs and runs signed on hardware; the manual pass above completes without a crash or dead-end; HealthKit data renders.

---

## Workstream 9 — Archive, export, upload (agent runs; human confirms in ASC)

All commands from `/Users/pak/Projects/Fuel`. Prereqs: WS1-4 merged, WS6 done, Team ID in pbxproj (WS8.1), API key at `~/private_keys/AuthKey_<KEYID>.p8`.

### 9.1 One-time: `Config/ExportOptions.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>TEAMID_HERE</string>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
```

(`destination: upload` sends the build straight to ASC during export — no separate upload tool needed. `altool` is gone in current Xcode; the fallbacks are `destination: export` + the Transporter app, or Xcode Organizer.)

### 9.2 Per-upload: bump the build number

`CURRENT_PROJECT_VERSION = 1` is hardcoded per-config in `project.pbxproj` for both targets. Simplest reliable bump that keeps app and widget matched (they must match): pass it as a command-line override on the archive (applies to every target uniformly):

```bash
BUILD_NUMBER=2   # increment for every upload; MARKETING_VERSION stays 1.0
```

### 9.3 Archive (Release; scheme already archives Release with `FUEL_BACKEND_ENVIRONMENT=production` via `Config/Production.xcconfig`)

```bash
xcodebuild \
  -project Fuel.xcodeproj \
  -scheme Fuel \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Fuel.xcarchive \
  CURRENT_PROJECT_VERSION=${BUILD_NUMBER} \
  archive \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/private_keys/AuthKey_<KEYID>.p8 \
  -authenticationKeyID <KEYID> \
  -authenticationKeyIssuerID <ISSUER_ID>
```

`-allowProvisioningUpdates` + the API key lets xcodebuild create the Apple Distribution cert and App Store profiles for `com.pak.fuel` and `com.pak.fuel.widgets` non-interactively. Expect `** ARCHIVE SUCCEEDED **`.

### 9.4 Export + upload to App Store Connect

```bash
xcodebuild -exportArchive \
  -archivePath build/Fuel.xcarchive \
  -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/private_keys/AuthKey_<KEYID>.p8 \
  -authenticationKeyID <KEYID> \
  -authenticationKeyIssuerID <ISSUER_ID>
```

Success = `EXPORT SUCCEEDED` and an upload confirmation in the log. (To sanity-check a build without uploading, temporarily set `destination` to `export` — you get `build/export/Fuel.ipa` to inspect/verify in Transporter.)

### 9.5 After upload (human, in ASC)

1. ASC → Fuel → TestFlight → iOS Builds: the build appears "Processing" (10-60 min), then becomes available. No Missing Compliance prompt should appear (WS1.3).
2. Add the build to the Internal Testing group → testers get the TestFlight push → install on device.

### Acceptance criteria (WS9)

- Build visible and installable in TestFlight on a physical iPhone via an internal group; icon and full-screen launch correct on device; no ITMS emails flagging icon/launch/encryption/privacy issues.

---

## What is explicitly deferred to v2 (do not block TestFlight on these)

- Backend deployment (`Backend/README.md` spec): auth, cloud sync, remote recognition, cloud export/delete. Unlocks re-enabling the SIWA section (WS3.2 gate flips on automatically once `FUEL_BACKEND_BASE_URL` is set — the plist mapping from WS4.4 makes that work on device builds), restoring the privacy-manifest collected-types and redoing the ASC App Privacy answers.
- StoreKit 2 + real premium features (or permanent removal of the premium concept).
- Real camera capture (`AVCapture` + `INFOPLIST_KEY_NSCameraUSageDescription`) and a food-specific CoreML model with portion heuristics.
- Final icon artwork, dark/tinted icon variants, launch-screen branding.
- Dead backend-client capabilities and unused analytics events (wire or delete).

## Suggested execution order (critical path)

1. **Today (parallel):** Human starts WS6 enrollment (the ~24-48h approval is the longest pole). Agents run WS1 → WS2 → WS3 → WS4 → WS5-draft as one PR series; simulator smoke test after each.
2. **When enrollment lands:** Human does WS6 steps 2-6 and WS7 (~1 hour of console work). Hosts the WS5 policy.
3. **Same day:** Agent applies WS8.1 (team ID), human runs WS8.2 device pass.
4. **Then:** WS9 archive + upload; human distributes to internal testers.

Total: roughly one agent-day of code, one human-hour of console work, plus Apple's enrollment and build-processing latency.
