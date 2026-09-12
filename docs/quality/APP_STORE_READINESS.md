# Fuel — App Store / TestFlight Readiness Report

> **Historical snapshot — 2026-08-22.** The report below preserves the findings and
> citations from that audit; its blockers and time estimates are not the current
> task list. [REMAINING_SCOPE.md](REMAINING_SCOPE.md) is the authoritative current
> scope, and [RELEASE_GATES.md](RELEASE_GATES.md) defines the remaining release evidence.

Current source already assigns team `5YJJCSFSQM` to the app and widget, maps
`AppIcon.png` in the app icon catalog, and includes `UILaunchScreen`, the backend
URL mapping, and the encryption declaration in `Fuel/Info.plist`. The in-app
privacy policy and hostable policy files also exist. Sign in with Apple is gated
on a configured backend and its entitlement is absent from the local-only build.
These corrections supersede the corresponding "empty", "missing", and "no team"
claims below. They establish source changes, not App Store acceptance or completion
of the device, backend, and human-review gates. Other historical findings likewise
need their current source and test evidence checked before being treated as pending.

Sources for this correction: `Fuel.xcodeproj/project.pbxproj`,
`Fuel/Assets.xcassets/AppIcon.appiconset/Contents.json`, `Fuel/Info.plist`,
`Fuel/Fuel.entitlements`, `Fuel/Features/Profile/ProfileView.swift`,
`Fuel/Features/Profile/PrivacyPolicyView.swift`, and `docs/legal/privacy-policy.md`.

Synthesized from five dimension audits (product, submission artifacts, signing, runtime, backend/services) on 2026-08-22. Contested findings were re-verified directly against the repo; citations are preserved on every item.

---

## 1) Verdict

Fuel is much closer to a real app than a prototype: it compiles with zero warnings, produces a clean unsigned Release archive with the widget embedded, launches and runs without crashing on the iPhone 16 simulator, and every local journey — 8-step onboarding, Today dashboard, full meal CRUD, food search (local catalog + live Open Food Facts), hydration, insights, local notifications with deep links, interactive widgets via an App Group queue, Spotlight, JSON export, delete-all, and a genuinely complete read-only HealthKit integration — is implemented end to end, not mocked (archive: `** ARCHIVE SUCCEEDED **` with `FuelWidgets.appex` embedded; runtime smoke test passed with data persisting across relaunch). What separates it from a TestFlight build is small in code terms and large in account terms: two code-fixable blockers (an entirely empty app icon set and a missing launch screen that letterboxes the app on every modern iPhone) plus the entire human-side stack — no Apple Developer team, no distribution certificate, no App ID/capability registration for its HealthKit/Sign-in-with-Apple/App-Group entitlements, and no App Store Connect record or privacy policy (mandatory for a HealthKit app). Beyond that, the biggest quality risks are a SwiftData crash-loop path that bypasses the designed recovery screen, two advertised-but-dead surfaces (a Fuel+ premium card with no StoreKit and a Sign in with Apple button with no backend) that need a product decision, and a photo-recognition pipeline that is honest but weak and can burst past Open Food Facts rate limits. With roughly a day of code fixes plus the Apple account work, this is a credible TestFlight candidate.

---

## 2) Blockers (code-fixable)

Ranked by impact on getting a usable build into TestFlight.

1. **App icon set is completely empty.** `Fuel/Assets.xcassets/AppIcon.appiconset/Contents.json` is `{"images":[],"info":{...}}` with no PNGs in the directory (verified); the built app contains no `Assets.car` and its Info.plist has no `CFBundleIcons`/`CFBundleIconName` despite `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` (project.pbxproj:185); the home screen shows the gray placeholder grid icon (runtime screenshot `clean-t8.png`). App Store Connect rejects uploads without the 1024×1024 marketing icon (ITMS-90022/90713-class errors), so this alone prevents TestFlight distribution. *Fix:* add a 1024×1024 PNG (no alpha) in the Xcode 16 single-size universal format. An agent can generate a placeholder now; final artwork is a branding call (see human decisions).
2. **No launch screen anywhere — app runs letterboxed in legacy compatibility mode.** `grep -rn "UILaunchScreen|LaunchStoryboard"` across `Fuel.xcodeproj/project.pbxproj`, `Fuel/Info.plist`, and `Config/*.xcconfig` returns nothing (re-verified: exit 1); no `INFOPLIST_KEY_UILaunchScreen_Generation` in any build configuration; runtime screenshots `launch-t0.png`/`clean-t4.png` show ~300px black bars top and bottom on the iPhone 16 simulator. Auditors disagreed on severity (major vs. blocker); resolved as a blocker: the letterboxing is directly observed on every screen, upload validation has required a launch screen since 2020, and the fix is one line. *Fix:* add `INFOPLIST_KEY_UILaunchScreen_Generation = YES` to all three Fuel-target build configurations (or a `UILaunchScreen` dict in `Fuel/Info.plist`).

---

## 3) Blockers (require the human)

Filed into PakOS Actions Needed; listed here as the system of record pointer.

1. **Apple Developer team, signing, and capability registration.** `DEVELOPMENT_TEAM = ""` in all six app/widget configurations with `CODE_SIGN_STYLE = Automatic` (project.pbxproj:189, 211-212, 223, 247, 270 — re-verified); `security find-identity` shows only an Apple Development cert (team TQ2X6D6PVH) and a macOS Developer ID cert (team 5YJJCSFSQM) — no Apple Distribution identity. The entitlements (`Fuel/Fuel.entitlements:5-16`: HealthKit + background delivery, Sign in with Apple, app group `group.com.pak.fuel`; `FuelWidgets/FuelWidgets.entitlements:5-8`) all require a paid Apple Developer team, App IDs `com.pak.fuel` / `com.pak.fuel.widgets` registered with those capabilities, and the app group created — and assume `com.pak.fuel` is still available. Simulator builds only succeed with `CODE_SIGNING_ALLOWED=NO`. ⚑ *filed action: Set up Apple Developer team and signing for Fuel [high]*
2. **App Store Connect record and HealthKit-app compliance.** No app record exists; primary category unset (chosen in ASC; `LSApplicationCategoryType` absent and not required on iOS); HealthKit apps must provide a privacy policy URL in ASC and an accessible in-app policy (App Review 5.1.1/5.1.3) — no privacy-policy URL or in-app policy screen exists anywhere in the repo (grep across `Fuel/Features/`); App Privacy questionnaire and export-compliance answers are outstanding; `docs/quality/RELEASE_GATES.md` and `PHASES6_9_ROADMAP.md:119-127` explicitly list these as uncompleted external gates. ⚑ *filed action: Create App Store Connect record and HealthKit compliance for Fuel [high]*

---

## 4) Major gaps

Ranked by real-world risk to a TestFlight user.

1. **SwiftData store-open failure hard-crashes in a loop instead of showing the designed recovery screen.** Eight SIGABRT crash reports in 12 seconds were captured this morning (`Fuel-2026-08-22-125107.ips`–`125119.ips`): an ObjC exception rethrown inside `-[NSPersistentStoreCoordinator addPersistentStoreWithDescription:]` during `ModelContainer(for:migrationPlan:)`. The Swift `do/catch` in `Fuel/App/FuelApp.swift:38-48` (re-verified) only catches Swift errors, so the in-memory fallback and `StartupFailureView` never engage for this failure class. The current V3 schema launches cleanly, but any store the migration plan cannot open will crash-loop users on upgrade. *Fix (code):* validate store metadata via an ObjC-exception-catching shim before constructing the on-disk container, routing incompatible stores to the recovery path.
2. **Fuel+ premium is a dead end: a permanently locked card advertising features that do not exist and cannot be bought.** `ProfileView.swift:44-46` renders `LockedFeatureCard` promising "Weekly reports, deep insights, meal plans, family mode and AI chat" (re-verified); there is zero StoreKit code in the repo (`grep -rn StoreKit/purchase/paywall` empty); `AppState.swift:70` wires `MockEntitlementService()` hardcoded to tier `.free` (`AppServices.swift:802-811`, re-verified); `canAccess()`/`PremiumFeature` have no call sites in any view. App Review may flag advertised-but-unpurchasable content. *Fix:* delete the section for v1 (trivial code change) or build StoreKit 2 + real features — which path is a business decision. ⚑ *filed action: Decide Fuel v1 scope: premium card and Sign in with Apple/cloud sync [medium]*
3. **Sign in with Apple and cloud sync are dead ends in this build.** `FUEL_BACKEND_BASE_URL =` is empty in all three `Config/*.xcconfig` files (re-verified), so `BackendAPIClient.isConfigured` is false (`BackendServices.swift:28`) and the entire backend stack (auth, sync, cloud export, remote deletion, remote recognition, remote config) is unreachable; `Backend/` contains only a README stating "it is not evidence that a production service has been deployed" (Backend/README.md:3). The SIWA button still always renders when signed out (`ProfileView.swift:132-150`, re-verified) but only stores a local identifier hash — "Apple identity saved; cloud remains unconfigured" (`AppState.swift:353`, `BackendServices.swift:533-551`); the cloud sync toggle is permanently disabled (`ProfileView.swift:115`). *Fix:* gate the "Optional account" section on `state.accountSummary.backendConfigured` for a local-only v1 (one-line condition), or deploy the specced backend — hosting and spend are human decisions. ⚑ *covered by the filed scope-decision action above*
4. **Photo recognition can burst past Open Food Facts' rate limit (10 searches/min), risking an IP block that also kills user-facing search.** `OnDeviceFoodRecognitionService` iterates up to 8 Vision observations and calls `database.search(label)` for each (`FoodServices.swift:243-254`); `CompositeFoodDatabaseService` forwards every one to the legacy `cgi/search.pl` endpoint (`FoodServices.swift:99, 189-205`); interactive search is debounced only 300ms with no caching (`MealEditorView.swift:478`). One photo scan ≈ 8 remote searches; two scans in a minute exceeds the documented limit. The required identifiable User-Agent is present (`FoodServices.swift:111` — good). *Fix (code):* resolve recognition labels against the local catalog only, add a search cache and client-side rate limiter, migrate to the OFF v2 search API.
5. **The recognition marquee feature is real but weak.** The wired default (`AppState.swift:87`, re-verified) is a genuine Vision `VNClassifyImageRequest` — not the unused mock — but it uses Apple's generic taxonomy with a 0.05 confidence floor, takes the first search hit per label, fixes every portion to "1 serving", and the offline fallback catalog is only 23 foods (`FoodServices.swift:227-281, 42-66`). Results are honestly flagged `isPartial` with a warning, so it is shippable, but expect frequent "No supported food was recognized" on real meals. *Fix:* bundle a food-specific CoreML model with a curated label→food mapping and portion heuristics, or wire the specced backend recognition path (backend + model costs = human decision).
6. **The app promises a camera it does not have.** The home-screen quick action says "Scan a meal / Open the meal camera" with a `camera.viewfinder` icon (`Fuel/Info.plist:20-32`, re-verified) and the Siri intent says "Open Fuel's meal camera and editor" (`FuelShared/SharedEngagement.swift:128`; repeated at `AppRouting.swift:54`), but `ScanView.swift:98` uses only `PhotosPicker` — no AVCapture/UIImagePickerController code exists anywhere and there is no `NSCameraUsageDescription` (grep empty). *Fix:* reword the shortcut/intent copy to "Choose a meal photo" (minutes), or implement real camera capture (+ `INFOPLIST_KEY_NSCameraUsageDescription`).
7. **[HUMAN] Nothing has been validated on a physical device.** HealthKit background delivery, real Health data, the read-only authorization UX, notifications, and widgets only behave realistically on hardware (`AppServices.swift:497-754` is a complete real implementation; `PHASES6_9_ROADMAP.md` external gates list physical-device validation as outstanding). Requires a signed device build, i.e. the developer account. ⚑ *filed action: Validate Fuel on a physical iPhone before TestFlight [medium]*

---

## 5) Minor polish

1. **Backend base URL can never reach a device build even once a backend exists.** `BackendConfiguration.load` reads the bundle key `FUEL_BACKEND_BASE_URL` (`BackendServices.swift:23-25`), but `Fuel/Info.plist` maps only `FUEL_BACKEND_ENVIRONMENT` (re-verified) and no `INFOPLIST_KEY` exists for the URL — only the env-var path (Xcode-launched runs) works. *Fix:* add `<key>FUEL_BACKEND_BASE_URL</key><string>$(FUEL_BACKEND_BASE_URL)</string>` to `Fuel/Info.plist`. Latent until a backend ships.
2. **`ITSAppUsesNonExemptEncryption` is not declared**, so every TestFlight build sits in "Missing Compliance" until answered manually in ASC (grep across repo empty; `Fuel/Info.plist` lacks the key — re-verified). *Fix:* add `<key>ITSAppUsesNonExemptEncryption</key><false/>` (HTTPS/system crypto only); the false attestation is a legal statement the owner should be aware of.
3. **Privacy manifest UserDefaults reason is incomplete.** `Fuel/PrivacyInfo.xcprivacy` declares only `1C8F.1` (app-group defaults) — re-verified — but the app also uses `UserDefaults.standard` directly (`AppServices.swift:782`, `Analytics.swift:80`, `FeatureFlags.swift:81`), covered by `CA92.1`. Won't fail today's automated check; the manifest is simply inaccurate. *Fix:* add `CA92.1` to the reasons array.
4. **`Fuel.entitlements` ships inside the app bundle as a stray resource.** The app target's synchronized-group exception set excepts only `Info.plist` (`project.pbxproj:84`, re-verified) while the widget group correctly excepts its entitlements (`:79`). Harmless to validation. *Fix:* add `Fuel.entitlements` to exception set `FF0000000000000000000002`.
5. **No AccentColor asset**, so system-drawn UI (alert buttons, untinted toggles) renders default iOS blue against the app's `FuelTheme.green` tint (`Fuel/Assets.xcassets` contains only AppIcon; no `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in pbxproj; `FuelApp.swift:58` tints manually). *Fix:* add an AccentColor color set + build setting.
6. **Fake notification badge.** The Today header bell renders an unconditional red dot (`TodayView.swift:211-213`) implying unread notifications; no inbox exists — tapping opens preferences. *Fix:* remove or bind to a real condition.
7. **Floating tab bar clips content on the Today dashboard** — card text ("2,450 left", "No Health data") is cut off with no bottom content inset (runtime screenshots `launch-t5.png`, `clean-t4.png`). *Fix:* add `safeAreaInset`/bottom padding matching the bar height.
8. **Open Food Facts ODbL attribution is minimal.** The captured per-product `attributionURL` (`DomainModels.swift:163`, set at `FoodServices.swift:155`) is never surfaced in UI, and there is no ODbL license notice — only the label "Open Food Facts · branded search" (`ProfileView.swift:536`). *Fix:* tappable product links + a license line in DataSourcesView.
9. **Dead/unwired code.** `SectionHeader` has an empty action closure and zero call sites (`Components.swift:93-107`); `remoteConfiguration()`/`RemoteConfigurationRecord` are never called (`BackendServices.swift:424`); analytics events `scanSucceeded`, `scanFailed`, `notificationOpened`, `remoteConfigurationApplied`, and source `.siriShortcut` are never recorded (and `analyticsCollectionEnabled` defaults false, `FeatureFlags.swift:36`); five backend client capabilities (recognition upload, nutrition proxy, remote recommendations, profile fetch/update, remote config) have zero call sites outside `BackendServices.swift`; `MockFoodRecognitionService` is referenced only in tests (`FuelTests/FuelTests.swift:234`). *Fix:* delete or wire; track backend endpoints as v2 items.

---

## 6) Explicitly fine as-is

Things that look missing or minimal but are acceptable for TestFlight.

- **Build and archive health.** Debug build compiles with zero warnings; unsigned Release archive succeeds with `FuelWidgets.appex` embedded; the archive scheme uses Release and resolves `FUEL_BACKEND_ENVIRONMENT=production` (xcodebuild `** ARCHIVE SUCCEEDED **`; `Fuel.xcscheme` ArchiveAction). Compilation is not a blocker.
- **Runtime smoke test passes.** Installs, launches, onboarding/dashboard/meal-logging render, data persists across relaunch, widget extension registers and loads cleanly; console shows only benign simulator noise (simctl launch PID 7892; chronod reload logs for `com.pak.fuel.widgets`; 10s scoped log stream with no app-authored errors).
- **No push or iCloud entitlements — correct, not missing.** Notifications are purely local `UNUserNotificationCenter` triggers (`NotificationService.swift:173-220`); no `registerForRemoteNotifications` or CloudKit usage anywhere (grep empty), so the absent `aps-environment`/iCloud entitlements are consistent with the code.
- **HealthKit usage strings are correct for read-only access.** Authorization passes `toShare: []` (`AppServices.swift:519`), so only `NSHealthShareUsageDescription` is needed — present (project.pbxproj:194); the absence of `NSHealthUpdateUsageDescription` is correct.
- **No `NSCameraUsageDescription` — correct for the code as-is** (no camera API is used; it only becomes required if camera capture is added). `NSPhotoLibraryUsageDescription` is present though `PhotosPicker` doesn't strictly need it — harmless.
- **Versioning is consistent.** `MARKETING_VERSION 1.0` / `CURRENT_PROJECT_VERSION 1` on app and widget alike (project.pbxproj; archived Info.plists match). Just bump the build number per TestFlight upload going forward.
- **Widget extension packaging is correct** — appex plist, `SKIP_INSTALL`, App Group entitlements; both `PrivacyInfo.xcprivacy` files are bundled automatically via Xcode 16 synchronized groups.
- **iPhone-only, iOS 18 target is a valid posture.** `TARGETED_DEVICE_FAMILY = 1` and `IPHONEOS_DEPLOYMENT_TARGET = 18.0` consistently across targets; Xcode 26.6 / iOS 26.5 simulator comfortably covers it.
- **Local-only degradation is honest.** With no backend, the sync toggle is disabled, cloud export/delete buttons are disabled, storage reads "Local only", and explanatory copy is shown (`ProfileView.swift:96-101, 115, 126, 130`) — the app does not pretend to sync.
- **On-device recognition being modest is disclosed to the user.** Every result is flagged `isPartial` with a portions warning (`FoodServices.swift:278`) and goes through a review-before-save editor — honest enough for beta, with quality improvements tracked under Major gaps.
- **`MockEntitlementService` at tier `.free` is harmless for a free beta** once the Fuel+ card decision lands — no premium gate blocks any shipped feature (`AppState.swift:70`, `AppServices.swift:802-811`).

---

## Actions filed to PakOS

- ⚑ filed action: Set up Apple Developer team and signing for Fuel [high]
- ⚑ filed action: Create App Store Connect record and HealthKit compliance for Fuel [high]
- ⚑ filed action: Decide Fuel v1 scope: premium card and Sign in with Apple/cloud sync [medium]
- ⚑ filed action: Validate Fuel on a physical iPhone before TestFlight [medium]
