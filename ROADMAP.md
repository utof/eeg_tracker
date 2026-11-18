# Roadmap

What the owner asked for, what each wish can honestly become with these electrodes, and where it stands.
Choices and their alternatives live in [DECISIONS.md](DECISIONS.md); evidence in `docs/research/`.
Update the status column whenever something lands.

## The owner's wishes (2026-11-18)

1. **Sleep**: headband on, one tap on the phone, sleep; in the morning see how the night went.
2. **Stress, anxiety, fatigue, focus**: know these states and what changes them.
3. **"Take a break" hints while coding.**
4. **Brain-driven generative music.**
5. **A great UI** (built with the `/impeccable` skill), phone at least as important as the PC.
6. **Lots of long-term statistics** on what affects you; data also flows into the private life tracker (utof_tracker).
7. **Features other EEG apps have**, including ones the owner might not know about.
8. **Devices**: BrainBit Black first, then the DIY ADS1299 helmet (8-16 electrodes, any positions), then OpenBCI and others.
9. **Sound for states** (added 2026-11-18): like the "alpha waves for sleep" videos, but personal: pick a state (fall
   asleep, focus, break, ...), the app plays sound to help you get there (binaural beats, isochronic tones, pulsed
   music or noise, nature), measures whether you actually got there, and learns over days what works for you.
10. **A state and trends page**: a few numbers (drowsiness, sleep, alertness, tension) to see at a glance where you
   are and where it is going.
11. **Meditation feedback, live and after the session** (added 2026-11-18, high priority): to improve faster.
12. **Neurofeedback training** (added 2026-11-18): alpha-theta training (owner: yes, aware it can bring up strong
   memories), and an honest check of whether the feedback itself helps: on some sessions the app replays an earlier
   session's feedback instead of the live one, and later shows whether live sessions did better. In the app this is
   behind a toggle (off by default), and before each meditation a reminder says it is on.
13. **Mission**: affordable EEG for everyone: build-at-home guides for the helmet plus this open app, with contributors.
14. **An "i" button next to every exercise and feature** (added 2026-11-18): what the research says, where the data
   supports it and where it does not; for ML features (noise cleaning, sleep scoring, forecasts) the research behind
   them; links to the sources and the libraries used. For the owner and for anyone else who uses the app.
15. **Repairable headband** (added 2026-11-18): the BrainBit's battery and electrodes by name, so they can be ordered
   and swapped.
16. **The phone app first** (owner, 2026-11-18): the web pages are only a stopgap until the app exists; keep them
   simple, put the effort into the app.

## What each wish becomes (honest version)

| Wish | What we build | How sure (4 dry electrodes O1 O2 T3 T4) |
|---|---|---|
| Sleep | night recording, sleep stages (AnySleep + YASA), sleep onset, time asleep, wake-ups, morning chart | timing usable; stages a first guess until checked |
| Fatigue | morning check-in: eyes-closed alpha strength, alpha peak speed, eyes-closed rise; drowsiness trend during work after calibration | reliable (alpha); usable (drowsiness) |
| Stress / tension | "tension" from jaw clench and muscle at T3/T4, plus your own 1-tap ratings beside the data | jaw: reliable; a "stress score": not honest at these sites |
| Anxiety, focus | your own ratings, kept next to EEG trends; "engaged vs drifting" only as a personal pattern | not measurable directly here |
| Breaks | stage 0 from ActivityWatch (no headband), then ratings, typing rhythm, then the EEG trend | no validated EEG break detector exists |
| Music | procedural ambient sound that calms as eyes-closed alpha rises; jaw clench blocks rewards | measurement fine; benefit evidence weak (say so) |
| Sound for states | binaural / isochronic / pulsed / nature sound per state; checks if you got there (sleep onset: alpha fades, slow eye rolls; relax: alpha up; break: drowsiness falls; focus: weak, rating + drowsiness); stops by itself once you are asleep | the brain's hearing area follows pulses reliably; whether that moves the whole state is less proven, which is why we measure it on you |
| Meditation feedback | live: sound and a simple display of settled / restless / drifting toward sleep; after: a timeline of the session, share of settled time, longest settled stretch, movement and jaw events, your own rating, and the trend across sessions | stillness, eyes-closed alpha and drowsiness are measurable; there is no reliable "meditation depth" signal, and a 2025 review found Muse-style feedback mainly helps through the practice itself, so it shows what is measurable and tracks your own progress |
| State and trends page | big numbers with arrows against your own usual and a "how sure" dot: sleep, morning alertness, drowsiness now, tension | as sure as each number's row above |
| Statistics | per-day export to utof_tracker's careful nightly analysis first; later "seen together" vs "tested" (random self-experiments) | needs about a month of days |
| Other apps' features | contact display per electrode, live artefact flags, meditation/alpha sessions, night jaw-clench count, open export, no account | standard |

## Status

| # | Feature | Status | Where |
|---|---|---|---|
| 1 | Laptop recorder + live check page | working; survives Bluetooth drops (restarts itself) | `scripts/record_night.sh` |
| 2 | Night → one BDF+ file | working | `scripts/to_bdf.py` |
| 3 | Sleep scoring + hypnogram chart | working on test data; first real night 2026-11-18; **on the phone too** (2026-11-18, branch `feat/app-sleep-report`): AnySleep as ONNX scores each night after Stop, a sleep report screen with the chart, periods and past nights; agrees with the laptop on 96.6 % of 30-s epochs of the owner's night; phone speed not yet measured | `scripts/score_sleep.py`; app: `lib/sleep/`, DECISIONS 95-99 |
| 4 | Export to utof_tracker's event format | working; utof_tracker does not read it yet (needs the owner's OK to change it) | `scripts/export_events.py` |
| 5 | Android recorder app (one tap, screen off all night) | code + tests done; first release APK built 2026-11-18 (30 MB, sent to the owner); phone test pending | branch `feat/android-recorder` |
| 6 | Morning check-in (eyes closed / open, ratings) + setup test | page, analysis, export and tests done on the fake headband; first real morning pending | `scripts/web/morning.html`, `scripts/morning_check.py` |
| 7 | Brain-reactive sound (alpha → calmer sound, jaw blocks) | feedback core v1 done (research A pass 2, item 1): live stream input, alpha in ~0.15 s around your own alpha peak, a target line held for 3-min blocks, at most 6 bells a minute, muscle / blink / drifting-to-sleep gates (shared `sleep-guard.js`), training and relax modes, a session log that replays exactly; tested on the demo and the fake headband. Real-head bench tests pending. The page is a stopgap: the pure modules port to the phone app | `scripts/web/sound.html`, [docs/brain-sound.md](docs/brain-sound.md) |
| 8 | Break hints stage 0 (ActivityWatch) | code + tests done; not yet run on the owner's laptop | `scripts/break_hints.py`, docs/break-hints.md |
| 9 | Night extras: jaw clench count, movement, signal quality per hour | **in the sleep report** (2026-11-18, branch `feat/app-night-extras`; not yet run on a phone): the phone runs the detectors beside the sleep model and the report shows how much of the sleep was read through noise, a Signal lane under the chart, jaw-muscle bursts and movements per hour asleep with earlier nights' jaw numbers, and the night hour by hour; the laptop report has the same `extras`. Phone code = Python reference on the owner's night (924 bursts, 508 movements, every epoch's quality); asleep: 22.8 jaw bursts and 18.9 movements an hour, 13 % read through noise. Next: the owner's setup test (clench limits) and a few nights to see the trend | `app/lib/sleep/extras.dart`, `analysis/night_extras.py`, [docs/detectors.md](docs/detectors.md), DECISIONS 140-146 |
| 10 | State and trends page (numbers + arrows vs your usual, 14-day lines; laptop first, then phone) | after 6 and 3 | - |
| 11 | utof_tracker importer for `eeg_*` events | waits for the owner's OK | - |
| 12 | Calibration for any electrode positions (helmet) | after the helmet exists | DECISIONS row 4 |
| 13 | DIY board driver (E9 frames) in the app | after the helmet exists | DECISIONS row 5 |
| 14 | Statistics engine + random self-experiments | after a month of data | DECISIONS row 12 |
| 15 | Build guides for the helmet | in `eeg_ads1299_lab` | other repo |
| 16 | Eyes open/closed test (high beep open, low beep closed) | working | `scripts/web/eyes.html` |
| 17 | Sound for states: binaural, isochronic, pulsed noise; presets per state; markers for checking | first page working (review fixes in); next: calm beds as the default, beats as optional extras | `scripts/web/beats.html` |
| 18 | Sound for states: measure "did I get there", stop when asleep, learn what works for you | the stop-when-asleep part is ready to use: the drift-off detector and its timers (fade 2.5 min after "probably asleep", silent 45 min after lights off regardless; row 25); the rest after research + 6 | `app/lib/detectors/drift_off.dart` |
| 24 | Research round 2 (18 lanes: neurofeedback and sound feedback; more from four electrodes; EEG machine learning 2025-26; app tech and data) + parts | done 2026-11-18 (second pass via API, $119.79); all findings on one page | `_local/research/2026-11-18-findings.html` |
| 19 | Research: sound for states; states and their markers; more features | done 2026-11-18 | `_local/research/2026-11-18-06-brain-states-sound-and-features.md` |
| 21 | Meditation feedback: live (sound + settled / restless / drowsy) and a report after each session, progress across sessions | **v1 in the phone app** (2026-11-18): the feedback core ported to Dart (agrees with the JS core on a JS-made session), sound with `flutter_soloud`, a meditation screen (5 / 10 / 20 min, silent calibration, state chip, report with a calm line, comparison with earlier sessions, the "i" note); tested with a fake headband; not yet heard or run on the phone. "Drifting" also comes from the shared drift-off detector since 2026-11-18 (row 25). Later: a no-feedback block, the learning verdict at 8 / 12 sessions, Bluetooth route detection | branch `feat/app-meditation` (from `feat/android-recorder`), `app/lib/feedback`, `app/lib/meditation`, DECISIONS 72-77 |
| 25 | Shared detectors ("what the electrodes see") and the drift-off detector | **built 2026-11-18**: Python reference checked on the night, the morning sleep and the check-in; Dart port in the app (same events on recorded excerpts), wired into meditation's "drifting". Sleep onset within 0.5 min of AnySleep on both recorded onsets (2 of the 5 nights it needs); blinks 3.1 a minute eyes open vs 0.5 closed; 86 % of loud muscle seconds flagged. Waits for the setup test (blink depth, glances, clenches) and 3 more lights-off nights | branch `feat/app-detectors`, [docs/detectors.md](docs/detectors.md), DECISIONS 85-89 |
| 22 | Alpha-theta training (eyes closed, back of the head; 10 sessions, the first 3 only 15 min, then decide; side-effect checklist every session; alertness check before driving; stop button; "practice, not treatment"; a note that strong memories can come up) | **built in the phone app** (2026-11-18; not yet heard or run on the phone): screening, consent and stop plan, check-in and after-session checklist with pause rules, the length rule and the decision after 10, stream-to-ocean sound with chime and gong, the drift-off detector as sleep guard (fade, rising wake tone), grounding, a 1-minute reaction test before you leave; tested with a fake headband | branch `feat/app-replay-alphatheta`, `app/lib/alphatheta`, DECISIONS 104-107 |
| 23 | Replayed-feedback check: some sessions secretly replay an earlier session's feedback; after enough sessions, live vs replayed is compared (feeling, the trained signal, ratings) | **built in the phone app** (2026-11-18; not yet run on the phone): toggle off by default with the reminder before every session, 4 live donor sessions per kind, then shuffled blocks of 4 drawn from a phone-made secret with the plan and the order's SHA-256 frozen first, own-replay of the sound with live gates, no live bell count, guess / control / randomness after each session, results per 12 with a permutation test; tested end to end with a fake headband | branch `feat/app-replay-alphatheta`, `app/lib/training`, DECISIONS 100-103 |
| 20 | Dream catcher (owner: "definitely build"): at sleep onset, ask what you're thinking, record the answer, let you drift again, 3-4 rounds | **built in the phone app** (2026-11-18; not yet run on a phone or a head): your own recorded theme and question (tones if none), Lights off with the 60 s baseline, round 1 at the detector's "drowsy" or a random moment in the usual time to fall asleep, later rounds when alpha came back and faded again (2 min apart at least, 4-7 min at most), answers recorded until 3 s of quiet, a two-halves "were you drifting?" tap, 3 or 4 rounds, 45 min cap, wake tone or the night starts by itself; its EEG is part of that night with markers; answers list with playback and notes; tested with a fake headband and microphone. Next: the owner's first nap (`app/README.md`, "Dream catcher") | branch `feat/app-dream-catcher`, `app/lib/dream`, DECISIONS 110-116 |

## What comes next, in order (updated 2026-11-18 after research round 2)

The owner's features first (wish 16: the phone app leads). Each step names the research behind it; the full
findings are on `_local/research/2026-11-18-findings.html`.

1. **Phone app** (battery line and packet count: done 2026-11-18): a once-a-minute phone battery line and a per-night count of missing packets in the log
   (assistant, small); then the owner's phone test (below); then merge `feat/android-recorder`. (Research D)
   - **Sleep report in the app** (row 3; owner: "the app is what I'm gonna be using"): built 2026-11-18 on
     `feat/app-sleep-report` (from `feat/app-meditation`): the night prepared in Dart exactly as on the laptop,
     AnySleep's three runs as ONNX (19.7 MB), scored after Stop, report screen (DECISIONS 95-99). Next: the
     owner's one-night speed test (`app/README.md`, "Sleep report"); then the morning check-in in the app and
     exporting the report with a night.
2. ~~**Meditation feedback in the app**~~ (row 21): v1 built 2026-11-18 on `feat/app-meditation`: the core in
   Dart, `flutter_soloud` at 48 kHz, the meditation screen and report (DECISIONS 72-77). Next: the owner listens
   and runs a few sessions (below); then the no-feedback block and the learning verdict. (Research A, D)
3. ~~**Shared detectors**~~ (rows 9, 18, 20, 21, 25): built 2026-11-18 on `feat/app-detectors`: blinks, eye
   movements on T3-T4, jaw 55-120 Hz, movement, epoch quality, and the drift-off detector with a lights-off
   baseline and both timers, in Python and Dart ([docs/detectors.md](docs/detectors.md)). Next: the lights-off
   button on the night screen and the counts in the sleep report; it ships when its onset falls within 5 minutes
   of AnySleep's on 4 of 5 recorded nights (2 so far). (Research B, C)
4. ~~"i" evidence notes~~ (wish 14): done 2026-11-18: 15 notes in `docs/evidence/`, "i" buttons on every page;
   the app will bundle the same files.
5. ~~**Replayed-feedback check** (row 23), then **alpha-theta** (row 22)~~: built 2026-11-18 on
   `feat/app-replay-alphatheta` (DECISIONS 100-107). Next: the owner listens to the stream-and-ocean sound, runs the
   first alpha-theta sessions, and switches the check on once 4 meditations are logged; the check needs 24-36
   sessions before it can say anything. (Research A)
6. **Our own headband connection** (replaces BrainBit's library; owner asked 2026-11-18): the protocol is mostly
   public (Neiry's MIT `web_sdk_neiry`); a 15-minute probe with the headband on, then a Python driver for the laptop
   (no process restarts: reconnects in seconds, no unpairing, no crashes, contact all night if command 5 works), then
   Dart in the app. BrainBit's library stays as a fallback. (Research D; DECISIONS 68, 84)
7. ~~**Dream catcher**~~ (row 20): built 2026-11-18 on `feat/app-dream-catcher` (from `feat/app-line`; DECISIONS
   110-116). Next: the owner's first try (a 20-minute nap, `app/README.md`, "Dream catcher"), then tune the voice and
   round timings from it; later speech-to-text for the answers. Then the nap preset. (Research C: a rule plus a timer
   is the proven design)
8. **State and trends page** (row 10): a sleep-pressure curve from the sleep log (not from EEG yet), "your usual"
   and "same as yesterday" next to every number; caffeine, alcohol and sleepiness taps in the morning check-in.
   Forecasts stay hidden until 60 days of ratings exist and they beat "same as yesterday" by 5 %. (Research B, C)
9. **Data safety**: a checksum file per night, a catalog, an encrypted restic backup to the `архив` drive and a
   monthly restore test (does not change DECISIONS 37). (Research D)

## Next tests that need the owner

- **Phone test** (about 1.5 h plus one night on battery): the steps in `app/README.md` on the app branch (install,
  phone settings, 1 hour screen off, the drop test, export). The assistant adds a few checks over USB while the
  phone is plugged in (forced deep sleep before the drop test, phone model, a 3-minute Bluetooth log).
- **Sound feedback bench tests** (6 x about 5 min, `sound.html`): a normal run with the headband on; 20 minutes
  reclined (does it catch dozing?); a few jaw clenches; a forced-roughness check; wired vs Bluetooth headphones;
  20 blinks on cue.
- **First meditations on the phone** (5-10 min each, `app/README.md` on `feat/app-meditation`): does the sound
  start and feel right (levels, rain, bells), does it follow eyes closing within about a second on wired
  headphones, does the chip say "restless" on a clench, and is the report believable.
- **Alpha-theta and the replay check** (`app/README.md` on `feat/app-replay-alphatheta`): read the screening and
  consent once; in the first session, are the stream and the waves pleasant at the same volume, are the chime and
  gong soft enough; does a short doze fade the sound and wake you gently; does the reaction test feel fair. For the
  check: switch it on in Training settings (gear button), and just meditate; results come after 12 sessions.
- **Extended setup test** (2 min, `morning.html`): blinks, left-right glances, clenches; it sets the detectors' blink
  depth, gives µV per degree and left vs right for glances on T3-T4, and confirms the 55-120 Hz jaw band
  ([docs/detectors.md](docs/detectors.md)).
- **First real morning check-in** (`morning.html`).
- **Sleep report on the phone** (one morning, about 15 minutes; `app/README.md` on `feat/app-sleep-report`,
  "Owner step"): after a recorded night press Stop and note how long the phone takes to show the time asleep,
  whether the app stays open, and whether the report looks like the night you remember.
- **First dream catcher nap** (about 20-45 min, `app/README.md` on `feat/app-dream-catcher`, "Owner step"): record
  both prompts and set the volume; 3 rounds, Wake me; tell the assistant whether the questions came half-asleep,
  too early or too late, whether the prompts' volume and the dim screen were right, whether answers were cut off or
  ran on, and whether the Drifting / Awake tap worked half-asleep.

## Decisions waiting for the owner

- Download about 58 GB of public sleep recordings (Dreem) to test the sleep scorer on headband-shaped data (over the
  10 GB-a-week download limit).
- Clear the GitHub billing lock, so GitHub builds the app on every change (the laptop can build it too).
- Morning check-in eyes-closed phase: keep 2 minutes or make it 3 (research D).
- Order a spare magnetic charging cable for the headband (order by about 28 November; see the parts report).
- Backups: an encrypted restic backup of the recordings to the `архив` drive needs a password you keep (a password
  manager or paper); say where it should live and the assistant sets it up. Today the recordings exist in one copy.

## Ideas for later (after the wishes above are built)

Anyone, including the assistant, adds ideas here. When one is started, move it into the Status table.

| Idea | What it is | Notes |
|---|---|---|
| Smart alarm | wakes you within a chosen window at a moment of light sleep, not deep sleep | AnySleep works live about 2 min behind the newest data (DECISIONS 79); needs the phone speed test |
| Nap coach | a nap that ends before deep sleep starts (so no groggy wake-up) | same as the smart alarm (DECISIONS 79) |
| Dream catcher (now row 20 above) | as you drift off, the app notices the half-dream stage (back-of-head alpha fading), quietly asks "what are you thinking about?", records your spoken answer, lets you drift again; 3-4 rounds. For creative ideas | MIT's Dormio; a 2021 study found 15 s in that stage tripled insight on a puzzle; needs only O1/O2 |
| Lucid dream cues | soft sound cues during dream sleep (REM) to become aware you are dreaming | evidence weak; fun |
| Hands-free controls | a double jaw clench or a look left-right as a switch: pause sound, mark a moment | jaw and eye movements are what these electrodes see best |
| Reaction-time check | a 1-minute daily tap test next to the EEG, an objective alertness number | now part of "Sharp-hours log" below |
| Self-experiments | the app picks random days (e.g. no coffee after 14:00) for a few weeks and reports the effect with a range | the only route to "this causes that" |
| Helmet-only | frontal brain asymmetry, a brain-typing speller (P300), flicker games (SSVEP) | need electrodes the headband lacks |

### Proposals from research round 2 (the assistant's; not approved yet)

Built only after the owner's features above, and only where the data clearly supports them. The owner can steer
or delete any of these.

| Idea | What it is | Evidence (research) |
|---|---|---|
| Sharp-hours log | hourly one-tap rating, 1-3 short reaction tests a day, focus-session count from ActivityWatch; no verdicts for 3 weeks (replaces "Reaction-time check" above) | some: computer logs explained ~9 % of how good a day felt (B) |
| "Unusual for you" card | NightSignal-style alerts on sleep, ratings and steps (EEG tested both ways), silent back-test first, on after 28 days | some for sleep and pulse data, none for EEG (B; Apache-2.0 code) |
| Sleep cues for memory | soft sound cues in deep sleep, only as a sham-controlled self-test; no closed-loop clicks | weak: a 13-lab replication is due ~2027; cues that wake you hurt memory (B) |
| Evening study, morning review | a plain reminder to study in the evening and review in the morning | some (B) |
| Open BrainBit driver | our own Bluetooth code instead of the closed SDK; contact quality all night | protocol mostly public via Neiry's MIT package; legal for your own device (D) |
| Sleep-scorer upgrade | AnySleep fine-tuned on public nights reshaped to the headband's channels (CHAT has them); adopt only if clearly better | some (C; needs the 58 GB download) |
| Live sleep stages on the phone | AnySleep itself, 2 min behind the newest data (DECISIONS 79); a small model only if the phone is too slow | Traumschreiber (MIT, Nov 2026) already runs AnySleep on a phone (C, D) |
| "Was this you?" | a warning when someone else wears the headband, after a month of nights | about 6 % error with two enrolment days (D) |
| Helmet layout | 8 sites M1 M2 F7 F8 Fz C3 C4 Pz plus the forehead reference, then 16; noted in `eeg_ads1299_lab` as a planning assumption | some (B) |
| Noise repair (ZUNA) | re-draw bad stretches on the laptop, mainly for the helmet | untested on 4 channels (C; Apache-2.0) |

## Research for later (proposed, not run yet)

| Lane | What it would answer |
|---|---|
| Rules for a public release | when an app counts as a medical device (EU MDR, US FDA "general wellness"), which claims are allowed, privacy law (GDPR) for brain data |
