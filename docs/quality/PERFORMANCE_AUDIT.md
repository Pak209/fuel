# Fuel Performance Audit

A code-first SwiftUI performance pass over the current tree: what the code
actually does today, what already mitigates cost, what is still a plausible hot
spot, and a runbook for capturing real traces. Every claim below cites a file;
nothing here substitutes for the "Trace evidence" section, which is explicitly
marked pending.

## Findings and current mitigations

### Image handling is downsampled before the expensive work, twice

- **Recognition upload prep** — `MealImageProcessor.prepareForRecognition`
  (`Fuel/Services/FoodServices.swift:207-219`) decodes with `UIImage(data:)`,
  scales to a maximum dimension of 1,600pt (never upscales — `min(1, ...)`),
  and re-encodes as JPEG at quality 0.82 before the image is used for
  recognition or upload. This bounds both memory (one scaled `UIGraphicsImageRenderer`
  buffer, not the original-resolution bitmap) and the request body size checked
  against `BackendEndpoint.maximumRequestBytes` (`Fuel/Services/BackendServices.swift:49-52`).
- **On-device classification path** — `OnDeviceFoodRecognitionService.analyze`
  (`Fuel/Services/FoodServices.swift:227-236`) does not run Vision on the
  full-resolution image at all. It creates a `CGImageSource` and asks for a
  thumbnail via `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceThumbnailMaxPixelSize: 1_200` and
  `kCGImageSourceCreateThumbnailFromImageAlways: true`, so the decoder itself
  produces a bounded-size `CGImage` rather than fully decoding and then
  resizing — this is the cheaper of the two paths for CPU/memory because the
  downsampling happens inside ImageIO during decode, not after.

### The SwiftData query layer uses predicates, not full-table scans in Swift

`SwiftDataMealRepository.meals(in:)` and `SwiftDataHydrationRepository.entries(in:)`
build a `FetchDescriptor` with a date-range predicate
(`Fuel/Persistence/Repositories.swift:119-130`, `:226-236`) rather than fetching
everything and filtering in Swift. Filtering happens in the persistence layer.

### `DailySummaryService`'s "cache" is a resilience fallback, not a memoization cache — this is worth correcting explicitly

The obvious assumption is that `DailySummaryCacheRecord` exists to skip
recomputation on the common path. That is **not** what the code does.
`DailyDataCoordinator.snapshot(for:profile:targets:)`
(`Fuel/Services/DailySummaryService.swift:98-135`) unconditionally re-fetches
HealthKit activity/sleep/workouts/body data, re-reads meals/hydration from
SwiftData, and rebuilds the snapshot via `DailySummaryService.build` on *every*
call — there is no "is the cache still fresh, return early" check anywhere in
this method. The cache is only read in the `catch` block, as a fallback when
the live rebuild throws (e.g., a HealthKit query failure), and the returned
snapshot is marked `isFromCache = true` (`:129-131`), which
`TodayView.swift:39` surfaces to the user as "Cached summary" text. It is
persisted after every successful rebuild via `summaryCache.save(...)`
(`:122`) precisely so that fallback has fresh data to fall back to, not to
avoid the rebuild next time.

Practically: this means the "cache" does not reduce the cost of `TodayView`'s
per-appearance/per-date-change data path. It is a correctness/availability
feature (don't show nothing if HealthKit errors), and should not be cited
elsewhere as a performance optimization. If avoiding redundant full rebuilds on
unchanged days becomes a real goal, this is the place a genuine memoized fast
path would need to be added — `sourceRevision(meals:hydration:)`
(`Fuel/Services/DailySummaryService.swift:532` area) already computes a
revision hash that a real cache-hit path could compare against, but nothing
currently reads it back for that purpose.

### `ViewThatFits` avoids hard-coded breakpoints, at the cost of building both branches

`ViewThatFits` is used in three places to let SwiftUI choose between a
horizontal and a stacked/scaled layout instead of hand-rolled size-class logic:

- `Fuel/Features/Today/TodayView.swift:294-298` (`DailyMetricsRow`, choosing
  `HStack` vs `VStack` for the metric cards)
- `Fuel/UI/Components.swift:69-76` (`MetricCard`'s value and detail text,
  choosing plain vs `.minimumScaleFactor(0.6)` variants)

`ViewThatFits` works by laying out every candidate view once to see which
fits, then discarding the ones it doesn't use. For the small, static-content
views here (a handful of text/icon rows) this is a reasonable, low-risk trade:
the discarded branch is cheap to build. It is not free, though — if this
pattern were extended to large or deeply nested subtrees, the "layout it twice
(or three times) to pick one" cost would start to matter. Worth confirming
during a scrolling trace (see runbook) rather than assuming it's negligible at
every call site.

### Network retry and backoff are bounded, not open-ended

Two independent retry mechanisms exist and both have caps:

- **Per-request transport retry.** `BackendAPIClient.send(...)`
  (`Fuel/Services/BackendServices.swift:348-406`) retries up to 3 attempts
  total for retryable failures (429, 408, 5xx, and other non-terminal errors),
  with a linear 0.5s/1.0s delay between attempts (`:400-402`). Terminal errors
  (401/403, invalid payload, payload too large) are not retried at all
  (`:395`). Each request carries its own timeout —
  `request.timeoutInterval = endpoint == .photoAnalysis ? 45 : 20`
  (`:363`) — layered under the `URLSessionConfiguration`'s
  `timeoutIntervalForRequest = 20` / `timeoutIntervalForResource = 45`
  (`Fuel/Services/BackendServices.swift:103-104`), so a stalled connection
  cannot hang indefinitely.
- **Queue-level retry (sync + pending recognition).** Both
  `DailyDataCoordinator.markSyncFailed` and `.markRecognitionFailed`
  (`Fuel/Services/DailySummaryService.swift:455-465`, `:355-365`) use the same
  bounded exponential backoff: `min(pow(2, attempts) * 30, 6 * 60 * 60)`
  seconds (30s doubling up to a 6-hour ceiling), and both stop offering the
  record for automatic retry once `attempts >= maxRetryAttempts` (8,
  `Fuel/Services/DailySummaryService.swift:73`). This bounds both the number of
  background network wake-ups a stuck record can cause and how long it keeps
  trying.

### Signposting exists for cold launch and image processing, but nothing calls it yet for those two

`FuelSignpost` (`Fuel/System/Observability.swift:60-104`) defines named
`OSSignposter` intervals for `coldLaunch`, `snapshotRebuild`, and
`imageProcessing`, with `begin`/`end`/`measure` helpers. Searching the app
target for call sites of `FuelSignpost.begin`, `.measure`, or `.end` currently
turns up the definitions only — no call site wraps app launch or the image
pipeline with these signposts yet. This means Instruments' Points of Interest
track will be empty for these intervals until they're wired up; a Time
Profiler/App Launch trace still works without them (see runbook), but the
custom, named intervals this file was clearly built to support are not yet
populated.

## Known hot spots (plausible from reading the code; not yet trace-confirmed)

- **`snapshots(ending:days:)` builds N days sequentially, each with its own
  HealthKit round-trip.** `DailyDataCoordinator.snapshots(ending:days:profile:targets:)`
  (`Fuel/Services/DailySummaryService.swift:140-151`) loops over the requested
  day range and does `values.append(try await snapshot(for: day, ...))` one day
  at a time — there is no concurrency across days, only the four
  `async let` HealthKit calls *within* a single day's `snapshot(for:)`
  (`:100-104`). `InsightsView` (`Fuel/Features/Insights/InsightsView.swift`)
  drives this for 7- and 30-day ranges. A 30-day insights load is therefore up
  to 30 sequential HealthKit+SwiftData+recompute cycles, each of which also
  does a full (non-cached, see above) rebuild. This is the most likely
  candidate for a visible stall and is worth a dedicated Time Profiler run
  scoped to opening Insights with the 30-day range selected.
- **Widget/App Group summary republishing.** Every successful `loadInitialData()`
  and `refresh()` call ends with `publishWidgetSummary()`
  (`Fuel/App/AppState.swift:155`, `:171`); this is cheap in isolation but
  compounds with however often `refresh()` is invoked (date changes, pull to
  refresh, connectivity restoration) — worth checking in a trace rather than
  assuming.
- **`ViewThatFits` at scale** — see above; currently only used on small
  subtrees, flagged here so a future addition to a larger view doesn't silently
  regress layout cost.

## Runbook: capturing cold-launch and scrolling traces (iPhone 16 simulator)

These commands assume Xcode's command-line tools are installed and the
scheme/bundle values already in this repo: scheme `Fuel`
(`Fuel.xcodeproj/xcshareddata/xcschemes/Fuel.xcscheme`), bundle identifier
`com.pak.fuel` (`Fuel.xcodeproj/project.pbxproj`), deployment target iOS 18.0.

1. **Confirm/boot an iPhone 16 simulator.**
   ```sh
   xcrun simctl list devices available | grep "iPhone 16"
   # If not booted:
   xcrun simctl boot "iPhone 16"
   open -a Simulator
   ```

2. **Build a Release-configuration app for the simulator** (Debug builds skew
   cold-launch numbers with extra instrumentation/dynamic linking overhead):
   ```sh
   xcodebuild -project Fuel.xcodeproj -scheme Fuel -configuration Release \
     -destination 'platform=iOS Simulator,name=iPhone 16' \
     -derivedDataPath build clean build
   ```

3. **Install the built app:**
   ```sh
   xcrun simctl install "iPhone 16" \
     build/Build/Products/Release-iphonesimulator/Fuel.app
   ```

4. **Cold-launch trace** with the "App Launch" template (measures time to
   first frame / time to interactive) and, separately, "Time Profiler" for CPU
   hot paths during launch:
   ```sh
   xcrun xctrace record --template 'App Launch' \
     --device "iPhone 16" \
     --launch com.pak.fuel \
     --output ~/Desktop/Fuel-ColdLaunch-AppLaunch.trace

   xcrun xctrace record --template 'Time Profiler' \
     --device "iPhone 16" \
     --launch com.pak.fuel \
     --output ~/Desktop/Fuel-ColdLaunch-TimeProfiler.trace
   ```
   Force-quit the app between runs (`xcrun simctl terminate "iPhone 16" com.pak.fuel`)
   so each launch is genuinely cold. Repeat 3-5 times and use the median, not a
   single run.

5. **Scrolling / interaction trace** using "Animation Hitches" (surfaces
   dropped frames and hitches directly) plus "Time Profiler" for the same
   session, attaching to an already-running instance instead of relaunching:
   ```sh
   xcrun simctl launch "iPhone 16" com.pak.fuel
   xcrun xctrace record --template 'Animation Hitches' \
     --device "iPhone 16" \
     --attach com.pak.fuel \
     --output ~/Desktop/Fuel-Scroll-Hitches.trace
   ```
   While this is recording, manually exercise the representative scroll paths:
   the Today tab's timeline list, Insights with the 30-day range selected
   (the hot spot flagged above), and the Meals list with a non-trivial number
   of logged meals. Stop recording (`Ctrl+C` in the same terminal, or via the
   Instruments UI if `--attach` opened one) after covering all three.

6. **Open and inspect** with `open ~/Desktop/Fuel-ColdLaunch-AppLaunch.trace`
   (etc.) — Instruments will launch to view it. Look specifically at: time to
   first `FuelApp.body` render, time spent in `ModelContainer` initialization
   (`Fuel/App/FuelApp.swift:11-27`), and — once `FuelSignpost` call sites are
   added per the finding above — the `ColdLaunch` and `SnapshotRebuild`
   Points-of-Interest lanes.

7. **Memory pass for image handling**, using "Allocations" while repeatedly
   triggering meal-photo recognition (Scan tab) to confirm the downsampled
   paths in `MealImageProcessor` and `OnDeviceFoodRecognitionService` (see
   above) keep peak memory bounded rather than spiking with original-resolution
   decodes:
   ```sh
   xcrun xctrace record --template 'Allocations' \
     --device "iPhone 16" \
     --attach com.pak.fuel \
     --output ~/Desktop/Fuel-Scan-Allocations.trace
   ```

## Trace evidence

**Pending capture.** No `.trace` files have been captured or attached to this
document. The findings above are static-analysis conclusions from reading the
source; they identify what the code does and where it plausibly costs time or
memory, but none of it is a substitute for running the runbook above on the
iPhone 16 simulator (or a physical device — see `docs/quality/RELEASE_GATES.md`
for why physical-device validation is a separate, external gate) and recording
actual numbers. Until traces are attached here, treat every "hot spot" above as
a hypothesis to confirm, not a measured regression.
