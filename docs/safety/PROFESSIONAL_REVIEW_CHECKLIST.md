# Fuel Health and Nutrition Professional Review Gate

Fuel is general wellness software, not a diagnostic or treatment product. A qualified registered dietitian or appropriately licensed nutrition professional must review the following before public release:

- Calorie target floor/ceiling, rate-of-change assumptions, and incomplete-day behavior
- Protein, carbohydrate, fat, fiber, hydration, step, and sleep target defaults
- Pregnancy, minors, older adults, medical conditions, specialized diets, and eating-disorder-sensitive handling
- Allergy and avoided-food exclusions, including the limits of label matching and cross-contact knowledge
- Health-score category formulas, weights, missing-data normalization, confidence adjustment, and explanatory copy
- Recommendation priority, repetition, deficit handling, workout/recovery context, and “not relevant” feedback
- Wording that could imply diagnosis, deficiency detection, guaranteed outcomes, moral judgment, or exact wearable energy expenditure
- Escalation language directing higher-risk users to qualified care

## Required evidence

- Reviewer name, qualification, jurisdiction, and review date
- Source version/commit or immutable review bundle
- Formula/rule inventory reviewed
- Findings with severity and disposition
- Explicit approval or remaining blockers
- Re-review trigger for material algorithm, safety-copy, or target changes

This checklist is intentionally an external gate. It must not be marked complete based only on engineering tests.
