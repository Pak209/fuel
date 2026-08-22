# Fuel Design QA

Source: `codex-clipboard-7c65ee58-75e5-45b1-8e96-2ed8bf4c3727.png`

Runtime target: iPhone 16 Simulator at 369 × 800 captured points.

## Comparison ledger

| Area | Source evidence | Render evidence | Result |
| --- | --- | --- | --- |
| Header | Greeting, dashboard title, notification and avatar | Compact semantic typography; controls are functional; accessibility sizes reflow vertically | Passed |
| Palette | Near-black background, charcoal panels, green accent | Matching near-black, raised charcoal, thin border, category accents | Passed |
| Score | Large score, ring, supporting message, category rows | Live score v2 values, pace-aware weighting, evidence disclosure, and accessibility reflow | Passed |
| Typography | Large rounded heading, strong number, muted secondary text | Native rounded hierarchy and high-contrast secondary labels | Passed |
| Navigation | Five persistent bottom tabs | All five native tabs present with selected green state | Passed |
| Responsive layout | Tall iPhone reference | Compact iPhone first viewport remains readable without horizontal overflow | Passed |
| Interaction | Tab-driven app with dashboard and scan | Five live tabs, PhotosUI scan, full meal editor, timeline details, computed insights, settings, export, and confirmed deletion | Passed |

## Copy diff

The supplied greeting, dashboard title, health-score labels, values, recommendation, timeline labels, and five tab names are preserved. Additional safety and permission copy comes directly from the product brief.

## Intentional adaptations

- The source is an aspirational long-form dashboard; the compact 368 × 800 simulator uses a vertically stacked health-score card so Dynamic Type and small-screen readability remain strong.
- Missing HealthKit data is shown as unavailable rather than replaced by reference-image numbers.
- Debug-only in-memory demo data is available for visual QA and is excluded from Release builds.
- The largest accessibility text size uses dedicated vertical dashboard and timeline layouts; normal text remains deliberately compact.

Final result: passed
