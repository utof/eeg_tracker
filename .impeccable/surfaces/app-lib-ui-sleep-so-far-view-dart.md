---
version: 1
slug: "app-lib-ui-sleep-so-far-view-dart"
primary_target: "app/lib/ui/sleep_so_far_view.dart"
related_targets: ["app/lib/ui/night_view.dart","app/lib/ui/sleep_chart.dart"]
---

# Sleep so far (app/lib/ui/sleep_so_far_view.dart)

Scope: the night screen's "Sleep so far" section while a night records (Night tab, under the Tonight strip) and the
page it opens. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world. Decided without
the owner (subagent run, no question channel; the brief stood in): every choice below is an assistant proposal.

Job and audience: the owner, awake in the night or early morning with the night still recording, in a dark room,
wants to see the sleep chart and totals so far ("or a button 'see graph now'"), then put the phone down again. It must
never look like the finished report: the after-Stop report scores the whole night together and may differ slightly.

## Direction contract

THESIS: the night's deck log read before the watch ends: the sleep report's own chart and lines, cut off at "now minus
2 minutes", with the provisional nature stated next to the numbers. Refuses: a live dashboard, a progress ring, a
pulsing "live" chart, colour per stage.

OWN-WORLD: inherited bridge-at-night palette and the sleep report's components (SleepChart, label-left / value-right
lines, muted honest note). Nothing new is drawn except one state: epochs not scored yet break the step line and stay
the empty track (no hatching: hatching means missing data).

SECTION (night screen): heading "Sleep so far", one muted line (the last look's asleep total and time, or what it
does), one outlined button "See sleep so far" with a chart icon; nothing scores until it is tapped. DIY board: one plain
sentence why there is none, no button.

PAGE: app bar "Tonight so far" with the "i" (sleep-scoring note). The status line in the alarm line's form (muted
bodyMedium, liveRegion) with one text button "Update" at its right: "To 03:12, 2 minutes behind the recording." /
"Scoring 01:04 to 02:08 (2 of 4)." / "Waiting while the live sleep model runs for the smart alarm." Then two
readouts split by a hairline (asleep so far, fell asleep at), the honest note in one muted sentence, the chart and
its legend, the totals as period lines (Light, Deep, Dream, Awake in between), wake-ups and not-recorded as plain
sentences, what the live model filled in and what is not scored yet as muted sentences, and the cost line at the foot
("Scored on this phone in 14 s over 3 looks ...").

STATES: nothing yet (under 5 minutes, or no data tonight), first look scoring (spinner-free: the status line says the
step), paused for the live model, failed (the reason, Update tries again), the night ended (Stop: the report comes
next). Refresh: on open, on return to the app, every 15 minutes while the page shows; never with the screen off.
