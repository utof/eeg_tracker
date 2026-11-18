---
version: 1
slug: "app-lib-ui-dream-screen-dart"
primary_target: "app/lib/ui/dream_screen.dart"
related_targets: ["app/lib/ui/dream_view.dart"]
---

# Dream catcher (app/lib/ui/dream_screen.dart)

Scope: the dream catcher (ROADMAP row 20), a pushed screen from the night screen: its setup, the in-bed session and
the answers afterwards. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world of
DESIGN.md (inherited, unchanged; one local addition: the session face on true black).
Audience and job: the owner at bedtime or a nap, lying down with the headband on, phone on the bed at arm's
length. Once: records two short prompts in his own voice. Each time: picks 3 or 4 rounds and how it ends, taps
Lights off, closes his eyes; half-asleep, hears a question, answers aloud, maybe taps "drifting" or "awake",
drifts again. Next morning: plays each answer back and types a note. Constraints: dark room, the screen on but
dimmed to the minimum for up to 45 minutes; 48 dp targets; system font scale; the "i" note reachable; nothing
claims the app detects dreams or helps sleep (docs/evidence/dream-catcher.md). Decided without the owner (a
subagent run, no question channel): the roll's lead structure below is taken as the choice.

Ranked structures (resonance): 1 deck-log column, session dimmed in place; 2 blackout face for the session;
3 45-minute drift track with numbered round pins; 4 morning-first answers; 5 two tabs (Tonight / Answers);
6 setup stepper; 7 the voice-clip list: prompts and answers as one family of playable clip rows (dealt lead).
Dealt: 7 (lead), 5, 3. Kept from 2: the session takes over the whole screen as a near-black face (a bed scene
needs it). Declined: 5 (two tabs hide the morning answers behind a tap), 3 (a lit chart in bed; the epochs are
kept in the file for later). Challengers (world-level type and print grammars) do not apply to an Operate
surface inside a settled world.

## Direction contract

THESIS: The dream catcher is about voices: two you record before, a few you speak half-asleep. Every recording
is the same playable clip row, so the prompts and the answers read as one tape log. Refuses the category default:
a moon-and-stars sleep screen with a big glowing start orb and a mood journal.

OWN-WORLD: The night-watch palette and type unchanged; clip rows on hairlines: a 48 dp ringed play control,
title and clock in ink, length and cause in ink-muted, the note as a ruled text field. Green only for a clip
that plays or records, and for Lights off. The session face: true black, one dim word, round marks as the
state circles (filled done, ringed dot now, ring to come).

STORY: Open: Last session's answers first (morning), then Your prompts (record or play each), Tonight (3 or 4
rounds; wake me, or record the night after), the notes, earlier sessions. Lights off: the screen goes black and
dim. Each round the face says Listening, Recording your answer, then splits into two big halves, Drifting and
Awake. At the end: the answers, ready to play and annotate.

FIRST VIEWPORT: App bar "Dream catcher" with Back and "i". A status mark and word ("Ready", "Session over"),
one sentence; the newest session's clip rows when there is one, else Your prompts. Lights off pinned at the
bottom, filled.

SIGNATURE: the clip row, shared by prompts and answers (play ring that turns to a green stop while it plays;
record turns the row green with its seconds counting), and the halved "were you drifting?" face.

FINISH: rendered at 100 % and 130 % text in test/dream_screens_test.dart (build/screens/dream_*.png), looked at,
fixed; the face also checked for light: nothing larger than a word lit.
