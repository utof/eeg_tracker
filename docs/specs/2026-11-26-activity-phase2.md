# Automatic recording, phase 2: knowing what you are doing inside a recording (gap analysis and design)

Written 2026-11-26 by the `activity2` lane, read on main `5743f62`; built the same day on `feat/activity-phase2` from main `01ba8ee`. Decisions are DECISIONS rows 1100-1116; section 12 says where the build differs from this design.
Read with: `_local/research/2026-11-20-00-auto-activity.md` (the research this builds: "Recommended design", "Phases",
"What runs by itself per state", "Never automatic"), `_local/research/2026-11-20-20-steps-and-activity-from-eeg.md`,
DECISIONS 600-609 (phase 1), 700-709 (the Archive's lanes), 860-869 and 960-975 (the quick checks), 880-910 and
980-989 (Record first), `docs/specs/2026-11-21-record-first-design.md`.

## In plain words

1. Much of phase 2 was already built under other names. The Archive already draws lanes for sleep, eyes closed,
   drowsy, talking, moving, walking and no signal on every recording; naps and walks are already asked about
   ("The headband thinks you slept. Did you?").
2. What was missing, and is built here:
   - **One "What happened" lane** on a recording's page: one best guess per moment, each with how sure it is,
     kept apart from what you marked and from your tags.
   - **"Meditating or resting?"**: when your eyes were closed and you were still for 3 minutes or more in the day,
     the app asks once (at most one such question a day). It never starts a sound or a session.
   - **Work on a running recording**: when the laptop says you started working while the headband records, the app
     starts (or offers) the silent work analysis on that same recording, as your "When I put the headband on" setting
     for Work says.
   - **Morning**: when you end your sleep and the headband keeps recording, one line offers the morning check-in.
     It is never started for you.
   - **Automatic Lights off**: worked out silently for every night and written next to your own tap. It is not used
     for anything until it has landed within 5 minutes of your taps on 4 of 5 nights.
   - **A table of every guess** with the numbers behind it and your answer, for the laptop. No learning yet: that
     needs about 30 answers of each kind.
3. Nothing here plays a sound, sets an alarm, gives a cue, starts neurofeedback or the dream catcher, or uses the
   microphone.
4. How sure each guess is: headband off, near certain; eyes closed, strong; asleep, good (within minutes); walking,
   good when the rhythm is clear; drowsy with eyes open, some; talking against chewing, weak (the app says "talking
   or chewing").

## 1. What phase 2 asks for, and what Record first changed

The research's phase 2: a "what happened" lane under each session; eyes closed and still for 3 minutes in the day,
one question; asleep in the day, marked as a nap and scored, never woken; automatic Lights off under the drift-off
rule; a morning check-in offer; and the per-state table "what runs by itself".

Since then (DECISIONS 880-910, 980-989) there are no separate sessions: one **Record** button records all day and
Sleep, Nap, Work, Meditate and the others are stretches marked on that recording. So "inside a session" now means
"inside a recording", and "the kind Other records with the detectors only" is simply a recording with nothing marked.

## 2. Gap analysis, state by state

| State | How sure (research) | Exists on main | Missing | Built here |
|---|---|---|---|---|
| Eyes closed, resting | strong (about 1 person in 10 shows little alpha rise) | Archive lane "Eyes closed" from the detectors' pass (`archive/seen.dart`, the work session's rule); truth label `eyes_closed` | "and still for 3 minutes" as one state; the question | the mark "Eyes closed, resting"; the question "Meditating or resting?" |
| Drowsy, eyes open | some | Archive lane "Drowsy" (same pass); live in a work session | nothing new is possible honestly | shown in the lane with "some" |
| Asleep by day (nap) | good; onset within minutes on 2 of 2 real onsets, needs 5 nights | sleep stretches, nap reports, "Did you nap?" (rows 886-887, 860-869); never woken | a word in the lane | the mark "Nap" (a daytime sleep under 3 hours) |
| Asleep at night | good; stages a first guess | sleep report, lane "Sleep" | - | the mark "Asleep" |
| Talking / chewing | jaw muscle strong; which of the two weak | Archive lane "Talking" ("Talking or chewing"); eating is a Python prototype waiting for labels (row 925) | telling them apart | not built; the mark says "Talking or chewing" and "weak" |
| Moving | good for big moves | Archive lane "Moving" | - | the mark "Moving" |
| Walking / running | good on a clear rhythm; slow strolls poor | walking pass, lane, steps, "Did you walk?", the sleep veto (rows 800-809, 920-924); the phone's step counter as referee (optional switch) | vehicle and cycling (need Google's activity recognition) | the marks "Walking", "Running"; vehicle not built (row 1116) |
| No signal / headband off | near certain | lane "Signal"; the 60-minute rule; lost notices | - | the mark "No signal" |
| Working at the laptop | from the laptop, not the brain | the tray's work signal, the watcher's work start (rows 603, 608), Work as a stretch on the recording (row 980) | **the signal is refused while a recording runs** (`/work` answers 503; the watcher skips "busy: night recording"), so with Record first it almost never fires | the signal taken during a recording; the work analysis started or offered on the recording |
| Just woke, headband still on | - | the morning check-in exists; it is offered only between recordings | the offer when the sleep ends and the recording goes on | one line on the Record tab |
| Lights off by itself | to be proven: 4 of 5 nights within 5 min | the Lights off tap; the drift-off check "4 of 5" | everything | computed at scoring time, logged, compared; off until proven |
| Learning from answers (phase 3) | - | `auto-start/log.jsonl` (the start questions), `estimates.tsv` (sleep and walk questions) | one table of the in-recording guesses with their numbers | `guesses.tsv`; no model |

## 3. The "What happened" lane (DECISIONS 1101-1104)

- A new first lane on a recording's timeline (the Archive's recording page), named **What happened**. The older
  lanes stay under it as the detail. Your marks (the stretches you pressed), the sessions and your tags keep their own
  lanes: the three kinds of knowledge are never mixed.
- One state per 30 seconds, the first that applies: No signal, Asleep or Nap (the sleep report), Walking or Running
  (the walking pass), Moving, Talking or chewing, Eyes closed resting, Drowsy. Otherwise nothing is drawn.
- A band is at least 1 minute (No signal and Moving: 30 s; Eyes closed resting: 3 minutes), bridging one odd epoch,
  as the other lanes do.
- "Eyes closed, resting" = eyes closed by the pass, awake, no movement second and under 2 jaw bursts in the epoch.
- A tap on a band says what it is, where it comes from and how sure, in one sentence, with the "i" note
  `docs/evidence/what-happened.md`.
- It comes from what the phone already keeps of a finished recording: the detectors' pass, the sleep report, the
  walking pass. It is not live: a recording that still runs shows it for its closed part only when the pass has run
  (as today). Row 1102 says why and when to switch.
- Any layout: the pass picks O1 O2 T3 T4 by name (row 633); a recording without them gets the marks that need no
  such site (asleep, walking) and a sentence saying why the others are missing.

## 4. The question "Meditating or resting?" (DECISIONS 1105-1106)

- Asked about an "Eyes closed, resting" stretch of 3 minutes or more that lies in the day (outside your usual night,
  `auto/bedtime.dart`), is not inside a sleep period, and is not inside a stretch you marked as Meditate, alpha-theta,
  Sound, Nap, Sleep, Dream catcher or a check-in (you already said what that was).
- At most one a day (the day runs 04:00 to 04:00): the longest stretch of that day.
- It goes through the quick checks (`ConfirmQuestions.register`), so the asking rules decide when and whether it is
  shown: the daily budget, quiet hours, backing off, "old and short" (rows 960-975, 1000). No new notification.
- The card is a new kind, **choice**: "13:05-13:12. Your eyes were closed and you were still. Meditating or
  resting?" with **Meditating**, **Resting**, **Something else** and **Not sure**. A chip makes a truth label of that
  word (`meditating`, `resting`); in a notification it opens the app, as a blind card does.
- No sound starts, and the Meditate session is never started by the app.

## 5. Work on a running recording (DECISIONS 1107-1109)

- The recorder's own Share on Wi-Fi server now takes the laptop's `POST /work` while a recording runs.
- The watcher handles the laptop's word during a recording without a worn check (the recorder holds the headband):
  it looks at the Work setting, at "quiet after Not now", at what is marked now (anything marked: nothing happens)
  and at whether data arrived in the last 2 minutes.
- **Automatic**: the Work page opens and starts its silent session on the recording (a `work` stretch, source
  `auto_start`; hints on the screen, no chime unless you switched it on). **Ask me**: one quiet notice "The laptop
  says you are working. Work session on this recording?" Start / Not now. **Do nothing**: nothing.
- Every word from the laptop is one line in `auto-start/log.jsonl`, and the lane "Work" shows "Working (the laptop
  said so)" where no work session covers the time.

## 6. Morning (DECISION 1110)

- When a sleep stretch of 3 hours or more that you ended yourself ends between 04:00 and 13:00, the recording goes
  on, data is arriving and no check-in was done today: one line above the Record tab's buttons, "Slept until 07:12.
  Morning check-in now? About 6 minutes." with **Check in** and **Not now**. It goes away after 2 hours, after either
  button, or when something else is marked. No notification (you just tapped Stop sleep, so the app is open).

## 7. Automatic Lights off (DECISIONS 1111-1112)

- For every sleep stretch at scoring time: the first run of 60 seconds with the phone's screen off, a clean signal, no
  blink and no movement (a blink or a movement starts the count again; an unreadable second neither counts nor starts
  it again). Its first second is the automatic Lights off. The screen comes from the recording's own log lines
  (`screen on` / `screen off`, read every 10 seconds).
- Written into the report as `auto_lights_off` beside your tap, with the difference in minutes.
- The check: of the newest 5 nights that have both your tap and the automatic one, 4 within 5 minutes. Until then it
  is shown as one muted line in the report's "Falling asleep" part and used for nothing.
- Once trusted, on a night without your tap the report counts "time to fall asleep" from it and says so. The live
  drift-off detector still waits for your tap.

## 8. The guesses table (DECISIONS 1113)

- Phone: `files/activity/<recording>.guesses.json`, written whole each time the marks are worked out.
- Laptop: the data book's `guesses.tsv`, one row per mark, with the numbers the research names (clock against your
  usual bedtime, charging, screen, laptop, the phone's steps, eyes-closed share, back alpha, jaw, movement, signal
  quality; empty = not known), the question's id and your answer where one was asked, and the truth label that covers
  it where you gave one.
- No model. `scripts/asking_check.py`-style tables can come when there are about 30 answers per kind.

## 9. Never automatic

Sounds, alarms, cues, neurofeedback, the dream catcher, the microphone, deleting, sending data anywhere new. The
automatic work session is silent unless "Chime in automatic work sessions" is on (phase 1's switch).

## 10. Not built (DECISIONS 1116)

Live marks while a recording runs; Google's activity recognition (vehicle, cycling); talking against chewing;
automatic stop at wake; the daytime check every 20 minutes; the laptop's own copy of automatic Lights off; any model.

## 11. Checks

Tests first for every rule (Dart; Python for the laptop's table); the full chain of
`_local/apk/activity2-logs/run-chain.sh` (builds, Flutter and Python, analyze, shared_labels, the real-time step, the
emulator checks) plus a new emulator check `app/tool/activity_check.py` for the question and the lane.

## 12. As built (2026-11-26): where the build differs from the design above

- **The lane (3)**: bridging is over epochs that have no state only, so a mark never runs across another state.
  The "Found" list shows the lane's count of stretches, not a total.
- **The question (4)**: the estimate's label is `eyes_closed` (what the detector does know), not `resting`; the word
  you pick is the label. Also not asked where you tagged the recording yourself. A question already asked that day
  stands. The detectors' pass now runs when a recording stops (the orchestrator's answer to the open question).
- **Work on a recording (5)**: built after the check came out clean (one channel registration in the recorder's
  engine). Not built: the Work lane's "the laptop said so" band; the span's source `auto_start` (the `leftovers`
  lane). Not run on a phone or the emulator (no paired laptop there).
- **Morning (6)**: only the newest sleep stretch counts; "Not now" is remembered until the app restarts.
- **Automatic Lights off (7)**: logged and compared only. Counting the time to fall asleep from it on a night
  without a tap is not built (it needs a second pass over the night).
- **The guesses table (8)**: `charging` is always empty (the phone does not write it down during a recording).
- **Checks (11)**: `app/tool/activity_check.py` shows the lane and the question on the emulator. The morning line
  and the work word are covered by unit and widget tests only (a 3-hour sleep stretch and a paired laptop cannot be
  made on the emulator in a check's time).
