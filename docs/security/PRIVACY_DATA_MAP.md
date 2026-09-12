# Fuel Privacy Data Map

| Data | Purpose | Default storage | Leaves device? | Retention | Access | Export / deletion |
| --- | --- | --- | --- | --- | --- | --- |
| Profile name, age range, height, weight, goals, dietary preferences | Targets and personalization | SwiftData, protected app container | Only when cloud sync is explicitly enabled | Until edited or deleted | App process; authenticated account service when enabled | JSON export; local and remote deletion |
| Meals, food items, portions, nutrients, notes, corrections | Logging, summaries, insights | SwiftData | Only when cloud sync is explicitly enabled | Until edited or deleted | App process; authenticated account service when enabled | JSON export; local and remote deletion |
| Meal photos | Recognition and visual history | Protected Application Support files | No in the default on-device recognizer; only with explicit future upload/retention consent | Until meal/pending scan deletion; a deleted meal photo has a protected 15-second in-app Undo quarantine, then is erased; server policy must define uploaded-photo TTL | App process; isolated recognition service when enabled | Not in JSON export; deleted with meal/pending scan/account policy |
| Hydration entries | Daily hydration summary | SwiftData | Only when cloud sync is explicitly enabled | Until edited or deleted | App process; authenticated account service when enabled | JSON export; local and remote deletion |
| HealthKit activity, sleep, workouts, body measurements, heart-rate summaries | On-device wellness summary | HealthKit plus short-lived daily summary cache | No in the current sync contract | Cache until recalculation/deletion; source remains controlled by HealthKit | App process after category permission | Not included in Fuel export; remove app permission/data through iOS/Health controls |
| Apple opaque user identifier | Optional account continuity | Keychain; one-way hash in SwiftData metadata | Sent only to account backend during Sign in with Apple | Until sign-out/account deletion | Account service only | Deleted on sign-out/account deletion |
| Access and refresh tokens | Authenticated backend calls | Keychain with ThisDeviceOnly accessibility | Sent as HTTPS authorization credentials | Until expiry, sign-out, or deletion | Backend client only | Never exported; deleted on sign-out/deletion |
| Widget summary | At-a-glance score and remaining targets | App Group UserDefaults | No | Replaced after every refresh; cleared with local deletion | Fuel app and Fuel widget extension only | Not separately exported; cleared with local deletion |
| Pending hydration commands and scans | Offline durability and retry | Hydration: atomically replaced JSON in the App Group, protected until first unlock, with a stable cross-process lock; scans: SwiftData and protected photo files | Only after configured sync/recognition and retry | Until processed, cancelled, or deleted; legacy hydration preferences migrate once into the file queue | App, widget intent, configured recognition service | Commands removed by ID after persistence acknowledgement; queue cleared with local deletion; storage errors are surfaced |
| Diagnostic events and MetricKit payload summaries | Reliability and performance | Unified logging / local diagnostic files | No in the current build | OS/local retention | Developer on a consenting diagnostic device | Removed with app/container; never includes health/account content |

## Network domains

- Open Food Facts may receive a branded-food search string. It does not receive meal photos, profile data, HealthKit data, or account credentials.
- A Fuel backend has no default URL in source. When configured, it must be HTTPS (localhost HTTP is Debug-only) and follow the server contract in `Backend/README.md`.
- No advertising, tracking, or cross-app profiling domains are used.

## Change control

Update this map, `PrivacyInfo.xcprivacy`, App Store privacy answers, in-app privacy copy, and backend retention documentation together whenever a new field or transfer is introduced.
