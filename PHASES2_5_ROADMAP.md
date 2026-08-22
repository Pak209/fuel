# Fuel Phases 2–5 completion matrix

This file is the acceptance contract for the remaining personal daily-use build. A checkbox is complete only when implementation, automated coverage, and simulator evidence agree.

## Phase 2 — Complete meal logging

- [x] Manual meal form: name, type, date/time, notes, optional photo
- [x] Food search with stable IDs, source attribution, serving conversions, macro and micronutrient data
- [x] Add/remove foods and edit quantity/unit with live total recalculation
- [x] Quick-add calories/macros and fully manual food entry
- [x] Review confidence, alternatives, partial-result and unsupported-image states
- [x] Save/cancel/retry/replace-photo behavior
- [x] Duplicate meals, copy recent meals, favorites, and user corrections taking precedence
- [x] Real recognition implementation with image downsampling, cancellation, timeout, validation, retry, and manual fallback
- [x] No provider secrets embedded in the application

## Phase 3 — Real HealthKit integration

- [x] Contextual authorization and explicit availability/connection states
- [x] Live local-day queries for steps, active/basal energy, exercise, workouts, sleep, body mass, height, resting heart rate, and heart-rate summary
- [x] Correct HealthKit units, timestamps, no-data/stale states, cancellation, and query errors
- [x] Source-aware aggregation and duplicate-resistant sleep/workout conversion
- [x] Refresh/reconnect behavior that does not break local-only use
- [x] Explicit calorie-balance model with incomplete-data and wearable-estimate disclosure

## Phase 4 — Goals, scoring, and recommendations

- [x] First-run onboarding for value/limitations, profile, goal, activity, diet, allergies/avoidance, units, targets, HealthKit, and notifications
- [x] Optional-step skipping, small-screen/accessibility support, persistence, and later editing
- [x] Goal calculator with sensible defaults, safety bounds, unit conversion, explanations, manual override, and goal history
- [x] Versioned score formulas, missing-data normalization, confidence/evidence thresholds, stable boundaries, and score-change explanations
- [x] Recommendations consider time, remaining energy, protein distribution, fiber, hydration, exercise, recovery, diet, allergies, avoidance, confidence, and repetition
- [x] Recommendation alternatives, limitations, dismiss/not-relevant feedback, and hard allergy/diet exclusions

## Phase 5 — Complete daily product experience

- [x] Today: live state, skeleton/error/cache/last-updated/source states, date navigation, detail navigation, refresh, and accessible summaries
- [x] Timeline: meal view/edit/delete, planned completion, workout detail, editable water, sleep detail, time correction, and empty days
- [x] Meals: search, calendar/day, working filters, daily grouping, edit, delete+undo, duplicate, favorites, recent foods, thumbnails, efficient loading, and states
- [x] Insights: computed 7/30-day trends, averages, consistency, activity, meal timing, common foods, possible gaps, completeness, sample thresholds, ranges, disclosures, and accessible summaries
- [x] Profile/settings: profile/goals/diet/allergies/units/HealthKit/notifications/appearance/data sources/privacy/export/delete/about/support
- [x] Destructive actions have confirmation, explicit outcomes, and tests

## Release gate for this goal

- [x] All Phase 2–5 requirements above have authoritative evidence
- [x] Unit and integration suites pass
- [x] App builds and launches on iPhone 16
- [x] Primary Phase 2–5 flows are exercised in Simulator
- [x] No production path silently substitutes mock health or nutrition values
- [x] Any externally configured service clearly reports unavailable state and preserves manual/offline operation

## Verification evidence

- Debug tests: 35 passed, 0 failed, 0 skipped on iPhone 16 Simulator.
- Release configuration: Simulator build succeeded with DEBUG-only demo and direct-screen QA paths excluded.
- Runtime: onboarding steps 0–7, empty and populated Today states, timeline, Scan, manual meal editor, Meals, Insights, and Profile were inspected on iPhone 16.
- Accessibility: Today and the meal editor were exercised at the largest accessibility content size, then the Simulator was restored to Large.
- Data integrity: tests cover day boundaries, typed nutrient math, persistence, soft delete/restore, water editing, favorites, goal history, export decoding, complete local deletion, score/recommendation rules, insight thresholds, and overlap de-duplication.
