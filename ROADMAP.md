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
| 5 | Android recorder app (one tap, screen off all night) | code + tests done; APK not built yet; phone test pending | branch `feat/android-recorder` |
| 6 | Morning check-in (eyes closed / open, ratings) + setup test | page, analysis, export and tests done on the fake headband; first real morning pending | `scripts/web/morning.html`, `scripts/morning_check.py` |
| 7 | Brain-reactive sound (alpha → calmer sound, jaw blocks) | feedback core v1 done (research A pass 2, item 1): live stream input, alpha in ~0.15 s around your own alpha peak, a target line held for 3-min blocks, at most 6 bells a minute, muscle / blink / drifting-to-sleep gates (shared `sleep-guard.js`), training and relax modes, a session log that replays exactly; tested on the demo and the fake headband. Real-head bench tests pending. The page is a stopgap: the pure modules port to the phone app | `scripts/web/sound.html`, [docs/brain-sound.md](docs/brain-sound.md) |
| 8 | Break hints stage 0 (ActivityWatch) | code + tests done; not yet run on the owner's laptop | `scripts/break_hints.py`, docs/break-hints.md |
| 9 | Night extras: jaw clench count, movement, signal quality per hour | next | - |
| 10 | State and trends page (numbers + arrows vs your usual, 14-day lines; laptop first, then phone) | after 6 and 3 | - |
| 11 | utof_tracker importer for `eeg_*` events | waits for the owner's OK | - |
| 12 | Calibration for any electrode positions (helmet) | after the helmet exists | DECISIONS row 4 |
| 13 | DIY board driver (E9 frames) in the app | after the helmet exists | DECISIONS row 5 |
| 14 | Statistics engine + random self-experiments | after a month of data | DECISIONS row 12 |
| 15 | Build guides for the helmet | in `eeg_ads1299_lab` | other repo |
| 16 | Eyes open/closed test (high beep open, low beep closed) | working | `scripts/web/eyes.html` |
| 17 | Sound for states: binaural, isochronic, pulsed noise; presets per state; markers for checking | first page working (review fixes in); next: calm beds as the default, beats as optional extras | `scripts/web/beats.html` |
| 18 | Sound for states: measure "did I get there", stop when asleep, learn what works for you | after research + 6 | - |
| 24 | Research round 2 (18 lanes: neurofeedback and sound feedback; more from four electrodes; EEG machine learning 2025-26; app tech and data) | in progress | `_local/research/2026-11-18-07-*` |
| 19 | Research: sound for states; states and their markers; more features | done 2026-11-18 | `_local/research/2026-11-18-06-brain-states-sound-and-features.md` |
| 21 | Meditation feedback: live (sound + settled / restless / drowsy) and a report after each session, progress across sessions | **high priority (owner)**, next after the 3 running lanes | builds on `feat/brain-sound` (live sound) and the morning check-in's alpha measures |
| 22 | Alpha-theta training (eyes closed, back of the head; 10 sessions, the first 3 only 15 min, then decide; side-effect checklist every session; alertness check before driving; stop button; "practice, not treatment"; a note that strong memories can come up) | planned, after meditation feedback and the replay check | uses the meditation feedback engine; plan changed by research A pass 2 (`_local/research/2026-11-18-07-neurofeedback-and-sound-feedback-pass2.md`): alpha-theta is the protocol with the most reported side effects |
| 23 | Replayed-feedback check: some sessions secretly replay an earlier session's feedback; after enough sessions, live vs replayed is compared (feeling, the trained signal, ratings) | planned with 21/22 | toggle, off by default; reminder text before each meditation while it is on |
| 20 | Dream catcher (owner: "definitely build"): at sleep onset, ask what you're thinking, record the answer, let you drift again, 3-4 rounds | planned, right after the current features | see Ideas |

## What comes next, in order (2026-11-18)

1. Merge the three running lanes (sound reacting to alpha, morning check-in, break hints) after testing them with you.
2. Meditation feedback, live and after the session (row 21; owner: high priority).
3. One shared detector for drifting off to sleep (feeds the dream catcher, nap coach, sleep-sound auto-stop, drowsiness tile).
4. Dream catcher (row 20), then the nap preset.
5. State and trends page (row 10).
6. Phone app: build, install, 1-hour screen-off test, then port the pages.

## Next tests that need the owner (each about 5 minutes)

- Eyes closed 2 min, eyes open 2 min, with the headband on (is alpha there?): `morning.html` on the live page's port.
- 20 cued blinks, 10 left-right glances, 5 jaw clenches (what the electrodes can see): the setup test on the same page.
- Brain sound bench tests (`http://localhost:8765/sound.html` while recording, training mode): calibrate and sit 5 min eyes closed (does the rain soften, how often do bells come?); 20 min reclined (does the drifting-off gate catch dozing, and stay quiet while awake?); light and strong jaw clenches (gated? any leak into O1/O2?); jaw relaxed while the sound is roughened (does the roughness itself raise the jaw measure?); wired against Bluetooth headphones (how late does it feel?); 20 cued blinks (blink gate).
- Install the phone app and run the 1-hour screen-off test (`app/README.md` on the app branch).

## Ideas for later (after the wishes above are built)

Anyone, including the assistant, adds ideas here. When one is started, move it into the Status table.

| Idea | What it is | Notes |
|---|---|---|
| Smart alarm | wakes you within a chosen window at a moment of light sleep, not deep sleep | needs live sleep staging on the phone |
| Nap coach | a nap that ends before deep sleep starts (so no groggy wake-up) | same live staging |
| Dream catcher (now row 20 above) | as you drift off, the app notices the half-dream stage (back-of-head alpha fading), quietly asks "what are you thinking about?", records your spoken answer, lets you drift again; 3-4 rounds. For creative ideas | MIT's Dormio; a 2021 study found 15 s in that stage tripled insight on a puzzle; needs only O1/O2 |
| Lucid dream cues | soft sound cues during dream sleep (REM) to become aware you are dreaming | evidence weak; fun |
| Hands-free controls | a double jaw clench or a look left-right as a switch: pause sound, mark a moment | jaw and eye movements are what these electrodes see best |
| Reaction-time check | a 1-minute daily tap test next to the EEG, an objective alertness number | |
| Self-experiments | the app picks random days (e.g. no coffee after 14:00) for a few weeks and reports the effect with a range | the only route to "this causes that" |
| Helmet-only | frontal brain asymmetry, a brain-typing speller (P300), flicker games (SSVEP) | need electrodes the headband lacks |

## Research for later (proposed, not run yet)

| Lane | What it would answer |
|---|---|
| Rules for a public release | when an app counts as a medical device (EU MDR, US FDA "general wellness"), which claims are allowed, privacy law (GDPR) for brain data |
