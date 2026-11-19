---
version: 1
slug: "app-lib-ui-hands-free-screen-dart"
primary_target: "app/lib/ui/hands_free_screen.dart"
related_targets: ["app/lib/ui/hands_free_view.dart","app/lib/ui/settings_screen.dart","app/lib/ui/night_view.dart"]
---

# Hands-free controls: settings and calibration (app/lib/ui/hands_free_screen.dart)

Scope: two pages in the established night-watch world (DESIGN.md): Settings (a gear in the night screen's app bar),
whose one entry is the Hands-free controls switch with its status, what each gesture does and Calibrate; and the
calibration page (connect, 30 s still, "Clench twice now" x3, "Look left, then right" x3 on soft tones, the result per
try). Mode: Operate. Platform: Android (Flutter, Material 3). Audience and job: the owner (not a scientist), once to
set up and again when gestures stop working; sitting up, lights on or dim, the phone in hand, about 90 seconds.
Constraints: off by default; the headband is free only between nights; plain short words; only measured numbers,
planning limits labelled; renders at 100 % and 130 % text, 393 dp. Decided without the owner (subagent run, no
question channel; the brief stood in). The structure roll ran without challengers: dealt 5, 6, 4 of the assistant's
list (seed:cfda07469b40887d, reproduced with the same deal); 5 (the live meter) leads, with 4 (the try track) as its row of tries.

## Direction contract

THESIS: Calibration shows what the headband sees while you do it: your jaw and your eyes as two live lanes, the
clench line drawn across, each try marked where it fell. Refuses the category default: a spinner, "Calibrating...",
and a pass/fail badge.

OWN-WORLD: The night-watch palette and parts: track-ground lanes worded "Jaw" and "Eyes" like the sleep chart's
levels, ink bars and steps, a dashed ink line for the clench level, the watch strip's cells as the row of six tries
(ringed while cued, filled `saved` when caught, a dash when missed), log rows for the result, one filled button.

STORY: The owner reads one instruction in large type, does it on the tone, sees the jaw bars jump over the line or
the eye steps go up then down, sees the try's cell fill, and at the end reads which gestures work and what they do.

FIRST VIEWPORT: App bar with Back, "Hands-free calibration" and an "i". A row of six try cells under a muted step line
("Try 2 of 6"). The instruction at display size ("Clench twice now"). The two lanes, the last 10 seconds, full width.
Pinned at the bottom, full width, 64 dp: Start (filled) before, Stop (outlined) during, Done (filled) after.

SIGNATURE: the jaw lane: the clench line and your own bars crossing it, in your own resting level's units.

FORM: the live meter (dealt lead, position 5 of 7), fused with the try track (4); seed:cfda07469b40887d.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
