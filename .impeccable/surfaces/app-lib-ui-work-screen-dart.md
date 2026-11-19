---
version: 1
slug: "app-lib-ui-work-screen-dart"
primary_target: "app/lib/ui/work_screen.dart"
related_targets: ["app/lib/ui/work_view.dart", "app/lib/ui/night_view.dart"]
---

# Work session (app/lib/ui/work_screen.dart)

Scope: the work session (ROADMAP row 35, DECISIONS 440-449), a pushed screen from the night screen's "Work" section
between nights: its start page, the connection, the optional eyes-closed minute, calibration, the running page with
hints and breaks, and the saved summary. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch
world of DESIGN.md (inherited, unchanged).
Audience and job: the owner at his desk in daylight, headband on for hours, the phone beside the keyboard or locked
in a pocket. He glances for a second: am I alert, how long since a break; when the chime comes, he answers with one
tap. Constraints: 48 dp targets; system font scale (checked at 130 %); the "i" note reachable; the level is a guess
from one morning's tuning and the page never claims "fatigue" or "focus".

## Direction contract

THESIS: One word says how awake you look to the headband, one sentence says why, and the hour behind it is twelve
cells you can read without reading. Refuses the category default: a gauge, a percentage, a red alarm.

OWN-WORLD: Night-watch palette and type unchanged. The status word at display size with the trio's mark (alert green
dot, getting drowsy an amber ringed dot, drowsy an amber dot, not sure a dash), always the word too. Hairline sections,
label-left lines for the rules, readouts with small units. One filled button: On a break / Back.

STORY: Start page: Ready and one sentence, How it works as four label-left lines, the eyes-closed switch, earlier
sessions; Start work session pinned. Running: the word, the sentence, the hint (when there is one) as the page's first
entry with Snooze 20 min, Not now and the optional 1-5 row; The last hour; worn and since-a-break readouts; the signal
line; hints today; On a break and Stop pinned (3 : 2). Done: Saved, the totals, the hints and what followed them.

SIGNATURE: The last hour: twelve of the watch strip's own cells (5 minutes each), filling from the bottom with the
level (empty alert, half getting drowsy, full drowsy), a dash for too noisy, a faint outline for a break or before
the session; the legend says it in words.

FINISH: rendered at 100 % and 130 % text in test/work_screens_test.dart (build/screens/work_*.png), looked at, fixed
(Snooze and Not now share a row 3 : 2 so "Snooze 20 min" stays on one line at 130 %).
