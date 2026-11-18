---
version: 1
slug: "app-lib-ui-trends-screen-dart"
primary_target: "app/lib/ui/trends_screen.dart"
related_targets: ["app/lib/ui/trends_view.dart","app/lib/ui/fortnight.dart","app/lib/ui/pressure_chart.dart"]
---

# Trends (app/lib/ui/trends_screen.dart)

Scope: the phone's trends page (ROADMAP row 10), opened from the night screen's Morning section and from a
check-in's result. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world.
Audience and job: the owner in the morning or during the day, glancing for where he is today against his own
usual and where the last two weeks went: sleep, morning sleepiness and reaction time, mood and tension, the
eyes-closed alpha numbers, practice, the coffee and alcohol he noted; sleep pressure from the sleep log; the
forecast's honest status. Constraints: few days of data now (1-2 nights), so every gap is said in words; no
scores, no red/green health colours, arrows only beyond the normal spread and always worded; 48 dp targets;
system font scale; nothing bright. Decided without the owner (subagent run, no question channel): the
decision round was replaced by the brief; every choice below is an assistant proposal.

## Direction contract

THESIS: Trends are the deck log's day entries: today's entry first, every number beside yesterday's and your
usual, then the last fortnight as a watch bill. Refuses the category default: metric cards with sparklines
and a readiness score.

OWN-WORLD: The bridge-at-night palette, Roboto tabular figures, hairline rules. Arrows are drawn icons with a
word, in ink, never coloured. The fortnight lines run through the watch strip's own cells (track ground,
6 dp), the usual band a faint rule fill; no data is an empty cell, never a zero.

STORY: The owner reads today's entry (value, yesterday, usual, an arrow only when it matters), sees the sleep
pressure curve labelled as an estimate, scans the fortnight rows, reads why the forecast is hidden, then the
earlier days.

FIRST VIEWPORT: App bar with Back, "Trends" and an "i" action; one muted sentence of how many days exist and
when "usual" and arrows begin; today's entry starts at once with Asleep.

SIGNATURE: the fortnight watch bill: one row per measure, fourteen day cells, the line through them.

FORM: day log as the lead (dealt lead, position 5 of 7), fused with the watch-bill grid (3) and per-measure
ledger rows (1); seed:a88e53a391a6a1d12ca1cd8b2ccb5c22.
