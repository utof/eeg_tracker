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
| Fatigue | morning check-in: eyes-closed alpha strength, alpha peak speed, eyes-closed rise; drowsiness trend during work after calibration (in the phone app's Trends from the work sessions, row 35: seen together, not tested) | reliable (alpha); usable (drowsiness) |
| Stress / tension | "tension" from jaw clench and muscle at T3/T4, plus your own 1-tap ratings beside the data | jaw: reliable; a "stress score": not honest at these sites |
| Anxiety, focus | your own ratings, kept next to EEG trends; "engaged vs drifting" only as a personal pattern | not measurable directly here |
| Breaks | stage 0 from ActivityWatch (no headband); in the phone app a work session with the headband (row 35): drowsiness from eyes-open alpha and still eyes, hints on the same rules, 1-5 taps beside it | no validated EEG break detector exists; drowsiness usable, mental fatigue not measured |
| Music | procedural ambient sound that calms as eyes-closed alpha rises; jaw clench blocks rewards | measurement fine; benefit evidence weak (say so) |
| Sound for states | binaural / isochronic / pulsed / nature sound per state; checks if you got there (sleep onset: alpha fades, slow eye rolls; relax: alpha up; break: drowsiness falls; focus: weak, rating + drowsiness); stops by itself once you are asleep | the brain's hearing area follows pulses reliably; whether that moves the whole state is less proven, which is why we measure it on you |
| Meditation feedback | live: sound and a simple display of settled / restless / drifting toward sleep; after: a timeline of the session, share of settled time, longest settled stretch, movement and jaw events, your own rating, and the trend across sessions | stillness, eyes-closed alpha and drowsiness are measurable; there is no reliable "meditation depth" signal, and a 2025 review found Muse-style feedback mainly helps through the practice itself, so it shows what is measurable and tracks your own progress |
| State and trends page | big numbers with arrows against your own usual and a "how sure" dot: sleep, morning alertness, drowsiness now, tension | as sure as each number's row above |
| Statistics | per-day export to utof_tracker's careful nightly analysis first; later "seen together" vs "tested" (random self-experiments) | needs about a month of days |
| Other apps' features | contact display per electrode, live artefact flags, meditation/alpha sessions, night jaw-clench count, open export, no account | standard |

## Status

Branches named `feat/app-...` in the rows below are all combined on `feat/app-line` now.

| # | Feature | Status | Where |
|---|---|---|---|
| 1 | Laptop recorder + live check page | working; survives Bluetooth drops (restarts itself) | `scripts/record_night.sh` |
| 2 | Night → one BDF+ file | working | `scripts/to_bdf.py` |
| 3 | Sleep scoring + hypnogram chart | working on test data; first real night 2026-11-18; **on the phone too** (2026-11-18, branch `feat/app-sleep-report`): AnySleep as ONNX scores each night after Stop, a sleep report screen with the chart, periods and past nights; since 2026-11-19 (branch `feat/app-two-pass-scorer`) it scores in two passes and gives the laptop's stage on every 30-s epoch of the three recorded nights (was 96.6-97.7 %); phone speed not yet measured | `scripts/score_sleep.py`; app: `lib/sleep/`, `analysis/two_pass.py`, DECISIONS 95-99, 260-264 |
| 4 | Export to utof_tracker's event format | working; utof_tracker does not read it yet (needs the owner's OK to change it) | `scripts/export_events.py` |
| 5 | Android recorder app (one tap, screen off all night) | code + tests done; first release APK built 2026-11-18 (30 MB, sent to the owner); the combined app on `feat/app-line` is about 52 MB (arm64); most phone tries are still pending (`app/README.md`, Try these) | branch `feat/android-recorder` (now inside `feat/app-line`) |
| 6 | Morning check-in (eyes closed / open, ratings) + setup test | page, analysis, export and tests done; first real morning 2026-11-18; **in the phone app** (2026-11-18, branch `feat/app-morning-trends`): the same routine and the same numbers (exact on the recorded check-in), plus caffeine, alcohol and an optional reaction test; not yet run on the phone | `scripts/web/morning.html`, `scripts/morning_check.py`; app: `lib/morning/`, DECISIONS 120-129 |
| 7 | Brain-reactive sound (alpha → calmer sound, jaw blocks) | feedback core v1 done (research A pass 2, item 1): live stream input, alpha in ~0.15 s around your own alpha peak, a target line held for 3-min blocks, at most 6 bells a minute, muscle / blink / drifting-to-sleep gates (shared `sleep-guard.js`), training and relax modes, a session log that replays exactly; tested on the demo and the fake headband. Real-head bench tests pending. The page is a stopgap: the pure modules port to the phone app | `scripts/web/sound.html`, [docs/brain-sound.md](docs/brain-sound.md) |
| 8 | Break hints stage 0 (ActivityWatch) | code + tests done; not yet run on the owner's laptop | `scripts/break_hints.py`, docs/break-hints.md |
| 9 | Night extras: jaw clench count, movement, signal quality per hour | **in the sleep report** (2026-11-18, branch `feat/app-night-extras`; not yet run on a phone): the phone runs the detectors beside the sleep model and the report shows how much of the sleep was read through noise, a Signal lane under the chart, jaw-muscle bursts and movements per hour asleep with earlier nights' jaw numbers, and the night hour by hour; the laptop report has the same `extras`. Phone code = Python reference on the owner's night (924 bursts, 508 movements, every epoch's quality); asleep: 22.8 jaw bursts and 18.9 movements an hour, 13 % read through noise. Next: the owner's setup test (clench limits) and a few nights to see the trend | `app/lib/sleep/extras.dart`, `analysis/night_extras.py`, [docs/detectors.md](docs/detectors.md), DECISIONS 140-146 |
| 10 | State and trends page (numbers + arrows vs your usual, 14-day lines; laptop first, then phone) | **built in the phone app** (2026-11-18, branch `feat/app-morning-trends`; phone first, no laptop page): today's numbers with yesterday's and your usual (from 7 days), worded arrows beyond the normal spread (from 14 days), 14-day lines, sleep pressure from the sleep log, the forecast hidden behind its gate; the night's jaw muscle bursts an hour asleep added 2026-11-18 (`feat/app-export-all`, DECISIONS 155); tested on made-up days, not yet on the phone | app: `lib/trends/`, `lib/ui/trends_*.dart`, DECISIONS 120-129 |
| 11 | utof_tracker importer for `eeg_*` events | waits for the owner's OK | - |
| 12 | Calibration for any electrode positions (helmet) | after the helmet exists | DECISIONS row 4 |
| 13 | DIY board driver (E9 frames) in the app | **laptop host and phone app built** (2026-11-19; tested on a fake board and on frames from the firmware's own code, not yet on the board, which is not assembled). Laptop (branch `feat/diy-board-host`): `DRIVER=diy scripts/record_night.sh` records it over USB serial or Wi-Fi into the same files, live pages and LSL bridge as the BrainBit. Phone (branch `feat/app-diy-board`): Headband connection, **DIY board (test)**, off by default; nights over Wi-Fi (UDP 9000) into `files/recordings-diy/`, the decoder pinned to the Python one by shared vectors; USB OTG and the 8-channel chip not on the phone. Both keep the board's nights apart (the sleep and morning tools and the detectors still read O1 O2 T3 T4 only, row 12) and never write to the board | `scripts/diy_board.py`, `scripts/record_diy.py`, `app/lib/headband/diy/`, [docs/diy-board.md](docs/diy-board.md), DECISIONS rows 5, 350-369 |
| 14 | Statistics engine + random self-experiments | **self-experiments built in the phone app** (2026-11-19, branch `feat/app-self-experiments`; not yet run on a phone): a question, one number, 4-8 weeks of random days in blocks with every weekday mixed, the plan and the order's fingerprint frozen before day 1, today's task each day, "did you keep to it?", the answer sealed until the planned end, then one sentence with a range from a randomisation test, labelled "tested" apart from "seen together". The laptop statistics engine (observational screens, Bayesian models) still waits for a month of data | DECISIONS rows 12, 200-209; app/README.md "Self-experiments"; `docs/evidence/self-experiments.md` |
| 15 | Build guides for the helmet | in `eeg_ads1299_lab` | other repo |
| 16 | Eyes open/closed test (high beep open, low beep closed) | working | `scripts/web/eyes.html` |
| 17 | Sound for states: binaural, isochronic, pulsed noise; presets per state; markers for checking | in the phone app (2026-11-18, branch `feat/app-sound-states`; not yet heard on the phone): calm beds as the default (rain, pink, brown, ocean), beats as optional extras, "no beat" at the same loudness, one -23 LUFS level, safe tone pitches, Listen to set the volume, works with or without the headband; each session saved with its sound and your 1-5 answer. The laptop page stays as a bench | `app/lib/states/`, `app/lib/sound/state_synth.dart`, `scripts/web/beats.html` |
| 18 | Sound for states: measure "did I get there", stop when asleep, learn what works for you | in the phone app: a quiet minute, then alpha and slow waves against it with the beat's echo left out (and named as an echo); fall asleep fades out 2.5 min after "probably asleep" and is silent 45 min after lights off, its EEG kept with the night, the night recording started afterwards if you like; without the headband, the timer. Over weeks (2026-11-19, branch `feat/app-states-weeks`; not yet run on the phone): per state the sounds you used side by side (minutes to fall asleep by the detector or that night's report, alpha for relax, slow waves for a break, your answer for focus and wake up, marked weak), each with its median and middle half from 14 sessions with a number, "seen together, not tested"; and an optional fair test of two sounds for one state: the app draws each day's sound in blocks of 4 for 4-8 weeks, freezes the plan, and answers with the self-experiments' randomisation test, labelled "tested". Next: the owner's first 4-week test at bedtime | `app/lib/states/`, `app/lib/detectors/drift_off.dart` |
| 24 | Research round 2 (18 lanes: neurofeedback and sound feedback; more from four electrodes; EEG machine learning 2025-26; app tech and data) + parts | done 2026-11-18 (second pass via API, $119.79); all findings on one page | `_local/research/2026-11-18-findings.html` |
| 19 | Research: sound for states; states and their markers; more features | done 2026-11-18 | `_local/research/2026-11-18-06-brain-states-sound-and-features.md` |
| 21 | Meditation feedback: live (sound + settled / restless / drowsy) and a report after each session, progress across sessions | **v1 in the phone app** (2026-11-18): the feedback core ported to Dart (agrees with the JS core on a JS-made session), sound with `flutter_soloud`, a meditation screen (5 / 10 / 20 min, silent calibration, state chip, report with a calm line, comparison with earlier sessions, the "i" note); tested with a fake headband; not yet heard or run on the phone. "Drifting" also comes from the shared drift-off detector since 2026-11-18 (row 25). **Built 2026-11-19** (branch `feat/app-meditation-learning`; tested with a fake headband and a mocked phone, not yet run on the phone): 2 silent minutes after the sound (the research's no-feedback block: alpha against the silent minute before, with muscle and drowsy shares), the learning verdict from 8 sessions, checked again at 12 (Theil-Sen trend with its 90 % range, equal to SciPy's; "seen together, not tested"; the replay check's new plans test the silent minutes too), and where the sound goes (Bluetooth: an amber note before and during the session, kept in the session file). Next: the owner's session and 8 meditations (`app/README.md`, "Meditate") | branches `feat/app-meditation` (from `feat/android-recorder`), `feat/app-meditation-learning`; `app/lib/feedback`, `app/lib/meditation`, `app/lib/sound/audio_route.dart`, DECISIONS 72-77, 420-425 |
| 25 | Shared detectors ("what the electrodes see") and the drift-off detector | **built 2026-11-18**: Python reference checked on the night, the morning sleep and the check-in; Dart port in the app (same events on recorded excerpts), wired into meditation's "drifting". Sleep onset within 0.5 min of AnySleep on both recorded onsets (2 of the 5 nights it needs); blinks 3.1 a minute eyes open vs 0.5 closed; 86 % of loud muscle seconds flagged. Lights off on the night screen and the live detector in the night recorder built 2026-11-19 (`feat/app-night-lightsoff`, DECISIONS 180-186): the morning report says how many minutes after lights off the detector and the sleep model each saw you fall asleep and counts the nights toward 4 of 5. Waits for the setup test (blink depth, glances, clenches) and the owner's Lights off nights | branch `feat/app-detectors`, [docs/detectors.md](docs/detectors.md), DECISIONS 85-89 |
| 22 | Alpha-theta training (eyes closed, back of the head; 10 sessions, the first 3 only 15 min, then decide; side-effect checklist every session; alertness check before driving; stop button; "practice, not treatment"; a note that strong memories can come up) | **built in the phone app** (2026-11-18; not yet heard or run on the phone): screening, consent and stop plan, check-in and after-session checklist with pause rules, the length rule and the decision after 10, stream-to-ocean sound with chime and gong, the drift-off detector as sleep guard (fade, rising wake tone), grounding, a 1-minute reaction test before you leave; tested with a fake headband | branch `feat/app-replay-alphatheta`, `app/lib/alphatheta`, DECISIONS 104-107 |
| 23 | Replayed-feedback check: some sessions secretly replay an earlier session's feedback; after enough sessions, live vs replayed is compared (feeling, the trained signal, ratings) | **built in the phone app** (2026-11-18; not yet run on the phone): toggle off by default with the reminder before every session, 4 live donor sessions per kind, then shuffled blocks of 4 drawn from a phone-made secret with the plan and the order's SHA-256 frozen first, own-replay of the sound with live gates, no live bell count, guess / control / randomness after each session, results per 12 with a permutation test; tested end to end with a fake headband | branch `feat/app-replay-alphatheta`, `app/lib/training`, DECISIONS 100-103 |
| 20 | Dream catcher (owner: "definitely build"): at sleep onset, ask what you're thinking, record the answer, let you drift again, 3-4 rounds | **built in the phone app** (2026-11-18; not yet run on a phone or a head): your own recorded theme and question (tones if none), Lights off with the 60 s baseline, round 1 at the detector's "drowsy" or a random moment in the usual time to fall asleep, later rounds when alpha came back and faded again (2 min apart at least, 4-7 min at most), answers recorded until 3 s of quiet, a two-halves "were you drifting?" tap, 3 or 4 rounds, 45 min cap, wake tone or the night starts by itself; its EEG is part of that night with markers; answers list with playback and notes; tested with a fake headband and microphone. **Answers as text** (2026-11-19, `feat/app-dream-text`): after the session the phone writes each answer out (sherpa-onnx + Parakeet v3, Russian and English, a 671 MB download; your edits kept apart), checked on TTS clips on the laptop and in the app on the emulator. Next: the owner's first nap (`app/README.md`, "Dream catcher"), then the model download and a few spoken answers | branches `feat/app-dream-catcher`, `feat/app-dream-text`; `app/lib/dream`, DECISIONS 110-116, 250-256 |
| 26 | Nap coach (Ideas, 2026-11-18): a nap that ends before deep sleep starts, or at a chosen length, whichever comes first; live sleep stages on the phone | **built in the phone app** (2026-11-19, branch `feat/app-nap-coach`; not yet run on a phone or a head): AnySleep scored live every 30 s on the last 60 minutes, read 2 min behind (Dart = the Python reference to 2e-6 on the recorded night; on the owner's recorded night the same stage as the full-night scoring on 88.9 % of epochs, kappa 0.84, deep sleep known 2-3 min after it started), Lights off with the drift-off detector for "fell asleep", 20 / 30 / 45 / 90 min, woken when 2 epochs in a row read deep sleep or at the length, a soft rising wake sound until "I'm awake", a report (fell asleep, stages, why it woke you, the model's time per check); the timer alone when the model is too slow, fails or the signal is lost, and the screen says so. Next: the owner's first nap (`app/README.md`, "Nap coach"): the phone's speed and the wake sound's volume | `app/lib/sleep/live_*.dart`, `app/lib/nap`, `analysis/live_stager.py`, DECISIONS 170-179 |
| 27 | Smart alarm (Ideas, 2026-11-18): wakes you within a chosen window at a moment of light sleep, never in deep sleep, always by the window's end | **built in the phone app** (2026-11-19, branch `feat/app-smart-alarm`; checked on the emulator, not yet on a phone or a head): set before Start (wake-by time and 15 / 20 / 30 / 45 min, off by default); a real phone alarm (AlarmManager) at the window's end set at Start, which rings even when the app is killed (emulator); the nap coach's live model inside the night recorder's service from an hour before the window only, guarded (an error, 2 % of the recorder's time or 700 MB more memory switch it off; the recording and the phone's alarm never depend on it); the first light, dream or awake epoch (2 min behind) inside the window and not within 10 min after deep sleep brings the alarm forward; rising notes, then the phone's alarm sound after 3 min; I'm awake over the lock screen; Waking up in the sleep report. Replayed on the owner's recorded night (DECISIONS 232). Next: the owner's first morning (`app/README.md`, "Smart alarm") | `app/lib/alarm`, `app/lib/ui/alarm_view.dart`, `app/android/.../WakeAlarm.kt`, `analysis/smart_alarm.py`, DECISIONS 230-239 |
| 28 | Hands-free controls (Ideas, 2026-11-18): a double jaw clench or a look left, then right as a switch during sessions | **built in the phone app** (2026-11-19, branch `feat/app-hands-free`; not yet run on a phone or with a real gesture): off by default, one switch in Settings (a gear on the main screen); a 90-second calibration sets the clench line, the look size and which way is left, showing your jaw and eyes live; a double clench pauses and resumes the sound in Sound and Meditation, answers Drifting in the dream catcher and marks a moment elsewhere and in the night recording; a look marks a moment and answers Awake; a soft tone confirms; off while asleep, never in the morning check-in. Python reference + line-by-line Dart port checked against each other; false triggers on the recorded night: double clench 0 an hour awake, 0.6 asleep; look 1.9 an hour awake (about 1 with left known), 0.6 asleep | `analysis/hands_free.py`, `app/lib/detectors/gestures.dart`, `app/lib/handsfree/`, docs/detectors.md, DECISIONS 240-249 |
| 29 | Share on Wi-Fi: the phone's recording live on the laptop, and its files mirrored during the night | **built in the phone app** (2026-11-19, branch `feat/app-share-wifi`; checked on the emulator, not yet on the phone): the laptop recorder's routes and the files with a code, local network only, off by default; the server in its own isolate, so it cannot hurt the recording; `pull_phone.py` mirrors new and growing files every 2 minutes; the phone test (screen off all night, battery) is the owner step in app/README.md | `app/lib/share/`, `scripts/pull_phone.py`, `scripts/page_server.py --token`, DECISIONS rows 220-229 |
| 30 | "Unusual for you" card (research round 2 proposal): NightSignal-style cards on sleep and ratings, the headband's numbers tested both ways, silent back-test first, on after 28 days | **the assistant's proposal, built; the owner can switch it off** (2026-11-19, branch `feat/app-unusual-card`; not yet run on a phone, never seen the owner's numbers): one number outside your usual (the 28 days ending a week back) on 2 days in a row makes one plain sentence on Trends and one line on the main screen; silent and only logging for the first 28 days; "What might explain it?" chips, "feeling ill" pauses 2 weeks; no notifications. Python reference = Dart port on 530 made-up days; back-test on 200 made-up people: 0.7 false cards a month, 69 % of cold-like weeks found; the headband's numbers would nearly triple false cards, so they are only logged. Steps are not recorded by the app, so not in it | `analysis/unusual.py`, `analysis/validate_unusual.py`, `app/lib/unusual/`, `docs/evidence/unusual-for-you.md`, DECISIONS 290-299 |
| 31 | Sharp-hours log (research round 2 proposal; **the assistant's proposal, built; the owner can switch it off**): when in the day you are sharpest | **built in the phone app** (2026-11-19, branch `feat/app-sharp-hours`; not yet run on a phone): off until switched on (Trends, Sharp hours); 4 one-tap "how sharp do you feel?" questions a day (3 or 6) at stratified random waking moments, never in the quiet hours (suggested from your recorded nights), during a night recording or a session; 2 a day suggest the 1-minute reaction test; inexact alarms with a delivery check for HyperOS; no pattern for 3 weeks and about 60 answers ("Collecting: N of about 60 ratings"), then 2-hour blocks by clock time, hours since waking and sleep pressure with 80 % ranges from resampled days and a best time only when it clearly stands out, "seen together, not tested"; day numbers in Trends and as self-experiment outcomes; switch off or delete on the page. ActivityWatch focus sessions: **laptop importer built** (2026-11-19, branch `feat/laptop-aw-focus`, `scripts/aw_focus.py`: counts of 35+ min related-work sessions per day and 2-hour block into `_local/phone/sharp-hours/focus-YYYY-MM.jsonl`, `--show` puts them beside the ratings; DECISIONS 510-514) | `app/lib/sharp/`, `lib/ui/sharp_*.dart`, `SharpPrompts.kt`, DECISIONS 280-289, app/README.md "Sharp hours", `docs/evidence/sharp-hours.md` |
| 32 | Lucid dream cues (Ideas, 2026-11-18): soft sound cues during dream sleep (REM) to become aware you are dreaming | **built; evidence weak** (2026-11-19, branch `feat/app-lucid-cues`; not yet run on a phone or a head): off by default; an evening practice (the cue, three soft rising tones, paired with "am I dreaming?"; the loudness set by tapping when you just hear it); in the night's second half the night recorder runs the live sleep model and plays the cue when two live epochs read dream sleep (at 0.6), the eyes move with the back of the head quiet, you lie still and the drift-off detector does not say awake; never within 10 min of deep sleep; 30 s apart, 10 a dream, 30 a night, +1 dB a cue up to +6 dB, a stir makes it 3 dB quieter and pauses 5 min, 3 stirs end the night; inside a guard (exception, 2 % of time, 700 MB: off with one log line, the recording goes on); on `feat/app-line` one live sleep model and one guard shared with the smart alarm, never two copies (DECISIONS 330); cue moments as markers; morning: three questions and a search of the night for left-right-left-right (and double clenches with the hands-free calibration); an honest test: in each block of 4 nights 2 are silent and the owner is not told which, results after 12 nights, "tested" apart from "seen together". Replayed on the owner's night of 2026-11-17: 30 cue moments, 28 in dream sleep by the full-night scoring, 2 in light sleep, none in deep sleep or awake; 0 false eye signals in 6.5 h asleep. Next: the owner's first week (`app/README.md`, "Lucid dream cues"): the loudness, the stirs, the model's cost over half a night, a real eye signal | `analysis/lucid_cues.py`, `analysis/lucid_signals.py`, `app/lib/lucid/`, `app/lib/sleep/night_scorer.dart`, DECISIONS 300-309, 330 |
| 33 | "Was this you?" (research round 2 proposal): a soft question when someone else seems to have worn the headband, so a borrowed headband does not pollute the trends and experiments | **the assistant's proposal, built; the owner can switch it off** (2026-11-19, branch `feat/app-was-this-you`; not yet run on a phone, never seen enough of the owner's recordings): alpha speed, alpha strength and the 1/f slope at O1/O2 from a check-in's eyes-closed 2 minutes or a night's awake minutes after Lights off; silent until 10 of a kind on 5 days; then over 2.5 (root mean square of z-scores against the newest 20) it asks "Was it you?" on the sleep report or the check-in's result; "Someone else" (also offered by hand on every recording) keeps it out of trends, the unusual card and experiments, tagged in the file, never deleted. Python reference = Dart port on a Python-made fixture; no other people's EEG on the laptop, so tested on made-up people: 0.10-0.21 false questions a month, 19-35 % of other wearers caught (the research's ~6 % error needs a network trained on many people; this simple owner-only check is much weaker; evidence weak) | `analysis/wearer_check.py`, `analysis/validate_wearer.py`, `app/lib/wearer/`, `app/lib/ui/wearer_view.dart`, `docs/evidence/was-this-you.md`, DECISIONS 370-379 |
| 34 | Evening study, morning review (research round 2 proposal; **the assistant's proposal, built; off by default**): a plain reminder to study in the evening and review in the morning | **built in the phone app** (2026-11-19, branch `feat/app-study-review`; not yet run on a phone): off until switched on (Settings, Study reminders); an evening reminder 90 minutes before your usual bedtime ("Good time to learn something you want to keep") and a morning one 45 minutes after your usual wake-up ("Try to recall what you studied last night, before looking"), times from your recorded sleep (from 3 nights, else 21:00 and 08:30) and editable, kept inside your waking hours; never during a night recording or a session; "No" to "studied tonight?" skips the next morning's reminder; one tap each way ("studied tonight: yes / no", "recalled: well / some / a little") kept app-private and in Export data; Trends shows the day's recall and a ready-made self-experiment "study in the evening or in the morning" uses it (the two arms also differ in the delay, said on the page); rides the Sharp hours alarms (one list, one chain, DECISIONS 401). Evidence: one small study of evening learning and morning relearning, grade some | `app/lib/study/`, `lib/ui/study_*.dart`, `SharpPrompts.kt`, DECISIONS 400-401, app/README.md "Study reminders", `docs/evidence/study-timing.md` |
| 35 | Work session (owner, 2026-11-19: "I wanna wear it right now so it tells me when to take a break"): the headband on while working, drowsiness live, break hints | **built in the phone app** (2026-11-19, branch `feat/app-work-session`; checked on the emulator: the page and its "i" open, without a headband it says "Headband not found", Stop while connecting goes back; not yet run on a phone or at a desk): 4 minutes of your usual work as the baseline (optional eyes-closed minute first), then alert / getting drowsy / drowsy every 30 s from the median of the last 5 minutes: eyes-open alpha at O1/O2 and still eyes (fewer blinks and glances) against the baseline, muscle, movement and noisy seconds left out, closed eyes shown apart; break hints on the laptop's rules (60 min worn then backing off, 4 a day, 45 min apart, Snooze 20, quiet 23:00-08:00) plus one when drowsiness stays up 6 minutes; a soft chime and the lock-screen card; On a break / Back or the headband off 5 min; after a break whether drowsiness went down; an optional 1-5 "how sharp" tap; a file per session; **day numbers on Trends and as self-experiment outcomes** (2026-11-19, branch `feat/app-work-trends`): per day (04:00 to 04:00, from 30 minutes of readable work time, noisy and closed-eyes time and breaks left out, sessions marked "someone else" excluded) the time worked, the share of it at getting drowsy or drowsy, the worked minutes until the first drowsy stretch, hints shown and followed by a break, breaks, and the mean "how sharp" tap, each beside yesterday and your usual, arrows from 14 days, "Seen together, not tested"; the drowsy share and the tap mean offered to the self-experiments. On the owner's recorded morning of 2026-11-18 (an hour with eyes open, then asleep at 09:15) it read alert until 08:42, getting drowsy from 08:43 and drowsy from 08:48, 8 min before the sleep model's first N1, and the drowsy hint would have come at 08:47; 2 h 10 min awake in bed earlier gave no drowsy reading and only the hourly hints; theta and slow eye power fell instead of rising, so they are logged only. Evidence: some (drowsiness); mental fatigue: weak. Next: the owner's first working day (`app/README.md`, "Work session") | `app/lib/work/` (`days.dart`: the day numbers), `app/lib/ui/work_*.dart`, `app/tool/work_check.dart`, DECISIONS 440-449 and 480-489, `docs/evidence/work-session.md` |
| 38 | Signal tab and the bottom bar (owner, 2026-11-20: "a 3D rotatable model of the head ... live graph readings per electrode ... µV, Ω ... buttons/tabs like modern apps ... the raw data of all electrodes") | **built in the phone app** (2026-11-20, branch `feat/app-signal-tab`; checked on the emulator, not yet with a headband or on a phone): five tabs at the bottom (Night, Sessions, Signal, Trends, More; the app opens on Night with Start night pinned); Signal shows a 3D head you turn, pinch and double-tap, each electrode's contact and ohms, a live trace per electrode (raw, 1-40 Hz, 50 Hz notch) with RMS, mains, flat/railed and the band shares, and the raw data of all electrodes (pause, 5 minutes back, counters, latest values); during a night or a session it reads the same stream and shows the last contact reading. Any number of electrodes and custom positions; the transport is still 4 channels (DECISIONS 590-599) | `app/lib/signal/`, `app/lib/ui/signal_*.dart`, `head_view.dart`, `home_tabs.dart`; owner step in `app/README.md` (Signal) |

## What comes next, in order (rewritten 2026-11-19)

**Where the code is.** Rows whose text says "branch `feat/app-...`" were built on separate branches. They are all
combined now on `feat/app-line` (the one branch the app is built from; `main` does not have the app yet). Merging
`feat/app-line` into `main` waits for the owner's phone tests.

The phone app leads (wish 16). Nothing below needs an API worker: the research is finished (findings on
`_local/research/2026-11-18-findings.html`).

### 1. Built, waiting for the owner's phone tests

Open **Try these** in the app: it lists these in order, with a button to each screen, what to tell the assistant,
and a note that leaves with Export data. The steps are the "Owner step" headings in [app/README.md](app/README.md)
(its table of contents at the top follows the same order). Longer lists of what to report are in "Next tests that
need the owner" below.

1. **A first night** (rows 3, 9, 25): Start night, tap Lights off as you close your eyes, read the sleep report in
   the morning (how long the phone took, the noise and jaw numbers, "Falling asleep"). Five Lights off nights decide
   whether the drift-off detector ships (it must land within 5 minutes of the sleep model on 4 of 5).
2. **Morning check-in and Trends** (rows 6, 10): two mornings.
3. **Export data**, then **Share on Wi-Fi** (row 29; data safety, DECISIONS 150-157, 220-229): the first export and the
   first night mirrored to the laptop, screen off, battery.
4. **Work session** (row 35): one working day with the headband on. Also **a first look at the Signal tab** (row 38, 5 minutes):
   the head, the traces and the raw data with the headband on.
5. **Meditation** (row 21): the first session, then 8 for the first learning verdict.
6. **Sound for states** (rows 17, 18), then the sessions with the phone locked, then the 4-week fair test of two sounds.
7. **A nap** (nap coach, row 26), **a smart alarm morning** (row 27), **a dream catcher nap** and its answers as text
   (row 20), **alpha-theta** (row 22), **hands-free** calibration (row 28).
8. **The lucid week** (row 32; evidence weak).
9. **Tries that take weeks**: a first self-experiment (row 14), the replay check (row 23), and the assistant's
   proposals: Sharp hours (31), Study reminders (34), "Unusual for you" (30, silent for 28 days), "Was this you?" (33).
10. **Our own headband connection** (DECISIONS 90-92, 210-219): the 5-minute probe on the
    phone, then one night with the switch on; the laptop's 15-minute probe too. And **the DIY board on the phone**
    (row 13) once the board is assembled and passes its bench steps.
11. Not in the app: the laptop's sound bench tests, the extended setup test (blink depth, glances, clenches: it sets
    the detectors' limits, row 9 and 25), and break hints on the owner's laptop (row 8, never run there).

The first real phone test (1 hour with the screen off, the drop test) is still at the end of `app/README.md`; the
phone's speed for scoring (rows 3, 26, 27) is unmeasured until the owner's first night and nap.

### 2. Left to build

Needs no owner decision, only time or data:

- **Fit the sleep-pressure constants** (row 10) once there are mornings of ratings.
- **The laptop statistics engine** (row 14): observational screens and Bayesian models, after a month of days.
- **ActivityWatch focus sessions** as a laptop importer beside Sharp hours' files (row 31, DECISIONS 289).
- **The DIY board on the phone**: USB (OTG) and the 8-channel chip (row 13); calibration for any electrode
  positions (row 12) after the helmet exists.
- **Tune from the owner's first tries**: the dream catcher's voice and timings, the smart alarm's and nap coach's
  wake sounds, the hints' rate, the lucid cues' loudness, the drift-off detector's limits.

Needs the owner's OK first:

- **utof_tracker importer** for `eeg_*` events (row 11; utof_tracker does not read them yet).
- **Packing old nights** (xz after 90 days); encryption and restic are deferred (see "Decisions waiting").
- **Sleep-scorer upgrade, parked (owner, 2026-11-19)**: first look for a better way *without* fitting a model: faster or simpler scoring algorithms, other ready-made sleep scorers, adapting the current one without labels, rules on the headband's own signals. Only if none is clearly better: AnySleep fine-tuned on public nights reshaped to the headband's channels (needs the 58 GB download, over the weekly download budget).

Later or only if the evidence grows (the "Ideas for later" and "Proposals" tables below):

- Helmet-only ideas: frontal asymmetry, a brain-typing speller, flicker games. Helmet layout and ZUNA noise repair.
- **Sleep cues for memory** (weak; only as a sham-controlled self-test).
- Already built from those tables: smart alarm, dream catcher, lucid cues, reaction check, self-experiments, study
  reminders, our own headband driver, live sleep stages on the phone.

Research for later: the rules for a public release (see the last table).

## Next tests that need the owner

- **Start from Try these in the app** (main screen between nights, after Morning; DECISIONS 340): the tests below that
  run on the phone, in order, each with its steps, a button to its screen, what to tell the assistant and a note that
  goes out with Export data. The app ticks some by itself.
- **Phone test** (about 1.5 h plus one night on battery): the steps in `app/README.md` on the app branch (install,
  phone settings, 1 hour screen off, the drop test, export). The assistant adds a few checks over USB while the
  phone is plugged in (forced deep sleep before the drop test, phone model, a 3-minute Bluetooth log).
- **Sound feedback bench tests** (6 x about 5 min, `sound.html`): a normal run with the headband on; 20 minutes
  reclined (does it catch dozing?); a few jaw clenches; a forced-roughness check; wired vs Bluetooth headphones;
  20 blinks on cue.
- **First meditations on the phone** (5-10 min each, `app/README.md` on `feat/app-meditation`): does the sound
  start and feel right (levels, rain, bells), does it follow eyes closing within about a second on wired
  headphones, does the chip say "restless" on a clench, and is the report believable.
- **Sound for states on the phone** (15-40 min, `app/README.md` on `feat/app-sound-states`, "Owner step"): are the
  beds pleasant at a low volume, is the beat soft enough, does "no beat" sound as loud; one relax session with the
  headband (quiet minute, then the readout); one bedtime "fall asleep" with the headband: did the sound fade once
  you were asleep, and did the night start recording.
- **Alpha-theta and the replay check** (`app/README.md` on `feat/app-replay-alphatheta`): read the screening and
  consent once; in the first session, are the stream and the waves pleasant at the same volume, are the chime and
  gong soft enough; does a short doze fade the sound and wake you gently; does the reaction test feel fair. For the
  check: switch it on in Training settings (gear button), and just meditate; results come after 12 sessions.
- **Extended setup test** (2 min, `morning.html`): blinks, left-right glances, clenches; it sets the detectors' blink
  depth, gives µV per degree and left vs right for glances on T3-T4, and confirms the 55-120 Hz jaw band
  ([docs/detectors.md](docs/detectors.md)).
- **First morning check-ins on the phone** (about 10 minutes, two mornings; `app/README.md` on
  `feat/app-morning-trends`, "Owner step"): tones, the dim eyes-closed page, contact words, the numbers, Trends.
- **Sleep report on the phone** (one morning, about 15 minutes; `app/README.md` on `feat/app-sleep-report`,
  "Owner step"): after a recorded night press Stop and note how long the phone takes to show the time asleep,
  whether the app stays open, and whether the report looks like the night you remember.
- **Export data, once set up** (5 minutes, `app/README.md` on `feat/app-export-all`, "Export data"): pick the folder
  (Syncthing's or Download/EEG), Export new, then `python3 scripts/import_phone.py <folder>` on the laptop; tell the
  assistant how long the first export took, and anything the summary called a PROBLEM.
- **Lights off, five nights** (a few seconds a night, `app/README.md` on `feat/app-night-lightsoff`, "Lights off and
  falling asleep"): tap Lights off as you close your eyes; in the morning read "Falling asleep" in the sleep report
  and tell the assistant whether the detector's minutes feel right, and the last line of the night's `.log` (the
  detector's cost on the phone).
- **First nap coach nap** (about 30 min, `app/README.md` on `feat/app-nap-coach`, "Nap coach"): pick 30 min, set the
  volume, Lights off; tell the assistant the report's "Sleep model" line (the phone's speed), whether the wake sound
  woke you and how loud its first note felt, and whether it woke you before deep sleep or at 30 minutes.
- **First smart alarm morning** (2 minutes of setup, `app/README.md` on `feat/app-smart-alarm`, "Smart alarm"): allow
  the lock-screen and pop-up permissions once, set the alarm volume, Set alarm for your usual time with 30 min, Start
  night; tell the assistant whether and when it woke you, whether I'm awake showed over the lock screen, the
  report's Waking up lines and the `.log`'s smart alarm cost line.
- **First dream catcher nap** (about 20-45 min, `app/README.md` on `feat/app-dream-catcher`, "Owner step"): record
  both prompts and set the volume; 3 rounds, Wake me; tell the assistant whether the questions came half-asleep,
  too early or too late, whether the prompts' volume and the dim screen were right, whether answers were cut off or
  ran on, and whether the Drifting / Awake tap worked half-asleep.
- **Hands-free calibration and a first try** (about 10 min, `app/README.md` on `feat/app-hands-free`, "Hands-free
  controls"): Settings, switch it on, calibrate; tell the assistant each gesture's "Works" / "Not used", the numbers
  after each try and any reason for a miss; then a 10-minute Relax sound session: does a double clench pause and
  resume the sound, does a look give the higher note, and did anything come up when you did nothing.
- **Dream catcher answers as words** (about 10 min on Wi-Fi, `app/README.md` on `feat/app-dream-text`, "Owner step:
  answers as words"): download the speech model (671 MB) under Answers as text; after the next session tell the
  assistant how long one answer took, how close the Russian and English words were, and whether a mumble came out.
- **"Unusual for you", after 4 weeks** (1 minute, `app/README.md` on `feat/app-unusual-card`, "Unusual for you"):
  nothing to do while it learns; when the first card appears, say whether it matched how you felt and whether the
  words were calm enough; switch it off beside its heading if it worries more than it helps.
- **First lucid week** (15 min an evening, 1 min a morning, `app/README.md` on `feat/app-lucid-cues`, "Lucid dream
  cues"): Lucid dreams, Turn on, the practice to the end, Start night and Lights off; once, awake with the headband
  on, make the eye signal on purpose and note the times; answer the three questions each morning; tell the
  assistant whether the practice level was audible, whether the night woke you, the `.log`'s `lucid cues` lines and
  the battery drain against a night without them.
- **First work session** (2 minutes to start, then a working day; `app/README.md` on `feat/app-work-session`, "Work
  session"): start fresh, work as usual, answer the hints and tap how sharp you feel; tell the assistant whether the
  level matched how you felt, whether the hints came too often, the battery and the headband's comfort over hours.
- **Own-driver probe** (about 15 min, docs/own-ble-driver.md): stop the recorder, run `scripts/ble_probe.py`, follow
  the spoken steps (eyes closed / open, lift each electrode for 4 s). Settles the channel order, the scale and
  whether contact can be measured all night.

## Decisions waiting for the owner

- Download about 58 GB of public sleep recordings (Dreem) to test the sleep scorer on headband-shaped data (over the
  10 GB-a-week download limit).
- Clear the GitHub billing lock, so GitHub builds the app on every change (the laptop can build it too).
- Morning check-in eyes-closed phase: keep 2 minutes or make it 3 (research D).
- Order a spare magnetic charging cable for the headband (order by about 28 November; see the parts report).
- Backups: encryption and restic are deferred (owner, 2026-11-18). Since Export data (DECISIONS 150-157) the phone's
  data reaches the laptop, but the laptop's `_local/` is still one copy on one drive.

## Ideas for later (after the wishes above are built)

Anyone, including the assistant, adds ideas here. When one is started, move it into the Status table.

| Idea | What it is | Notes |
|---|---|---|
| Smart alarm (now row 27 above) | wakes you within a chosen window at a moment of light sleep, not deep sleep | **built 2026-11-19** (status row 27) |
| Dream catcher (now row 20 above) | as you drift off, the app notices the half-dream stage (back-of-head alpha fading), quietly asks "what are you thinking about?", records your spoken answer, lets you drift again; 3-4 rounds. For creative ideas | MIT's Dormio; a 2021 study found 15 s in that stage tripled insight on a puzzle; needs only O1/O2 |
| Lucid dream cues (now row 32 above) | soft sound cues during dream sleep (REM) to become aware you are dreaming | **built 2026-11-19; evidence weak** (status row 32) |
| Reaction-time check | a 1-minute daily tap test next to the EEG, an objective alertness number | now part of the Sharp-hours log (status row 31): 2 tests a day at random moments |
| Self-experiments | the app picks random days (e.g. no coffee after 14:00) for a few weeks and reports the effect with a range | the only route to "this causes that". **Built 2026-11-19** (status row 14) |
| Helmet-only | frontal brain asymmetry, a brain-typing speller (P300), flicker games (SSVEP) | need electrodes the headband lacks |

### Proposals from research round 2 (the assistant's; not approved yet)

Built only after the owner's features above, and only where the data clearly supports them. The owner can steer
or delete any of these.

| Idea | What it is | Evidence (research) |
|---|---|---|
| Sleep cues for memory | soft sound cues in deep sleep, only as a sham-controlled self-test; no closed-loop clicks | weak: a 13-lab replication is due ~2027; cues that wake you hurt memory (B) |
| Evening study, morning review (now row 34 above) | a plain reminder to study in the evening and review in the morning | **built 2026-11-19; off by default** (status row 34); some (B) |
| Open BrainBit driver | our own Bluetooth code instead of the closed SDK; contact quality all night | protocol mostly public via Neiry's MIT package; legal for your own device (D) |
| Sleep-scorer upgrade (parked, owner 2026-11-19) | first: a better way without fitting (faster/simpler algorithms, other ready-made scorers, adapting without labels); only then AnySleep fine-tuned on public nights reshaped to the headband's channels (CHAT has them); adopt only if clearly better | some (C; the fine-tune needs the 58 GB download) |
| Live sleep stages on the phone | built for the nap coach (row 26, DECISIONS 170-172): AnySleep itself, 2 min behind; a small model only if the phone is too slow | Traumschreiber (MIT, Nov 2026) already runs AnySleep on a phone (C, D) |
| Helmet layout | 8 sites M1 M2 F7 F8 Fz C3 C4 Pz plus the forehead reference, then 16; noted in `eeg_ads1299_lab` as a planning assumption | some (B) |
| Noise repair (ZUNA) | re-draw bad stretches on the laptop, mainly for the helmet | untested on 4 channels (C; Apache-2.0) |

## Research for later (proposed, not run yet)

| Lane | What it would answer |
|---|---|
| Rules for a public release | when an app counts as a medical device (EU MDR, US FDA "general wellness"), which claims are allowed, privacy law (GDPR) for brain data |
