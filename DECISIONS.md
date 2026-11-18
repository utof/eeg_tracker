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
| 18 | Phone recorder after a Bluetooth drop | save, leave the lost sensor object untouched (no SDK call at all), then a fresh scan, a new sensor object and a new file set; `to_bdf.py` joins the sets | decided (assistant, 2026-11-18) | call `connect()` again on the same sensor without a scan (the research note's mitigation for screen-off scans) | the laptop SDK segfaulted on calls to a lost sensor and a fresh start always worked (row 17). Switch if test T3(d) shows a screen-off scan never finds the headband again |
| 19 | Phone recorder when an SDK call blocks | every SDK call has a deadline (30 s; scan + connect 90 s); past it the data is saved, the foreground-task restart alarm is armed and the app process ends; Android restarts the service, which continues the night with a new file set | decided (assistant) | keep going in the same process; stop the night | the Android plugin runs commands under one lock, so one blocked call blocks all later ones; a fresh process is the laptop's proven cure. Switch if T3 shows HyperOS does not bring the service back |
| 20 | Contact quality words | good <= 1 MOhm, fair <= 2.5 MOhm, poor above, "none" when infinite or missing | planning assumption, unproven | BrainBit's own limits (README says "2.5 ohms", unit garbled) | no measured on-head values were available to the phone work; recalibrate from the owner's `contact ohms` log lines |
| 21 | When the phone checks contact | once a night, at the first connection; not after reconnects or process restarts | decided (assistant) | before every file set | on the laptop a stream started right after a resistance check once sent nothing; at 3 a.m. the data matter more than a contact reading |
| 22 | Where the phone writes | the app's private folder `files/recordings` (Context.getFilesDir), handed to both Flutter engines by a small Kotlin channel (registered in the service's engine through `FlutterForegroundTaskLifecycleListener` in `Application.onCreate`); nothing leaves it except by Export (row 25) | decided (assistant; changed 2026-11-18 from `Android/media`) | `Android/media/<app>/recordings` (the first pick: adb pull and Syncthing see it, but so can other apps with storage access); `Android/data/...` (still external storage); MediaStore | EEG identifies a person like a fingerprint and is health data; the private folder cannot be read by other apps and Android encrypts it (research 2026-11-18-07, app tech and data). Switch to a shared folder only for encrypted copies (age to the laptop's key) if automatic Syncthing sync becomes worth that work |
| 23 | Phone permissions | Nearby devices only on Android 12+ (scan flagged `neverForLocation`); location only on Android 11 and older; `ACCESS_BACKGROUND_LOCATION` from neurosdk2 removed; battery-optimisation exemption asked with the system dialog (GitHub build) | decided (assistant) | location on every version, as BrainBit's example does | fewer scary prompts. Switch if test T0 finds no headband without location |
| 24 | Phone screen | one dark screen, "night watch" design (DESIGN.md, PRODUCT.md, `.impeccable/surfaces/`): status word, minutes, data age, a half-hour strip of what was saved, headband facts, phone-setting checks with fix buttons, one Start/Stop button | proposed (assistant, owner asleep) | a dashboard of metric cards; a light theme | used in a dark bedroom half-asleep; the strip shows gaps at a glance. Made with `/impeccable` (row 14); PRODUCT.md facts marked *(inferred)* need the owner's check |
| 25 | Getting a night off the phone | "Export a night" on the screen (only while not recording): pick a night (runs grouped noon to noon, like `night_of` in docs/data-format.md), then a folder with the system folder picker (Storage Access Framework); the files are copied unchanged into a new subfolder `eeg-night-YYYY-MM-DD` and stay on the phone | decided (assistant) | the system share sheet (share_plus: copies into the cache, then needs an app that takes ~160 MB); a ZIP (deflate saves only ~1.2x, storage lane); an automatic copy into the Syncthing folder | works offline with no other app: Download/EEG then `adb pull`, a USB cable, or the phone's Syncthing folder; files keep the exact layout `to_bdf.py` reads. Switch to adding the share sheet if nights mostly go out by Telegram or Drive; to an automatic encrypted copy if picking a folder each morning gets tiresome |
| 26 | Android backup and phone-to-phone transfer | none at all: `allowBackup="false"`, plus `dataExtractionRules` (Android 12+) excluding every domain from both cloud backup and device transfer, plus `fullBackupContent` (Android 11 and older) excluding every domain | decided (assistant) | Android's default (everything up to 25 MB goes to Google Drive, everything moves to a new phone); exclude only `files/recordings`; cloud backup only with client-side encryption (`disableIfNoEncryptionCapabilities`) | the recordings and the saved night state (sleep times, contact values, per-half-hour sample counts) are EEG or derived from it, and no setting is worth restoring. `allowBackup="false"` alone is not enough: on Android 12+ some makers still run device-to-device transfers (Android Auto Backup guide); excluding everything instead of one folder also covers files added later (a database, a log). Switch to including one settings file if the app ever has settings worth restoring; never the recordings |

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
- `app/`: the Android recorder (Flutter, branch `feat/android-recorder`, rows 18-26). Writes the same files as
  `record_night.py` to its private folder; "Export a night" copies a night out. Not yet run on a phone.
- `scripts/export_events.py`: `eeg_sleep_night` events in utof_tracker's envelope (docs/data-format.md); a separate
  type from utof_tracker's own `sleep_night`, so neither overwrites the other. utof_tracker does not read them yet.
