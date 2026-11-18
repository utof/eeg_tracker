---
version: 1
slug: "app-lib-ui-sleep-report-screen-dart"
primary_target: "app/lib/ui/sleep_report_screen.dart"
related_targets: ["app/lib/ui/sleep_chart.dart","app/lib/ui/night_view.dart","app/lib/ui/sleep_extras_view.dart"]
---

# Sleep report (app/lib/ui/sleep_report_screen.dart)

Scope: the phone's night report, opened from the night screen's Sleep section; one night per page, the past
nights listed under it. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world.
Audience and job: the owner in the morning (often still in bed, room dim), later in the day, and when looking
back over a week: how long did I sleep, when, how many times did I wake, how much deep and dream sleep, how
much data is missing, and how far to trust it; since the night extras (2026-11-18, DECISIONS 140-146) also how
noisy the signal was, how often the jaw muscle fired and how much he moved, compared with earlier nights. Constraints: the stages are a first guess (not validated on
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

STORY: The owner reads the asleep total, sees "first guess" beside it with how much of the sleep was read
through noise, sees where in the night he slept and woke and, on the Signal lane under the chart, where the
signal was noisy; reads each period's deep / dream / light and wake-ups; then jaw muscle bursts and movements an
hour asleep against his earlier nights, the night hour by hour, and goes back a night from the list below.

FIRST VIEWPORT: App bar with Back, "Night of Tue 17 Nov" and an "i" action. Then the asleep total as the
big readout with the periods count beside it, split by a hairline; the honest note in one muted sentence;
the chart, full width, about 190 dp tall (plus the 18 dp Signal lane when the report has extras), hour labels
under it. The period entries start below.

EXTRAS (2026-11-18, same brief standing in for the owner): the honest note carries the noise share; the Signal
lane reuses the strip's amber for trouble only (dots = noisy, solid = no usable electrode; clean stays the empty
track, so the eye goes to the amber); "Jaw and movement" sits after the periods (it is secondary to sleep) with
label-left / value-right rate lines, plain count and trend sentences and the not-a-bruxism-test line; "Hour by
hour" is a log table (hour, signal bar, jaw, moves) instead of a second chart, so numbers stay readable at 130 %
text. Refused: a tension score, a jaw chart, colour-coded hours, the word "clenches".

SIGNATURE: the hypnogram on the deck-log clock, periods numbered on it and in the log.

FORM: night index opening night pages (dealt lead, position 4 of 7), fused with the strip's clock grid
(5) and per-period log entries (3); seed:aa1970634eb59197.
