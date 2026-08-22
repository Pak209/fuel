# Fuel Accessibility Audit

A code-grounded accessibility pass over the current SwiftUI tree (iOS 18.0
minimum deployment target, confirmed in `Fuel.xcodeproj/project.pbxproj`).
Every line below was checked against the source at the time of writing. This
repository was under active, concurrent development while this audit was
written — several of the items below (notably validation announcements and
hit-target sizing) landed mid-session, and are called out explicitly as
**"in progress this change"** rather than presented as long-standing, stable
coverage. Re-run the greps in this document before treating any "gap" as still
open.

## Checklist mapped to code

### VoiceOver labels and combined elements

Present and reasonably broad. Custom composite views collapse their subviews
into one VoiceOver stop with `.accessibilityElement(children: .ignore)` (or
`.combine`/`.contain` where the sub-elements should remain individually
readable) plus an explicit `.accessibilityLabel`:

- `HealthScoreRing` — `Fuel/UI/Components.swift:15-16` — "Health score N out of 100"
- `MetricCard` — `Fuel/UI/Components.swift:88-89` — "{title}, {value}, {detail}"
- `NutrientProgressRow`-family ring — `Fuel/UI/Components.swift:56`
- `SectionHeader` title — `Fuel/UI/Components.swift:94` — `.accessibilityAddTraits(.isHeader)`
- `TransientMessageBanner` — `Fuel/App/FuelApp.swift:177` — `.combine`
- Insights summary card — `Fuel/Features/Insights/InsightsView.swift:63-64` — labeled with `report.accessibleSummary`
- Insights disclosure/insight card — `Fuel/Features/Insights/InsightsView.swift:206` — `.combine`
- Scan date/time group — `Fuel/Features/Scan/ScanView.swift:189` — `.contain`
- Meals empty-state — `Fuel/Features/Meals/MealsView.swift:306`
- Meal editor date/time group — `Fuel/Features/Meals/MealEditorView.swift:125` — `.contain`
- Meal editor food row — `Fuel/Features/Meals/MealEditorView.swift:155` — `.ignore`
- Widget hydration ring and score — `FuelWidgets/FuelWidgets.swift:70,134` — `.combine`

Discrete controls are individually labeled throughout `TodayView.swift`
(previous/next day, notifications, profile, add-event, mark-meal-completed —
see hit-target section below for exact lines), `ScanView.swift` (remove
photo/delete scan), `MealsView.swift` (calendar picker, log-meal, favorites,
filter chips), `MealEditorView.swift` (food row hint), and
`ProfileView.swift` (per-reminder time labels, e.g. line 403 and 413).

**Gap:** no screen was found using `.accessibilitySortPriority(` to control
VoiceOver traversal order explicitly; ordering currently relies entirely on
view-tree order, which is adequate for the mostly-linear layouts in this app
but should be spot-checked on `TodayView`'s stacked accessibility-size layout
(see Dynamic Type section) where visual order changes but traversal order may
not.

### Chart accessibility

The one Swift Charts usage in the app,
`InsightsView.trendChart` (`Fuel/Features/Insights/InsightsView.swift:71-83`),
has a complete, non-boilerplate treatment:

- Each `BarMark` carries its own `.accessibilityLabel` (the date) and
  `.accessibilityValue` (calories) — `InsightsView.swift:77-78`.
- `.chartYAxisLabel("Calories")` — `InsightsView.swift:80`.
- A full `AXChartDescriptorRepresentable` conformance, `TrendChartDescriptor`
  (`InsightsView.swift:138-178`), provides a categorical x-axis, numeric
  y-axis with a formatted-value closure, and a per-point `AXDataSeriesDescriptor`
  — this is what powers VoiceOver's Audio Graph / rotor navigation for the
  chart, not just per-mark labels. It's driven by `.accessibilityChartDescriptor(TrendChartDescriptor(report:))`
  at `InsightsView.swift:82`.
- The chart's caption text below it ("Days without meals remain visible as
  missing logs rather than being removed from the range") reinforces the
  color-independent meaning point from `PHASES6_9_ROADMAP.md`'s accessibility
  section — zero-calorie days are visually distinguished by gradient
  (`FuelTheme.panelRaised.gradient` vs `.green.gradient`,
  `InsightsView.swift:76`) but are also just as present/labeled in the data
  series, not silently dropped.

No other chart or custom-graphic view in the app needs equivalent treatment;
`HealthScoreRing` is a custom `Circle().trim` ring, not a Swift Charts view,
and is already collapsed to a single static label rather than exposed as an
interactive/adjustable element.

### Dynamic Type

No `.dynamicTypeSize(` (which would force a size) and no `@ScaledMetric`
exist anywhere in the app — sizing is left to the system default type scale.
Several views explicitly read (not force) `@Environment(\.dynamicTypeSize)`
and branch to a stacked/expanded layout at accessibility sizes via
`.isAccessibilitySize`:

- `DashboardHeader` — `Fuel/Features/Today/TodayView.swift:150,162`
- `CompactHealthScoreCard` — `Fuel/Features/Today/TodayView.swift:239,243`
- `TimelineRow` — `Fuel/Features/Today/TodayView.swift:482,485`
- `InsightsView` summary metrics — `Fuel/Features/Insights/InsightsView.swift:12,43`
- `MealsView` — `Fuel/Features/Meals/MealsView.swift:293,298`
- `OnboardingView` controls (stacks Back/Continue vertically at accessibility
  sizes instead of side-by-side) — `Fuel/Features/Onboarding/OnboardingView.swift:6,61`

`.minimumScaleFactor(` is used for text that would otherwise truncate at
larger sizes (`Fuel/UI/Components.swift:71,75`; `Fuel/Features/Today/TodayView.swift:164,171,180`),
and `.lineLimit(` is used extensively for bounded truncation, including a
range form (`lineLimit(2...5)`) on a multi-line field in
`Fuel/Features/Meals/MealEditorView.swift:209`.

**Not yet verified:** none of this has been checked against actual rendering
at the largest accessibility sizes in the simulator (AX5) — see the runbook
below. Reading `isAccessibilitySize` correctly in six places is a good sign,
but is not the same as having looked at the result.

### Reduce Motion

`HealthScoreRing` (`Fuel/UI/Components.swift:3-30`) is the only place in the
codebase that reads `@Environment(\.accessibilityReduceMotion)`, and it does
so correctly: both `.onAppear` and `.onChange(of: score)` branch to set the
displayed score directly when `reduceMotion` is true, and only use
`withAnimation(.easeOut(duration: 0.6))` when it's false
(`Fuel/UI/Components.swift:18-29`).

**Gap:** this is the *only* reduce-motion-aware code path in the app.
`UIAccessibility.isReduceMotionEnabled` is never referenced, and no other
`withAnimation` call site in the codebase (there are others, e.g. transient
message banners, tab transitions) checks the environment value. Anything
beyond the health-score ring's own animation should be assumed motion-unaware
until proven otherwise.

### Hit targets

This is the item that moved the most during this session. As of the current
state of the tree:

| Control | File:line | Explicit 44×44 target? |
| --- | --- | --- |
| `SectionHeader` action button | `Fuel/UI/Components.swift:102-103` | Yes |
| Today: previous/next day chevrons | `Fuel/Features/Today/TodayView.swift:183,194` | Yes |
| Today: notifications bell | `Fuel/Features/Today/TodayView.swift:213-215` | Yes (visual badge stays 34×34; tappable area is 44×44) |
| Today: profile avatar | `Fuel/Features/Today/TodayView.swift:222-224` | Yes |
| Today: "Add event" | `Fuel/Features/Today/TodayView.swift:410-412` | Yes |
| Today: "Mark meal completed" circle | `Fuel/Features/Today/TodayView.swift:430-432` | Yes |
| Onboarding: Back button | `Fuel/Features/Onboarding/OnboardingView.swift:76` | `minHeight: 44` only (width unconstrained, but the button has visible text so width is not the concern .frame(minHeight:) addresses) |
| Meals: history filter chips | `Fuel/Features/Meals/MealsView.swift:133-135` | Yes |
| Meals: favorite chips | `Fuel/Features/Meals/MealsView.swift:162-164` | Yes |
| Scan: remove-photo "x" button | `Fuel/Features/Scan/ScanView.swift:62-70` | **No** — icon + 10pt padding, no `.frame(minWidth:/minHeight:)` or `.contentShape(` |

**Remaining gap:** the Scan screen's remove-photo button is the one clearly
under-sized target left after this session's changes. Worth a direct check —
grep for `.frame(minWidth: 44` / `.contentShape(` across `Fuel/` again after
any further work lands, since this list was accurate only as of the time this
document was written.

### Keyboard / Switch Control

No `.focusable(`, `.focusSection(`, `.accessibilityAdjustableAction(`, or
`.accessibilityScrollAction(` exists anywhere in the codebase. This is a real
gap in the sense that no custom Switch Control affordances have been added,
but it is not necessarily a functional gap: every interactive control in the
app is a standard SwiftUI control (`Button`, `Toggle`, `Stepper`, `Picker`,
`DatePicker`, `TextField`) which gets baseline Switch Control and full-keyboard
navigation support from the system without any extra code. The one custom
drawn control, `HealthScoreRing`, is intentionally non-interactive (collapsed
to a static label, not exposed as adjustable), so it does not need
`.accessibilityAdjustableAction`. Treat this section as "no custom work
needed today," not "untested" — but it has not been walked with a physical
keyboard or Switch Control device either (see "External, physical-device
gates" in `docs/quality/RELEASE_GATES.md`).

### Validation and state-change announcements

**Landed this session; the codebase had zero calls to this API when this
audit began and now has eight.** Every user-facing error path found and
several success paths now post an explicit `AccessibilityNotification.Announcement`:

- `Fuel/Features/Today/TodayView.swift:128` — generic action failure
- `Fuel/Features/Today/TodayDetails.swift:216` — "Added N milliliters of water"
- `Fuel/Features/Today/TodayDetails.swift:232` — generic hydration failure
- `Fuel/Features/Onboarding/OnboardingView.swift:131` — onboarding save failure
- `Fuel/Features/Meals/MealsView.swift:225` — generic action failure
- `Fuel/Features/Meals/MealsView.swift:254` — "{meal} deleted"
- `Fuel/Features/Meals/MealsView.swift:267` — "{meal} restored"
- `Fuel/Features/Meals/MealEditorView.swift:244` — generic save/validation failure

This directly closes what had been a real gap (silent failures that only a
sighted person would notice via an `.alert`/inline banner). **Because this
landed mid-session, verify it hasn't regressed**: confirm every `catch` block
that sets a user-visible `errorMessage` also posts the same message via
`AccessibilityNotification.Announcement` (the pattern above is consistent —
`fail(_:)` helper functions do both together — but new call sites added after
this document should keep doing both, not just set `errorMessage`).

## Screens vs. status

| Screen | VoiceOver labels/combine | AX-size layout | Hit targets | Announcements | Notes |
| --- | --- | --- | --- | --- | --- |
| `TodayView` (+ `DashboardHeader`, `CompactHealthScoreCard`, `TodayTimeline`) | Yes | Yes (3 components) | Yes (this session) | Yes (this session) | Richest screen; re-verify traversal order at AX5 |
| `Fuel/UI/Components.swift` (`HealthScoreRing`, `MetricCard`, `SectionHeader`) | Yes | Partial (`.minimumScaleFactor`) | Yes | n/a (no error paths here) | Only reduce-motion-aware code in the app |
| `InsightsView` | Yes | Yes | Not separately audited | Not separately audited | Only screen with a chart; audio-graph descriptor present |
| `MealsView` | Yes | Yes | Yes (this session) | Yes (this session) | |
| `MealEditorView` | Yes | Not checked | Not separately audited | Yes (this session) | Range `lineLimit(2...5)` on notes field |
| `ScanView` | Yes | Not checked | **Gap** (remove-photo button) | Not checked | See hit-target gap above |
| `ProfileView` (+ sub-editors) | Yes (reminder times) | Not checked | Not separately audited | Not checked | |
| `OnboardingView` | Not separately audited | Yes | Yes (Back button) | Yes (this session) | |
| `FuelWidgets` | Yes | n/a (widget, no Dynamic Type controls surfaced) | n/a | n/a | Combines hydration/score into single VoiceOver stops |

"Not separately audited"/"Not checked" means this pass did not find evidence
either way in a targeted grep — it does not mean the screen fails, only that
it wasn't specifically confirmed.

## Simulator verification runbook

None of the code-level findings above substitute for actually looking at and
listening to the app. On the iPhone 16 simulator (Xcode 26.6 / iOS 18
runtime, confirmed available via `xcrun simctl list devices`):

1. **Boot the simulator and install a build:**
   ```sh
   xcrun simctl boot "iPhone 16"
   open -a Simulator
   xcodebuild -project Fuel.xcodeproj -scheme Fuel -configuration Debug \
     -destination 'platform=iOS Simulator,name=iPhone 16' \
     -derivedDataPath build build
   xcrun simctl install "iPhone 16" \
     build/Build/Products/Debug-iphonesimulator/Fuel.app
   xcrun simctl launch "iPhone 16" com.pak.fuel
   ```

2. **Enable VoiceOver** on the simulator: Settings app → Accessibility →
   VoiceOver → toggle on. (There is no `simctl` flag to toggle VoiceOver
   directly; it must be done through the Settings app UI on the simulated
   device, same as a physical device.) Alternatively, use the standalone
   **Accessibility Inspector** (Xcode → Open Developer Tool → Accessibility
   Inspector), point it at the booted simulator, and use its Inspection
   pointer to read the label/value/hint/traits of each on-screen element
   without needing full VoiceOver gesture navigation.

3. **Walk each screen in the table above with VoiceOver's swipe-right
   traversal**, confirming: every control the table marks "Yes" actually
   speaks the expected label; the combined cards (`MetricCard`, summary cards)
   read as one stop, not N sub-stops; the Insights chart is reachable and its
   Audio Graph (double-tap the chart, or use the rotor to select "Charts")
   plays the calorie series.

4. **Enable larger Dynamic Type sizes**: Settings → Accessibility → Display &
   Text Size → Larger Text → drag to the largest (AX5) setting, or use
   Accessibility Inspector's Settings pane to preview each size without
   changing the whole simulator. Confirm the six `isAccessibilitySize`
   branches listed above actually produce a usable stacked layout — nothing
   clipped, no unreadable truncation outside the `.minimumScaleFactor`-covered
   text.

5. **Enable Reduce Motion**: Settings → Accessibility → Motion → Reduce
   Motion. Confirm the health-score ring no longer animates on `TodayView`
   load/date-change, and separately note (for follow-up, not as something to
   fix in this pass) any other transition that still animates — that's the
   documented gap above, now visually confirmed rather than just inferred
   from a grep.

6. **Switch Control**: Settings → Accessibility → Switch Control → enable
   with the simulator's pointer as a virtual switch (or use a connected
   keyboard as a switch source). Confirm every interactive control from the
   screens table is reachable via Switch Control's scanning, since — per the
   checklist section above — this app relies entirely on standard-control
   baseline support rather than custom `.focusable`/adjustable-action code.

7. **Full keyboard navigation**: attach a hardware keyboard to the simulator
   (Simulator app supports this natively) and confirm Tab/Shift-Tab traversal
   and Space/Return activation work across the same screens, since no custom
   `.focusSection(` grouping exists to guide it.

8. **Validation announcements**: with VoiceOver on, trigger at least one
   failure path per screen listed in that checklist section (e.g., attempt an
   invalid meal save, delete then undo a meal, add water) and confirm VoiceOver
   actually speaks the posted announcement — a `.post()` call succeeding in
   code is not proof VoiceOver surfaced it audibly in every interaction
   context (e.g., while a sheet is mid-transition).

Record pass/fail against the table above per run; update the table's "Not
checked" cells as they're actually walked.
