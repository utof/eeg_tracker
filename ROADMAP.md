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
| 3 | Sleep scoring + hypnogram chart | working on test data; first real night 2026-11-18 | `scripts/score_sleep.py` |
| 4 | Export to utof_tracker's event format | working; utof_tracker does not read it yet (needs the owner's OK to change it) | `scripts/export_events.py` |
| 5 | Android recorder app (one tap, screen off all night) | code + tests done; first release APK built 2026-11-18 (30 MB, sent to the owner); phone test pending | branch `feat/android-recorder` |
| 6 | Morning check-in (eyes closed / open, ratings) + setup test | page, analysis, export and tests done on the fake headband; first real morning pending | `scripts/web/morning.html`, `scripts/morning_check.py` |
| 7 | Brain-reactive sound (alpha → calmer sound, jaw blocks) | feedback core v1 done (research A pass 2, item 1): live stream input, alpha in ~0.15 s around your own alpha peak, a target line held for 3-min blocks, at most 6 bells a minute, muscle / blink / drifting-to-sleep gates (shared `sleep-guard.js`), training and relax modes, a session log that replays exactly; tested on the demo and the fake headband. Real-head bench tests pending. The page is a stopgap: the pure modules port to the phone app | `scripts/web/sound.html`, [docs/brain-sound.md](docs/brain-sound.md) |
| 8 | Break hints stage 0 (ActivityWatch) | code + tests done; not yet run on the owner's laptop | `scripts/break_hints.py`, docs/break-hints.md |
| 9 | Night extras: jaw clench count, movement, signal quality per hour | next, as part of the shared "what the electrodes see" detector (jaw band 55-120 Hz: the signal does not stop at 70 Hz, checks of 2026-11-18) | - |
| 10 | State and trends page (numbers + arrows vs your usual, 14-day lines; laptop first, then phone) | after 6 and 3 | - |
| 11 | utof_tracker importer for `eeg_*` events | waits for the owner's OK | - |
| 12 | Calibration for any electrode positions (helmet) | after the helmet exists | DECISIONS row 4 |
| 13 | DIY board driver (E9 frames) in the app | after the helmet exists | DECISIONS row 5 |
| 14 | Statistics engine + random self-experiments | after a month of data | DECISIONS row 12 |
| 15 | Build guides for the helmet | in `eeg_ads1299_lab` | other repo |
| 16 | Eyes open/closed test (high beep open, low beep closed) | working | `scripts/web/eyes.html` |
| 17 | Sound for states: binaural, isochronic, pulsed noise; presets per state; markers for checking | first page working (review fixes in); next: calm beds as the default, beats as optional extras | `scripts/web/beats.html` |
| 18 | Sound for states: measure "did I get there", stop when asleep, learn what works for you | after research + 6 | - |
| 24 | Research round 2 (18 lanes: neurofeedback and sound feedback; more from four electrodes; EEG machine learning 2025-26; app tech and data) + parts | done 2026-11-18 (second pass via API, $119.79); all findings on one page | `_local/research/2026-11-18-findings.html` |
| 19 | Research: sound for states; states and their markers; more features | done 2026-11-18 | `_local/research/2026-11-18-06-brain-states-sound-and-features.md` |
| 21 | Meditation feedback: live (sound + settled / restless / drowsy) and a report after each session, progress across sessions | **high priority (owner)**; v1 built in the phone app 2026-11-18 (Dart port of the feedback core, rain/drone/bells via flutter_soloud, 5/10/20 min, report vs earlier sessions; 122 tests pass, release APK 33 MB); waits for the owner's first phone sessions | branch `feat/app-meditation` (on top of `feat/android-recorder`) |
| 22 | Alpha-theta training (eyes closed, back of the head; 10 sessions, the first 3 only 15 min, then decide; side-effect checklist every session; alertness check before driving; stop button; "practice, not treatment"; a note that strong memories can come up) | planned, after meditation feedback and the replay check | uses the meditation feedback engine; plan changed by research A pass 2 (`_local/research/2026-11-18-07-neurofeedback-and-sound-feedback-pass2.md`): alpha-theta is the protocol with the most reported side effects |
| 23 | Replayed-feedback check: some sessions secretly replay an earlier session's feedback; after enough sessions, live vs replayed is compared (feeling, the trained signal, ratings) | planned with 21/22 | toggle, off by default; reminder text before each meditation while it is on |
| 20 | Dream catcher (owner: "definitely build"): at sleep onset, ask what you're thinking, record the answer, let you drift again, 3-4 rounds | planned, right after the current features | see Ideas |

## What comes next, in order (updated 2026-11-18 after research round 2)

The owner's features first (wish 16: the phone app leads). Each step names the research behind it; the full
findings are on `_local/research/2026-11-18-findings.html`.

1. **Phone app**: a once-a-minute phone battery line and a per-night count of missing packets in the log
   (assistant, small); then the owner's phone test (below); then merge `feat/android-recorder`. (Research D)
2. **Meditation feedback in the app** (row 21): port the tested feedback core (DECISIONS 41-48) to Dart, sound
   through `flutter_soloud` at 48 kHz; the meditation mode (session template, settled / restless / drifting, a
   report after each session). The laptop bench tests come first. (Research A, D)
3. **Shared detectors** (rows 9, 18, 20, 21): "what the electrodes see" (blinks, eye movements on T3-T4, jaw
   55-120 Hz, movement) and the drift-off detector grown from `sleep-guard.js`, with a "lights off" button; it
   ships when its sleep onset falls within 5 minutes of AnySleep's on 4 of 5 recorded nights. (Research B, C)
4. ~~"i" evidence notes~~ (wish 14): done 2026-11-18: 15 notes in `docs/evidence/`, "i" buttons on every page;
   the app will bundle the same files.
5. **Replayed-feedback check** (row 23), then **alpha-theta** (row 22). (Research A)
6. **Dream catcher** (row 20), then the nap preset. (Research C: a rule plus a timer is the proven design)
7. **State and trends page** (row 10): a sleep-pressure curve from the sleep log (not from EEG yet), "your usual"
   and "same as yesterday" next to every number; caffeine, alcohol and sleepiness taps in the morning check-in.
   Forecasts stay hidden until 60 days of ratings exist and they beat "same as yesterday" by 5 %. (Research B, C)
8. **Data safety**: a checksum file per night, a catalog, an encrypted restic backup to the `архив` drive and a
   monthly restore test (does not change DECISIONS 37). (Research D)

## Next tests that need the owner

- **Phone test** (about 1.5 h plus one night on battery): the steps in `app/README.md` on the app branch (install,
  phone settings, 1 hour screen off, the drop test, export). The assistant adds a few checks over USB while the
  phone is plugged in (forced deep sleep before the drop test, phone model, a 3-minute Bluetooth log).
- **Sound feedback bench tests** (6 x about 5 min, `sound.html`): a normal run with the headband on; 20 minutes
  reclined (does it catch dozing?); a few jaw clenches; a forced-roughness check; wired vs Bluetooth headphones;
  20 blinks on cue.
- **Extended setup test** (2 min, `morning.html`): blinks, left-right glances, clenches; it confirms the 55-120 Hz jaw band
  on real clenches, gives µV per degree for glances on T3-T4, and settles the blink sign on 20 cued blinks.
- **First real morning check-in** (`morning.html`).

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
