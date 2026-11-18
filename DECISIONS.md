# Decisions and alternatives

One row per decision. Ask "why X instead of Y" and the answer should be here.
Status: **proposed** (my pick, not yet confirmed by the owner), **decided**, **open** (waiting on research or the owner).

## Goal (user, 2026-11-18)

An open-source app that gets the most information out of EEG electrodes, to make life better:
sleep tracking, stress / anxiety / focus, "take a break" hints while coding, generative music,
lots of statistics on how things affect the owner. Phone matters at least as much as the PC
(put the headband on, tap one button, sleep). Device order: BrainBit Black first, then the DIY
ADS1299 board (8-16 electrodes, any positions), then others such as OpenBCI.

## Facts measured on this laptop (2026-11-18, Linux Mint 22.3)

- BrainBit Black (firmware 1.10) connects from
  Python with BrainBit's pyneurosdk2 1.0.15: 4 channels O1 O2 T3 T4, 250 Hz, battery read,
  contact check (resistance) works. No pairing needed. No motion sensor or pulse sensor reported.
- Not yet tested on a head: the readings above were with the headband off (contacts = infinity).
- Setup without sudo: `libneurosdk2.so` (from BrainBit's Ubuntu 24.04 package, 1.0.6.39) plus
  libc++ / libc++abi / libunwind 18 unpacked into `~/.local/lib/neurosdk2`; run with
  `LD_LIBRARY_PATH=~/.local/lib/neurosdk2`. Probe: `scripts/brainbit_probe.py`.

## Decisions

**Working rule (owner, 2026-11-18):** the assistant chooses without waiting for the owner and records each choice here with its alternatives, so the owner can steer later. Status: **decided** = in force (by the owner where marked, otherwise by the assistant under this rule; any row can be reopened); **open** = needs a test.
"Switch if" says what would make the alternative the better pick.

| # | Topic | Pick | Status | Alternatives | Why / switch if |
|---|---|---|---|---|---|
| 1 | Where the code lives | three repos: this one (public app: phone app, shared code, analysis), `eeg_ads1299_lab` (public hardware + build guides), `utof_tracker` (private, imports this app's exports) | decided | one monorepo for app + hardware; EEG features inside utof_tracker | contributors should not need KiCad or hardware safety gates; private data never in a public repo |
| 2 | App framework | Flutter app on Android whose first job is recording all night; Python on the PC for heavy analysis | decided | native Kotlin recorder + Python desktop; Kotlin Multiplatform; React Native; Tauri; Python + browser screens | BrainBit's Flutter package covers Android; the owner already knows Flutter. Recorder shape (docs/research/android-overnight-ble-xiaomi.md): one foreground service of type `connectedDevice` only, never `dataSync` (6 h/day cap on Android 15+); `flutter_foreground_task` 11.0.3 with the whole BrainBit session inside its TaskHandler isolate (the plugin has one instance per engine and starts no service or wakelock itself). Switch to a Kotlin recorder if the 1-hour screen-off test on the Xiaomi loses data; React Native if iPhone becomes the main target |
| 3 | BrainBit connection | BrainBit's NeuroSDK2 (Flutter package on the phone, pyneurosdk2 on the PC), kept in its own module | decided | BrainFlow; raw Bluetooth | only route to the BrainBit Black on every system; BrainFlow has no Black support and no Flutter. Core is a closed binary, hence the separate module. Flutter `neurosdk2` 1.0.21 ships its binaries under its MIT file (docs/research/neurosdk2-flutter.md); the Linux `.so` exports what a Linux desktop plugin would need. On the PC: never import numpy in the recorder process (segfault) |
| 4 | Any electrode positions | each tracker learns its channels from a 1-2 min eyes-closed / eyes-open setup task; positions optional; re-calibrate when electrodes move | decided | require standard positions; large pretrained "brain models" | benchmarks show small classical methods match the big models when data is scarce; pyRiemann is the toolkit |
| 5 | DIY board data format | keep the board's own "E9" format | decided | OpenBCI Cyton mode (about 2-4 days of firmware, estimate); host adapter to LSL | E9 has error checks and sample counters the Cyton format lacks; Cyton 16-channel mode halves the rate. Switch if using OpenBCI's own app becomes important |
| 6 | First trackers | contact check, sleep timing, morning check-in (alpha strength and speed), jaw tension; stress / focus only as the owner's own ratings beside the data | decided | vendor-style stress and focus scores | no brand's stress or focus score has independent validation; these 4 positions cannot measure them |
| 7 | Where signal processing runs | live basics on the phone, everything heavy in Python on the PC | decided | sleep scoring on the phone; shared Rust core; Python on the phone | fastest to build. Switch to on-phone scoring when people without a PC use the app |
| 8 | Sleep model | AnySleep (accepts any channels; code and weights MIT; 128 Hz, robust scaling, no filter), YASA 0.8.1 (BSD-3) on O1-T3 as cross-check; disagreement shown as low confidence | picked, unproven | YASA alone; U-Sleep | published: AnySleep macro-F1 ~0.68 with 1 channel, ~0.73 with 4 (wet PSG); YASA expected ~60-75% on these sites (estimate). Neither was tested on dry side-of-head electrodes: judge on the owner's own nights (docs/research/anysleep.md, yasa-single-occipital.md) |
| 9 | Storage | add-only chunk file with checksums on the phone; the PC joins a night's chunks into one BDF+ (pyedflib), filling missing time with held values marked `BAD_gap`, so file time equals clock time; results as JSON-lines events in utof_tracker's format | decided | write BDF on the phone (needs a Dart writer); keep samples contiguous and only annotate gaps; XDF; HDF5 | a killed app loses seconds, not the night; BDF+ is read by the sleep tools; no Python library writes BDF+D, and sleep epochs must line up with the clock (docs/research/bdf-plus-writing.md) |
| 10 | Sync | app writes to an export folder; Syncthing carries it for the owner; ZIP / USB export for everyone else; "last synced" warning | decided | built-in Wi-Fi transfer; Health Connect | Syncthing already runs for utof_tracker; its Android app changed hands in 2026, so it must not be the only way. Health Connect later as an optional extra: write one multi-stage sleep session per night with `health_connector` (the `health` package cannot), read heart rate / HRV / other apps' sleep (docs/research/health-connect.md) |
| 11 | Sound engine | `flutter_soloud` with rule-based ambient sound; first mode: sound calms as alpha rises, jaw tension blocks rewards | decided | native low-delay audio core; Pure Data; AI-generated music on the PC | low risk, runs on phone and desktop. Switch to a native core only for precisely timed pulses |
| 12 | Statistics | per-day export analysed first by utof_tracker's nightly job; every result labelled "seen together" or "tested"; self-experiments suggested | decided | quick correlations like commercial apps | one person needs about a month of days for a large effect; loose correlations mislead |
| 13 | Break hints | start on the PC from activity data with no headband; add own ratings, then typing rhythm, then the EEG trend; at most 4 a day | decided | EEG-only focus score | no validated EEG break detector exists for these positions |
| 14 | UI | built with the `/impeccable` skill (owner's instruction) | decided | - | user request 2026-11-18 |
| 15 | Licence of the app | MIT | decided (owner) | Apache-2.0; GPL | owner's choice 2026-11-18 |
| 16 | Repository visibility | public on GitHub from the start | decided (owner allowed it) | private until first release | cloud agents and contributors need it; nothing personal is committed (`_local/` is excluded) |
| 17 | PC recorder survives Bluetooth drops | after 40 s without data the recorder process exits and `record_night.sh` starts a fresh one (new file); `to_bdf.py` joins the files of a night | decided | reconnect inside one process | 2026-11-18 night: in-process reconnect after an out-of-range drop segfaulted inside the SDK (exit 139) and StartSignal after a resistance check sent nothing; a fresh process always worked |
| 18 | Brain sound baseline | 60 s calibration at the start (30 s eyes open = 0, 30 s eyes closed = 1, first 5 s of each dropped); if eyes closed gives under 1.5x alpha, or the person skips it, the 10th-90th percentile of the last 5 min (a 2x span centred on it when the range is narrower) | decided | running percentile only; fixed µV thresholds; eyes-open level only | calibration gives a scale the person understands ("your eyes-closed level") and doubles as an alpha check; the fallback keeps it working when alpha is weak or the user skips. Switch to running only if real sessions show the calibrated scale drifting off within 10-20 min (contact settling) |
| 19 | Brain sound measures | alpha = log power 8-12 Hz, mean of usable O1/O2; jaw = 30-45 Hz at T3/T4 against its own 20th percentile of 2 min; 1 s Hann window every 0.25 s, alpha smoothed 0.5 s | decided | relative alpha (alpha / 4-30 Hz); band around each person's alpha peak; 2-4 s windows | short delay matters most for alpha feedback, and absolute alpha is what eyes closing changes most. Switch to relative alpha if real sessions show broad power drifting with contact; to a personal band if the owner's peak sits near 8 or 12 Hz |
| 20 | Brain sound rewards | a bell only after alpha >= 0.7 on the person's scale for 3 s with jaw under 2x rest and a usable side electrode; any block resets the count and locks bells for 2 s; bells exist only as rewards | decided | Muse-style random birds plus rewards; no rewards, sound only; also block on O1/O2 high-frequency power | muscle can never earn a bell, and every sound you hear maps to a measure. Add an O1/O2 muscle check if real clenches leak into back-of-head alpha |
| 21 | Brain sound prototype | browser page `scripts/web/sound.html` with Web Audio; pure ES modules for features, session, mapping and mixer, tested with `node --test`; engine kept separate | decided | Python audio in the recorder (needs numpy: forbidden there); Tone.js or another audio library; go straight to Flutter | runs today on the laptop with the existing recorder and no install; the pure modules are small enough to port to Dart line by line for `flutter_soloud` (row 11) |
| 22 | Morning check-in protocol | contact check, 2 min eyes closed then 2 min eyes open on a dot, soft tones at each change, then Karolinska Sleepiness Scale (1-9) and mood / tension (1-5); every boundary is a page marker | decided | alternating 1-min closed / open blocks; 3 min each; eyes open first; visual analogue scales | simplest routine that gives the three alpha measures in 5 min; KSS is the standard short sleepiness rating. Switch to alternating blocks if the eyes-closed value drifts within the 2 min (drowsiness turns alpha into theta) or depends on order |
| 23 | Alpha speed (individual alpha frequency) | centre of gravity of the power above the 1/f line in 7-14 Hz, eyes closed, 2 s segments zero-padded to 0.25 Hz; the peak of that excess is stored too; `null` if no point rises 0.1 log units (+26 %) above the line | decided | raw spectral peak; raw centre of gravity (biased low by 1/f); specparam peak; restingIAF (Savitzky-Golay) | a single peak bin jumps with 0.5 Hz resolution and split peaks; removing 1/f first stops the slope from pulling the value down; no extra dependency. Switch to the peak or specparam if it has smaller day-to-day spread on the owner's first two weeks |
| 24 | Artefact rejection for the check-in | 2 s segments, reject if peak-to-peak over 150 µV after a 1-40 Hz band-pass, flat (under 0.5 µV spread) or spread over 3x the phase median; skip the first 3 s and last 1 s of each phase; a channel needs 20 s clean per phase | decided | ICA; autoreject; fixed threshold only | 4 channels are too few for ICA, and autoreject needs many epochs; amplitude rules are simple and explainable. Switch thresholds if real mornings keep under 60 % clean data, or if blinks leak into the eyes-open alpha |
| 25 | 1/f (aperiodic) slope | straight-line fit of log power on log frequency, 2-40 Hz without 7-14 Hz, eyes closed | decided | specparam (FOOOF) | no extra dependency, transparent; beta peaks bias it a little. Switch to specparam if the slope turns out to track anything for the owner |
| 26 | How a check-in is compared | median and range of the last 14 earlier check-ins in the same folder; "within / above / below your range"; a note until 5 exist; never a score or a norm | decided | z-scores; percentiles; population norms | no norms exist for this headband; with under 14 days a z-score is unstable and a range is plain to read. Switch to a rolling percentile once there are 30+ days |
| 27 | Lining up page markers with samples | the marker's sample index `i` (samples received when the marker arrived), not clock time | decided | clock time through the `.idx` arrival times | stays right across Bluetooth gaps and needs no clock maths; delivery delay is about 0.1 s, far under the 3 s skipped at each phase start. Switch if the phone app writes markers without a sample index |
| 28 | Setup test ("what can it see") | 20 cued blinks, 10 left / right glances, 5 jaw clenches, all on tones in about 2 min; each scored as signal-to-noise against the moments around it, "visible" at 2 or more | decided | a free-form recording with hand-labelled events; per-event detection rates | gives a quick yes / no per event type for these 4 sites. Switch to per-event detection once these events drive features (jaw tension, break hints) |
| 29 | Tests without a headband | pytest in `analysis/tests` (run with `uv run --project analysis --with pytest`, so `uv.lock` is unchanged), `node --test` for the page logic (no npm packages); one slow test runs the real recorder on the fake headband | decided | a dev dependency group in `analysis/pyproject.toml`; a JS test framework | nothing new to install or lock; the cloud sessions cannot reach the PyTorch index to re-lock. Switch to a dev group when the lock can be refreshed |

## Untested things the plan rests on

1. An all-night Bluetooth recording on the Xiaomi phone (Xiaomi kills background apps).
2. Whether the headband is bearable to sleep in and keeps contact lying down.
3. Whether sleep scoring works at these electrode positions.

## Mission (user, 2026-11-18)

Affordable EEG for everyone: step-by-step guides to build a helmet at home (what to buy, how to assemble)
plus an open app, with outside contributors expected, that helps people understand themselves.
The owner's phone: Xiaomi 12T-family (Android; Xiaomi's system is known for killing background apps,
which matters for overnight recording).

## Sibling projects (user, 2026-11-18)

`../utof_tracker` (personal life tracker: Flutter app for Android and Linux plus Python analysis in `pc/`) and
`../pls_breathe` (Expo / React Native breathing app) share the same aim. Data from this app is meant to flow
into utof_tracker for deeper analysis, so a clean export / data contract is a requirement, not an extra.
utof_tracker is Flutter on Android (its Linux build is only a development harness with fake phone data); its pc/ side is Python. The phone there is recorded as a Xiaomi 11T, HyperOS, Android 14 (the owner said "12T or something"; confirm with `adb shell getprop ro.product.model`).

## Research (2026-11-18)

Eight topic notes in `_local/research/2026-11-18-01-*.md`; combined report
`_local/research/2026-11-18-01-eeg-life-tracker-architecture.md` (alternatives table, 17 risks with the
cheapest test for each, first-week build order). The picks below come from it.

Follow-ups (cloud session, merged 2026-11-18) in `docs/research/`: `anysleep.md`, `yasa-single-occipital.md`,
`neurosdk2-flutter.md`, `android-overnight-ble-xiaomi.md` (includes the phone settings checklist and test plan),
`health-connect.md`, `bdf-plus-writing.md`.

## Tools made so far

- `scripts/record_night.sh`: records the BrainBit to `_local/recordings/` until Ctrl+C, keeps the laptop awake,
  starts a fresh recorder after a stall (row 17). Serves a live check page on port 8765 (signal, hum, contact).
- `scripts/to_bdf.py`: joins one night's files into a BDF+ file with gap annotations and prints a quality summary.
- `scripts/brainbit_probe.py`: scan, connect, contact, 5 s of signal.
- `scripts/score_sleep.py`: AnySleep (3 runs averaged, 4 channels, 0.3 Hz high-pass added by us) and YASA (O1-T3) per 30 s epoch;
  epochs missing over 5 s are not scored; writes JSON and a hypnogram PNG. Environment: `analysis/` (uv, CPU torch).
- `scripts/web/morning.html`: guided 5-minute morning check-in (contact, eyes closed, eyes open, ratings) and a
  2-minute setup test, served by the recorder; `?short=1` for 60 s phases.
- `scripts/morning_check.py`: analyses the newest check-in in a recording, writes `<start>.morning.json` and
  compares it with the last 14 (rows 18-24).
- `scripts/export_events.py`: `eeg_sleep_night` and `eeg_morning_check` events in utof_tracker's envelope (docs/data-format.md); a separate
  type from utof_tracker's own `sleep_night`, so neither overwrites the other. utof_tracker does not read them yet.
