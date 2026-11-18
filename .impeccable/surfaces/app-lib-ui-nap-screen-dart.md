---
version: 1
slug: "app-lib-ui-nap-screen-dart"
primary_target: "app/lib/ui/nap_screen.dart"
related_targets: ["app/lib/ui/nap_view.dart"]
---

# Nap coach (app/lib/ui/nap_screen.dart)

Scope: the nap coach (ROADMAP "Nap coach", DECISIONS 173-177), a pushed screen from the night screen: its setup, the
in-bed session, the wake and the report. Mode: Operate. Platform: Android (Flutter, Material 3), inside the
night-watch world of DESIGN.md (inherited, unchanged; the session face on true black as the dream catcher's).
Audience and job: the owner (not a scientist; plain short words) lies down for a nap with the headband on, phone on
the bed at arm's length. Each time: picks a length (20 / 30 / 45 / 90 min), taps Lights off, sleeps; is woken by a
soft rising cue, taps "I'm awake", reads how the nap went. Constraints: dark or dim room, screen kept on and dimmed
for up to 90 minutes; 48 dp targets; system font scale; the "i" note reachable; nothing claims more than the data
(the live stages are a first guess, not checked on this headband). Decided without the owner (a subagent run, no
question channel): the roll's lead structure below is taken as the choice.

Ranked structures (resonance): 1 deck-log column, session dimmed in place; 2 the length as a strip of half-minute
cells filling during the nap; 3 report-first (last nap leads); 4 a countdown dial; 5 the stage ladder: the sleep
report's worded levels as the screen's spine, plan before and record after; 6 a two-step wizard; 7 alarm-clock rows.
Dealt (seed 6fb86dcba8c2574a8520fe02fef880ce, surface, operate): 5 (lead), 2, 1. Kept from 1: the deck-log column
and the pinned Lights off; from 2: minute rules along the ladder's length. Declined: 4 (the category's countdown
ring), the challengers (each would replace the settled world: a video feed, a transit mural, a type specimen, a dance
score, an acetate manual).

## Direction contract

THESIS: The nap coach makes one promise: you go down from Awake to Light, and it wakes you at the Deep line or at your
length, whichever comes first. The screen draws that promise on the sleep report's own worded ladder, as the plan
before the nap and as what happened after it. Refuses the category default: a glowing countdown ring and a moon.

OWN-WORLD: Night-watch palette and type unchanged. The ladder is the sleep chart's grammar: worded levels left (Awake,
Dream, Light, Deep) on track lanes, an ink step line, minute rules every 10 minutes, amber hatch where the signal was
lost, nothing told by colour. Report lines label-left, value-right on hairlines. The face true black, words only.

STORY: Open: status and one sentence, the plan ladder for the length picked, the length choice, the last nap's
ladder and lines, earlier naps. Lights off: black face, one dim word, "12 of 30 min", whether the sleep model is on.
Wake: normal brightness, a screen-wide "I'm awake" and why. Done: the report.

FIRST VIEWPORT: app bar "Nap coach" with Back and "i"; status mark + "Ready" + one sentence; the plan ladder full
width; the length row (20 / 30 / 45 / 90 min); Lights off pinned, filled.

SIGNATURE: the ladder, shared by plan and report: the plan as a dashed line falling to Light and a short ink bar on
Deep worded "wakes you here", the length's rule at the right "or at 30 min"; the report the measured step line with an
ink rule where it woke you.

FINISH: rendered at 100 % and 130 % text in test/nap_screens_test.dart (build/screens/nap_*.png), looked at, fixed;
the face checked for light: nothing larger than a word lit, except the wake.
