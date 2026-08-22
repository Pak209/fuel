# Phase 1 — Reliable local-first foundation

## Authoritative data flow

```text
SwiftData repositories
  ├─ profile and time zone
  ├─ daily targets
  ├─ meals and typed food items
  ├─ hydration entries
  └─ settings
          │
          ▼
DayBoundaryService + DailySummaryService + HealthDataService
          │
          ▼
DailyHealthSnapshot (cached by local calendar day)
          │
          ├─ Today dashboard
          ├─ HealthScoreService
          ├─ NutritionRecommendationService
          └─ Insights
```

## Foundation guarantees

- The production dashboard does not seed or display mock meal, calorie, hydration, activity, or sleep values.
- Zero and unavailable are distinct. Health data that has not been queried is represented as unavailable.
- Profile, targets, meals, hydration, settings, and summary caches are persisted locally using SwiftData.
- Meal images are stored as protected files; SwiftData stores only their local file reference.
- Meal items are typed and include quantity, unit, nutrition, confidence, and provenance.
- All writes go through repositories and surface persistence failures instead of silently discarding them.
- Calendar-day queries use the profile time zone and support daylight-saving transitions.
- Meal and hydration mutations invalidate the affected day cache and immediately rebuild the visible snapshot.
- A failed refresh can fall back to a cached summary without presenting the cache as live data.
- The SwiftData schema begins at version 1 and is attached to an explicit migration plan for future releases.

## Added in Phases 2–5

- Live HealthKit statistics, sample, observer, anchored, and background-delivery queries.
- On-device food recognition plus offline common foods and branded Open Food Facts search.
- Full manual/review meal editing, recent foods, favorites, duplication, soft delete/undo, and photo lifecycle management.
- Onboarding, conservative goals, score v2, explainable recommendations, Today/timeline, 7/30-day Insights, settings, JSON export, and confirmed local deletion.

Cloud accounts/sync, paid subscriptions, production notification scheduling, and production analytics remain outside Phases 1–5.

Those integrations can replace their protocol implementations without changing the local persistence or daily-summary pipeline.
