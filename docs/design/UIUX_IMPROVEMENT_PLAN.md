# Fuel — UI/UX Improvement Plan (synthesis of three critiques)

**Scope constraints (fixed):** v1 is local-only (no backend, accounts, or paywall). The non-shaming, ED-safe copy stance is non-negotiable. iPhone-only. SwiftUI.
**Sources:** Critique A (visual), Critique B (IA/flows), Critique C (engagement/retention). All file/line citations below were re-verified against the repo at `phases-6-9` and the screenshots in `uiux-shots/`.

---

## 1) Verdict

Fuel is a structurally sound, safety-conscious logging app wearing the visual and motivational shell of an internal dashboard: its data layer, error recovery, and permission timing beat category norms, but its hero surface answers a question no user asks (a proprietary 0–100 score) while burying the one every competitor leads with (calories remaining). Against Cal AI, Yazio, Lose It, and MacroFactor, Fuel currently loses on all three battleground variables — seconds-to-log (no camera, no barcode, name-gated manual entry), perceived polish (flat cards, broken Light appearance, defeated Dynamic Type), and reason-to-return (no payoff at the log moment, no consistency mechanic, notifications that talk users out of opening the app). The good news: the worst problems are concentrated in a handful of files, most of the top fixes are small, and Fuel's honesty/ED-safe stance is a genuine differentiator once the app stops undermining it with fake confidence percentages and alarm-colored fiber bars.

**Conflict resolutions made in this plan:**

- **Hero of Today** — A wanted the Health Score to own the largest type; B wanted calories remaining as hero with the score demoted. **B wins.** Verified: the score's Recovery category renders "—" without Health data even in the seeded demo (`09-main-today.png`), so the score degrades on every fresh install, while `calorieDetail` in `TodayView.swift:346-349` already computes the remaining number. Calories-remaining is also the market-universal hero. A's underlying point (largest type must be data, not filler) is adopted.
- **Light mode** — A proposed removing `.light` "and arguably `.system`". Verified: `.system` is equally broken (`AppAppearance.colorScheme` returns `nil` at `FuelApp.swift:285`, so a light-mode device renders black-on-black over the hardcoded dark `FuelTheme`, per `19-light-mode-today.png` and `21-app-light-pref-today.png`). The fix must force Dark for all three cases, not just remove one.
- **Onboarding length** — A wanted 8 steps compressed toward 5; B explicitly notes 8 is "refreshingly short vs Yazio's 78" and the problem is value delivery, not length. **B wins:** fix ordering, controls, and the plan reveal; don't chase step count.
- **Log-moment toast deltas** — C proposed "score 58→67" in the save toast. Adopted with an ED-safe guard: show only additive, factual nutrient deltas and omit anything that reads as judgment (no negative deltas, no score framing when it dropped).

---

## 2) Top 10 improvements (ranked by user-impact per engineering effort)

Effort key: **S** ≤ half a day · **M** ≤ 2 days · **L** > 2 days.

### 1. Force Dark; remove the broken Light/System appearance options — **S**
**What/why:** One Settings tap makes the entire app unreadable — black-on-black greeting, headline, and score labels (A blocker #1, `21-app-light-pref-today.png`, `19-light-mode-today.png`). `FuelTheme` is a single hardcoded dark palette (`FuelApp.swift:292-303`) yet the picker offers System/Dark/Light. A tester who hits this files "app is broken."
**Files:** `Fuel/Fuel/App/FuelApp.swift`, `Fuel/Fuel/Features/Profile/ProfileView.swift` (AppPreferencesView, lines 377-379).
**Spec:** Make `AppAppearance.colorScheme` return `.dark` for every case (or apply `.preferredColorScheme(.dark)` unconditionally at `FuelApp.swift:69`). Remove the "Appearance" `Picker` row from `AppPreferencesView` entirely for v1 (screen title becomes "Units"). Do **not** attempt a light palette this build.

### 2. First-run credibility pass: kill the "Pak" defaults, put units before body stats, fix the CTA, label the pickers — **S**
**What/why:** Every fresh install greets the tester with a stranger's name ("Pak", "25–34" pre-filled — B #8, `DomainModels.swift:38-39`, `02-onboarding-step1-profile.png`); units are asked at step 4 *after* height/weight at step 1, silently poisoning the calorie target for imperial users (B #7); the Continue button renders as a small centered capsule because the `maxWidth` frame is on the Button, not the label (A #8, `OnboardingView.swift:82-90`, `01-onboarding-step0-welcome.png`); the goal/activity pickers render as bare green phrases with swallowed labels (`03-onboarding-step2-goal.png`).
**Files:** `Fuel/Fuel/Models/DomainModels.swift`, `Fuel/Fuel/Features/Onboarding/OnboardingView.swift`.
**Spec:** (a) `UserProfile.firstName = ""`, `ageRange = ""` — this also un-breaks the empty-name validation at `OnboardingView.swift:88`. (b) Move the unit-system segmented control to the top of `ProfileStep` (step 1) and delete `UnitStep`; `totalSteps` 8→7; keep the step-4 target calculation trigger on the new step index. Default the initial selection from `Locale.current.measurementSystem`. (c) Continue button: put `.frame(maxWidth: .infinity, minHeight: 44)` *inside* the label and add `.controlSize(.large)`. (d) In `GoalStep`, wrap both pickers in `LabeledContent("Primary goal")` / `LabeledContent("Usual activity")` rows with panel-card chrome so the controls read as fields, not links.

### 3. Make the water row do what it says — **S**
**What/why:** The row literally reads "Tap to add 250 ml" but opens a sheet requiring two more taps (B #5, `TodayView.swift:443-447` → `HydrationLogView`), while Fuel's own widget does it in one (`FuelWidgets.swift`, `AddWaterIntent`). Hydration is the highest-frequency action in the app; a lying label on it trains distrust of every label.
**Files:** `Fuel/Fuel/Features/Today/TodayView.swift`.
**Spec:** Row tap calls `try await state.addWater()` (exists at `AppState.swift:291`, already fires the "Water added" toast at :295). Add a separate trailing chevron button (44pt target) on the row that opens the existing `HydrationLogView` sheet for edits/history. Keep the row's copy unchanged — it's now true.

### 4. Pay out at the log moment — **S**
**What/why:** Saving a meal — the app's most important action — yields a gray "Meal saved" capsule (C blocker #1, `AppState.swift:194`), while the app happily computes "+9 potential score points" for a *hypothetical* action (`09-main-today.png`). Every retained competitor pays out at the log moment; sub-30s logs retain at 78%.
**Files:** `Fuel/Fuel/App/AppState.swift` (`saveMeal`), optionally `FuelApp.swift` (`TransientMessageBanner`).
**Spec:** In `saveMeal`, capture nutrition totals before `reloadAfterMutation()`, then compose a factual delta toast: `"Logged Yogurt bowl — protein 63→74 g · 1,140 cal left"`. **ED-safe guard:** deltas are additive facts only; when calories exceed target, show the neutral `"· 360 cal logged"` instead of "over"; never show a score decrease. Same 3-second timing.

### 5. Semantic color + surface pass — **S**
**What/why:** Color currently contradicts itself: Fiber's bar is alarm-red at 68/100 because red encodes *category*, not state (A #4, `Components.swift:37`, `09-main-today.png`); "No Health data" renders in celebratory green (`Components.swift:77`); the ring's green→orange→red gradient is a judgment scale that contradicts the adherence-neutral stance (`Components.swift:11`); the orange avatar is the loudest pixel on screen (`TodayView.swift:222`); the meal editor's food-row title is link-green among white siblings (`MealEditorView.swift:151`, `22-meal-editor.png`); and cards barely exist — panel is 3% lighter than background (A #5, `FuelApp.swift:293-295`).
**Files:** `Fuel/Fuel/UI/Components.swift`, `Fuel/Fuel/App/FuelApp.swift`, `Fuel/Fuel/Features/Today/TodayView.swift`, `Fuel/Fuel/Features/Meals/MealEditorView.swift`.
**Spec:** (a) Add `FuelTheme.teal = Color(red: 0.25, green: 0.72, blue: 0.66)`; fiber uses it (`Components.swift:37`). (b) `HealthScoreRing` stroke becomes solid `FuelTheme.green` over the existing 10%-white track — delete the `AngularGradient`. (c) `MetricCard`: when the detail is a no-data placeholder, render it in `FuelTheme.secondary` (add an `isPlaceholder` flag or pass `FuelTheme.secondary` as `color` from `DailyMetricsRow` when `availability != .available`). (d) Avatar `foregroundStyle(.orange)` → `FuelTheme.secondary`. (e) Meal-editor food-row title → `.primary`. (f) Raise `panel` to ~`(0.07, 0.09, 0.085)` and `panelRaised` to ~`(0.10, 0.12, 0.11)` so cards separate by luminance, not hairline alone.

### 6. Give the Insights chart a target line and a real axis — **S**
**What/why:** Seven identical bars, no target rule, "Aug 16 / Aug 18 / Aug 20" axis, and a range label off by one day ("Aug 16 – Aug 23" for a window ending Aug 22) make the tab decorative — "is 1,140 good?" is unanswerable from the pixels (A #6, B #12, `InsightsView.swift:67-88,117-119`, `11-main-insights.png`). "7/7 logged days" sits unreconciled above "60% data completeness."
**Files:** `Fuel/Fuel/Features/Insights/InsightsView.swift`.
**Spec:** (a) Add `RuleMark(y: .value("Target", targets.calories))` — dashed, `FuelTheme.secondary`, trailing annotation "Target 2,450". (b) `.chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }`. (c) Fix `dateRange` to display the inclusive end date (`endDate` is exclusive — subtract one day for display). (d) Caption the completeness stat: "Reflects connected Health sources — logging counts separately."

### 7. Invert the Today hero: calories remaining owns the screen, the score steps back — **M**
**What/why:** The largest text on the dashboard is the filler line "Here's your dashboard"; the market-universal hero — calories remaining — is a 10pt caption inside a small `MetricCard`, and the actual hero (score 67) is half-dead on fresh installs with Recovery at "—" and two of three metric cards reading "No Health data" (A #3, B #3, `09-main-today.png`, `TodayView.swift:169-183,284-295,319-326`).
**Files:** `Fuel/Fuel/Features/Today/TodayView.swift`, `Fuel/Fuel/UI/Components.swift`.
**Spec:** (a) Delete the "Here's your dashboard" line; greeting shrinks to `.caption` weight above the date switcher. (b) New `CaloriesHeroCard` first in the stack: "**1,310** left" in `.system(.largeTitle, design: .rounded, weight: .bold)`, a progress ring/bar toward `targetCalories`, and an MFP-style equation caption "2,450 target − 1,140 logged = 1,310 left" (data already in `DailyMetricsRow.calorieDetail` / `state.calorieBalance`). (c) `CompactHealthScoreCard` moves below the metrics row, drops its 37pt numeral to `.title2`, hides unavailable category rows entirely, and replaces them with one quiet footnote: "Connect Health in Profile to include recovery." (d) The "AI Recommendation" card's "+9 potential score points" line becomes the concrete fact: "adds ~8 g fiber."

### 8. Meal-slot logging entry points on Today — **M**
**What/why:** The only log affordance on Today is a caption-sized "Add event" — calendar vocabulary — which opens an editor hardcoded to `.lunch` even at 8am, while `ScanView` already infers meal type by hour (B #4, `TodayView.swift:95,409`, `ScanView.swift:362-369`). The timeline shows only already-logged meals; every incumbent uses tappable breakfast/lunch/dinner slots. Favorites — the fastest flow in the app — are invisible until created via long-press (B #6).
**Files:** `Fuel/Fuel/Features/Today/TodayView.swift`, `Fuel/Fuel/Features/Scan/ScanView.swift` (extract helper), `Fuel/Fuel/Models/DomainModels.swift`.
**Spec:** (a) Move `suggestedMealType` to `MealType.suggested(at:)` in shared code; both `ScanView` and Today use it. (b) Rename "Add event" → "Log meal"; the `.newMeal` draft uses `MealType.suggested()`. (c) In `TodayTimeline`, render a quiet row for each of breakfast/lunch/dinner not yet logged for the selected day: slot icon, "Breakfast", detail "Log", plus glyph; tap opens `MealEditorView` pre-typed to that slot (name pre-filled per item 9). Replaces the single "No meals logged today" caption. (d) On empty slot rows, show up to two favorite chips inline (reusing `state.favorites`) for one-tap logging; keep the existing undo toast prominent.

### 9. De-friction the manual meal editor — **M**
**What/why:** Save is disabled until a meal *name* is typed (`MealEditorView.swift:73`) — no incumbent requires this; every added food force-opens a second editor sheet (`MealEditorView.swift:261,268`); and the form stacks six sections into a wall (B #2, `22-meal-editor.png`). Current cheapest manual log ≈ 6 taps + two keyboard sessions — the 60–120s flow users flee.
**Files:** `Fuel/Fuel/Features/Meals/MealEditorView.swift`.
**Spec:** (a) Default the name: on save, `name.isEmpty ? type.rawValue : name`; enable Save whenever the meal has any content; placeholder text shows the meal-type default. (b) Delete `editingItem = item` from `addFood`/`addRecentFood` — foods append with the 1-serving default and an inline portion control on the row; tapping the row still opens the item editor *optionally*. (c) Collapse Photo/Notes into a "More" `DisclosureGroup`. The safety section's copy is retained verbatim (stance is non-negotiable) but moves below the fold with the disclosure. Target: 3 taps + one search string.

### 10. Dynamic Type: replace every fixed font on the Today path — **M**
**What/why:** At XXXL and AX sizes the greeting balloons while the score numeral (fixed 37pt), nutrient rows (9–11pt), and `MetricCard` (10/18pt) stay frozen — the app's *primary data* is the only thing a low-vision user can't enlarge, and the fixed 70pt timeline column hyphenates "Break-fast" (A blocker #2, `15-xxxl-today.png`, `17-ax-xl-today.png`, `Components.swift:42-83`, `TodayView.swift:287-291,494-496`).
**Files:** `Fuel/Fuel/UI/Components.swift`, `Fuel/Fuel/Features/Today/TodayView.swift`.
**Spec:** `Components.swift`: 9pt icon → `.caption2`; 11pt labels → `.caption`/`.caption.bold()`; `MetricCard` 10pt → `.caption2.weight(.semibold)`, 18pt value → `.title3.bold()` rounded. `TodayView`: hero numeral → `.system(.largeTitle, design: .rounded, weight: .bold)` (aligns with item 7), "/100" → `.footnote`; bell 15pt → `.subheadline`; avatar 35pt via `@ScaledMetric`. `TimelineRow`: 12pt icon → `.caption`; replace `.frame(width: 70)` with a natural-width column (`.frame(minWidth: 64, alignment: .leading)`, no fixed cap). `HealthScoreRing` inner icons via `@ScaledMetric`.

---

## 3) Deferred / rejected critic suggestions

**Deferred (planned, mostly Build 3):**

- **Camera-first Scan capture** (B #1, A #10) — highest-ceiling change in the backlog, but feature work (AVFoundation capture feeding `prepareForRecognition`), not a quick win; first item on the Build 3 roadmap, with "Log as-is" on `RecognitionSummary`.
- **Barcode scanning** (B #9) — same tier; VisionKit `DataScannerViewController` + the existing Open Food Facts lookup; Fuel's cheapest competitive wedge, scheduled with the camera work.
- **Consistency ribbon "N of last 7 days logged"** (C #2) — adopted in principle (windowed counting is inherently non-punitive; `loggedDays` already computed in `InsightsService`), but ships Build 3 after an ED-safety copy review of milestone language.
- **Data-bearing notification copy** (C #3) — right call; depends on the delta-string plumbing item 4 introduces; Build 3 alongside deleting the "or don't" hedges while keeping the tone.
- **Daily-review reminder default ON** (C #4) — needs one product decision; recommended middle path preserves consent: visually pre-set the toggle ON on the reminder step so the user actively confirms or declines before Finish, never a silent default. Approve → trivially pullable into Build 2.
- **Widget staleness fix + log-meal button** (C #5) — real and contained (~30 lines in `FuelWidgets.swift`: stale-date check → "Log breakfast" CTA deep-linking `fuel://scan`); Build 3.
- **Week-over-week deltas + insight-card severity tiers** (C #6, A #9) — builds directly on item 6; call `historicalSnapshots` twice and lead cards with the change; Build 3.
- **Post-onboarding first-log bridge** (C #7) — one interstitial ("Log your first meal" / "I'll do it later"); Build 3, lands best paired with camera capture.
- **Recommendation trust-copy pass** (C #8, B #13) — drop "Confidence 96%" and the "AI" label from a rules engine, show real values in "Why you're seeing this" (`TodayDetails.swift:62-70`, `RecommendationCard`). **S effort, copy-only — pull into Build 2** (listed here only because the Top 10 was full; it is in the Build 2 shortlist below).
- **Translucent tab bar / iOS 26 material adoption** (A #7) — correct direction, but removing the opaque `.toolbarBackground` (`FuelApp.swift:173-174`) needs visual QA across all five tabs plus a Today scroll-edge treatment; Build 3. (The 2-line removal may be trialed earlier behind a quick device pass.)
- **Per-tab date state** (B #10) — real but low-frequency; Build 3 via a "Viewing Aug 14 — back to Today" banner rather than forked state.
- **Empty-state action buttons** (B #11) — `ContentUnavailableView` actions for Meals/Scan; small, Build 3 or opportunistic.
- **Disclaimer consolidation** (C #9) — consolidate repeated legal copy into one "How Fuel estimates" page linked from footers; requires a careful copy pass to preserve the safety stance, so not rushed into Build 2.
- **Brand/personality moments** (A #11) — real gap, but identity work (illustration, empty-state warmth) belongs after the structural fixes, not before.
- **Onboarding step compression + text-field inputs + plan-reveal redesign** (A #8 remainder, B #7 remainder) — Build 3; item 2 fixes the damaging parts (ordering, defaults, CTA, labels) first.

**Rejected:**

- **"Let the Health Score own the largest type on screen"** (A #3 fix) — conflicts with B #3 and with every researched competitor; the score degrades without Health data on fresh installs. Calories remaining is the hero (item 7).
- **Build a full light palette now** (A #1 alternative) — out of v1 scope; forcing Dark is the correct-sized fix.
- **Compress onboarding 8 → 5 steps** (A #8) — B's evidence stands: length isn't the problem, value delivery is; step count untouched (item 2 removes one step only as a side effect of merging units into profile).
- **Score deltas in the save toast when the score dropped** (C #1 literal spec) — violates the non-shaming stance; adopted as additive-facts-only (item 4).

---

## 4) Build 2 shortlist — the very next TestFlight build

Everything below is S except item 7; combined scope ≈ one focused week.

1. **Force Dark, remove the appearance picker** (Top-10 #1) — deletes the worst bug a tester can hit.
2. **First-run credibility pass** (#2) — no more "Pak", units before body stats, real CTA, labeled pickers.
3. **One-tap water row** (#3) — the label becomes true.
4. **Log-moment payoff toast** (#4) — the core action finally pays out, ED-safely.
5. **Semantic color + surface pass** (#5) — no more alarm-red fiber, green "No data", judgment-gradient ring, or invisible cards.
6. **Insights target line + weekday axis + range fix** (#6) — the chart answers a question.
7. **Calories-remaining hero inversion** (#7) — the one structural change worth its M cost now; every returning tester sees the number they came for.
8. **Recommendation trust-copy fix** (deferred-list pull-in, copy-only) — drop the fake "Confidence 96%" and "AI" label; show real values.

Items #8–10 (meal-slot entry points, editor de-friction, Dynamic Type) open Build 3, followed by the camera/barcode roadmap.
