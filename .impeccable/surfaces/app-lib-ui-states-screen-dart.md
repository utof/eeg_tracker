---
version: 1
slug: "app-lib-ui-states-screen-dart"
primary_target: "app/lib/ui/states_screen.dart"
related_targets: ["app/lib/ui/states_view.dart","app/lib/ui/sound_score.dart"]
---

# Sound for states (app/lib/ui/states_screen.dart)

Scope: sound for states (ROADMAP rows 17-18), a pushed screen from the night screen, offered between nights and also
during one (then sound only). Its setup, the session face and the result afterwards. Mode: Operate. Platform: Android
(Flutter, Material 3), inside the night-watch world of DESIGN.md (inherited, unchanged; the session face on true black
as in the dream catcher).
Audience and job: the owner, not a scientist. Picks a state (fall asleep, relax, focus, break, wake up) and a calm
sound, optionally a beat, or "no beat" to compare; with the headband on, a silent quiet minute, then the sound and what
his brain does against that minute; "fall asleep" stops by itself once he is probably asleep, or at its timer; with no
headband (or the night recording holding it) the sound plays by its timer. Afterwards: plain result lines and one
answer, "did it help you get there?". Constraints: dark bedroom for fall asleep (screen kept on, black, dimmed),
a desk for focus; 48 dp targets; system font scale; the "i" note reachable; nothing claims the sound moves the brain
into a state (docs/evidence/sound-for-states.md); the beat's echo is named as an echo, with the tone-leak risk.
Decided without the owner (a subagent run, no question channel): the roll's lead structure is taken as the choice.

Ranked structures (resonance): 1 deck-log column with the session dimmed in place; 2 blackout face for the session;
3 recipe row (state, sound, length as three dials); 4 shared phase track (quiet, sound, fade) like the meditation;
5 the sound score: the session drawn before Start as a strip of its real minutes, loudness envelope below and the beat's
rate as a line above (dealt lead); 6 state-first rows that open into their sound options; 7 a comparison ledger of
past sessions first. Dealt: 5 (lead), 6, 7. Kept from 2: eyes-closed sessions take the whole screen as a near-black
face. Declined: 6 (five open rows push Start off the first viewport), 7 (no comparison engine yet; the ledger stays
a short list at the bottom). Challengers (split-flap board, transit diagram, timetable slides, ticket wallet, metro
tiles) bring their own worlds; this surface lives inside a settled one.

## Direction contract

THESIS: A session is a score you can read before you press Start: its real minutes left to right, the quiet minute
blank, the sound's loudness as a band that fades in and out, and the beat's rate as one line sliding from 10 to 3 Hz
(or no line: no beat). Refuses the category default: a wall of glowing "alpha / theta / delta" tiles with waveform art.

OWN-WORLD: The night-watch palette and type unchanged: warm ground, parchment ink, hairline sections, Material chips
and segmented rows in surface-high, one filled Start in live-fill. The score: track-colored band, ink rate line with
its two ends worded in Hz, minute ticks in ink-muted, the live position a thin green rule; nothing glows.

STORY: Choose a state, see its score; change the sound or add a beat and the score redraws; Listen sets the phone's
volume. Start: a quiet minute (words only), then the sound; eyes-closed states go black and dim. Afterwards: where it
ended on the score, what the brain did in plain words, one 1-5 answer.

FIRST VIEWPORT: App bar "Sound" with Back and "i". Status mark and word ("Ready", or "Night recording: sound only"),
one sentence. The score, full width, 96 dp, worded ends. Then State chips and the state's one line. Start pinned at
the bottom, filled, 64 dp.

FORM: the sound score, structure 5 of 7; seed:c412c8d042c9b3b7.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Finish review (2026-11-18) and open points

In-thread review (a subagent run; no separate reviewer spawned) of the test renders at 100 and 130 % text
(`build/screens/states_*.png`) against the contract. Verdict: ship, with these applied: the rate's arrow became
"10 to 3 Hz" (the arrow had no glyph in the test font); a "Next session" heading separates the last session's score
from the next one's; the score's right label says minutes of sound ("sound: 30 min at most"). Seen and kept: the
quiet minute's cell is narrow on a 45-minute score (its label says it); the face is words only. DESIGN.md gained the
sound score component and the session-face line. Open for the owner: levels and beds not yet heard; whether a
locked phone should keep playing (DECISIONS row 135).
