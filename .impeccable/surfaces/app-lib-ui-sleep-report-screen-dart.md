---
version: 1
slug: "app-lib-ui-sleep-report-screen-dart"
primary_target: "app/lib/ui/sleep_report_screen.dart"
related_targets: ["app/lib/ui/sleep_chart.dart","app/lib/ui/night_view.dart"]
---

# Sleep report (app/lib/ui/sleep_report_screen.dart)

Scope: the phone's night report, opened from the night screen's Sleep section; one night per page, the past
nights listed under it. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world.
Audience and job: the owner in the morning (often still in bed, room dim), later in the day, and when looking
back over a week: how long did I sleep, when, how many times did I wake, how much deep and dream sleep, how
much data is missing, and how far to trust it. Constraints: the stages are a first guess (not validated on
this headband), so the honest note sits next to the numbers, never in a footer; 48 dp targets; system font
scale; nothing bright. Decided without the owner (subagent run, no question channel): the decision round was
replaced by the brief; every choice below is an assistant proposal.

## Direction contract

THESIS: A night is a page of the deck log: the stages drawn on the watch strip's clock, the sleep periods
logged under it as ruled entries numbered like the chart. Refuses the category default: a sleep-score ring,
a stage donut and metric cards.

OWN-WORLD: The inherited bridge-at-night palette and Roboto tabular figures. The chart is ink on the
`track` ground: a step line through four worded levels (Awake, Dream, Light, Deep), hairline hour rules,
missing data as `caution` amber hatching (the strip's gap colour), each sleep period a faint band with its
number on top.

STORY: The owner reads the asleep total, sees "first guess" beside it, sees where in the night he slept and
woke, reads each period's deep / dream / light and wake-ups, and goes back a night from the list below.

FIRST VIEWPORT: App bar with Back, "Night of Tue 17 Nov" and an "i" action. Then the asleep total as the
big readout with the periods count beside it, split by a hairline; the honest note in one muted sentence;
the chart, full width, about 190 dp tall, hour labels under it. The period entries start below.

SIGNATURE: the hypnogram on the deck-log clock, periods numbered on it and in the log.

FORM: night index opening night pages (dealt lead, position 4 of 7), fused with the strip's clock grid
(5) and per-period log entries (3); seed:aa1970634eb59197.
