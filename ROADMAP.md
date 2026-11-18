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
11. **Mission**: affordable EEG for everyone: build-at-home guides for the helmet plus this open app, with contributors.

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
| 5 | Android recorder app (one tap, screen off all night) | code + tests done; APK not built yet; phone test pending | branch `feat/android-recorder` |
| 6 | Morning check-in (eyes closed / open, ratings) | in progress | branch `feat/morning-check` |
| 7 | Brain-reactive sound (alpha → calmer sound, jaw blocks) | in progress (browser prototype first, then the app) | branch `feat/brain-sound` |
| 8 | Break hints stage 0 (ActivityWatch) | in progress | branch `feat/break-hints` |
| 9 | Night extras: jaw clench count, movement, signal quality per hour | next | - |
| 10 | State and trends page (numbers + arrows vs your usual, 14-day lines; laptop first, then phone) | after 6 and 3 | - |
| 11 | utof_tracker importer for `eeg_*` events | waits for the owner's OK | - |
| 12 | Calibration for any electrode positions (helmet) | after the helmet exists | DECISIONS row 4 |
| 13 | DIY board driver (E9 frames) in the app | after the helmet exists | DECISIONS row 5 |
| 14 | Statistics engine + random self-experiments | after a month of data | DECISIONS row 12 |
| 15 | Build guides for the helmet | in `eeg_ads1299_lab` | other repo |
| 16 | Eyes open/closed test (high beep open, low beep closed) | working | `scripts/web/eyes.html` |
| 17 | Sound for states: binaural, isochronic, pulsed noise; presets per state; markers for checking | first page being built | `scripts/web/beats.html` |
| 18 | Sound for states: measure "did I get there", stop when asleep, learn what works for you | after research + 6 | - |
| 19 | Research: sound for states; states and their markers; more features | in progress | `_local/research/` |

## Next tests that need the owner (each about 5 minutes)

- Eyes closed 2 min, eyes open 2 min, with the headband on (is alpha there?).
- 20 cued blinks, 10 left-right glances, 5 jaw clenches (what the electrodes can see).
- Install the phone app and run the 1-hour screen-off test (`app/README.md` on the app branch).

## Ideas for later (after the wishes above are built)

Anyone, including the assistant, adds ideas here. When one is started, move it into the Status table.

| Idea | What it is | Notes |
|---|---|---|
| Smart alarm | wakes you within a chosen window at a moment of light sleep, not deep sleep | needs live sleep staging on the phone |
| Nap coach | a nap that ends before deep sleep starts (so no groggy wake-up) | same live staging |
| Dream catcher | as you drift off, the app notices the half-dream stage (back-of-head alpha fading), quietly asks "what are you thinking about?", records your spoken answer, lets you drift again; 3-4 rounds. For creative ideas | MIT's Dormio; a 2021 study found 15 s in that stage tripled insight on a puzzle; needs only O1/O2 |
| Lucid dream cues | soft sound cues during dream sleep (REM) to become aware you are dreaming | evidence weak; fun |
| Hands-free controls | a double jaw clench or a look left-right as a switch: pause sound, mark a moment | jaw and eye movements are what these electrodes see best |
| Meditation sessions | guided sessions with feedback on how settled you were | alpha and movement |
| Reaction-time check | a 1-minute daily tap test next to the EEG, an objective alertness number | |
| Self-experiments | the app picks random days (e.g. no coffee after 14:00) for a few weeks and reports the effect with a range | the only route to "this causes that" |
| Helmet-only | frontal brain asymmetry, a brain-typing speller (P300), flicker games (SSVEP) | need electrodes the headband lacks |
