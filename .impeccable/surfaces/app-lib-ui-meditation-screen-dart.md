---
version: 1
slug: "app-lib-ui-meditation-screen-dart"
primary_target: "app/lib/ui/meditation_screen.dart"
related_targets: ["app/lib/ui/meditation_view.dart","app/lib/ui/phase_track.dart"]
---

# Meditation screen (app/lib/ui/meditation_screen.dart)

Scope: the meditation mode, a pushed screen from the night screen. Mode: Operate. Platform: Android
(Flutter, Material 3), inside the night-watch world of DESIGN.md (inherited, unchanged).
Audience and job: the owner, sitting or reclined, about to meditate 5-20 minutes with the headband on and
headphones in. Picks a length, starts, follows two silent calibration steps (eyes open on one spot, then
eyes closed), meditates with eyes closed while the sound follows him, glances at the screen rarely, then
reads a short report and how it compares with earlier sessions. Constraints: dim room, screen kept on but
dark; 48 dp targets; system font scale; the "i" note must be reachable in every state; nothing claims a
meditation depth or score (docs/evidence/meditation-feedback.md). Decided without the owner (asleep, no
question channel; a subagent run): the roll's lead structure below is taken as the choice.

Ranked structures (resonance): 1 session watch strip; 2 fixation lamp; 3 deck-log of events; 4 instrument
over event log; 5 three-phase track (dealt lead); 6 Material vertical stepper; 7 bottom sheet over the
night screen. Dealt: 5 (lead), 4, 3. Challengers declined: labanotation score (kept: a mark's length is its
exact duration); split-flap concourse (declined for the night screen too; kept: values in fixed cells).

## Direction contract

THESIS: A meditation is one line run end to end: eyes open, eyes closed, the session, the report; each
segment as long as its real duration, so the user always sees where on the line he is. Refuses the
category default: a glowing breathing circle or progress ring with a mood word.

OWN-WORLD: The night-watch palette and type unchanged: warm chart-table ground, parchment ink, the dimmed
navigation-light trio for state (settled green filled mark, restless amber ringed dot, drifting red ring,
settling muted ring, no signal red dash); track cells like the watch strip; hairlines, one ply, no cards.

STORY: Choose 5, 10 or 20 min and see the line laid out (30 s, 60 s, the session). Start: the live marker
walks the line while one big word says what to do. Eyes closed, the sound does the talking. At the end the
session segment becomes the calm line with restless and drifting marks at their real times; the numbers
and the comparison sit under it.

FIRST VIEWPORT: Top app bar "Meditation" with Back and an "i" action. Status: state mark and word at display
size, one sentence. The phase track, full width. Two tabular readouts split by a hairline (time left,
bells). Notes below (headphones, contact). Primary action pinned at the bottom, 64 dp: Start (filled) or
Stop (outlined, confirmed); after the report, Done.

SIGNATURE: the phase track: segments proportional to real durations, filled as time passes, the live one
outlined green; after the session its segment draws the calm line, ticks at each restless (amber) and
drifting (red) moment.

FORM: three-phase track, surface structure 5 of 7; seed:975b700a15f303e1.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review and the verdict.

## Finish review (2026-11-18) and open points

Disposition "fix", eight findings, all applied: track keeps eyes closed exactly twice eyes open (22 dp floor
on eyes open only); finished sessions wear the idle ring, not the green "good" mark; the eyes-open spot is a
still 28 dp dot mid-screen; the length selector keeps Material's check mark; no double rule in the report;
the settled share moved into the readout label; screen fixtures keep counts and marks one-to-one.
For the owner (DESIGN.md not changed without approval): DESIGN.md says "Start night is the only filled
button" and "no sounds"; this screen adds one filled primary of its own and is a sound practice by design.
