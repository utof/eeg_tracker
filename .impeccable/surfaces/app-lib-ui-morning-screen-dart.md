---
version: 1
slug: "app-lib-ui-morning-screen-dart"
primary_target: "app/lib/ui/morning_screen.dart"
related_targets: ["app/lib/ui/morning_view.dart","app/lib/ui/morning_section.dart","app/lib/ui/reaction_test.dart","app/lib/ui/form_parts.dart"]
---

# Morning check-in (app/lib/ui/morning_screen.dart)

Scope: the phone's morning check-in (the laptop page `scripts/web/morning.html` moved to the app), opened from
the night screen's Morning section. Mode: Operate. Platform: Android (Flutter, Material 3), night-watch world.
Audience and job: the owner just after waking, often sleepy, headband on, sitting still: check contact, close
the eyes for two minutes, look at a dot for two, answer a few taps (sleepiness, mood, tension, caffeine,
alcohol), a one-minute reaction test, then see this morning's numbers next to his usual. Constraints: the
eyes-closed phase must not light the room (sound tells when to open the eyes); the countdown pauses without
signal and says so; Stop asks once and keeps nothing; 48 dp targets; system font scale. Decided without the
owner (subagent run, no question channel): the decision round was replaced by the brief; every choice below
is an assistant proposal.

## Direction contract

THESIS: The routine is a short watch: one page per step, the steps logged at the top as state marks, one
forward action pinned at the bottom. Refuses the category default: a breathing ring, a progress circle and
cards.

OWN-WORLD: The night-watch palette; state marks from DESIGN.md (filled done, ringed current, ring to come);
the eyes-closed page sinks to ground with only a dim countdown; the eyes-open page holds one ink dot.

STORY: Intro lists the routine as a log; Check contact; four electrode lines with words; Start; low tone, eyes
closed; rising pair, eyes open on the dot; the questions and the reaction test; Save; this morning's entry with
yesterday and usual, and the way to Trends.

FIRST VIEWPORT: App bar with Back, "Morning check-in" and an "i" action; the routine as ruled lines with their
lengths; whether today's check-in is done; the pinned "Check contact".

SIGNATURE: the step marks line that carries through every page.

FORM: one page per step (dealt lead, position 6 of 7), fused with the routine as a checklist log (4) and the
result-first glance on the intro (5); seed:9d98b33d3b5a6301ef174a97d38c0e83.
