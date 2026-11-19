---
version: 1
slug: "app-lib-ui-sharp-hours-screen-dart"
primary_target: "app/lib/ui/sharp_hours_screen.dart"
related_targets: ["app/lib/ui/sharp_hours_view.dart","app/lib/ui/sharp_rating_screen.dart","app/lib/ui/sharp_chart.dart","app/lib/ui/trends_view.dart"]
---

# Sharp hours: the page and the one-tap question (app/lib/ui/sharp_hours_screen.dart)

Scope: two pages in the established night-watch world (DESIGN.md). The Sharp hours page (reached from a "Sharp
hours" section on Trends; no entry on the main screen): the proposal and its switch, the waking window and how many a
day, whether the questions reach the phone, the collection toward the first pattern, the answers by clock time /
hours since waking / sleep pressure, today's answers, delete. And the question page (opened by tapping the
notification, or Rate now): "How sharp do you feel right now?" as five rows, one tap saves, then the optional
1-minute reaction test (alpha-theta's ReactionPanel). Mode: Operate. Platform: Android (Flutter, Material 3).
Audience and job: the owner (not a scientist), a few seconds several times a day to answer, a glance a week at the
page, once to switch it on. Constraints: the assistant's proposal, off by default, labelled as such, switchable off
and deletable; no pattern before 3 weeks and about 60 ratings; "seen together, not tested"; plain short words; renders
at 393 dp, 100 and 130 % text. Decided without the owner (subagent run, no question channel; the brief stood in).
Structure roll seed:cfef118e0666b681 dealt 6, 4, 2 of the assistant's list (1 the day's hour strip, 2 the
collection ledger, 3 three lenses on one chart, 4 the day raster, 5 question-first, 6 the proposal and its switch
first, 7 a sealed verdict sentence); no decision page was served (nobody to answer it), so the dealt lead is built.
Challengers (split-flap board, airport wayfinding yellow, doujin catalog grid, design-annual plates, ticket
wallet, orienteering map) declined: each would replace the settled world. Kept: from the wayfinding system, one
decision on the panel at a time (the question page shows only the question, then only the test); from the
catalog grid, whole cells as the unit (the collection ledger counts in the watch strip's cells).

## Direction contract

THESIS: A proposal you can see the whole of before you say yes: what it asks of you, when, and how far it is from
saying anything. Refuses the category default: a "productivity score" ring and a best-hour badge from day one.

OWN-WORLD: Night-watch palette and parts: a Material switch row and label-left / value-right log rows for the
window and the count; the collection ledger as the watch strip's own cells (60 for ratings, 21 for days, filled
`saved`); the hours chart on the `track` ground with worded levels (Foggy to Very sharp), answers as ink dots, later
a `rule` range band with an ink mean tick per block; amber with an icon only when questions are held back.

STORY: The owner reads that this is the assistant's idea, switches it on, sees the cells fill as answers come in and
the day count toward 21, sees the dots gather by the hour, and only then reads one plain sentence about a best time,
with its range and "seen together, not tested".

FIRST VIEWPORT: App bar with Back, "Sharp hours" and an "i". One muted line: the assistant's proposal, off unless
switched on. The switch row "Questions during the day" with its one-line status. Two log rows: "Awake" 10:00 to
22:00 (Change) and "A day" 3 / 4 / 6 (segmented). The delivery line. "Collecting" with the status sentence and the
two ledger rows. Pinned at the bottom, full width, 64 dp: Rate now (filled). Question page: the question at headline
size, five full-width 64 dp rows (5 Very sharp at the top to 1 Foggy), one muted line saying when it was asked.

SIGNATURE: the collection ledger: the 60 rating cells and 21 day cells filling, the gate made visible.

FORM: the proposal and its switch first (dealt lead, position 6 of 7), with the collection ledger (2) as its state
and the day raster (4) declined to the hours chart's columns; seed:cfef118e0666b681.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Finish review (2026-11-19)

A fresh reviewer agent (no shared context) judged the renders against this contract and DESIGN.md: first a
recapture (the harness had shot only the first screen and pages without their Back arrow; fixed: every page pushed
over a stub route, every state also at full length, 100 and 130 % text), then five material fixes, all applied and
scored resolved, disposition ship: the "how it works" sentence below the ledger once on, so the ledger reaches the
first screen at 100 %; the test's Start as the one filled step with Skip as a text button and Done pinned only after a
test; one full-width segmented row for the three groupings instead of wrapping chips; the pressure axis worded
("rested", "bedtime", "of 100"); clock spans and end ticks kept inside the waking window ("09:30 to 12:00"); plus
tick labels that never touch. Not taken (the reviewer's "ceiling", optional): today's cell outlined green in the Days
row, and a "now" hairline with today's answers ringed in the charts. At 130 % text the ledger starts just below the
first screen (accepted: the larger text forces the reflow).
