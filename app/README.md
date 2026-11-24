# EEG Tracker: Android recorder and meditation

Records a BrainBit headband all night on an Android phone. The main screen: Start night, Stop, the state,
minutes recorded, seconds since the last data, a half-hour strip of what was saved, battery, signal,
contact per channel, and phone settings that could stop the recording. Between nights, the **Morning** section
opens the **morning check-in** and the **trends** page (below), and **Meditate** opens a guided eyes-closed
session whose sound follows your alpha rhythm (below); from there, **Alpha-theta** training and the **replay
check** (both below). Also between nights, the **Dream catcher** asks what is on your mind as you drift off and
records your answers, and the **Nap coach** wakes you before deep sleep starts or at the length you pick (both
below). The **Smart alarm**, set just above Start night, wakes you in a window you choose at a light moment of the
night, never in deep sleep, and always by the window's end (below). **Sound** (at the bottom, also during a night) plays calm sound
for a state, with an optional beat, and with the headband shows what your brain does (below).

**The bar at the bottom** (since 2026-11-20, DECISIONS 597): **Night** (the night screen: status, the strip, Sleep,
Morning, Try these, Headband, Phone, with Start night pinned; the app opens here), **Sessions** (Meditation, Dream
catcher, Nap coach, Lucid dreams, Work, Sound), **Signal** (the head, live traces and raw data, below), **Trends** and
**More** (Your data: Export data, Export a night, Share on Wi-Fi; Settings; Licences). Where a section below says
"on the main screen", look in the tab that holds it; Back on another tab returns to Night.

## Owner steps, in the order to try them

Every feature below has an **Owner step** heading in its section: what to do, and what to tell the assistant. The app's
**Try these** page (next section) walks through the same list and ticks some steps itself. A feature marked "no steps
of its own" is covered by another one's steps. The old one-hour phone test is still at the end of this file.

**Tonight and the morning**

- [Lights off and falling asleep](#lights-off-and-falling-asleep): a night with Lights off, then four more (a few seconds a night)
- [Sleep report](#sleep-report): how long the phone takes to score a night; the noise, jaw and movement numbers
- [Morning check-in](#morning-check-in) and [Trends](#trends): the first check-ins on two mornings (about 10 minutes); the owner step is under Trends
- [Export data](#export-data-everything-every-few-days): set it up once, then every few days
- [Archive](#archive-every-recording-its-timeline-and-tags): look through a day, tag it, delete one (5 minutes)

**Another night**

- [Sleep so far](#sleep-so-far): one look at the chart in the night (1 minute)
- [Smart alarm](#smart-alarm): one morning
- [Pulse](#pulse-heart-rate-from-the-headband-an-experiment): a night with a watch on, then 10 minutes (evidence weak)
- [Share on Wi-Fi](#share-on-wi-fi-the-laptop-watches-and-copies-while-the-phone-records): connect the laptop by one scan, then the first night mirrored to it (the first night doubles as the phone test)

**Daytime sessions**

- [Signal](#signal-the-head-live-traces-and-raw-data): a first look at the head, the traces and the raw data (5 minutes)
- [Work session](#work-session): wear it for a working day
- [Meditate](#meditate): one session, then eight for the first learning verdict
- [Nap coach](#nap-coach): a 30-minute nap
- [Sound for states](#sound-for-states): the first sound sessions, then a bedtime
- [Sessions with the phone locked](#sessions-with-the-phone-locked): 15 minutes, then one bedtime
- [Dream catcher](#dream-catcher): a 20-minute nap; then the answers as words
- [Hands-free controls](#hands-free-controls-off-unless-you-switch-it-on): calibrate and try (about 10 minutes)
- [Walking](#walking-steps-from-the-headband): a walk of 15 minutes or more with the phone's step counter on

**Tries that take weeks**

- [Lucid dream cues](#lucid-dream-cues-off-unless-you-turn-them-on): a first week (evidence weak)
- [Memory cues](#memory-cues-the-assistants-proposal-off-unless-you-switch-it-on): a first week, 12 minutes an evening and 2 a morning (evidence weak)
- [Self-experiments](#self-experiments-does-this-habit-change-that-number-for-you): a first experiment; later a fair test of two sounds (under Sound for states)
- [Sharp hours](#sharp-hours-the-assistants-proposal-off-unless-you-switch-it-on): switch on and watch two days
- [Study reminders](#study-reminders-the-assistants-proposal-off-unless-you-switch-it-on): switch on and watch two days
- [Unusual for you](#unusual-for-you-on-unless-you-switch-it-off): nothing to do for 4 weeks, then one look
- [Was this you?](#was-this-you-on-unless-you-switch-it-off): nothing to do for about two weeks, then one look
- [Replay check](#replay-check-off-unless-you-switch-it-on): switch on in Training settings, then just meditate (no steps of its own)
- [Alpha-theta](#alpha-theta): read the screening and consent once; no steps of its own

**After a day and a night of normal use**

- [Logs, usage and battery](#logs-usage-and-battery-more-how-the-app-runs): a look at the Battery, usage and log pages (5 minutes)

**When the headband is on anyway**

- [When I put the headband on](#when-i-put-the-headband-on-automatic-recording-asks-first-unless-you-change-it): pair it once, then a bedtime with "Ask me" (5 minutes, then a few evenings)

**When the headband and the board are ready**

- [Our own headband connection](#our-own-headband-connection-test-off-by-default): the probe (5 minutes), then one night with the switch on
- [The DIY board](#the-diy-board-test-off-by-default): only after the board passes its bench steps

**Beside the app, on the laptop** (no app steps of their own)

- Packing old nights: nothing to do on the phone, which packs recordings older than a day by itself between nights;
  on the laptop `python3 scripts/pack_old.py` once a day ([data format](../docs/data-format.md))
- The laptop tray: `python3 scripts/tray.py`, then a working day ([laptop-tray.md](../docs/laptop-tray.md)); its
  **Pair phone…** runs the one-scan pairing of [Share on Wi-Fi](#share-on-wi-fi-the-laptop-watches-and-copies-while-the-phone-records)
- Every day's numbers for utof_tracker: `python3 scripts/export_events.py --daily` after each copy from the phone
  ([utof-interface.md](../docs/utof-interface.md))

- Files: `<stamp>.f32/.idx/.log` in the app's private folder (other apps cannot read it), the same format as
  `scripts/record_night.py` (`docs/data-format.md`); join a night with `scripts/to_bdf.py`. Only **Export data**
  (everything the app keeps) and **Export a night** copy anything out (below; DECISIONS rows 53, 56 and 150-156).
  Android backups and phone-to-phone transfers skip the app completely (row 57), so a new phone starts empty:
  export first.
- Packing (owner, 2026-11-19): a recording nothing has written for a day becomes `<stamp>.f32.gz` (gzip, lossless,
  checked before the `.f32` goes; about 40 % smaller), between nights after the sleep report, never while anything
  records. Every reader, Export data and Share on Wi-Fi take either form; the laptop unpacks it on import.
  `lib/recorder/packed.dart`, `files/packing.jsonl`; DECISIONS rows 540-549, `docs/data-format.md`.
- Export data: `lib/export/` (what leaves the phone, the index, the manifest), `lib/ui/export_*.dart`,
  `android/.../DataExport.kt` (the folder grant), `../scripts/import_phone.py` on the laptop; DECISIONS rows 150-156.
- Recorder: a foreground service of type `connectedDevice` (`lib/recorder/recorder_service.dart`) whose
  isolate owns the BrainBit session (`lib/recorder/night_recorder.dart`, rules in DECISIONS row 17 and rows 49-54).
- Screen: `lib/ui/`, design in `../DESIGN.md`.
- Meditation: `lib/feedback/` (the laptop page's feedback core in Dart), `lib/sound/` (flutter_soloud),
  `lib/meditation/` (session and report), `lib/ui/meditation_*.dart`; DECISIONS rows 72-77.
- Sleep report: `lib/sleep/` and `lib/ui/sleep_*.dart`, scored on the phone after Stop (below); DECISIONS rows 95-99,
  night extras (jaw, movement, signal quality) rows 140-146.
- Sleep so far (during a night): `lib/sleep/so_far.dart` (the windows, the cache, the look), `lib/sleep/live_log.dart`
  (the live model's epochs written down), `lib/ui/sleep_so_far*.dart`; DECISIONS rows 640-648 (below).
- Lights off and falling asleep: `lib/recorder/live_drift.dart`, `lib/sleep/drift.dart`, `lib/ui/lights_off_view.dart`
  (below); DECISIONS rows 180-186.
- Self-experiments: `lib/experiments/` (plan, hidden order, randomisation test, store), `lib/ui/experiments_*.dart`,
  `lib/ui/experiment_setup.dart`.
- Replay check: `lib/training/` (schedule, frozen plan, replay, results), `lib/ui/training_settings_screen.dart`,
  `lib/ui/check_views.dart`, `lib/ui/replay_results_screen.dart`; DECISIONS rows 100-103.
- Alpha-theta: `lib/alphatheta/` (rules, engine, notebook), `lib/sound/alpha_theta_sound.dart`,
  `lib/ui/alpha_theta_*.dart`; DECISIONS rows 104-107.
- Dream catcher: `lib/dream/` (rounds, answer end, files, headband link, session), `lib/sound/dream_sound.dart`,
  `lib/ui/dream_*.dart`; DECISIONS rows 110-116.
- Nap coach: `lib/sleep/live_prep.dart` and `live_stager.dart` (live sleep stages, reference
  `../analysis/live_stager.py`), `lib/nap/` (rules, file, session), `lib/sound/nap_sound.dart`, `lib/ui/nap_*.dart`;
  DECISIONS rows 170-179.
- Smart alarm: `lib/alarm/` (the rule, the live model in the recorder's isolate, the phone's alarm clock, the files),
  `lib/ui/alarm_view.dart`, `android/.../WakeAlarm.kt` and `WakeService.kt` (the alarm clock and the ringer),
  reference `../analysis/smart_alarm.py`; DECISIONS rows 230-239.
- Morning check-in and trends: `lib/morning/` (the laptop's `morning_check.py` in Dart, the session, the files),
  `lib/trends/` (days, your usual, sleep pressure, the forecast gate), `lib/ui/morning_*.dart`,
  `lib/ui/trends_*.dart`; DECISIONS rows 120-129.
- Our own headband connection (test, behind a switch): `lib/headband/` (the switch, the driver, the probe),
  `lib/ui/own_ble_*.dart`; DECISIONS rows 210-219 and `../docs/own-ble-driver.md` (below).
- Was this you?: `lib/wearer/` (the rule, the files, the words; reference `../analysis/wearer_check.py`),
  `lib/ui/wearer_view.dart`; DECISIONS rows 370-379.
- Sound for states: `lib/states/` (presets, stop rule, readout, files, session), `lib/sound/state_synth.dart` (the
  sound, made in the app) and `lib/sound/soloud_state_sound.dart`, `lib/ui/states_*.dart` and `lib/ui/sound_score.dart`;
  DECISIONS rows 130-139.
- Try these: `lib/try_these/` (the cards, the progress file, what the app sees by itself), `lib/ui/try_these_*.dart`;
  DECISIONS row 340 (below).
- Signal tab and the bottom bar: `lib/signal/` (layouts, the 3D head's math, the live signal, the taps, the feed),
  `lib/ui/signal_*.dart`, `lib/ui/head_view.dart`, `lib/ui/home_tabs.dart`; DECISIONS rows 590-599 (below).
- When I put the headband on (automatic recording): `lib/auto/` (rules, worn check, battery guard, the watcher, its
  log, its own engine `task.dart`), `lib/ui/auto_*.dart`, `android/.../AutoWatch.kt`, `AutoWatchService.kt` and
  `HeadbandPresenceService.kt`; DECISIONS rows 600-609 (below).

## Try these

Between nights the main screen's **Try these** section (after Morning) opens one page with each feature's first try,
in order: tonight and the morning (a night with Lights off, how long scoring takes, the report's noise and jaw numbers,
the morning check-in, Export data), another night (smart alarm, Share on Wi-Fi, the headband noticed when you put it on), sessions, the tries that take weeks
(a self-experiment, the replay check, the lucid dream cues, and the assistant's proposals Sharp hours, Memory cues,
Unusual for you and Was this you?, marked as such), our own headband connection when the headband is charged, and the DIY board
(a test, not EEG yet) when the board is built. Each stop says what it is, what to do, opens its screen, lists what to
tell the assistant, and takes a note ("What happened?"); **Done** or **Skip** folds it away and opens the next. "4 of
23 tried" and a row of cells sit at the top.

The app ticks a stop itself when it sees it done (a scored night with Lights off tapped, a scored night, a check-in,
a complete export, the smart alarm rang, a meditation, a nap, a dream catcher session, an answer written out, an
alpha-theta session, a Fall asleep sound session with the headband, an experiment started, the replay check on,
sharp-hours answers on 2 days, lucid dream questions answered, a memory cues morning test, 10 minutes recorded from the DIY board); a stop you
skipped or reopened stays as you left it.

Ticks and notes are kept in `files/try-these/` (`progress.json`, `events.jsonl`; `docs/data-format.md`) and leave the
phone with **Export data**; after `scripts/import_phone.py` the assistant reads them in `_local/phone/try-these/`. The
cards are written by hand from this README's "Owner step" sections (`lib/try_these/cards.dart`):
`test/try_these_test.dart` fails when an owner step has no card, so a new feature's owner step needs one there.

## Build and test

```bash
source ~/.local/share/linsa/env.sh         # Flutter, Android SDK, Java on the owner's laptop
flutter pub get
flutter analyze
flutter test --concurrency=1               # writer, recorder rules (fake headband), screen states
flutter build apk --release --target-platform android-arm64
```

`flutter test` also renders the night screen in six states (two also at the owner's 393 dp width), the meditation
screen in eleven, the sleep report in nine, the replay check's and alpha-theta's pages in nineteen, the dream catcher in thirteen, the nap coach in sixteen, the check-in, trends
and Morning section in eighteen, sound for states in fourteen, Export data in nine, Headband connection in eleven, Try these in seven and "Was this you?" in thirteen
(the sleep report, the check-in's result, Settings; `test/wearer_screens_test.dart`) to `build/screens/*.png`
(normal and 130 % text). `test/own_ble_*_test.dart` run our own connection on a fake
headband: the driver, a night, sessions, the probe and its page. `test/export_test.dart` exports a fake app folder (every place the app writes) and remakes,
with `EXPORT_FIXTURE=write`, the export the laptop importer's test reads (`test/fixtures/phone_export/`).
`test/dream_test.dart` runs whole dream catcher sessions on a fake
headband whose alpha fades and comes back, with a fake microphone. `test/morning_cross_check_test.dart` checks the
check-in's numbers against a fixture made by the laptop's Python (`test/fixtures/make_morning_fixture.py`); with
`MORNING_F32=<check-in .f32> MORNING_JSON=<its .morning.json>` it also runs a whole recorded check-in.
`test/nap_test.dart` runs whole naps the same way with a scripted sleep model (ONNX cannot run in
`flutter test`); `test/live_prep_test.dart` checks the live scorer's input against `analysis/live_stager.py` (fixture
made by `test/fixtures/make_live_fixture.py`), and `tool/live_night.dart` streams a whole recorded night through it.
`test/states_controller_test.dart` runs
sound-for-states sessions the same way, and `test/state_synth_test.dart` checks the made sound (loudness, pulse
edges, the beat in the sound or only between the ears) without an audio device.
`test/wearer_cross_check_test.dart` checks "Was this you?" against `analysis/wearer_check.py` (fixture made by
`analysis/make_wearer_fixture.py` from made-up signals and histories).
`test/replay_headband_test.dart` plays made-up recordings of any layout through the replay headband into the night
recorder and whole work sessions (DECISIONS 730-739); `test/start_log_test.dart` checks `files/app-starts.log`.
`test/heavy_reads_test.dart` counts the files the app opens on the screen's thread (DECISIONS 620-629) on a made-up
folder with 60 days of history (`test/support/app_folder.dart`, `test/support/read_count.dart` wraps every `File` the
code makes): the night screen's lines, the study reminders, "Was this you?", Trends, Try these, the Lucid page and the
nights' list the sleep scoring and the bedtime checks ask for (each file set opened again only when one of its files,
its header included, changed).
Work that reads more than a few KB belongs in a background isolate, and a file shown again and again is read once
(`lib/cache/file_summaries.dart`: newest by name, kept JSON, kept summaries in `files/cache/`).
`test/sleep_prep_test.dart` checks the sleep model's input against a fixture made by the laptop's Python
(`test/fixtures/make_sleep_fixture.py`); `test/night_extras_cross_check_test.dart` checks the night extras against
`analysis/night_extras.py` (fixture made by `analysis/make_extras_fixture.py`), and `tool/night_extras.dart` runs them
over a whole recorded night on the laptop for comparison (docs/detectors.md). The meditation tests stream a synthetic headband through whole
sessions; `test/feedback_cross_check_test.dart` checks the Dart core against a session made by the JavaScript
core (`node app/test/fixtures/make_js_session.mjs` from the repo root remakes it after a change to the JS core).

The first build on the owner's laptop (2026-11-18) took about 5 minutes and fits under
`systemd-run --user --scope -p MemoryMax=4500M`. Release builds work: `flutter build apk --release
--target-platform android-arm64` (39 MB with the sleep model: 18 MB of models, ONNX Runtime's library 11 MB
compressed; 51 MB since the dream catcher's speech engine, DECISIONS row 257; only the named ABI is packaged and native libraries are compressed, `android/app/build.gradle.kts`;
`android/app/proguard-rules.pro` keeps ONNX Runtime's Java classes). The neurosdk2 1.0.21 plugin shrinks its own release build without keep
rules, which stripped its `Neurosdk2Plugin` class; `android/build.gradle.kts` builds that one plugin unshrunk.

## Pre-install check (before every phone install)

One command on a temporary emulator checks what reached the owner's phone on 2026-11-19/20 (DECISIONS 730-739).
Build the candidate (`flutter build apk --release --target-platform android-arm64
-Pkotlin.compiler.execution.strategy=in-process`) and, for (c), its replay build (the same command with
`--dart-define=EEG_REPLAY=true`; never install that one on the phone), then:

```bash
source ~/.local/share/linsa/env.sh
cd app && python3 tool/precheck.py --old <the APK on the phone now> --new build/app/outputs/flutter-apk/app-release.apk \
  [--replay <replay build>] [--adb-port N]     # run it in the heavy build slot: it boots an emulator
```

It makes an AVD under `/var/tmp` (API 36 x86_64 image, **2 cores**: the phone's arm64 APK runs there through Android's
ARM translation, and ONNX Runtime crashes at launch with 4), uses a private adb server (port 5041 or `--adb-port`,
`ADB_LIBUSB=0 ADB_USB=0`) and the emulator's own serial on every call, never the phone or the default adb server, and removes the
AVD, the emulator and its adb server at the end. It prints PASS / FAIL / SKIP:

- **(a) update over yesterday**: the old APK with the phone's finished nights (copies of the reports in
  `_local/phone/nights/` and the recordings they name from `_local/recordings/`, read-only; `--reports`, `--nights`),
  then `adb install -r` of the new one: no night may be scored again, every report stays byte for byte. Catches the
  "old nights scored again after each update" bug (DECISIONS 580).
- **(b) Share on Wi-Fi between nights**: sharing on (More tab), `/state` must answer with the app in front. Then
  Home, Doze forced, standby bucket "rare", past Android's freezer delay: since DECISIONS 678 (no notification, so
  nothing keeps the app running for sharing between nights) the app is a cached process there and need not answer;
  the run only reports it. Once the app is started again `/state` must answer within 2 minutes: a server that stays
  dead (the Share hang of 2026-11-19, DECISIONS 587) fails. On the emulator Android can take minutes to take the
  commands right after it froze the app (its ActivityManager stalls on the translated process); that wait is not
  counted.
- **(b2) Share on Wi-Fi in the background during a work session** (with (c)): the same background steps while the
  replayed work session runs; its service holds the app, so `/state` must answer within 5 s, three times.
- **(c) a replayed noisy work session** (with `--replay`; a SKIP without it): the made-up talking recording through
  the replay headband into a real work session for 6.5 minutes; no break may start by itself, and the saved session
  must name the replay as its headband. Catches the "calibrating, then on break" loop of 2026-11-20 (DECISIONS 680,
  735); the laptop's replay tests check the same with talking from the start and after calibration.
- **(d) crashes, ANRs, exit reasons**: logcat, `/data/anr` and `dumpsys activity exit-info` are kept; a crash or an
  ANR fails, and the app's own `files/app-starts.log` must hold its starts with Android's exit reasons.

Logs and details go to `/var/tmp/eeg-precheck-<time>/out/` (`--out`). About 12 minutes, 30 with (c) on the 2-core AVD.

### The push's own check

`python3 tool/push_smoke.py <release APK> [--work <folder on a disk with room>]` (heavy build slot, about 25
minutes, adb port 5049) pairs a temporary emulator with a receiver on this laptop and checks the phone's own
sending (DECISIONS 849): the spare port, the scheduled job run by Android itself with the app closed, forced
runs, the laptop's own copy beside it, and that no notification is shown. It waits for Android's own run before
it forces any: every run of a periodic job moves Android's next window 15 minutes on.

## Replay headband (test and replay builds only)

`lib/headband/replay.dart` plays a recording in the app's own format (`.f32` plain or packed, `.idx`, the header) into
the app through the same slot the tests' fake headbands use (the finder that hands out a headband): batch by batch
at the recorded arrival times, so drop-outs, talking or the headband off reach the real sessions and the real night
recorder. Any layout: four channels at the BrainBit's sites at 250 Hz play as a BrainBit; any other count, rate or
place plays as another board (the recorder keeps it under its own header, sessions say they need O1 O2 T3 T4).
Laptop tests drive it on a clock of its own (`ReplayPace.virtual`: a working day in seconds;
`test/replay_headband_test.dart`). Made-up recordings only in the repository: `lib/headband/replay_scenarios.dart`
(quiet work, talking, the headband off, drop-outs, the helmet plan's 8 channels at 500 Hz, 3 channels with one at a
custom place); `dart run tool/replay_scenario.dart list` shows them, `... <name|all> <folder>` writes them.

On a device it needs a **replay build** (`--dart-define=EEG_REPLAY=true`; a normal build has no replay code at all)
and `files/replay/plan.json` (only `adb root` can put it there):
`{"files": ["talking/2026-11-20-100000.f32"], "speed": 1, "from_s": 0, "max_gap_s": 60, "loop": false}` with the
files under `files/replay/` (the app's owner and SELinux label, as in step 1 below). Every session and Start night
then use the replay instead of the headband (the DIY board's switch still wins in the night recorder: turn it off);
its name is "Replay (not a headband)" and the night's `.log` says what it plays.

## Emulator smoke test

What `flutter test` cannot reach (ONNX Runtime, SoLoud, the microphone, the folder picker, the foreground service,
NeuroSDK2's native library) runs on an x86_64 Android emulator on the laptop, no phone needed (first run 2026-11-18,
DECISIONS rows 160-161). It found two bugs: Export data could not open (an isolate closure that sent the whole page)
and Android's own files were exported. What it cannot test: the headband (no Bluetooth device), real sound and
microphone (the emulator's host audio is a dummy here), the phone's speed and Xiaomi's background rules.

> **Testing the phone's arm64 release APK? Set `hw.cpu.ncore=2` first.** On an AVD with 4 cores (avdmanager's
> default) the arm64 APK crashes at launch under Android's ARM translation, while ONNX Runtime's library loads
> (a SIGSEGV, fault address 0x8). The same APK, and the very build that runs on the owner's phone, starts and runs
> normally on a 2-core AVD. That crash is the emulator's, not the app's (checked 2026-11-19: the ONNX Runtime library
> is byte-identical across the builds; only the core count differed). The x86_64 build needs no such setting.
> Add the line to the AVD's `config.ini` (by default `~/.android/avd/eeg_smoke.avd/config.ini`) before the first boot:
> `echo 'hw.cpu.ncore=2' >> ~/.android/avd/eeg_smoke.avd/config.ini`.

```bash
source ~/.local/share/linsa/env.sh
export ANDROID_SERIAL=emulator-5554        # always: another device (the phone) may be on USB
# once: an AVD (API 36 google_apis x86_64, 3 GB RAM)
avdmanager create avd -n eeg_smoke -k 'system-images;android-36;google_apis;x86_64' -d pixel_6
echo 'hw.cpu.ncore=2' >> ~/.android/avd/eeg_smoke.avd/config.ini   # needed for the arm64 APK (step 7), see above
# build while the emulator is off (memory), then boot it headless
cd app && systemd-run --user --scope -q -p MemoryMax=4500M flutter build apk --release \
  --target-platform android-x64 -Pkotlin.compiler.execution.strategy=in-process   # R8 + AOT, as on the phone
systemd-run --user --scope -q -p MemoryMax=4500M emulator -avd eeg_smoke -no-window -no-snapshot \
  -no-boot-anim -timezone Europe/Moscow -gpu swiftshader_indirect &
adb wait-for-device; adb install -r build/app/outputs/flutter-apk/app-release.apk
```

1. **A recorded night into the app's private folder** (google_apis images allow `adb root`; copy real files, not
   links, and give them the app's owner and SELinux label, or the app cannot read them):
   `adb root; adb push <night files>/. /data/local/tmp/rec/`, then in `adb shell`: `cp` them into
   `/data/data/io.github.utof.eeg_tracker/files/recordings/`, `chown` to the app's user, and
   `chcon` with the context `ls -Z` shows on that folder. Opening the app scores the night; pull
   `files/nights/<date>.report.json` and compare its `stages` with the laptop's `<date>.sleep.json`.
2. **Every screen**: `python3 tool/emu.py texts` lists what is on screen, `tap "Sleep report" --exact` taps it,
   `find`, `scroll`, `back`, `shot <file>` (Flutter's labels reach Android's accessibility tree). Watch
   `adb logcat --pid=$(adb shell pidof io.github.utof.eeg_tracker)`. A debug build (`--debug`) also reports
   overflows and assertions; `adb shell wm density 440` gives the owner's 11T width (393 dp),
   `adb shell settings put system font_scale 1.3` large text.
3. **The sound engines** (meditation, alpha-theta and the check-in only sound with a headband):
   `flutter build apk --debug --target-platform android-x64 -t tool/sound_smoke.dart`, install, open, then
   `adb logcat | grep SMOKE`: one `SMOKE ok` line per engine. Reinstall the app afterwards.
4. **Export data**: pick or create `Download/EEG` in the picker, export, then
   `adb pull /sdcard/Download/EEG/eeg-export <dir>` and `python3 scripts/import_phone.py <dir> --dest <scratch>`
   (not the real `_local`).
5. **Start night** without a headband: the service starts ("Searching ... The app keeps looking"); Stop ends it.
6. **The live sleep scorer's speed** (the nap coach): `flutter build apk --release --target-platform android-x64
   -t tool/live_bench.dart`, install, open, then `adb logcat | grep BENCH`: the time per 30-second check at 5 to 60
   minutes of window and the peak memory. Reinstall the app afterwards.
7. **The phone's own arm64 APK** also runs on this x86_64 image through Android's ARM translation (slowly: about
   a minute per model part), but **only with `hw.cpu.ncore=2`** in the AVD's `config.ini` (see the warning above): the translator's stand-in
   `/proc/cpuinfo` lists 2 processors, and with 4 cores in sysfs ONNX Runtime's CPU detection (cpuinfo) crashes
   while the library loads, at app start. That crash is the emulator's, not the phone's.
8. **Sessions with the phone locked** (DECISIONS rows 190-197):
   `flutter build apk --debug --target-platform android-x64 -t tool/screen_off_smoke.dart`, install, grant
   `RECORD_AUDIO`, `BLUETOOTH_CONNECT` and `POST_NOTIFICATIONS` with `adb shell pm grant`, open the app, wait for
   `SMOKE sound on` in logcat, then lock: `adb shell input keyevent 26`. Expect a `SMOKE tick` line every 5 s (a
   frozen app would leave a gap), `SMOKE mic ok` with levels above -90 dBFS and `SMOKE night ok`. Meanwhile
   `adb shell dumpsys activity services io.github.utof.eeg_tracker` shows `SessionService` with
   `isForeground=true types=0x00000092`, and `adb shell dumpsys media.audio_flinger` one active track on an
   output thread that is not in standby. In the app itself: **Sound**, **Sound only**, **Start**, lock, and
   `adb shell cmd media_session dispatch stop` ends the session like Stop on the lock screen (`end: stopped` in
   the newest `files/sound-states/*.sound.json`). Reinstall
   the app afterwards.
9. **Share on Wi-Fi** (2026-11-19): switch it on in Your data, read the code from the sheet (`tool/emu.py texts`),
   `adb forward tcp:18765 tcp:8765`, then `curl -H "Authorization: Bearer <code>" http://127.0.0.1:18765/state`
   (401 without the code), `EEG_PHONE_TOKEN=<code> scripts/page_server.py --recorder http://127.0.0.1:18765` and
   `EEG_PHONE_TOKEN=<code> scripts/pull_phone.py http://127.0.0.1:18765 --once --dest <scratch>`; Start night (the
   recorder's service serves, status `reconnecting` without a headband), Stop (the app serves again), switch off
   (the port closes). All of it passed; the emulator cannot show Wi-Fi with the screen off or the battery cost.

10. **The smart alarm inside the night recorder** (DECISIONS rows 230-231): `flutter build apk --release
   --target-platform android-x64 -t tool/alarm_smoke.dart`, install with `-g`, put one recording into
   `files/smoke/` (adb root, the app's owner and SELinux label, as in step 1) and optionally `files/smoke/plan.json`
   (`{"mode": "night", "startInMin": 35, "windowMin": 10, "speed": 2, "skipS": 330}`), open the app, lock the phone
   (`adb shell input keyevent 26`). The real recorder service replays the recording at 2x with the real smart alarm:
   `adb logcat | grep -E 'SMOKE|EegWake'` shows the model's calls from inside the service's engine (time per call,
   stage, the process's memory) every 20 s, then the early ring (`EegWake: ringing (smart)`, the notes, after 3
   minutes `loud`); tap **I'm awake** on the page over the lock screen. With `{"mode": "killed", "endInMin": 2}` it
   only sets the phone's alarm: `adb shell kill -9 $(adb shell pidof io.github.utof.eeg_tracker)`, lock, and the
   alarm must still ring 2 minutes later (`EegWake: ringing (window end)`). Reinstall the app afterwards. The
   scripts used on 2026-11-19 are kept in the lane's `_local/emu/` (not in the repository). With the lucid cues too
   (DECISIONS 330: one live sleep model for both): add `"lucidAfterMin": 3, "lucidModelBeforeMin": 2` and a later
   window (`"startInMin": 70`, `"speed": 1`); the tool switches the cues on with a made-up loudness, their model
   starts a minute in and the alarm's ten minutes in. `adb logcat | grep 'SMOKE scorer'` then says `loads 1 ... used by
   [lucid cues, smart alarm]`, and the night's `.log` (`files/recordings/*.log`) `live sleep model on for the lucid
   cues (load 1 tonight)`, then `live sleep model: shared with the smart alarm (no second copy)`.

11. **The dream catcher's speech to text** (DECISIONS rows 250-257): push a made-up session and its WAVs (the laptop
   check's TTS clips, `_local/stt/check/clips/`, never personal audio) into `files/dream-catcher/` as in step 1, open
   **Dream catcher**, tap **Download (671 MB)** under Answers as text and wait for "Speech model on this phone"; the
   answers are written out at once: `files/dream-catcher/<stamp>-r<n>.text.json` holds the text and `tookS`. Then
   delete `files/nights/*.report.json` and bring the app back to the front: the night is scored again in the same
   process, so both ONNX Runtimes work side by side. On 2026-11-19 (release x86_64 build): the download took about
   100 s and passed its hash check; two Russian and one English answer came out word for word, 0.38 s per second of
   audio (2.0-2.8 s an answer, the model already loaded), the room-hiss answer as "No words heard." in 0.2 s; the
   night scored again afterwards; the app was back to 154 MB (PSS) once the speech isolate had ended.
12. **Connecting by one scan** (DECISIONS rows 530-539; 2026-11-20, the arm64 release APK on a 2-core AVD): on the
   laptop `python3 scripts/phone_link.py --address 10.0.2.2 --phone-at http://127.0.0.1:28765` (the emulator reaches
   the laptop at 10.0.2.2; `adb forward tcp:28765 tcp:8765` for the copy) prints the code's link under the QR code.
   `adb shell am start '<the page's intent:// link>'` (what Chrome hands over) and `adb shell am start -a
   android.intent.action.VIEW -d 'eegtracker://pair?h=10.0.2.2&p=8771&s=<code>&n=<name>'` both opened **Connect to
   this laptop?** in the app's own task; **Not now** sent nothing; **Connect** said **Connected**, the laptop printed
   "Paired" and copied (`_local/phone/link.json`, mode 600, with the phone's token), and its live pages answered from
   the phone. **New code** on the sheet reached the laptop by itself within seconds ("The phone says it is at ..."),
   and the copies went on with the new token; a restart of the app and **Start night** (the recorder's service then
   serves) each told the laptop again; the laptop command run again copied from the remembered phone without a scan.
   The first run found a bug the unit tests had missed: Dart sent the handshake chunked and Python's server read an
   empty body ("The laptop said no"); fixed in `69f5e27`. Not checked here: Chrome opening the page (Chrome hung at
   its first-run screen on the loaded laptop), a real camera, a VPN.

13. **The night's Wi-Fi lines and lock** (2026-11-20, DECISIONS 616): Share on Wi-Fi on, Start night, then
   `adb logcat -s eeg_tracker flutter | grep -i wifi` shows who holds the lock (`wifi lock: recorder on, held for
   [screen, recorder]`) and a `wifi ...` line at every change: `adb shell svc wifi disable` / `enable`, the power
   key, `adb shell dumpsys deviceidle force-idle` (after `dumpsys battery unplug`). `adb shell dumpsys wifi` lists the
   lock under "Locks held". `adb shell settings put global wifi_sleep_policy 0` and battery saver on show the Phone
   section's Wi-Fi rows. All of it passed.

The night of 2026-11-17 (58 recordings, 12.9 h) scored on the emulator in 99 s with a peak of 448 MB (PSS) and the
laptop's stage on every scored epoch (two passes, 2026-11-19; the 1-hour pieces before took 69 s, peaked at 442 MB
and agreed on 96.6 %, measured in the same session; see `assets/models/README.md`). The emulator's speed is the
laptop's, not a phone's.

**The combined app** (`feat/app-line` with the smart alarm, the dream catcher's text, "Unusual for you", two-pass
scoring and sharp hours, 2026-11-19, release x86_64): every screen opened; the same night scored in 93 s and matched the laptop on all
1330 scored epochs; Start night with Share on Wi-Fi on and the smart alarm set searched for the headband, served the
laptop from the recorder's service, set the phone's alarm, took Lights off and Alarm off (the phone's alarm went
away), and Stop ended it; the speech model downloaded in about 95 s and wrote out the three spoken answers word for
word, and the night scored again afterwards with the same stages, both ONNX Runtimes loaded in one process. Sharp
hours switched on armed its questions beside the smart alarm's alarm clock, and a rating from its page was saved. The
emulator refuses to boot ("not enough disk space") when the disk that holds the AVD is nearly full: free space there,
or make an AVD of your own elsewhere (`ANDROID_AVD_HOME=/var/tmp/<name> avdmanager create avd ...`).

**Scoring after an update, and Share on Wi-Fi meanwhile** (`fix/app-scoring-background`, 2026-11-20, release x86_64,
2-core AVD, DECISIONS rows 580-589): with the 12.9-hour night in the app and Share on Wi-Fi on, the scoring started 49 s
after the app opened (Share answered from 4 s); `adb install -r` of the same APK after 8 of 78 model calls ended the
app like an update, and the next start said "Preparing the recording to go on from 10 %" and made only the other 70;
the report matched the laptop on all 1330 scored epochs; a restart scored nothing. `/state` answered every 2 s
throughout in at most 0.16 s; the first `/files` hashed 215 MB in 10 s, later ones (also after the update) took
0.01-0.05 s. With sharing on and the app in the background, `dumpsys activity processes` showed it as a foreground
service (`curProcState=4`), and the server answered. Check `adb logcat -s flutter` for the lines `sleep scoring of
<night>: starting / going on at N of M model calls / done, ...`. The scripts are in the lane's `_local/emu/`.

**With the lucid dream cues** (second integration, 2026-11-19, release x86_64): the Lucid dreams page opened from
the night screen, **Turn on** started the evening practice (the cue every 3 s, a little louder each time: "Cue 6,
0.6 % of the media volume") and Stop kept the cues waiting for a loudness. The alarm smoke tool with the cues on
(step 10) replayed a recorded night through the real recorder service: the cues opened the live model at 09:24, the
smart alarm joined it at 09:33 (`live sleep model: shared with the smart alarm (no second copy)`), and the service
reported `loads 1 ... used by [lucid cues, smart alarm]`: one model for both, about 0.6 s a call with 3 runs, the
process at about 330 MB (RSS). No app errors in logcat. The speech-model download was not repeated.

**The DIY board** (`feat/app-diy-board`, 2026-11-19, release x86_64, DECISIONS rows 360-369): the console's
`adb emu redir add udp:9000:9000` does not reach the guest's `wlan0` on the API 36 image, so the frames are sent from
inside: frames from the fake board's encoder (`fake_board.encode` in `tests/fake_diy/fake_board.py`, consecutive
sequence numbers) into a file, `adb push` it to `/data/local/tmp/frames.bin`, **DIY board (test)** on Headband
connection, **Start night**, then `adb shell 'i=0; (while [ $i -lt 600 ]; do dd if=/data/local/tmp/frames.bin bs=37
skip=$i count=1 2>/dev/null; sleep 0.02; i=$((i+1)); done) | nc -u -q 1 10.0.2.16 9000'` (10.0.2.16: the address the
page shows). With Bluetooth's permissions revoked first (`adb shell pm revoke io.github.utof.eeg_tracker
android.permission.BLUETOOTH_CONNECT`, and `BLUETOOTH_SCAN`) the night started, the screen read "Recording the board's
test signal. It is not EEG." with 3750 µV on every channel and the alarm line "the sleep model is off", and after Stop
(`adb root`, `adb pull .../files/recordings-diy`) all 600 frames were in the `.f32`, in order, scaled as on the laptop.
The emulator's OpenThread simulator holds UDP 9000 on a multicast address, so the `.log`'s link line says the port is
shared.

**Study reminders, the night pipeline fixes** (sixth integration, 2026-11-19, the arm64 release APK on the x86_64
image, `hw.cpu.ncore=2`): Settings shows Study reminders and "Was this you?". With Sharp hours on (6 a day) and the
study reminders on, the phone's one plan (`shared_prefs/sharp_hours.xml`, `plan`) held sharp questions (`s`), evening
(`e`) and morning (`m`) reminders together. An evening time set by hand a few minutes ahead (Change, then the
picker's text input) rang on time: the `study_review` notification "Good time to learn something you want to keep",
`files/study-review/prompts.jsonl` `shown`, and the next alarm armed was the next sharp question. Tapping it opened
"Did you study something tonight?"; **Yes** wrote the answer to `files/study-review/log.jsonl`. A BrainBit Start night
without a headband searched (a 31 s scan every 41 s), Share on Wi-Fi switched off and on three times within seconds
left one server answering for the recorder (`ss -ltn`: one listener pair on 8765), Stop (and its confirmation) ended
the service, the app's own server took over, and switching Share off freed the port. **Once, in the first of three
nights** (about 3 minutes in, right after the Share toggles), BrainBit's library blocked the app's main thread inside
`Scanner.getSensors` (native, under the ARM translation) for good: the app showed "isn't responding", Stop could not
be tapped, and the recorder's own 90 s scan timeout never fired, since with Flutter's merged platform and UI threads
(3.47, the default) every Dart isolate of the process waits on that thread too. Two later nights (7 minutes each, one
with the same toggles) and one on the previous head did not hang. Fixed on `fix/app-sdk-main-thread` (below).

**BrainBit's calls off the main thread** (`fix/app-sdk-main-thread`, 2026-11-19, DECISIONS rows 410-414): the app uses a
copy of the plugin (`packages/neurosdk2/`, every change listed in its `VENDORED.md`) whose synchronous calls and scan
results run on a thread of its own, `neurosdk2-calls`. Flutter 3.47 cannot switch the merged threads off on Android
(the engine aborts on `MergedPlatformUIThread=disabled`). The hang itself is inside BrainBit's library and can be
brought on: during a night without a headband, `adb root`, then `adb shell kill -10 <pid>` every 3 s (ART answers
SIGUSR1 with a garbage collection) and, for more, three busy loops in `adb shell` (`sh -c "while :; do :; done"`).
`adb shell kill -3 <pid>` writes every thread's stack to `/data/anr/trace_NN`: a `neurosdk2` frame under `"main"` is
the freeze; under `pool-N-thread-M` or `neurosdk2-calls` it is the kind the recorder survives. What it showed (arm64
APKs under the ARM translation, x86_64 API 36 image):

- the integration's APK (`dda9ba2`, plugin as published): hangs in `Scanner.freeScanner` (`pthread_join` on the
  library's own scan thread, which never ends), `startScanner` and `createScanner`, on the first close in 3 of 3
  processes right after a fresh boot, then once in 8 scans, and 3 times in 8 minutes with the busy loops. Each was on
  the plugin's pool, so the main thread stayed free and the recorder's 90 s deadline restarted the process
  (`exited cleanly (3)`), as DECISIONS row 50 planned; the integration's one happened to be the main thread's
  `getSensors`, which froze everything. Without forced collections, 7 scans in a row were clean.
- the fixed APK (`d191e17`): no hang in 13 scans with the forced collections (after Share on Wi-Fi switched on and
  off five times); with the busy loops too, `freeScanner` hung once in 12 minutes (the 8th close), the main thread and
  `neurosdk2-calls` stayed idle, a volume key sent every 35 s never gave an ANR, the recorder restarted the process
  2.5 minutes later and the scans went on. Stop ended the service.
- BrainBit's x86_64 library (no translation), original plugin (an older x86_64 build, `8ea4fad`) and the fix: no hang
  in about 11 and 15 scans with the forced collections. So the hang has only been seen with the arm64 library under
  the emulator's translator: most likely the translator's doing; a phone (arm64, no translator) cannot be tried here.
  Either way a hang there is now a stall the recorder ends, not a frozen app.

12. **When I put the headband on** (DECISIONS rows 600-609; a **debug** build: only it has the fake "headband came
   near"): `flutter build apk --debug --target-platform android-x64`, install with `-g`, and allow background starts the
   way the owner's fallback does (`adb shell dumpsys deviceidle whitelist +io.github.utof.eeg_tracker`; the emulator
   has no companion pairing). Open Settings, **When I put the headband on**. Put "now" inside the bedtime window
   (`run-as io.github.utof.eeg_tracker` and write `files/auto-start/settings.json` with `bed_min` an hour ahead), press
   Home, then `adb shell am broadcast -n io.github.utof.eeg_tracker/.AutoDebugReceiver -a
   io.github.utof.eeg_tracker.auto.DEBUG_PRESENCE --es fake worn` (`--es fake off` for a headband off the head,
   `--ez force true` for a check past the quiet time). Within seconds the quiet notification "Headband on. Start the
   night?" shows; **Not now** must leave `files/recordings/` empty, and **Start the night** must leave one run of the
   simulated minutes (its `.log` begins `auto-start: the headband was found on`) and the recorder's notification
   ("Looking for the headband"). `files/auto-start/log.jsonl` has every step. First run 2026-11-20 (`0b92c6f`,
   API 36 x86_64, `hw.cpu.ncore=2`): the app-opened check searched and found nothing, the fake presence asked within
   13 s, Not now wrote nothing, a forced check with the headband off logged `worn: false`, and Start the night saved
   20 s (4,960 samples) as `2026-11-20-032859` and started the recorder from the watcher's own engine. The first try
   found that engine could not start (its entry point sat outside the libraries main reaches); it now sits in
   `main.dart`.

The plugin's JVM tests: `cd android && ./gradlew :neurosdk2:testDebugUnitTest` after one `flutter build apk`.

**The rest of the night pipeline review and BrainBit's calls off the main thread together** (seventh integration,
2026-11-19, the arm64 release APK of `aa96f98` on the x86_64 API 36 image, `hw.cpu.ncore=2`): a BrainBit Start night
without a headband, with Lights off tapped over and over from the moment of Start, kept the first tap: the saved night
(`FlutterSharedPreferences.xml`, `prefs.night`) had `lightsOffMs` at the tap, 1.2 s after the recorder began the
night, and the screen read "Lights off 16:26." with "Lights off again". The recorder was already up 0.35 s after
Start, before the screen showed Lights off, so the screen could not reach the queued path itself (the tests do). The
process had the plugin's `neurosdk2-calls` thread, searched for 3.5 minutes (6 scans) in one process with no "isn't
responding", and Stop ended the service and the night (`active: false`, `lightsOffMs` kept).

## Meditate

1. Make sure no night is being recorded (the headband talks to one thing at a time). Put the headband on and
   switch it on. Use wired headphones or the phone's speaker: Bluetooth headphones add about 0.25-0.5 s, so the
   sound comes late. When the sound goes to Bluetooth headphones, the screen says so in amber, before and during
   the session, and the session file keeps where the sound went; you can still go on.
2. On the main screen scroll to **Meditation** and tap **Meditate**. Pick 5, 10 or 20 minutes and tap
   **Start meditation**.
3. The app finds the headband and checks contact (keep still a few seconds).
4. Calibration, 1½ minutes in silence: look at the green dot with your eyes open for 30 s; at the low tone close
   your eyes and relax for 60 s (longer if the signal was not quiet enough: keep the jaw loose).
5. A second tone and the sound starts: rain, wind and a low drone. When the alpha rhythm at the back of your head
   rises above your own line, the rain softens and the drone warms; stay there a few seconds and a bell rings
   (at most 6 a minute). A tight jaw, blinks or drifting toward sleep pause the bells. Nothing to do: just notice.
   The screen stays on. You can lock the phone with the power button: the session goes on, and **Stop** is on
   the lock screen (see "Sessions with the phone locked").
6. A third tone, and the sound fades out for **2 silent minutes** while the headband keeps measuring: go on the
   same way, eyes closed ("Without sound" on the screen). Can you reach the state without the sound? A last tone
   ends the session. The report shows minutes settled, bells, restless moments (jaw, blinks, movement), drifting
   moments, a line of how calm the sound was, how this session compares with earlier ones (a range from the 4th
   session), **Alpha without sound** (alpha in the silent minutes against the silent minute before the sound),
   and **Learning**: from the 8th session with the silent minutes, whether that number is going up across
   sessions, with its 90 % range (checked again at 12, then every 12). **Stop** ends early and keeps what there
   was (not during calibration); stopped before the silent minutes, the session does not count for Learning.

The **i** button shows what the research says (`docs/evidence/meditation-feedback.md`): a guided practice, not
a treatment, and no "meditation depth" is measured. Each session is kept in the app's private folder,
`files/meditations/<time>.meditation.json` (the summary) and `<time>.session.json` (every sample and decision,
in the laptop page's session format, so it can be replayed). **Export data** copies them out (below). Both are
written every minute while the session runs (the summary then says `"end": "running"`) and once more at the end,
before the sound fades, so a closed app or a crash loses at most the last minute.

If the headband drops out, the countdown pauses ("No signal") and the app reconnects by itself. After 5 minutes
with no signal at all, or at the length + the silent minutes + 20 minutes from Start, the session ends by itself
and the report says so; a calibration still short of quiet signal after 10 minutes ends the session too (nothing is
saved). The same holds for alpha-theta.

### Owner step: the silent minutes and the Bluetooth note (one session, about 15 minutes)

Nothing of this has run on a phone yet: not the route reading, not the tone before the silent minutes.

1. If you have Bluetooth headphones, connect them, then open **Meditation**: under Before you start an amber
   line should name them and say the sound comes 0.25-0.5 s late. Disconnect them: within a few seconds the
   usual headphones line should be back.
2. Wired headphones or the speaker, 10 minutes, **Start meditation**. After the 10 minutes a tone, the sound
   fades: go on the same way, eyes closed. After 2 minutes a last tone.
3. Read the report: **Alpha without sound** under This session, and **Learning** ("Not enough sessions yet: 1 of
   8").
4. Tell the assistant:
   - Did the amber line come and go with the headphones, with their name?
   - Was the tone before the silent minutes clear? Were 2 minutes fine, or too long?
   - The number beside Alpha without sound.

### Owner step: eight meditations, then the first learning verdict (a few weeks)

1. Meditate as usual, at least 8 times to the end (the silent minutes count; a session stopped before them does
   not). Wired headphones or the speaker when you can.
2. After the 8th, **Learning** in the report says going up, no clear trend, or going down, with its 90 % range. It
   is checked again at 12. It is "seen together, not tested": with the replay check on, its results say whether
   the live sound itself made the difference.
3. Tell the assistant the Learning sentences after the 8th and the 12th session, and anything that changed in
   those weeks (sleep, time of day, how the headband sat).

## Sleep report

After **Stop** the app scores the night on the phone (AnySleep, the laptop's sleep model, three runs; DECISIONS
rows 95-99). The main screen then shows last night's time asleep under the strip; **Sleep report** opens the
night: time asleep and time not recorded, a chart of the stages on the clock (missing data hatched amber, sleep
periods numbered), each period's start and end, deep, dream and light sleep, wake-ups over 5 minutes and missing
minutes, and the past nights. It is a first guess: the model is not validated on this headband (the **i** button
shows `docs/evidence/sleep-scoring.md`).

**Same stages as the laptop (since 2026-11-19).** To keep memory low the phone feeds the model about an hour of the
night at a time. AnySleep weighs its four electrodes by how they look over everything it is given, so an hour alone
weighed them a little differently from the laptop's one pass over the whole night (96.6 % of 30-second stretches
the same). Now each of the three runs goes over the night twice: first it adds up, hour by hour, what that weighing
needs for the whole night; then it scores every hour with the whole night's weighing. The hours also start and end
on an 8-minute grid, which the model's own halving of the signal needs. On the three recorded nights the phone now
gives the laptop's stage for every scored 30 seconds, and the same totals (night of 2026-11-17: asleep 387 min,
deep 42.5, dream 114; before 382.5, 42 and 105.5). The model takes longer (laptop: 30 instead of 17 s for a 12.9-hour night; emulator:
the whole scoring 99 instead of 69 s); memory per hour is the same. Details: DECISIONS rows 260-264,
`analysis/two_pass.py`. (Until 2026-11-20 every night the phone had scored before this change was scored again after
the update; no longer, see below.)

**After an app update (since 2026-11-20, DECISIONS rows 580-589).** A night that has its report is never scored again
by itself, whatever the update: only new data for that night (10+ minutes more, a file gone) scores it again. A
report from an earlier version of the scorer stays as it is; at the bottom of its page the app says "An earlier
version of the app scored this night" with **Score again**, which takes a few minutes and gives the current model's
stages. What you see:

- After an update (or after Android closed the app) while a night was being scored: about 45 seconds after you open
  the app, the Sleep section says "Scoring the night of ...: Preparing the recording to go on from 40 %", then
  "Sleep model 40 % (run 2 of 3)" and on from there. Nothing done before is done again except the preparation
  (a minute or two). The percentage counts the model's steps.
- The scoring always waits about 45 seconds after the app opens or comes back, so the screen and Share on Wi-Fi
  answer first. It stops when you press **Start night** or start a session (meditation, check-in, work session, nap,
  ...), and goes on after them from where it was. While the laptop copies files over Share on Wi-Fi it says
  "Waiting while the laptop copies files" and goes on after.
- "Scoring this night stopped before it finished" with **Try again** now appears only when the app closed three times
  in a row before the model's first step (most likely memory), or when the scoring failed with a reason; **Try
  again** goes on from the saved progress.
- The first words say why a night is scored: "Preparing the recording" (no report yet), "...: new data since its
  report" (10+ minutes more), "... to go on from 40 %" (after an update or a close), "... to score it again" (your
  Score again). Never because the app was updated.
- On the night of Wed 18 Nov (2026-11-19) the phone scored the 10.4 h night in 46 s; that was not what kept Share on
  Wi-Fi from answering afterwards (see Share on Wi-Fi).

The night extras come from the shared detectors (`lib/detectors/`), run over the same samples in a second background
isolate after the model (one heavy step at a time, DECISIONS row 583): the note under the totals says how much of your sleep was read through noise; a
**Signal** line under the chart marks noisy stretches (amber dots) and stretches with no usable electrode (solid
amber); **Jaw and movement** gives jaw-muscle bursts and movements per hour asleep with the earlier nights' jaw numbers
(a trend, not a teeth-grinding test; its **i** shows `docs/evidence/jaw-and-blinks.md`) and the night hour by hour;
the past nights show "jaw N an hour". If that pass fails, the report is still there without them. It also runs when the app is opened between nights, for any night whose
report is missing or 10+ minutes behind, and never while a night records.

- Code: `lib/sleep/` (preparation as `scripts/score_sleep.py`, the model, sleep periods as
  `scripts/sleep_report.py`, the night extras as `analysis/night_extras.py`, the report file),
  `lib/ui/sleep_*.dart`. Models: `assets/models/` (see its README
  for how they were made and checked). Reports: `files/nights/<date>.report.json` (`docs/data-format.md`).
- If the app closes while scoring (an update, Android), the scoring goes on from its last saved step the next time
  the app is open (`files/cache/scoring/<night>.progress`, never exported); after three closes in a row before the
  model's first step, or a failure, the main screen says so and offers **Try again** (DECISIONS rows 581-582).
- ONNX Runtime cannot run inside `flutter test`, so the models are checked in Python:
  `uv run --project analysis --group onnx --with pytest pytest analysis/tests/test_anysleep_onnx.py` (from the
  repo root), and on a recorded night with `scripts/export_anysleep_onnx.py --check-only --night ...`.

### Owner step: how long does the phone take? (once, about 15 minutes)

Nothing about the phone's speed or memory has been measured yet. On the laptop a 12.9-hour night took 17 s to
prepare and 30 s for the model (two passes); a phone is likely 3-10 times slower.

1. Record a night as usual (or use the first real one). In the morning press **Stop** and leave the app open on
   the main screen, phone on the charger or not (write down which).
2. Note the clock time. After about 45 seconds the Sleep section says "Scoring the night of ...: Preparing the
   recording", then "Sleep model 0 % (run 1 of 3)" up to "Sleep model 97 % (run 3 of 3)", then "Counting jaw,
   movement and signal" (the detectors' pass, after the model).
3. When the time asleep appears, note the clock time again; open **Sleep report**: the line at the bottom says
   "Scored on this phone in ..." (that is the measured working time, over every go if the app was closed in
   between). Note how long "Counting jaw, movement and signal" showed.
4. Tell the assistant: hours recorded, the time it took, and whether the phone got warm or the app closed. If it
   says scoring stopped, tap **Try again** once and report what happens. With USB debugging on, also send
   `adb shell dumpsys meminfo io.github.utof.eeg_tracker | head -40` taken during "Sleep model, run 2 of 3".

### Owner step: the night extras (the next morning, 2 minutes)

1. Open **Sleep report** after the night is scored. Read the note under the totals: how much of your sleep was read
   through noise. Under the chart, the **Signal** line: do the amber stretches fall where you remember turning over,
   touching the headband or lying on it?
2. Scroll to **Jaw and movement**: jaw-muscle bursts and movements an hour asleep. On the laptop's copy of your first
   night they were about 23 and 19. Is a night you slept badly higher?
3. Tell the assistant the two numbers, the noise share, and anything that looks wrong in **Hour by hour** (for
   example an hour you were awake and talking with no jaw bursts). The setup test's 5 clenches will check the jaw
   limits.

## Pulse (heart rate from the headband; an experiment)

The headband has no pulse sensor, but each heartbeat moves the head and the skin under the electrodes a little (the
temple artery runs under T3 and T4; the back of the head presses on the pillow), and that leaves a slow wave at your
heart rate in the signal. After a recording ends, the app looks for it every 30 seconds on every electrode the recording
has (any number, any layout) and reads it where it shows: a red **Pulse** line in its own lane under the **Sleep
report**'s chart and under the recording's timeline in the **Archive**, drawn only where there is a reading, with gaps
everywhere else. The sleep report adds one line, "Pulse while asleep: about X/min (read in Y % of the night)", the
lowest 5 minutes and an **i** (`docs/evidence/pulse.md`); **Trends** gets **Pulse while asleep** night by night against
your usual (an arrow only from 14 nights, and only for a change of 5 a minute or more). It runs once per recording in
the background (when the sleep report, the recording's page or the Archive opens), never while a night or a session
records, and the result stays after the raw signal moves to the laptop (`files/pulse/<recording>.pulse.json`,
`docs/data-format.md`).

It is an experiment: no study has checked heart rate from EEG electrodes on a headband, and this method was tried on
three of the owner's recordings only, with no watch to compare: it read the pulse in 29 % of the time asleep of the nap
of 2026-11-20 (about 56 a minute), 22 % of the night of 2026-11-19 and 16 % of the night of 2026-11-17 (about 55 both),
and never during the 2 hours of the walk of 2026-11-20. It says "no reading" while you move, walk or talk, in most
deep sleep (the slow brain waves cover it), and whenever the rhythm looks like steps or is not clear. A pulse under 42 or
over 120 a minute is outside what it looks for.

On the laptop, `scripts/compare_pulse.py` runs the same detector (`analysis/pulse.py`, the phone's twin) on a night's
BDF, a recording's `.f32` files or the phone's pulse file, and compares it with a watch's heart-rate export (Health
Connect's "Export data", Mi Fitness's data copy, Samsung Health's "Download personal data", Garmin's FIT files through
the FIT SDK's FitCSVTool, Apple Health's `export.xml`, Fitbit's Takeout files, or any CSV with a time and a bpm column):
the bias, the 95 % limits of agreement, the mean difference and the share of half minutes within 5 a minute.

```
uv run --project analysis python scripts/compare_pulse.py _local/nights/2026-11-21.bdf \
    --stages _local/nights/2026-11-21.sleep.json --reference _local/watch/heart_rate.csv
```

### Owner step: a night with a watch on (a night, then 10 minutes)

1. Wear a watch that records heart rate through the night (a friend's will do) together with the headband; **Start
   night** as usual.
2. In the morning, once the night is scored, open **Sleep report**: the red **Pulse** lane under the chart and the line
   "Pulse while asleep" (it appears a minute after the report).
3. Open the night in the **Archive** (**More** → **Open the archive**): the same Pulse lane under the timeline.
4. Export the watch's heart rate from its app (Health Connect, Mi Fitness, Samsung Health, Garmin, or a CSV) and put
   the file in the laptop's `_local/` folder.
5. Tell the assistant: the "Pulse while asleep" line and the lowest 5 minutes; the watch's own number for the night
   (its sleeping or resting heart rate) and which app the export came from; anything odd (a pulse line where you were
   moving, or none all night). The assistant runs `scripts/compare_pulse.py` with the export.

## Sleep so far

While a night records, the Night tab has **Sleep so far** under the Tonight strip: one line with what the last look
found ("At the last look: 3 h 37 min asleep by 03:28.") and **See sleep so far**. Its page shows the night up to 2
minutes behind the recording: the chart as in the sleep report, asleep so far and when you fell asleep (the first
sleep period's start), then deep, dream, light, awake in between and the wake-ups over 5 minutes. It is marked as
"so far": after **Stop** the whole night is scored together, which can move some edges between stages, so the
report may differ slightly (DECISIONS rows 640-648). On the night of 2026-11-19/20, replayed on the emulator, the
looks matched the report on 96 % of 30-second stretches; asleep 288 vs 288.5 minutes, deep 67.5 vs 66.5.

- **Nothing scores until you open it.** The page scores only what is new since the last look (each hour of the night
  is scored once, in an 80-minute window of its own, and kept), then looks again every 15 minutes while it is open
  and when you come back to it; never with the screen off. The line at the top says what it does ("Scoring 02:14 to
  03:12 (2 of 2).") and has **Update**.
- **The report after Stop is still scored from the whole night**, exactly as before; Sleep so far changes nothing in
  it. It cannot reuse the looks: the sleep model weighs the night as a whole, so every number before Stop would move
  after it. A finished night's so-far data is removed.
- **With the smart alarm or the sound cues running their own live sleep model** the page waits ("Waiting: the live
  sleep model runs for the smart alarm."), so two models never compete for the phone's memory while the recording
  runs; meanwhile the live model's own readings fill in the chart, and the page says how many minutes are theirs.
- A dropout and reconnect (a new file set, as on 2026-11-20 at 08:15) shows as hatched "no data"; the hours before it
  are not scored again. The DIY board's nights have no sleep so far (the page says why).
- Files: `files/cache/so-far/<night>.json` and `files/cache/live-stages/` (never exported; `docs/data-format.md`).

### Owner step: one look in the night (1 minute, one night)

1. Some night when you wake anyway (or before you get up), open the app while it still records. Under **Tonight**,
   tap **See sleep so far**.
2. Wait for the line at the top to say "Scored up to ..." (the first look late in a night takes the longest; note
   about how long). Does the chart look like your night so far?
3. In the morning press **Stop** as usual and open **Sleep report** once it is scored. Compare the asleep total and
   the chart with what you saw in the night.
4. Tell the assistant: what time you looked, how long the first look took, whether the phone got warm, and how far the
   night's report differed from the look.

## Lights off and falling asleep

While a night records, the bar at the bottom of the main screen has **Lights off** beside **Stop** (DECISIONS
180-186). Tap it as you close your eyes to sleep. It marks that moment in the night's recording and starts the
drift-off detector (the back-of-head alpha rhythm fading for 3 minutes, `docs/detectors.md`) from there. The line above
the buttons says what the detector thinks: "Learning your eyes-closed alpha (a minute)", then awake, drowsy, or
"Asleep since 23:51, by the detector". If you get up and come back, tap **Lights off again** (it asks first, so a
3 a.m. brush does not move the moment). Without a tap the night counts from its start.

The detector runs inside the recorder, on the samples it already saves; if it ever fails or takes too much time it
switches itself off and the recording goes on (the night's `.log` says so in one line). The last lines of the `.log`
give its cost: `drift-off detector: <s> s of work for <h> h of signal (<s> s an hour)`.

In the morning the sleep report has **Falling asleep** after the sleep periods: the minutes from lights off to sleep
by the detector and by the sleep model, whether they agree (within 5 minutes), and the check: the detector is
trusted once 4 of 5 nights with Lights off agree. Its **i** shows the drift-off note (`docs/evidence/dream-catcher.md`).
Both are guesses, so the check shows that they agree, not that either is right. Nights recorded before this change get
the same comparison (counted from their start, or from a dream catcher's lights off): after installing this version
the app scores each night it already has once more, between nights, which takes the same few minutes a night as
before. The laptop's sleep report writes the same.

Checked on the emulator (x64 release build, 2026-11-19): Start night without a headband, Lights off (the line
became "Lights off 02:20." and the button "Lights off again"), the question on a second tap, Stop; and a 2-hour piece
of the owner's recorded night with a `lights off` marker at 03:12, scored on the phone side in 54 s: detector 4½ min,
sleep model 3 min after lights off, agreeing. The headband, the phone's speed and a whole night still need the phone.

- Code: `lib/recorder/live_drift.dart` (live), `lib/sleep/drift.dart` (the morning's comparison and the check),
  `lib/ui/lights_off_view.dart`; Python `analysis/night_drift.py`. `tool/live_drift.dart` replays a recorded night
  through the live detector on the laptop (cost per hour, live against the morning; `docs/detectors.md`).

### Owner step: tonight and the next four nights (a few seconds a night)

1. Start the night as usual. Lie down; when you close your eyes to sleep, tap **Lights off** (bottom left). The line
   above it should say "Lights off 23:42. Learning your eyes-closed alpha". Keep your eyes closed.
2. If you glance at the phone later, the line says what the detector thinks (awake, drowsy, or asleep since when).
   Got up? Tap **Lights off again** when you lie back down.
3. In the morning press **Stop**, wait for the report, open **Sleep report** and scroll to **Falling asleep**: do the
   two numbers feel right? Tell the assistant both, and the last `drift-off detector:` line of the night's `.log` (in
   the export, or ask the assistant to pull it).
4. After five such nights the check line says whether the detector can be trusted (4 of 5 within 5 minutes).

## Morning check-in

About 6 minutes after waking, between nights (the headband talks to one thing at a time). The phone does what the
laptop's morning page did and works the numbers out itself, the same way (DECISIONS rows 120-129).

1. Stop the night first. Headband on, switched on; sit comfortably, sound on. Start says so if the media volume is
   off or low, or if the tones would go to Bluetooth headphones: the tone to open your eyes must be heard.
2. On the main screen, **Morning** section: **Morning check-in**, then **Check contact**. Each electrode gets a word
   (good, fair, noisy, not touching). The back two (O1, O2) matter most: part the hair, press, sit still, **Check
   contact again** if needed. Then **Start: eyes closed**.
3. A low tone: eyes closed for 2 minutes (the screen goes dim). A rising pair of tones: look at the dot for 2
   minutes. A last tone ends the recording. Without signal the countdown waits and says so. **Stop** keeps nothing.
   You may lock the phone (a notification with **Stop** keeps it going). A phone call or another app's sound
   stops the check-in and keeps nothing, as a drop does: start again when it is quiet.
4. The questions: sleepiness (1-9, the words of each step shown), mood, tension, **How did you sleep?** (one
   optional tap, 1 very badly to 5 very well; Save does not wait for it), yesterday's cups of coffee or
   strong tea (and whether one came in the 8 hours before sleep), drinks of alcohol, caffeine this morning. Then,
   if you like, the 1-minute reaction test (tap when the green dot appears). **Save**.
5. This morning's numbers, each beside yesterday's and your usual (from 7 days), with an arrow and words only when
   a number is beyond your normal spread (from 14 days). **See trends** opens the trends page.

Kept in `files/mornings/` (the result in the laptop's format, and the raw signal with the page's markers;
`docs/data-format.md`); **Export data** copies them out. The **i** button shows `docs/evidence/morning-check-in.md`.

## Trends

**Trends** (Morning section, or after a check-in) shows today's entry: last night's sleep (time asleep, minutes of
light, deep and dream sleep, wake-ups, time to fall asleep after Lights off, sleep efficiency, and sleep regularity
over the last 7 nights; from the sleep model, not yet checked against a lab test on this headband, nights marked
"someone else" or mostly noise left out, DECISIONS rows 650-659), the morning's numbers (with your "How did you
sleep?" tap), practice minutes, coffee and alcohol, each with yesterday's value and your usual; then sleep pressure, an estimate
from your sleep times ("like 9 hours awake after a regular night", with a 36-hour curve); the last 14 days as
small lines; the earlier days; and tomorrow's sleepiness forecast, which stays hidden until 60 mornings are rated
and it beats "same as yesterday" by 5 %. With a few days, the page says what is still missing. The **i** button
shows `docs/evidence/trends.md`.

### Owner step: the first phone check-ins (about 10 minutes, the next two mornings)

Nothing of this has run on the phone yet; the numbers were checked against the laptop on the recorded check-in of
2026-11-18 (the same to the last digit).

1. In the morning, Stop the night, wait for the sleep report (or not), then do a **Morning check-in** as above.
2. Notice: did the tones play and were they soft enough; did the screen stay on and dim with the eyes closed; did
   the contact words match what you felt (try lifting O1 a moment: it should say "not touching" or "noisy"); did
   the countdown ever wait for the signal.
3. After Save: the numbers should be close to the laptop's from your first check-in (alpha speed about 9.6 Hz,
   eyes-closed rise about 2.6x); a very different alpha speed means contact was poor.
4. Open **Trends**: last night's sleep, the check-in's numbers and the sleep pressure should be there, with "usual
   after N more days".
5. Tell the assistant what felt wrong or slow. If the app closed or stalled, note at which step.

## Unusual for you (on unless you switch it off)

The assistant's proposal from the research, not one of your own wishes: switch it off with the switch beside its
heading on the Trends page, and nothing more is noted. It compares your sleep length, sleepiness, mood, tension,
reaction time and, if you use Sharp hours, the day's average sharpness and reaction time with your own usual (the middle of the 28 days with a number that end a week before). When one of
them has been well outside it on 2 days in a row, the Trends page leads with one sentence, such as "Your sleep has
been 2 h shorter than usual for 2 nights", and the main screen's Morning section shows the same line. It says your
numbers moved, not why: it often follows a late night, alcohol, travel, stress, hard exercise, a vaccine or the
start of a cold, and it is never a diagnosis (DECISIONS rows 290-299; the **i** shows
`docs/evidence/unusual-for-you.md`).

- **Silent for the first 28 days with a number**: "Learning your usual: N of 28 days". Meanwhile it only notes what
  it would have said; afterwards it tells you how often that was.
- **No notifications**, and nothing while a night records. Sleep length counts both ways; the ratings, the
  reaction tests and the Sharp-hours day numbers only the way that means strain (less sharp, slower). The headband's own numbers (alpha, the eyes-closed rise, jaw
  bursts) are noted but never make a card: no study shows they warn of anything.
- Under a card, **What might explain it?** chips are for your own record. **Feeling ill** pauses the card for two
  weeks and keeps those days out of your usual (**Resume now** ends it). "Back in your usual range" follows a card
  for 3 days.
- On made-up people it gave about one false card every 6 weeks and found about 7 in 10 cold-like or low-mood weeks;
  smaller changes, such as a cold's 20-40 minutes of lost sleep, are usually missed.

Files, app-private, exported by Export data: `files/unusual/settings.json` (the switch), `events.jsonl` (switch,
causes, resume) and `log.jsonl` (one line per finished day: what it said or would have said, with and without the
headband's numbers; `docs/data-format.md`).

### Owner step: nothing to do for 4 weeks, then one look (1 minute)

Nothing of this has run on the phone yet, and it has never seen your numbers.

1. Record nights and do the morning check-in as usual. Open **Trends** now and then: under "Unusual for you" the
   count should climb ("Learning your usual: 5 of 28 days").
2. After 28 days with a number it switches on. If a card appears, read it, tap what might explain it (or nothing),
   and tell the assistant whether it matched how you felt and whether the words were calm enough.
3. If it ever feels more worrying than useful, switch it off beside its heading, and say so: the assistant then
   turns it off by default.
4. Export data as usual: the log travels with it, and after a few months the laptop can count its cards against
   your own days.

## Was this you? (on unless you switch it off)

The assistant's proposal from the research, not one of your own wishes: switch it off in **Settings** (the gear on the
main screen), beside its heading, and nothing more is checked or asked. It learns roughly what your eyes-closed alpha
looks like at the back of the head (its speed, its strength and the slope of the background signal) and asks when a
later recording looks clearly different, so a borrowed headband does not end up in your trends (DECISIONS rows
370-379; the **i** shows `docs/evidence/was-this-you.md`).

- **Silent while it learns**: check-ins and nights apart, until 10 of a kind on 5 different days. The check-in's
  result and the sleep report say "Learning what your brain looks like: 3 of 10 check-ins." at their end.
- **Check-ins** use their 2 minutes with eyes closed. **Nights** use the awake minutes in the first 10 minutes after
  you tap **Lights off**; a night without Lights off is not checked. Nights scored before this update are not part of
  it.
- When a recording looks clearly different, the page leads with "This doesn't look like your usual brain signal. Was
  it you?", what differed, and two answers. **Yes, it was me** adds it to what the check knows about you;
  **Someone else** keeps that night or check-in out of your trends, the unusual card and experiments, and that night
  out of Sharp hours' wake-up times and the study reminders' usual bedtime (written into its own file; nothing is
  deleted). **Undo** takes either back.
- **Someone else wore it** is under every other recording too: the check notices only a clearly different signal
  (on made-up people 2 to 4 in 10 other wearers), so when you know someone borrowed the headband, say so yourself.
- It asked about the person's own recordings about once in 5 to 10 months of daily recordings on made-up people. A
  moved headband, a loose electrode, alcohol, a new medicine or a short night can look different too, which is why it
  only asks. Never a lock, a notification, a name or a health claim.

Files, app-private, exported by Export data: `files/wearer/settings.json` (the switch), `events.jsonl` (switch and
answers), `log.jsonl` (each recording's first verdict); the answer itself as `wearer` in the night's report or the
check-in's result, the night's numbers as the report's `wearer_signal` (`docs/data-format.md`).

### Owner step: nothing to do for about two weeks, then one look (1 minute)

Nothing of this has run on the phone yet, and it has seen only one of your check-ins.

1. Do the morning check-in as usual, and tap **Lights off** as you close your eyes at night. At the end of each
   check-in's result and sleep report the count should climb ("Learning what your brain looks like: 4 of 10
   check-ins."). A night that says "Not checked" tells you why (no Lights off, too little clean signal, no clear
   alpha).
2. If anyone else wears the headband, tap **Someone else wore it** on that recording.
3. Once it checks, if it ever asks about a recording that was you, tap **Yes, it was me** and tell the assistant
   what was different that day (alcohol, a short night, the headband sat differently).
4. If it asks too often, or you never lend the headband, switch it off in Settings and say so.

## Self-experiments (does this habit change that number, for you?)

Everything on the Trends page is only "seen together". A self-experiment is the one way to test a habit: the app
draws random days, you do the thing on those and not on the others, and at the end it says what the habit did to
one number, with a range (DECISIONS rows 200-209; the **i** button shows `docs/evidence/self-experiments.md`).

1. **Trends**, then **Experiments**, then **New experiment**. Pick a question (for example "No screens in the last
   hour before bed"; or write your own "do" and "don't" lines), ONE number (time asleep, sleepiness, reaction
   time...), and 4, 6 or 8 weeks. **Start tomorrow**. Nothing can be changed afterwards.
2. Every day the Experiment page shows that day's task (also one line on the main screen's Morning section and
   after a check-in). The days ahead are hidden, and the app cannot be asked for them.
3. The next day, tap **Kept** or **Not kept**. A day you could not keep still counts: say so and carry on.
4. Record the night and do the morning check-in as usual: a task is judged by the next day's number, and a day
   without it is left out.
5. The answer opens by itself the day after the last number: one sentence such as "On 'No screens...' days your
   time asleep was 18 min longer than on 'Screens as usual' days (range −5 to +41 min): not clear yet." It ends
   in one of: **likely real for you**, **little or no effect for you**, **not clear yet**, **too few days to say**.
   Under it: the days counted, how often you kept to the day, and other numbers as "seen together, not tested".

**Look early anyway** shows the answer so far, but the look is marked on the final answer for good; a half-time
result is often wrong. **Stop this experiment** ends it and keeps the days that are over. Four weeks can only show
a large effect, and you know which kind of day it is, so ratings can follow what you expect: trust measured
numbers more, and run an experiment a second time before relying on it. The files are in `files/experiments/`
(exported with everything else; `sealed.json` holds the days ahead: please do not open it, or ask the assistant
to, before the app shows the answer).

### Owner step: start a first experiment (2 minutes, then one tap a day)

Nothing of this has run on the phone yet. A good first one is caffeine: research found late caffeine costs about 45
minutes of sleep on average.

1. Open **Trends**, scroll to **Self-experiments**, tap **Experiments**, then **New experiment**.
2. Choose "No caffeine in the last 8 hours before bed", leave **Asleep** as the number and 4 weeks, tap
   **Start tomorrow**.
3. From tomorrow: look at the task once a day, wear the headband at night, do the morning check-in, tap Kept or
   Not kept for the day before.
4. Notice and tell the assistant: was the task easy to find; did the day change at a sensible hour for you (a day
   runs 04:00 to 04:00); was anything unclear in the words.
5. The answer opens after 4 weeks and 2 days. Export data as usual in between: the experiment travels with it.

## Sharp hours (the assistant's proposal; off unless you switch it on)

Not something you asked for: the assistant built it from the research on when people are sharpest (DECISIONS rows
280-289; the **i** button shows `docs/evidence/sharp-hours.md`). A few times a day, at random moments while you are
awake, a notification asks **How sharp do you feel?** One tap answers (1 Foggy to 5 Very sharp). Two of the day's
questions also suggest the 1-minute reaction test; Skip is always fine.

- Trends, scroll to **Sharp hours**, tap **Sharp hours**. Switch **Questions during the day** on (Android asks once
  to allow notifications). The waking hours are suggested from your recorded nights; **Change** them if they are wrong,
  and pick 3, 4 or 6 a day.
- Never in the quiet hours, during a night recording or during a session. A question you miss goes after an hour;
  **In 15 min** on the notification puts it off once. **Rate now** answers without a question (marked as such).
- Weeks 1-3: the page shows how far it is from a first pattern ("Collecting: 23 of about 60 ratings, day 9 of 21"),
  your answers as dots, and today's answers. No best time yet: a few days can look like a pattern by chance.
- After 3 weeks and about 60 answers: your answers by 2-hour blocks of the clock, of hours since you woke, or of sleep
  pressure, each block with its range, and one sentence such as "Sharpest 10:00 to 12:00: 0.8 points above your
  other times (probably 0.4 to 1.2)", or "No clear best time yet" (a likely answer: the hour moves how sharp people
  feel very little). Reaction times the same once 30 tests are in. Everything is "seen together, not tested".
- Trends shows the day's mean sharpness and reaction time; a self-experiment can use either as its number.
- **Switch it off** with the same switch (your answers stay), or **Delete my sharp-hours data** at the bottom of the
  page (asks once; exported copies stay where they are). **Sound of the questions** opens the phone's setting for
  them (make them silent there if you like).

Files, app-private, exported by Export data: `files/sharp-hours/settings.json`, `ratings.jsonl`, `reactions.jsonl`,
`prompts.jsonl` (what happened to each planned question: shown, skipped and why, late, postponed, swiped away) and
`events.jsonl` (each change); format in `docs/data-format.md`.

**On the laptop: focus sessions (the research's third measure).** `python3 scripts/aw_focus.py` reads ActivityWatch
and counts **focus sessions** (35 minutes or more of related work in terminals, editors, AI-assistant windows and
documentation, with short switches allowed and no break of 5 minutes) per day and per 2-hour block, into
`_local/phone/sharp-hours/focus-YYYY-MM.jsonl` beside the imported ratings. Sessions are counted, never summed as
hours, and no window title is stored. `python3 scripts/aw_focus.py --show` prints them next to your ratings, block by
block, "seen together, not tested". The rule and the files: `docs/break-hints.md` ("Focus sessions"), `docs/data-format.md`
(DECISIONS rows 510-514).

### Owner step: switch it on and watch the first two days (2 minutes, then a tap a few times a day)

Nothing of this has run on a phone yet, and HyperOS may hold notifications back.

1. Trends, Sharp hours, switch on, allow notifications. Check the waking hours (Change if needed).
2. On a Xiaomi: Settings, Apps, EEG Tracker: **Autostart** on and **Battery saver: No restrictions** (the recorder
   needs the same). Without them the questions can come late or not at all. If the phone stops the app (a force
   stop, or HyperOS clearing it), Android drops its alarms: the questions pause until you next open the app, which
   arms them again.
3. Answer what comes for two days. Then open the page: under the switch it says how many of the last days' questions
   arrived. If it shows an amber "Only N of M questions reached you", tap its Autostart and Battery buttons and tell
   the assistant the numbers.
4. Tell the assistant: did any question come at a bad moment (asleep, in a session); was the sound too much; did the
   reaction test feel too long to do twice a day. To stop it: the same switch, off.

## Study reminders (the assistant's proposal; off unless you switch it on)

Not something you asked for: the assistant built it from the research on learning and sleep (DECISIONS rows 400-401;
the **i** button shows `docs/evidence/study-timing.md`). The idea, from one small study: learn something in the evening,
sleep, and go over it again the next morning. The app only nudges the order: it does not teach anything and does not
know what you study.

- Settings (the gear on the main screen), **Study reminders**. Switch it on (Android asks once to allow notifications).
- **Evening**, 1 to 2 hours before your usual bedtime: "Good time to learn something you want to keep". Afterwards one
  tap: **Did you study something tonight?** Yes, No or Not yet.
- **Morning**, 30 to 60 minutes after you usually wake: "Try to recall what you studied last night, before looking".
  One tap: **How much do you recall?** Well, Some or A little. Then look at your notes.
- The times follow your recorded sleep (from 3 nights; until then 21:00 and 08:30). **Change** sets one by hand,
  **Follow my sleep again** takes it back. They stay inside your waking hours (the Sharp hours window if you have one).
- Never during a night recording, a sound session or a session on screen. A reminder you miss goes after an hour;
  **In 15 min** puts it off once. Say **No** to studying and the next morning's reminder is skipped.
- **Studied tonight?** and **Recalled it?** on the page log without a reminder. Trends shows the day's recall; the
  self-experiment **Study in the evening, a few hours before bed** against **Study in the morning instead** (Trends,
  Experiments) can test it on you. On a morning-study day the recall is 24 hours after studying, not 12, which
  favours the evening: keep that in mind when you read the answer. If you answered No that evening, log the recall from
  the page.
- **Switch it off** with the same switch (your answers stay), or **Delete my study data** at the bottom of the page.

Files, app-private, exported by Export data: `files/study-review/settings.json`, `log.jsonl`, `prompts.jsonl` and
`events.jsonl`; format in `docs/data-format.md`.

### Owner step: switch it on and watch the first two days (2 minutes, then a tap twice a day)

Nothing of this has run on a phone yet, and HyperOS may hold notifications back (the reminders use the same alarms as
Sharp hours).

1. Settings, Study reminders, switch on, allow notifications. Look at the two times (Change if they are wrong).
2. On a Xiaomi: Settings, Apps, EEG Tracker: **Autostart** on and **Battery saver: No restrictions**.
3. The first evening: study something for a while, then tap the reminder and answer. The next morning, try to recall it
   before looking, then tap the reminder and answer.
4. Open the page: under the times it says how many reminders arrived in the last 7 days. If none came, tell the
   assistant.
5. Tell the assistant: did a reminder come at a bad moment (asleep, in a session); was the evening time too close to
   bed or too early; did the morning reminder come before you were up.

## Replay check (off unless you switch it on)

Does the live link to your brain matter, or would a similar sound do as well? The replay check finds out for you.

1. On the Meditation screen tap the **gear** button (Training settings) and switch **Replay check** on. The page
   says what it does and, for meditation and alpha-theta separately, where it stands.
2. Meditate as usual. Before every session the screen says "Replay check is on". Some sessions now replay the sound
   of one of your own earlier sessions instead of following you; you are not told which. Jaw, blinks and dozing still
   act on the sound in both, and the screen shows no bell count and no "settled" word, so it cannot give it away.
3. The first 4 sessions of each kind are always live (the check needs something to replay; older sessions count).
   Before the 5th, the phone draws the hidden order and saves the plan with its fingerprint; it never changes after.
4. After each check session, before the report: how calm you feel, your guess (live, replay, not sure, and how
   sure), how in control and how random the sound felt.
5. After 12 such sessions, **See the results** in Training settings opens: live against replay for the brain
   measure with a fair test, how often you guessed right, how the sessions felt, every session of the set, and what
   it means. Plan 24 to 36 sessions; one person often finds no difference, and that is a real answer.

Please do not test it (for example by opening your eyes to see whether the rain reacts): your guesses show whether
the blinding held. Switching it off keeps everything; switching it on again continues the same plan.

## Alpha-theta

An eyes-closed drift toward the edge of sleep: a stream sound while the alpha rhythm leads, ocean waves as the
slower theta rhythm rises, a soft high chime and a low gong. Practice, not treatment. It can bring up strong
memories or feelings, and leave you drowsy for a while.

1. On the Meditation screen scroll to **Other practice** and tap **Alpha-theta training**.
2. The first time: a few screening questions (if any applies, the app does not offer it: talk to a doctor or
   therapist first), what it can do, and your stop plan (someone to call, what grounds you).
3. Each session: **Check in** (sleepiness, distress, side effects since last time; in the first three also a
   1-minute reaction test that sets your usual speed), then **Start the session**. Recline with the back of your head
   free, wired headphones. The same 1½ minutes of silent calibration as meditation, then 15 minutes (the first three
   sessions) or 20 or 25.
4. If you fall asleep, the sound fades and a soft rising tone wakes you. **Stop** is always there and does not ask;
   the sound fades over about 10 seconds. You can lock the phone during the session; it goes on.
5. Afterwards: a minute of eyes-open grounding, the questions (with the replay check's guess when it applies), then
   **Before you leave**: a sleepiness rating and a 1-minute reaction test. If you are slower than usual or sleepy,
   do not drive or cycle yet; the retest opens after 10 minutes. Then the report.
6. The app pauses alpha-theta after distress of 7/10 or more, distressing memories two sessions in a row, feeling
   unreal or detached, a side effect lasting into the next day, or anything like a seizure. It resumes only when you
   confirm you have talked to someone. After 10 sessions it asks you to decide whether to go on.

Sessions are kept in `files/alpha-theta/` (`<time>.alphatheta.json`, `<time>.session.json` and `journal.json` with
your answers), app-private like the meditations; the replay check's files are in `files/replay-check/`. If
`journal.json` is ever there but cannot be read, the app keeps a copy (`journal.json.damaged`), asks the screening
again and pauses alpha-theta, saying why: a pause that was in the lost notebook is not lifted by the damage.

## Dream catcher

At bedtime or a nap: as you drift off, the app asks what is going through your mind, records your answer, and lets
you drift again, 3 or 4 times. For ideas, not for sleep. The **i** button shows what the research says
(`docs/evidence/dream-catcher.md`).

1. Between nights, on the main screen scroll to **Dream catcher** and tap it.
2. Once: under **Your prompts**, tap **Record** and say the theme, for example "Think of a tree... and drift off",
   then **Stop**. Do the same for the question, for example "What is going through your mind?". Tap the play
   button to hear one and set the phone's volume so you can just hear it lying down. **Record again** replaces it.
   Without your own prompts the app plays a low tone (theme) and two rising notes (question).
3. Under **Tonight** pick 3 or 4 rounds and how it ends: **Wake me** (a soft rising tone at the end) or **Record
   the night** (no tone; the night recording starts by itself afterwards).
4. Headband on and switched on, lie down, phone near your head with the screen up. Tap **Lights off**. The first
   time Android asks for the microphone (and Nearby devices); allow both.
5. The screen goes black and dim. The theme plays; close your eyes and think of it. The first minute sets your
   starting level.
6. When your alpha fades (or at a random moment, if it does not), the question plays. Answer aloud, in a few
   words or more; recording stops after 3 seconds of quiet. Then the screen shows two halves: tap **Drifting**
   (top) or **Awake** (bottom), or nothing. The theme plays again: drift off.
7. After the last round, or 45 minutes after Lights off: the wake tone, or the night starts and the app goes back
   to the main screen showing "Recording". **Stop** ends at any time and keeps the answers.
8. Afterwards (or in the morning) open **Dream catcher**: the last session's rounds are at the top. Play each
   answer and type what it was about; the note is saved as you type. Earlier sessions are at the bottom.
9. Your answers as words (once the speech model is on the phone, see the owner step below): under each play
   button the phone shows what it heard, Russian or English. It writes them out after the session, never during
   it, while this screen is open ("Words: writing out…"; a few seconds an answer). Fix a word in its box: your
   version is shown from then on and kept apart from the phone's (**Undo edit** brings the phone's back). If an
   answer cannot be written out, its row says why; the recording is always kept.

The screen stays on (black and dim) during a session. You can lock the phone: the session goes on and still
records your answers, but the **Drifting / Awake** halves need the screen, so a locked round counts as not
answered. With **Record the night** and the app not yet allowed to run in the background, Lights off asks for it
(the same system dialog as sound for states) and that session's screen says **Do not lock the phone**: Android
starts the night recording from a locked phone only for an app allowed to. During a phone call or another app's
sound no question is asked. Do not swipe the app away. Files, app-private like the meditations: `files/dream-catcher/<time>.dream.json`
(the rounds, the drift-off detector's epochs), `<time>-r<n>.wav` (your answers) and `<time>-r<n>.text.json` (their
words: the phone's and yours, `docs/data-format.md`), your prompts in `files/dream-catcher/prompts/`; the speech
model in `files/models/` (not exported). The session's EEG is a normal recording in `files/recordings/` with every question
as a marker, so it is part of that night: the sleep report includes it and **Export a night** copies it.

### Owner step: the first try (a 20-minute nap, once)

Nothing of this has run on a phone yet: not the microphone, the prompt volume, the dim screen, or the detector
asking at the right moment.

1. In the afternoon or at bedtime, with no night recording: open **Dream catcher**, record both prompts, play
   them, set the volume. Pick **3 rounds** and **Wake me**.
2. Lights off, lie down, eyes closed. Let it run to the wake tone (up to 45 minutes) or press **Stop** after the
   first answer if you just want to see it work.
3. Tell the assistant:
   - Did the questions come at a good moment (half asleep), too early (wide awake) or too late (already asleep)?
     Each round's line says "alpha faded" (the detector) or "timer".
   - Were the prompts too loud, too quiet, or fine? Did the dim screen bother you?
   - Did an answer get cut off while you paused, or keep recording long after you stopped? (The answer's line says
     how it ended.)
   - Could you tap Drifting / Awake half-asleep?
4. With **Record the night** on a later evening, check in the morning that the night recorded and that **Sleep
   report** covers the time from Lights off.

### Owner step: answers as words (once, about 10 minutes on Wi-Fi)

The speech to text has run on the laptop and on the emulator, never on the 11T or on a real sleepy voice.

1. On Wi-Fi, open **Dream catcher**, scroll to **Answers as text** and tap **Download (671 MB)**. Keep the page
   open until it says "Speech model on this phone" (a few minutes; **Stop** pauses it, Download again goes on).
   The app downloads only this model, from one fixed address, and checks it; your answers never leave the phone.
2. If you already have dream catcher sessions, their answers are written out now, one after another.
3. Next time, after a session: watch the words appear under each answer.
4. Tell the assistant:
   - How many seconds did one answer take ("Words: writing out…" to the words)? Did the phone get warm?
   - How close were the words, in Russian and in English? Which words were wrong?
   - Did a whispered or mumbled answer come out as "No words heard."?
   - Did your fixes stay after closing and opening the page?

## Nap coach

A nap that ends before deep sleep starts (waking from deep sleep is what makes you groggy), or at the length you
pick, whichever comes first, with a soft wake sound that rises until you tap. The **i** button shows what the
research says (`docs/evidence/nap-coach.md`).

1. Between nights, on the main screen scroll to **Nap coach** and tap it.
2. Pick the length: **20**, **30** (the default), **45** or **90 min**, counted from Lights off. The plan on the
   screen shows the rule: Awake, then Light sleep; it wakes you where Deep would start, or at your length.
3. Set the phone's media volume to where you would hear an alarm. Headband on and switched on, lie on your side or
   half reclined (lying flat presses the back electrodes), phone near you with the screen up. Tap **Lights off**.
   If the media volume is off or under a third, or the sound would go to Bluetooth headphones, a dialog says so
   first (**Lights off anyway** goes on): the wake sound is the nap's only way to wake you.
4. The screen goes black and dim. Close your eyes; the first minute sets your starting level. One dim word says
   what the app sees (Eyes closed, Resting, Drifting, Asleep), with the minutes and whether the sleep model is on.
   From 5 minutes in the sleep model checks every 30 seconds; if it is too slow, does not answer within a minute,
   fails, or the signal is lost, the line says "timer" and the length alone ends the nap.
5. The wake: the screen comes up and three soft rising notes play, a little louder every 20 seconds. Tap the big
   **I'm awake**. **Stop** (or Back) ends the nap at any time.
6. The report: when you fell asleep (the alpha rule), minutes of light, deep and dream sleep (the live model, a
   first guess; "not scored" when the timer alone ran, and never the last 2 minutes and the wake), why it woke you,
   how long you took to tap, and how fast the model was. Earlier naps are below.

The screen stays on during a nap. You may lock the phone: a notification **Nap**, "Wakes you by ..." with **Stop**
keeps the nap and its wake sound going (Stop there is "I'm awake"). Do not swipe the app away. Files, app-private:
`files/naps/<time>.nap.json` (the length, the onset, the live stages one letter per 30 s, why it ended, the model's
time per check). The nap's EEG is a normal recording in `files/recordings/` with markers (lights off, drowsy,
asleep, deep sleep starting, the wake), so the sleep report scores it in full afterwards and Export copies it. While
last night is still being scored, the nap's model checks wait (the line says so) and the timer covers.

### Owner step: the first nap (about 30 minutes, once)

Nothing of this has run on a phone yet: not the model's speed, the wake sound's volume or the dim screen.

1. Some afternoon with no night recording: open **Nap coach**, pick **30 min**, set the volume, Lights off, nap.
2. Tell the assistant:
   - The **Sleep model** line of the report (for example "3 runs, 2.1 s a check"): the phone's speed, which the
     laptop cannot measure. If it says "1 run" or "timer only", what the sentence under it says.
   - Did the wake sound wake you, and was its first note too soft or too loud? How many notes until you tapped (the
     report's "Up after")?
   - Did it wake you before deep sleep or at 30 minutes, and did you feel groggy?
   - Whether the dim screen or the headband bothered you lying down.
3. Later, Export data: the laptop can then score the nap in full and compare it with what the phone saw live.

## Smart alarm

Wakes you within a window you choose, at a moment of light sleep, dream sleep or being awake, never in deep sleep;
always by the end of the window. Off until you set it. The **i** button shows what the research says
(`docs/evidence/smart-alarm.md`: the evidence that it beats a plain alarm is weak).

1. Before Start, the line above **Start night** says "Smart alarm off." Tap **Set alarm**: set **Wake me by** (for
   example 07:30) and how much earlier it may wake you (**15**, **20**, **30** or **45 min**; 30 first), then
   **Set alarm**. The line then says "Wakes you by 07:30 tomorrow, from 07:00 at a light moment." The setting stays
   for the next nights until you change it or tap **Alarm off** in the same sheet.
2. **Start night** as always. At Start the app sets a real phone alarm at 07:30 (Android's alarm clock: the alarm
   icon in the status bar). It rings even if the phone closes the app in the night, the sleep model is too slow or
   fails, or the headband's signal is lost. If the phone does not allow exact alarms, its alarm volume is off, or it
   blocks pages over the lock screen, the app says so and opens the setting.
3. During the night the headband records as always. From 06:00 (an hour before the window) the sleep model runs in
   the recorder and a second line in the bar says what it sees ("Alarm 07:00-07:30. Watching your sleep: deep sleep
   2 min ago."). **Alarm off** there asks first, then nothing wakes you.
4. Between 07:00 and 07:30 it wakes you at the first 30 seconds read as light sleep, dream sleep or awake, but not
   within 10 minutes after deep sleep; if none comes, at 07:30. The sound: the nap coach's three soft rising notes
   on the phone's alarm volume, a little louder every 20 seconds; after 3 minutes the phone's own alarm sound with
   vibration. The screen comes on with a big **I'm awake** (also on the notification); it stops the sound, not the
   recording. With no tap it gives up after 13 minutes.
5. In the morning **Stop** the night. The sleep report's **Waking up** says when it woke you, why, what the
   full-night scoring says about that minute, and how long until you tapped.

Files, app-private, exported with everything else: `files/alarm/setup.json` (your setting),
`files/alarms/<window end>.alarm.json` (the live model: when it ran, its stages, the wake and why, its speed),
`files/alarms/rings.jsonl` (the phone alarm's own log: set, ring, loud, I'm awake, gave up, off). The night's
recording gets markers (`smart alarm: sleep model on`, `smart alarm: wake, light sleep ...`). Code: `lib/alarm/`
(rule, the model in the recorder, the phone alarm's channel, the files), `lib/ui/alarm_view.dart`,
`android/.../WakeAlarm.kt`, `WakeService.kt`, `AlarmActivity.kt`, `AlarmReceiver.kt`; reference
`../analysis/smart_alarm.py`; DECISIONS rows 230-239.

### Owner step: the first smart alarm (one morning, 2 minutes of setup)

Checked on the emulator only (the model inside the recorder, the early ring, the ring after the app was killed);
not on the 11T, not with a head, and the volumes are guesses.

1. Once: in the phone's settings for EEG Tracker, allow **Show on lock screen** and **Display pop-up windows while
   running in the background** (HyperOS "Other permissions"), and keep **Autostart** and **No restrictions** on (as for
   the night). Set the phone's **alarm** volume (not media) to where an alarm wakes you.
2. Before a night: **Set alarm** for your usual time with **30 min**, then **Start night**. Check the alarm icon in
   the status bar.
3. In the morning, tell the assistant:
   - Did it wake you, at what time, and did you feel groggy? Was the first note too soft or too loud?
   - Did "I'm awake" show over the lock screen, or only in the notification?
   - The sleep report's **Waking up** lines (the full-night scoring's word for that minute).
   - The last lines of the night's `.log` (`smart alarm: sleep model ... s of the recorder's time`; with the lucid
     cues on too, `smart alarm and lucid cues, one sleep model: ...`) and whether the night's battery drain looked
     higher than usual.
4. If it rang only at the window's end every time, or never early, Export data: the laptop can replay the night.

## Lucid dream cues (off unless you turn them on)

Soft sounds in dream sleep to help you notice that you are dreaming: an evening practice pairs a cue (three soft
rising tones) with "am I dreaming?", and in the second half of the night the night recorder plays the same cue when
the headband reads dream sleep. An experiment: the evidence is weak, and sounds can disturb sleep. The **i** button
says what the research shows (`docs/evidence/lucid-cues.md`); the page says who should not use it.

1. On the main screen, between nights, scroll to **Lucid dreams** and tap it. Read **Who should not use it**, then
   **Turn on**. The first time this opens the practice, because the cues need your loudness.
2. Each evening, in bed, as you will sleep (earbuds in, or the phone where it will lie): **Start practice**. The cue
   plays every 3 seconds from very quiet, a little louder each time: tap **I hear it** as soon as you hear it. Then 4
   cues with words to read (am I dreaming? notice your body, your breathing; if it is a dream, look left-right-left-
   right, twice) and 12 with your eyes closed, about 15 minutes, the screen black and dim. Keep the media volume where
   it is now.
3. **Start night** as usual, and tap **Lights off** when you settle: the cues may play from 4.5 hours after it, only
   in dream sleep with your eyes moving and you lying still, never in deep sleep; at most 10 in a dream and 30 a
   night, a little louder each time; a stir makes them quieter and pauses them.
4. If you notice you are dreaming: stay calm and look left-right-left-right, twice, wide.
5. In the morning the page asks three questions (lucid? heard the sound? how much do you remember?) and shows last
   night on its clock: when the cue moments were, any stirs after them, and any eye signals found in the night (and
   double jaw clenches, once hands-free is calibrated).
6. The test: in each block of 4 nights, 2 are silent on purpose and nobody tells you which; everything else is the
   same, so the page cannot tell you either. After 12 nights it shows whether nights with sound gave more lucid
   mornings than silent ones, "tested" apart from what is only "seen together". Expect "not clear": one person and a
   few nights rarely show more.

Files, app-private: `files/lucid/` (the settings, practice and night records, the morning answers and signals, the
sealed order of the nights; docs/data-format.md "Lucid dream cues"). Export data takes them; please do not open
`sealed.json` or `plays.jsonl` on the laptop before the results open. The cue moments are markers in the night's
recording, the same on silent nights.

### Owner step: the first week (15 minutes an evening, 1 minute a morning)

Nothing of this has run on a phone or a head yet: not the loudness, the model running half the night inside the
recorder, or the eye-signal finder.

1. The first evening: in bed, open **Lucid dreams**, **Turn on**, do the practice to the end. Then Start night and
   Lights off as usual.
2. While awake with the headband on, once, make the eye signal on purpose (left-right-left-right, twice, wide, eyes
   closed) a few times a minute apart, and note the times: the morning search should find them (they show as "other"
   signals, not in dream sleep). This is the first real signal on this headband.
3. Each morning answer the three questions before anything else.
4. After the first night tell the assistant:
   - Whether you heard the practice's first cues at the level you tapped, and whether the night woke you (the page's
     "A stir after a cue" and your answer).
   - The night's `.log` end line `lucid cues: ... s of the recorder's time` (with the smart alarm on too, `smart alarm
     and lucid cues, one sleep model: ...`: they share one sleep model), and any line starting `lucid cues stopped`
     or `lucid cues off`.
   - The phone's battery drain that night against a night without the cues.
5. Export data after a few nights: the laptop can replay the cue rule on your nights (`analysis/lucid_cues.py`) and
   check the eye signals you made in step 2 (`analysis/lucid_signals.py`).

## Memory cues (the assistant's proposal; off unless you switch it on)

Soft sounds in deep sleep for one half of an evening task, tested the next morning: targeted memory reactivation as
a self-test. The assistant's proposal: the evidence is weak (a small effect in the lab, several recent studies found
none, a 13-lab replication is due around 2027), and sounds that wake you make the cued memories worse. The **i**
button says what the research shows (`docs/evidence/memory-cues.md`); the page says who should not use it. Never on a
night with the lucid dream cues: one kind of cue a night.

1. **Settings** (the gear on the main screen), **Memory cues**, **Turn on**. Once on, the main screen has a Memory
   cues section between nights.
2. Each evening, before Start night: **Start the evening task** (about 12 minutes). Set the media volume so the
   sounds are soft but clear and leave it there. 32 objects appear one by one at their places on a board, half with a
   soft bell, half with a soft knock; then put each one back (you see where it was and hear its sound again; up to 3
   rounds); then once more with no help. Last, lie down with the phone where it stays tonight and tap **I hear it** as
   soon as you hear the bell, then the knock (each plays every 3 s, a little louder each time).
3. **Start night** within 3 hours, and tap **Lights off** when you settle. From 30 minutes to 4.5 hours after it,
   when the headband reads light or deep sleep and you lie still, one of the two sounds plays, 3 dB under where you
   tapped: at most one every 10 s and 120 a night; a stir makes it quieter and pauses it, three stirs end it.
4. In the morning, before anything else: **Start the morning test**, the same board with no help (about 2 minutes),
   and "did you hear a sound in the night?". The page then shows the board with a line from each object's place to
   where you put it, and the numbers against the evening.
5. The test: in each block of 4 nights, 2 are silent on purpose, and which half's sound plays is a coin you are not
   told. After 12 finished nights the page shows, on nights with sound, whether the half whose sound played drifted
   less overnight than the other half, "tested" apart from what is only "seen together". Expect "not clear": about 24
   nights would be needed to see the best home study's effect.

Files, app-private: `files/memory_cues/` (the settings, each evening's session, the night records, the mornings, the
sealed order of the nights and halves; docs/data-format.md "Memory cues"). Export data takes them; please do not open
`sealed.json` or `plays.jsonl` on the laptop before the results open. The cue moments are markers in the night's
recording, the same on silent nights.

### Owner step: the first week (12 minutes an evening, 2 minutes a morning)

Nothing of this has run on a phone or a head yet: not the sounds at night, the model running the night's first hours
inside the recorder, or the board on a real screen.

1. The first evening: Settings, **Memory cues**, **Turn on**, then **Start the evening task** to the end. Then Start
   night and Lights off as usual.
2. Each morning do the morning test before anything else.
3. After the first night tell the assistant:
   - Whether you heard the sounds at the loudness you tapped, and whether the night woke you (the page's "A stir after
     one" and your answer).
   - The night's `.log` end line `memory cues: ... s of the recorder's time` (with the smart alarm on too, `smart alarm
     and memory cues, one sleep model: ...`), and any line starting `memory cues stopped` or `memory cues off`.
   - How long the evening task took, and whether the board was too hard or too easy (the page's "Placed close").
4. Export data after a few nights: the laptop can replay the cue rule on your nights (`analysis/memory_cues.py`).

## Sound for states

Calm sound to help you fall asleep, relax, focus, take a break or wake up. A beat is an optional extra. With the
headband on, the app first measures a quiet minute, then shows what your brain does during the sound. The **i**
button says what the research shows (`docs/evidence/sound-for-states.md`): calm sound has the better evidence, and
no beat is proven to put your brain into a state.

1. On the main screen scroll to **Sound** and tap it. It works between nights and during one (then without the
   headband, by its timer).
2. Pick a state. The line at the top (the score) shows the session: a quiet minute, the sound fading in and out over
   its minutes, and the beat's rate as a line if you add one.
3. Pick a sound: Rain, Pink noise, Brown noise or Ocean. Under **Beat** leave **No beat**, or add Pulsed noise,
   Isochronic tones or Binaural beats (headphones in both ears). On some days use No beat on purpose: it is just as
   loud, so you can compare.
   Under the beat's explanation one line says where the sound goes now (the phone's speaker, wired or Bluetooth
   headphones). It turns amber only for **Binaural beats** on the phone's speaker: there you hear no beat, so put
   stereo headphones on or pick another beat. Bluetooth's delay does not matter for these sounds.
4. Tap **Listen** and set the phone's volume low with its buttons. Pick the length.
5. **Headband**: **Measure** (headband on and switched on) or **Sound only**. For **Fall asleep** with the headband,
   choose what happens when the sound has stopped: **Record the night** (the night recording starts by itself) or
   **Let the headband go**.
6. Tap **Start**. With the headband: lie or sit as you will during the sound, eyes closed for fall asleep, relax and
   break; the first minute is silent. The sound then starts by itself (or tap **Start the sound now**). The screen
   goes black (dim for eyes-closed states) and says **You can lock the phone**: lock it, or let the screen turn off.
   The sound, the headband and the stop-when-asleep rule go on. **Stop** is also on the lock screen. If you want
   the screen lit as before, choose **Screen: Stays on** on the setup page.
7. Fall asleep: the sound fades out over 2.5 minutes once you are probably asleep, and is silent 45 minutes after
   lights off at the latest; with **Record the night** the night recording then starts, also on a locked phone. An
   unlocked screen stays dim and turns off by itself. Other states end at their timer. **Stop** fades out over
   3 seconds.
8. Afterwards: what was measured in plain words, and one question, "did it help you get there?" (1-5). After a
   night, open **Sound** in the morning to answer it.

Files, app-private: `files/sound-states/<time>.sound.json` (the sound, timings, readout, your answer;
`docs/data-format.md`). Only **Fall asleep** with the headband keeps its EEG, as a normal recording in
`files/recordings/` with the sound's events as markers, so it is part of that night's sleep report and export.

**What works for you.** Under the settings, the page compares the sounds you played for the chosen state: the
minutes to fall asleep (the drift-off detector, else that night's sleep report; still awake at 45 minutes counts as
45), alpha against the quiet minute for **Relax**, slow waves (drowsiness) for **Break**, and your 1-5 answer for
**Focus** and **Wake up** (weak: you knew what played). A sound shows its median and the middle half of its sessions
once 14 sessions have a number; until then its cells count toward 14. This is seen together, not tested: you chose
the sound.

**A fair test.** **Plan a fair test** lets the app choose between two sounds of one state for 4, 6 or 8 weeks: each
day draws one of them (shuffled blocks of 4 days, like the self-experiments), and that day the state plays it (the
sound and length are locked, with a line saying so). The plan is frozen before day 1, which is tomorrow
(`files/sound-states/plans/<id>/`). One session a day counts, the first with a number. The answer opens the day after
the last number can come in, tested with the self-experiments' randomisation test and worded the same way ("likely
real for you", "little or no effect for you", "not clear yet"). **Stop this test** opens it early, marked as stopped.

### Owner step: the first sound sessions (15 minutes, then one bedtime)

Nothing of this has been heard on a phone yet: not the levels, the beds, the beats, or the stop when asleep.

1. Between nights, open **Sound**. For each bed tap **Listen**: is any of them harsh or too loud at a low phone
   volume? Then add each beat (Pulsed noise, Isochronic tones; Binaural with headphones) and Listen again: is the
   beat soft enough, and does **No beat** sound as loud as with a beat?
2. **Relax**, Ocean, **Measure**, 5 minutes, headband on, eyes closed. Afterwards read the result lines.
3. At bedtime: **Fall asleep**, Pink noise (a beat if you like), **Measure**, **Record the night**. Sleep.
4. Tell the assistant:
   - Which beds and beats you liked or disliked, and whether any level was off.
   - In the morning: did the sound stop by itself, did the night record from then (the sleep report starts at
     lights off), and what did the result say ("probably asleep N min after lights off")? Did that match how you
     felt?
   - Did the dim black screen bother you? (You can lock the phone now: see the next owner step.)
   - The session file's `stalls` (0 is right; the assistant can read it from an exported night or over USB).

### Owner step: a fair test of two sounds (2 minutes, then 4 weeks of bedtimes)

Nothing of this has run on a phone yet. A clear difference takes 3 to 6 weeks; a 2-minute difference in falling
asleep is barely seen in a month.

1. Open **Sound**, pick **Fall asleep**, scroll to **A fair test** and tap **Plan a fair test**.
2. Keep **Pink noise, no beat** as the first sound and **Pink noise, pulsed noise** as the second, 30 min, 4 weeks.
   Tap **Start tomorrow**.
3. Every bedtime from tomorrow: **Sound**, **Fall asleep** (the sound is already drawn), **Measure**, **Record the
   night**, **Start**. A night you cannot is simply left out.
4. Tell the assistant:
   - Was today's sound easy to see, and did the locked chips make sense?
   - After a week: does **What works for you** count the nights (its cells toward 14)?
   - Any night the result said the detector did not see you fall asleep although you slept.

## Signal (the head, live traces and raw data)

The **Signal** tab shows what the electrodes see, for any number of them (DECISIONS rows 590-599). At the top one line
says where the samples come from; under it **Head**, **Traces** and **Raw**:

- **Head**: a 3D head you turn with a finger, pinch to zoom and double-tap to straighten. Each electrode is a mark in
  its contact's colour and shape (filled good, ringed dot fair, ring poor, dash none) with its name and ohms beside it;
  the reference and the bias are squares. Good up to 1 MΩ and fair up to 2.5 MΩ are planning limits, not measured on
  your head. Tap an electrode (or its row) for its last 5 seconds (1-40 Hz), its RMS, the mains (50 Hz), whether the
  last second was flat, railed or swinging, and its delta / theta / alpha / beta shares.
- **Traces**: every channel's last 5 seconds in µV, as it came (**Raw**), **1-40 Hz** or with only the **50 Hz
  notch**, at **Auto** or a fixed scale, each with its numbers and band strip.
- **Raw**: all channels stacked as they came, **Pause** and slide back up to 5 minutes, the counters (samples, the
  newest sample's time, the rate, missing and repeated packets, the night's file set) and every channel's latest value.

Where the samples come from: while a night records, the night recorder's own stream (the contact is the one measured
when the night started); while a session holds the headband, that session's stream; otherwise the tab connects by
itself (contact first, about 6 s, then the stream), and **Measure contact again** reads it again. It never opens a
second connection and never switches a recording headband into resistance mode. Leaving the tab lets the headband go.
With the DIY board chosen it listens for the board's frames (no contact reading).

Electrode places: the 10-10 names (O1, Fz, C3, T7, M1 ...; old T3 T4 T5 T6 too) find their places by themselves. A
helmet's other sites: **Positions** (under the electrode list) takes one line a site, `name polar azimuth` in degrees
(down from the top; round from the nose toward the right ear) or `name x y z` (right, front, up), and `ref` / `ground`
lines; checked before it is saved, in `files/signal/positions.txt` (it leaves the phone with Export data).

Not yet: an 8- or 16-channel board. The view works for any count (tested at 4, 8 and 16), but the BrainBit and the
DIY board both arrive in the app's 4-channel record (DECISIONS 363).

### Owner step: a first look at the signal (5 minutes)

Nothing of this has run with a headband yet: not the head's speed on the phone, the traces, or the contact readings.

1. Between nights, headband on and switched on. Tap **Signal** at the bottom: it looks for the headband, checks the
   contact (keep still a few seconds), then shows the head.
2. Turn the head with a finger, pinch, double-tap. Tap O1, then the other electrodes. Open **Traces**, try the three
   filters; blink, clench your jaw, close your eyes for 10 s (alpha should grow at O1 / O2).
3. Open **Raw**, tap **Pause**, slide back a minute, tap **Back to live**.
4. Tell the assistant:
   - Did the head turn smoothly, and were the marks and the ohms where you expected (do they match the night
     screen's contact)?
   - Did blinks, the jaw and closed eyes show up where you expected? Any channel always "flat" or "railed"?
   - Any missing packets in Raw after a few minutes? Did the phone get warm?

## Work session

Wear the headband while you work: the phone watches for heavy eyelids (drowsiness) and suggests a break now and then,
on the laptop's break-hint rules (`docs/break-hints.md`). The **i** button shows what the research says
(`docs/evidence/work-session.md`): drowsiness is usable with these electrodes, "mental fatigue" without sleepiness is
not measured.

1. Between nights, on the main screen scroll to **Work** and tap **Work session**. Start when you feel fresh: the
   first minutes are your awake baseline. **Start with 1 minute eyes closed** is optional (it helps tell closed eyes
   from heavy eyelids later).
2. **Start work session**. After the connection, work as usual: 1 minute of settling in, then 3 quiet minutes of
   baseline ("Calibrating"). Calibration learns only from quiet half minutes (20 of their 30 seconds without
   talking, chewing or moving): while you talk it says **Waiting for a quiet minute to calibrate (talking?)** and
   simply waits; it never starts a break by itself. Then the big word says **Alert**, **Getting drowsy**, **Drowsy**
   or **Not sure** (too noisy), from the last 5 minutes against your baseline. **The last hour** shows twelve
   5-minute cells (empty alert, half full getting drowsy, full drowsy). Talking, chewing and moving are not the
   headband off: the signal line says **Talking / moving — reading paused**, the minutes count as worn, and no break
   starts. If the signal line says **An electrode has no contact: eye readings paused**, press the headband on:
   until then the level reads alpha alone. If the headband stops sending, the app restarts its stream after 8
   seconds and reconnects after 40.
3. Lock the phone if you like: the session goes on (a card with the level and Stop on the lock screen) and the chime
   still sounds.
4. A **hint**: a soft two-note chime, and the words on the screen and the lock-screen card: after 60 minutes worn
   (plus 15 for each hint you let pass), or when drowsiness read up for most of the last 6 minutes, or your eyes were
   closed for 3 of them. At most 4 a day, 45 minutes apart, none 23:00-08:00. Answer **On a break**, **Snooze 20
   min** or **Not now**; tap how sharp you feel (1 Foggy to 5 Very sharp) if you can. A hint nobody answers goes
   after 30 minutes. Stopping the session for 5 minutes or more (lunch) counts as the break after a hint; a restart
   within 5 minutes carries the hour on. If the media volume is off or under a fifth when you start, a quiet line
   under the session says the chime may not be heard.
5. **A meeting**: a call on the phone (ringing, a phone call, or a voice or video call in another app), or the
   laptop tray's word that its session is in a meeting (Zoom, Teams, Meet...; the phone hears it while Share on
   Wi-Fi is on and the laptop is paired), makes the page say **In a meeting**: talking is expected, those minutes
   give no drowsiness reading, and no hint comes until it ends (one shown just before it keeps its words; its chime
   waits). The session file keeps the meetings and their minutes.
6. **On a break** when you get up, **Back** when you return (on the lock-screen card too). Taking the headband off
   counts as a break after 5 minutes: "off" is judged from the signal itself (flat, at the rails or wild on most
   electrodes, or no data), the same check automatic recording uses, never from talking. A forgotten Back ends the
   break by itself 2 minutes after the headband is back on, or after 20 minutes of readable work with it on. Back
   never calibrates again: the baseline stays the session's first quiet minutes; only a baseline not finished yet
   starts over, after the headband was off 5 minutes. Some minutes after the break the screen says whether
   drowsiness went down.
7. **Stop** at the end: the session's totals and its hints.
8. If someone else wore the headband, tap **Someone else wore it** on the end page, or under that session in the list of
   earlier sessions on the start page (**Undo** takes it back). The session stays on the phone but is left out of
   Trends, the unusual card and experiments. It shows only while "Was this you?" is on in Settings.

**In Trends** (DECISIONS rows 480-489): once a day has 30 minutes of readable work time, Trends gains a few rows
for it, each next to yesterday and your usual like the other numbers, with a worded arrow from 14 days and a line in
"The last 14 days": **Work with a signal** (minutes, not counting noisy or closed-eyes time or breaks), **Work time
drowsy** (the share of that time at getting drowsy or drowsy), **Work until first drowsy stretch** (only on days
that had one), **Break hints shown**, **Hints followed by a break**, **Work breaks** (5 minutes or more) and
**Sharpness at work** (the mean of your "how sharp" taps). A hint counts as followed by a break when you took one
within 30 minutes, also by stopping the session for 5 minutes or more. Every row says "Seen together, not tested."
A day with under 30 minutes of readable time has no work number, and sessions marked as worn by someone else are
left out. The share of work time drowsy and the tap mean can also be the outcome of a self-experiment (Experiments
in Trends).

Files, app-private, exported by Export data and listed by Share on Wi-Fi: `files/work-sessions/<time>.work.json`
(written every 5 minutes and at Stop; every 30 s the numbers behind the level, the hints, breaks, meetings, taps and
connection events; `docs/data-format.md`, "Work sessions"), and the session's **raw EEG**, calibration included, as a
recording beside the nights': `files/recordings/<stamp>.f32 .idx .log .header.json .markers.jsonl` whose header says
`"session": "work"`, so it is never listed, scored or exported as a night (the nights' list, the sleep scoring and
the laptop's `night_files.py` leave it out). It costs about **19.5 MB an hour** (18 MB of samples, 1.5 MB of
index), about 160 MB for an 8-hour day, and after a day it is packed like a night (about 40 % smaller: some 100 MB
for that day). `pull_phone.py` mirrors it into the laptop's `_local/recordings/`; `scripts/to_bdf.py <stamp>.f32`
makes a BDF of it. On the laptop, `cd app && dart run tool/work_check.dart RECORDINGS PREFIX
SLEEP.json HH:MM:SS-HH:MM:SS[@HH:MM:SS]` replays recorded data through the same rules.

### Owner step: wear it while you work (2 minutes to start, then a working day)

Nothing of this has run on a phone or at a desk yet: not the level on a working day, the hints' rate, the chime's
volume, the locked phone over hours, or the headband's comfort.

1. A working day with no night recording: headband on when you feel fresh, **Work session**, **Start work session**,
   work as usual for 4 minutes, then lock the phone if you like.
2. Use **On a break** / **Back** when you get up; answer the hints; tap how sharp you feel when you can.
3. Tell the assistant:
   - Did "getting drowsy" or "drowsy" come when you felt heavy-eyed, and stay away when you felt fine (including
     long stretches of focus)?
   - Were the hints too many, too few or about right; was the chime soft enough?
   - Did it keep going with the phone locked; the phone's and the headband's battery at the start and the end.
   - Was the headband comfortable after an hour, two, four?
4. Later, Export data: the laptop can then compare your taps with the level.

## Sessions with the phone locked

Sound for states, meditation, alpha-theta, the dream catcher, the nap coach and the morning check-in go on when the
phone is locked (since 2026-11-19, DECISIONS rows 190-197 and 460). While a session runs, the app shows a notification with the session's name and **Stop**,
also on the lock screen; Android then treats the app like a music player and does not put it to sleep. The night
recording is separate and unchanged.

- **Sound for states**: the screen is not kept on any more. Lock the phone or let it turn off.
  **Screen: Stays on** on the setup page brings the old lit screen back.
- **Meditation, alpha-theta, dream catcher, nap coach, morning check-in**: the screen still stays on by itself;
  press the power button if you want it dark.
- **A phone call or another app's sound** (DECISIONS row 468): the session asks Android for the sound, so music
  from another app pauses when it starts. When a call rings or another app takes the sound, meditation and
  alpha-theta go quiet with no bells, sound for states pauses, and the dream catcher asks no question, until the
  sound is back; the session file notes it. The morning check-in stops and keeps nothing. The nap asks for nothing
  (a podcast you fall asleep to goes on) and its wake sound plays regardless; nor does the work session (your music
  while you work goes on, and a hint's chime plays over it).
- **Fall asleep, then Record the night**: the night starts by itself on a locked phone. The first time, if the app
  is not yet allowed to run in the background, Start asks for it and that one session keeps its screen on.
- Do not swipe the app away from Recents during a session: that ends it.
- The same Xiaomi settings as for the night matter here (main screen, **Phone**: Autostart, battery "No
  restrictions").

Not tried on a phone yet. On the emulator, with the screen off, the sound engine kept playing and being fed for two
minutes, the microphone recorded real sound, and the night recording started from the locked session
(`tool/screen_off_smoke.dart`, "Emulator smoke test" step 8).

### Owner step: lock the phone during a session (15 minutes, then one bedtime)

1. Daytime, no night recording: **Sound**, **Relax**, Ocean, **Measure**, 10 minutes, headband on. Tap **Start**.
   When the sound has started, press the power button. Put the phone down and listen.
2. After about 5 minutes wake the screen without unlocking: is there a card with **Relax** and **Stop**? Leave it.
3. Let it run to the end. Then unlock. Tell the assistant:
   - Did the sound play the whole 10 minutes, without gaps or an early stop?
   - Does the result show what was measured for the whole time (not "No signal")?
   - How the lock-screen card looked, and whether **Stop** there works (try it in another short session).
4. At bedtime: note the battery percent. **Fall asleep**, **Measure**, **Record the night**, **Screen: Can lock**.
   Start, lock the phone, sleep.
5. In the morning tell the assistant: did the sound stop by itself, did the night record from then, and the battery
   percent at lights off and in the morning. Send the session file's `stalls` and `end` (Export data has it).
6. If a locked session stopped early: choose **Screen: Stays on** for now and say so; that is the old behaviour.

## When I put the headband on (automatic recording; asks first unless you change it)

You wished the app would start reading by itself when you wear the headband and know what you are doing. This is the
first phase (DECISIONS rows 600-609; research `_local/research/2026-11-20-00-auto-activity.md`; the **i** button
shows `docs/evidence/auto-start.md`).

- Settings (the gear on the Night tab, or More, **Settings**), **When I put the headband on**. For **At night**, **Working** and **Anything
  else**: **Automatic**, **Ask me** (the default) or **Do nothing**. "Anything else" can only ask for now.
- **Pair the headband** once: Android's own dialog offers the headband ("BB Black"). Then Android tells the app when
  the headband comes near and lets it start a recording with the app closed. Without it the battery exemption the app
  already asks for does the same job, less reliably; with neither, the app checks only when you open it. The page says
  which of these your phone allows.
- When it checks: when you open the app, every 10 minutes in your **bedtime window** (from 2 hours before your usual
  bedtime to your usual wake-up, from your last 14 days of nights; 23:00 to 07:00 until 3 nights; **Change** sets it
  by hand), when the paired headband comes near, and when the laptop tray says a work session started (it tells the
  phone paired by its QR code, through Share on Wi-Fi between nights). **Check now** runs one. Never during a
  recording or a session, nor while the Signal tab holds the headband, and not in the 30 minutes after a recording's
  last data.
- A check connects for about 10 seconds: contact on each electrode (off the head: no contact at all) and the battery,
  then it lets go. On the head, the app guesses what you are doing from the clock and the phone: in the bedtime window,
  or charging with the screen off (or Do Not Disturb) after 20:00, it is the night; the laptop's work session is work;
  anything else is other.
- **Ask me**: one quiet notification, "Headband on. Start the night?" (**Start the night**, **Not now**), "Headband on.
  Start a work session?" (**Start**, **Not now**) or "Headband on. What are you doing?" (**Night**, **Work session**,
  **Not now**). The minutes since the check are kept in memory meanwhile (up to 15): **Start the night** saves them as
  the night's first part, so the night counts from when you put the headband on. **Not now**, or no answer in 15
  minutes, writes nothing, and the app asks about that kind no more for 30 minutes and for the rest of that wearing.
  A work start opens the work page, which starts the session.
- **Automatic** only ever means recording and silent analysis: the night recorder (the drift-off detector, the sleep
  report after Stop; no smart alarm, no lucid or memory cues, no sound), or the work page with a session whose hints
  show on the screen and the lock-screen card; its chime only with **Chime in automatic work sessions** on. After 10
  yes in a row for the night or for work, the page (and a notification) offers to switch it to Automatic.
- **The night comes first**: a work session starts by itself or is offered only while the headband keeps enough for
  tonight (planning: 10 % an hour, plus 15 %; down to 15 % while bedtime is 4 hours or more away, ending 4 hours
  before bed), and it stops itself in time. Otherwise: "Charge the headband for tonight" (once a day). A night is never
  refused, only warned about in the question.
- A night started this way says so in its log ("started automatically" or "started after Yes"). Stop it in the
  morning as usual. Starting anything by hand (Start night, a session) makes the watcher let go of the headband at
  once; its question goes away and nothing is kept.
- **How often it was right** on the page counts your answers per kind.

Files, app-private, exported by Export data and listed by Share on Wi-Fi: `files/auto-start/settings.json`,
`state.json`, `log.jsonl` (every check, guess, question, answer and outcome) and `laptop.json`; format in
`docs/data-format.md`. A debug build has a fake "headband came near" for the emulator (Emulator smoke test).

### Owner step: pair it, then a bedtime with "Ask me" (5 minutes, then a few evenings)

Nothing of this has run on a phone yet. Only the phone can tell: whether HyperOS shows the pairing dialog and keeps
"headband near" working with the screen off, the contact numbers on and off the head, and how much the checks take
from the headband's battery.

1. Settings, **When I put the headband on**, **Pair the headband** with the headband nearby and not in use. Choose
   it in the dialog. Note what the "Watching for the headband" lines say.
2. On a Xiaomi: Settings, Apps, EEG Tracker: **Autostart** on and **Battery saver: No restrictions**.
3. Headband on, **Check now**: within about 20 seconds a quiet notification should ask. Tap **Not now**. Then take
   the headband off and tap **Check now** again: no question should come.
4. At bedtime, leave everything on **Ask me**, put the headband on, put the phone on the charger and lock it. Within 10
   minutes "Headband on. Start the night?" should come. Tap **Start the night**. Stop in the morning as usual.
5. Tell the assistant (and Export data: `auto-start/log.jsonl` has the contact numbers and battery of every check):
   - Did the pairing dialog show the headband; did the question come, how late, with the screen off?
   - Did the night's report start when you put the headband on, not when you tapped?
   - Did a question ever come at a wrong moment (off the head, in a session, right after Stop)?
   - The headband's battery in the evening and in the morning, on a day with checks.

## Hands-free controls (off unless you switch it on)

A firm double clench of your teeth, or a look far left and then far right, works as a switch during sessions, with
a soft tone when it is caught. The temple electrodes see jaw muscle and sideways eye movements best. The **i**
button shows what the research says (`docs/evidence/hands-free.md`); the rules are in `docs/detectors.md`
("Hands-free gestures").

| Where | Double clench | Look left, then right |
|---|---|---|
| Sound for states, Meditation | pauses the sound; the next one brings it back | marks a moment |
| Dream catcher | while "were you drifting?" waits: Drifting (a nod); else a moment | while it waits: Awake (a shake of the head); else a moment |
| Alpha-theta, Nap coach | marks a moment | marks a moment |
| Night recording | marks a moment (no tone) | not used at night (dream sleep is full of eye movements) |

Never in the morning check-in (it would change the measurement), and never while the drift-off detector says you are
probably asleep (except while the dream catcher's question waits for its answer). The tone comes 2-4 seconds after
the gesture: the app waits for 2 quiet seconds first, so chewing, talking or looking around do not count.

1. Between nights, tap the **gear** at the top of the main screen (Settings).
2. Switch **Hands-free controls** on. The first time this opens the calibration (about 90 seconds, headband on,
   sitting up): 30 seconds still, then on each low tone clench twice (short and firm, about a second apart), three
   times, and on each rising tone look far left, then far right, then back (eyes only), three times. Two lanes show
   your jaw and your eyes as you do it, and each try's cell fills when it was seen.
   **Stop** works at any moment, also while it is still looking for the headband; Stop then Start again begins a
   fresh calibration (the first search can no longer spoil it).
3. The result says which gestures work (caught at least 2 of 3), each try in words, and the levels it set. Only the
   gestures that work are used; **Calibrate again** any time.

Files, app-private, exported by Export data: `files/hands-free/settings.json` (the switch), `calibration.json` (the
levels and each try), `events.jsonl` (each change), and the calibration's EEG in `files/hands-free/recordings/`
(never with the nights). Gestures act on a session as markers (`hands-free: moment (double clench)`, `hands-free:
sound paused (double clench)`, ...): in the session's events or log, and in the recording's `.markers.jsonl`.

### Owner step: calibrate and try it (about 10 minutes, once)

Nobody has made these gestures with this headband yet: the levels are first guesses until your calibration.

1. Between nights: Settings, switch **Hands-free controls** on, calibrate. Tell the assistant the result page's
   lines: for each gesture "Works" or "Not used", the numbers after each try (for example "48 x" and "131 µV"),
   and the reason for any miss.
2. Then a 10-minute **Sound** session (Relax) with the headband: once the sound plays, clench twice: does the
   sound pause, with two soft low notes? Clench twice again: does it come back? Look left, then right: one higher
   note? Tell the assistant how many tries each took, and whether anything came up when you did nothing.
3. Next time you use the dream catcher, answer one "were you drifting?" by gesture.
4. Export data: the laptop can then check the calibration's own EEG (`files/hands-free/recordings/`) against the
   Python reference (`analysis/hands_free.py`), the first real gestures this code has seen.

## Our own headband connection (test, off by default)

The app can reach the headband in two ways. **BrainBit's own library** is the default. **Our own connection**
(`lib/headband/own/`, DECISIONS rows 210-219, `docs/own-ble-driver.md`) is ours from the Bluetooth packets up: it
mends a drop inside the same connection in seconds (the night stays in one file set), counts lost packets, never
needs the "Bluetooth stuck, restarting" path, and can never unpair anything. It has only met a made-up headband so
far, so it sits behind a switch.

Night screen, Headband section, **Headband connection** (between nights only: the headband keeps one connection):

- **Run the probe**: about 5 minutes with the headband on. The page says what to do in large type; a low tone means
  close your eyes, two rising tones mean open them, one tone means lift the electrode it names for 4 seconds. It
  checks the packet layout, the channel order, stop and start, the contact check, signal and contact together
  (command 5), and whether pairing is needed. "Headband on my head" off = the headband lies on the desk: connection
  steps only (1½ minutes), not a full pass.
- **The result**: one sentence on top (Passed / what is missing) and one per check. The full files stay in the
  app (`files/own-ble/probe/<time>/`, `summary.txt` first) and leave with Export data; on the laptop
  `scripts/import_phone.py` puts them in `_local/phone/own-ble/probe/<time>/`.
- **Use our own connection (test)**: offered after a passed probe (or with "Try anyway", which asks once more).
  On: the night recorder and every session (meditation, alpha-theta, dream catcher, morning check-in, sound) use
  our connection. Off: BrainBit's library, as before. The setting is read when a night or a session starts.
- **Measure contact all night**: appears when the probe saw command 5 work; a `contact ohms` line a minute in the
  night's `.log`.

The code: `lib/headband/finder.dart` (the switch; every screen asks the same `BrainBitFinder`),
`lib/headband/own/` (`protocol.dart` holds every constant, the unverified ones marked TO VERIFY; `driver.dart`;
`own_headband.dart`; `probe.dart`), `lib/ui/own_ble_*.dart`. Tests run on a fake headband
(`test/own_ble/fake_headband.dart`); `test/fixtures/own_ble_vectors.json` pins the Dart parser to the laptop's
Python parser (make it again with `python3 app/test/fixtures/make_own_ble_vectors.py`).

### Owner step: the probe on the phone, then one night with the switch on (15 minutes, then a night)

1. Install the new APK. Charge the headband. Stop any night first; phone sound on (media volume about half).
2. Night screen, scroll to Headband, **Headband connection**, **Run the probe**. Allow "Nearby devices" if asked.
   When it says so, put the headband on and tap **Ready**. Follow the page: sit still, close your eyes at the
   low tone, open them at the two rising tones, lift each electrode it names for 4 seconds.
3. Read the sentence on top.
   - **Passed**: go on to 4.
   - **Asks for pairing**: hold the headband's button 4 s until it blinks fast, leave "Pair first" on, run it again.
   - **Channel order not settled**: run it again and lift one electrode clearly off the skin each time.
   - **Anything else**: do not switch. Export data, import on the laptop, and give the assistant
     `_local/phone/own-ble/probe/<time>/summary.txt`.
4. Turn on **Use our own connection (test)** (and **Measure contact all night** if it is offered).
5. Record one night as usual. Once, on purpose: walk out of range for a minute and come back. The screen should go
   back to Recording by itself within seconds.
6. In the morning: is the sleep report there as usual? Then **Export data** and import on the laptop
   (`python3 scripts/import_phone.py <folder>`); tell the assistant. In the night's `.log` it looks for: the line
   `driver own Bluetooth LE ...` (the recorder's service used our connection) and its `mtu`, `headband lost` /
   `reconnected after N s ... same files`, `lost N samples in M gaps`, and the `packets:` line at the end.
7. If the night went wrong (no recording, many drops, an odd sleep report): turn the switch off. Nothing else
   changes; BrainBit's library is used again from the next start.

What only this test can show: every protocol guess (the probe), whether the phone reaches the headband's address
without a scan, the packet size it gets, pairing, drops with the screen off on HyperOS, and the battery a night
costs compared with BrainBit's library (the `phone battery summary` line of each night's `.log`).

## The DIY board (test, off by default)

The app can also record the ADS1299 board you build (eeg_ads1299_lab's bench firmware, its "E9" frames) over
**Wi-Fi**: the board's ESP32 sends one frame per UDP datagram to the phone's port 9000, and the night recorder only
listens (DECISIONS rows 360-369, `docs/diy-board.md`). Same files as the laptop's DIY recorder, in their own folder.

> **Safety.** The app never sends the board anything and nothing in it authorises connecting the board to a body,
> powering it, or changing its safety gates: follow eeg_ads1299_lab's bring-up card. Its prompts (R, V, then T or N)
> are yours to answer in a serial terminal. Today's firmware records only the chip's own test signal or its shorted
> inputs: **not EEG**, whatever the channel names say. The page and the night screen say so too.

Night screen, Headband section, **Headband connection** (between nights only), **Headband: BrainBit / DIY board
(test)**:

- **DIY board (test)**: Start night listens for the board instead of looking for the BrainBit. Its nights go to
  `files/recordings-diy/` (`.f32 .idx .log .markers.jsonl .header.json`, the laptop's layout: the board's sequence
  number, then each of its 4, 6 or 8 channels in volts at 4.5 V reference and gain 24, and a header naming them),
  never among the BrainBit nights. The page shows this phone's Wi-Fi address for the firmware's `UDP_HOST`, and the
  channel names (default O1 O2 Fz Fp1, the breadboard's plan; 4, 6 or 8 names from CH1, one per channel of the board;
  a board with another count records as Ch1..ChN).
- **While it records**: the night screen shows each channel's swing over the last second (the test square reads
  about 3750 µV), "Test signal, not EEG" (or "Shorted inputs, not EEG"), where the frames come from and how many
  samples were lost. A board restart or a new mode starts a new file set, never joined to the old one; lost frames
  are counted in the `.log`, never filled in; damaged, repeated and late datagrams are counted and dropped.
- **Off with the board**: the sleep report, the morning check-in, meditation and the other sessions (they say so
  when started), the drift-off detector, hands-free, the smart alarm's sleep model and the lucid dream cues (with the
  live sleep model they share): all read the BrainBit's O1 O2 T3 T4. The phone's alarm itself still rings. No contact
  or battery reading from the board.
- **Not built**: USB (OTG serial) to the phone, Bluetooth (the firmware has none). The 8-channel chip records on the
  phone since 2026-11-20 (DECISIONS 630-639).
- **Your data**: Export data takes `recordings-diy/` with everything else; `scripts/import_phone.py` files it under
  `_local/recordings-diy/`, beside the laptop's DIY recordings. Export a night lists BrainBit nights only.

The code: `lib/headband/diy/` (`e9.dart`, the decoder, a line-for-line port of `scripts/diy_board.py`; `link.dart`,
the UDP socket; `board.dart`, the board behind the app's headband interface; `night.dart`, the recorder's settings
for it; `settings.dart`), `lib/ui/diy_board_view.dart`. Tests run on a fake board (`test/diy/fake_board.dart`) and
on a real UDP socket on the test machine; `test/fixtures/diy_vectors.json` pins the Dart decoder to the Python one
(make it again with `python3 app/test/fixtures/make_diy_vectors.py`).

### Owner step: the board on the phone (15 minutes, once the board passes its bench steps)

Only after eeg_ads1299_lab's bring-up card has passed its steps on the bench; nothing here replaces any of them.

1. In the firmware's `board_config.h` (eeg_ads1299_lab `docs/PROTOCOL.md`, "Host behavior"): `USE_WIFI_UDP = true`,
   your home Wi-Fi's name and password in `WIFI_SSID` / `WIFI_PASSWORD`, and `UDP_HOST` = the phone's address that
   the app shows on Headband connection (DIY board chosen); port 9000 stays. Build and flash it as the card says.
   Phone and board on the **same Wi-Fi** (a private network: the frames are not encrypted). If the phone's address
   changes later, reserve it in the router or change `UDP_HOST`.
2. Install the new APK. Night screen, Headband section, **Headband connection**, choose **DIY board (test)**. Check
   the address and the channel names.
3. Power the board as the card says and answer its prompts in a serial terminal on the laptop (R, V, then T for the
   test signal). Close the terminal.
4. On the phone: **Start night**. Within a minute the screen should say "Recording the board's test signal. It is
   not EEG." and show about 3750 µV on every channel (the test square, 1.875 mV each way).
5. After 10 minutes: **Stop**, **Export data**, and on the laptop `python3 scripts/import_phone.py <folder>`; tell
   the assistant. In `_local/recordings-diy/<time>.log` it looks for `driver DIY board`, `datagrams from <board>`,
   the `mode` line, and any `lost N samples in M gaps (board missed X, link lost Y)` lines.
6. Choose **BrainBit** again on Headband connection before a BrainBit night or session.

What only this test can show: whether the board's datagrams reach the phone with the screen off (HyperOS and the
Wi-Fi lock the app holds during a board night), the loss rate over Wi-Fi, and whether the 4.5 V reference matches
the meter (the test square cancels it).

## If the headband drops out

With our own connection switched on (above) a short drop is mended inside the same recording; what follows is the
rule for BrainBit's library, and for a headband that stays away longer than 30 s.


The app saves what it has and reconnects by itself: first straight to the same headband (no Bluetooth scan,
because Android blocks scans while the screen is off), after 2, 5, 10, 30 s and then every minute; every
third try is a short scan instead. Each try is written in the night's `.log` with its time (`drop`,
`reconnect try`, `reconnected`), so gaps can be marked later. It never stops trying until you press Stop.

## Archive (every recording, its timeline and tags)

**More** → **Open the archive** lists everything the phone keeps, newest first, under each day (a day runs from 04:00
to 04:00, as in Trends): every night, nap, dream catcher and sound session, check-in, calibration, work session and
meditation. The bar on top shows the space each kind takes, in the Storage page's colours; tap a part of it (or its
word) to see only that kind, or **Storage** beside it for the space by kind of data and the automatic clearing. Each
row says when it ran and how long, what it is and **who started it** ("You: Start night", "By itself: the headband
watcher", "The headband watcher asked; you said Yes"), its tags (the button gives one: Start night means "sleep"; yours
follow), what was found in it, its size and whether the laptop holds a checked copy.

A night is one recording even when the headband dropped out and came back: the recorder's reconnects join it, and so
does whatever its sleep report scored with it (the dream catcher before it, a morning nap). Open a recording for its
**timeline**: lanes for Sleep (the sleep report's stages, where scored), Eyes closed, Drowsy, Talking (jaw muscle,
also chewing), Moving, Signal (none, or noisy), Work and Meeting (from the work session's file), Sessions and Your
tags. Zoom with two fingers or the buttons; tap a band to see it, anywhere else to see the raw signal at that moment
(every channel, as recorded or filtered, 5 to 30 seconds, earlier and later). **Add a tag** (sleep, work, walk,
meeting, meditation, rest, or your own word) on any span; tags are kept per recording in `archive/` and leave with
Export data and Share on Wi-Fi.

The activity lanes come from the detectors the rest of the app uses, run once per recording in the background while
the archive is open (a night takes about a minute on the laptop; the phone is untested), kept until the recording
changes, and never while a night or a session records. They need O1 O2 T3 T4 at 250 a second: another layout shows
its sessions and tags only, and says why. All their limits are planning values, not checked against what you did:
your tags are the check.

**Deleting** (the owner's rules): when the laptop holds a checked copy of a recording's raw files, **Remove from this
phone** removes them (the raw samples and index) and keeps every statistic: the sleep report, the session's results,
the logs and your tags. Anything only on this phone is the **Danger zone**'s, in red: it says it is the only copy and
asks twice, and only there can you pick **Everything** (the statistics too). A day's menu does the same for the whole
day. Nothing in use goes: the night being recorded, a running session, the night being scored, or anything written in
the last hour or being read on the phone. The laptop reports its checked copies itself when it copies (see Storage);
it uses the same delete helper as the Storage page.

### Owner step: look through a day, tag it, delete one (5 minutes, the morning after a night)

1. **More** → **Open the archive**. Find last night: is it one row, with the right start and end, and does it say
   who started it?
2. Open it. The lanes fill within a minute or two. Tap a few bands, then a moment on the clock: the signal page opens.
3. Add a tag where you know what you did (sleep, a walk, a meeting).
4. Delete an old test recording you do not need: the Danger zone asks twice when it is the only copy.
5. Tell the assistant: which bands were wrong and when; how long the lanes took for a night; anything you could not
   delete, and what it said.

## Walking (steps from the headband)

The headband has no motion sensor, but every step shakes it a little, and that leaves a rhythm in its signal. After a
recording ends, the app looks for that rhythm (every electrode the recording has, any layout): **walking** wherever it
holds for 30 seconds or more, its **pace** in steps a minute, **running** where the pace stays at 150 or more for a
minute, the **stops** of a minute or more between, and **steps** as pace times time, counted only where the rhythm is
clear. A walk also needs the headband to shake as much as in walking and a rhythm that is not a heartbeat's (the pulse
leaves one too, strongest asleep). The Archive's timeline gets a **Walking** lane with the pace; **Trends** gets **Walking** (minutes) and **Steps
(estimated)** per day with your usual, a round **i** for what the research says, and a line saying where the day's
steps came from. It runs once per recording in the background (from the Archive, a recording's page or Trends), never
while a night or a session records, and is kept even after the raw signal moves to the laptop.

**The phone as the second opinion** (off until you switch it on): **Settings** → **Count steps with the phone while
recording**. Android asks for "Physical activity"; then, while the headband records, the phone's own step counter is
written into the recording's log once a minute (nothing leaves the phone). Wherever the phone counted steps in a minute,
its steps are used and the minute says so; where it lay still (left on a desk), the headband's estimate fills in. It
works best with the phone in a front trouser pocket. Once 10 minutes have been walked with both, the app checks the
headband against the phone: its pace within 5 % in 8 of 10 minutes and the totals within 15 %, or its steps are left
out and only the phone's count and the walking minutes show. Until then Trends says the steps are not yet checked.

Slow strolls, short walks indoors, stairs, cycling and buses are not seen; a walk read at half or double the pace is
the main way it can be wrong. On the laptop, `scripts/walks.py` makes the same walk files from the raw recordings, and
`scripts/export_events.py --daily` sends each day's walking minutes and steps to utof_tracker
([docs/utof-interface.md](../docs/utof-interface.md)).

### Owner step: a walk with the headband and the phone (2 minutes to set up, then a walk of 15 minutes or more)

1. **Settings** → switch on **Count steps with the phone while recording**; allow **Physical activity**.
2. Headband on, **Start night** (it records in the day too); the phone in your front trouser pocket.
3. Walk as you usually do for 15 minutes or more, with a stop or two; then **Stop**.
4. Open **Trends** (Walking, Steps (estimated) and where they came from) and the recording in the **Archive** (the
   Walking lane: tap a band for its pace and steps).
5. Tell the assistant: roughly when you walked and stopped, and whether the lane matches; the steps Trends shows and
   its source line; whether Android asked for Physical activity; anything odd.

## Export data (everything, every few days)

Everything the app keeps stays inside it until you export it: nights, sleep reports, check-ins, meditations,
alpha-theta and its notebook, the replay check, dream catcher answers, notes and prompts, sound sessions. **Export
data** copies all of it into a folder you pick once, adding only what is new each time. Nothing on the phone is
deleted, and it never runs while a night records. The laptop then checks every file against the export's list of
checksums (`manifest.json`) before copying it in.

### Owner step: set it up once, then export every few days (5 minutes)

1. Between nights, on the main screen scroll to **Your data** and tap **Export data**.
2. Tap **Pick a folder**. With Syncthing on the phone, pick its folder (the one it shares with the laptop); else open
   `Download`, make a folder `EEG` and pick it (Android does not allow `Download` itself). Tap **Use this folder** and
   **Allow**. The app keeps this permission, so you pick it only once.
3. Tap **Export new** and keep the app open; the cells fill as files arrive. The first export copies everything
   (about 160 MB a night), later ones only what is new. **Stop** keeps what was copied.
4. On the laptop, get the folder `eeg-export`: Syncthing brings it by itself (share it from the phone as "Send
   Only"); otherwise, with the phone on USB, `adb pull /sdcard/Download/EEG/eeg-export /tmp/eeg-export`, or copy the
   folder with the file manager.
5. In the repo folder on the laptop: `python3 scripts/import_phone.py /tmp/eeg-export` (or the Syncthing folder). It
   prints what it copied and ends with "Everything in the phone's list is on the laptop." A `PROBLEM:` line says what
   to do (wait for Syncthing, or **Export everything** on the phone). Run it again any time: it copies only what is
   new and never overwrites a file silently.
6. Every few days, **Export new** again. The main screen says when the last export was, in amber once new data has
   been only on the phone for 3 days.

Good to know:

- Raw nights go into `_local/recordings/` next to the laptop's own; everything else into `_local/phone/` in the
  app's layout. Phone sleep reports are in `_local/phone/nights/`, apart from the laptop's own.
- The export folder grows as large as the app's data. Once the import says everything is on the laptop, you may
  delete the files in `eeg-export` on the phone to free space; the app keeps its own copies, and the next import
  still checks that the laptop has every file.
- The replay check's files (`replay-check/`) hold the hidden order of live and replayed sessions. They are exported
  so a lost phone does not lose the check; do not open them (or ask the assistant to) before the app shows the
  results.
- **Change folder** starts again in the new folder: use **Export everything** there.

## Share on Wi-Fi (the laptop watches and copies while the phone records)

Off unless you switch it on. With it on, the phone answers the laptop over your home Wi-Fi: the live signal with
contact, battery and drops (the same pages the laptop recorder has), and every file the app keeps, so the laptop has
a copy of the night within minutes instead of after Stop and Export data. Nothing is sent anywhere by itself (the
laptop asks), nothing goes to the internet, and nothing on the phone can be changed or deleted this way: the paired
laptop can only say that it holds a checked copy of a file, prove it again before anything leaves, and the phone
itself then decides what leaves it (Storage, below).

**Safety, in plain words** (DECISIONS 750-759, after a security review). It is your brain data, so: every request
needs the code the app shows (12 characters), or, from the paired laptop, a signature made with a key the two worked
out at the scan and never sent; only devices on the same local network are answered; it turns itself off 12 hours
after you switched it on, and 15 minutes after Stop, unless a laptop is paired: then it stays on until you switch it
off or tap **Forget this laptop** (DECISIONS 675). It is **not encrypted** (plain HTTP): a device on the same Wi-Fi
could listen in. So a paired phone shares only on your home Wi-Fi (the laptop recognises its own router and tells
the phone) or on a Wi-Fi you allow for 12 hours with **Share here for 12 hours** on the sheet; anywhere else it is
paused. No notification comes with it (row 678): the line under the switch and the sheet say where it shares and
when the laptop last copied, and so does the laptop tray's menu. The sheet cannot be screenshotted, and its QR code
holds only the address. **New code** shuts out every device that has the old one; the paired laptop does not use
the code: **Forget this laptop** shuts it out.

**The phone also sends by itself** (DECISIONS 840-849, `../docs/phone-link.md`). With a laptop paired, the phone
does not wait to be asked: about every 15 minutes while it is on your home Wi-Fi, and a few seconds after each
recording or session ends, it sends the laptop whatever the laptop lacks. This works with the app closed and the
screen off, and there is no notification: Android runs it as a short background job. It goes only to the paired
laptop (which must prove the pairing first) and only at home (the laptop recognises its own router). During a
recording the laptop can also still ask the phone, as before; the two ways use the same rules and never copy a file
twice. The Share sheet says so in one sentence, and the laptop tray shows "Phone: sent its files by itself 14:05".
If something else on the phone holds port 8765, the app now serves on the next free port (8766-8768) and keeps
trying during a recording; before, one failed start meant no sharing until Stop.

**Connecting the laptop by one scan** (DECISIONS rows 530-539 and 753, `../docs/phone-link.md`). The square code on
the laptop works once, for 5 minutes. The app asks before anything is sent; the laptop proves it showed that square
code, and then both work out the same key from it, so neither the code, the key nor the phone's own code crosses the
Wi-Fi. The two remember each other, so next time there is nothing to scan: a Wi-Fi drop on either side, a restart, a
new address or **New code** needs no new scan (the laptop finds the phone again on your home network; its tray keeps
its side running, DECISIONS 677). **Paired before this version?** Pair once more (one scan): the app and the tray
say so, and nothing leaves the phone by itself until then.

**It cannot hurt the recording.** The server runs apart from the recorder, which only hands it copies of the samples
and never waits for it. If the server fails, sharing goes off with one line in the night's log and the night goes on
(DECISIONS row 221; tested with servers that crash and hang). An error inside the server itself no longer stops it:
it is written to the log and the server goes on answering (row 587). The SHA-256 the laptop's list needs are kept
between app updates, so the first list after an update takes seconds, not minutes (row 585). The night's sleep
scoring waits while the laptop copies (row 583).

**Between nights it answers while the app runs (row 678, which replaced row 589 on 2026-11-20).** There is no
"Sharing on Wi-Fi" notification any more (the owner did not want a permanent, player-like one). The app answers while
it is open or holds a session (a Work session, meditation, ...: their own card keeps it running); during a night the
recorder's service answers. In the background Android may freeze the app, and a frozen app's server takes connections
and never answers: the laptop then copies what it missed the next time the app is open, a session runs or a night
records. Nothing is lost.

**If the laptop loses the phone at night, nothing is lost (rows 610-616).** The night stays on the phone and the
laptop copies what it missed once it reaches the phone again (Export data works without Wi-Fi at all). On 2026-11-20
the owner's Xiaomi dropped off the network soon after the screen went off. The app holds a Wi-Fi lock whenever it
shares, but from Android 14 no app can keep Wi-Fi out of power saving with the screen off, so **the phone's own
settings decide**. Now the night's `.log` has a `wifi ...` line whenever the phone's Wi-Fi changes (and every 30
minutes; never the network's name), and `scripts/phone_night_check.py` says "Wi-Fi off from 03:25 to 07:40" or
"connected all night".

**Phone settings to check before a night the laptop mirrors** (Xiaomi names; they move between HyperOS versions and
were not checked on the owner's phone):

- **Keep Wi-Fi on during sleep** → Always, if the phone has it (Settings → Wi-Fi → Additional settings or Advanced
  settings). The night screen's Phone section says so when the phone reports Wi-Fi set to sleep with the screen off.
- **Battery saver** and **Ultra battery saver** off for the night (the Phone section shows battery saver). In the
  battery settings, nothing that turns off Wi-Fi or mobile data when the phone is locked.
- **Wi-Fi assistant** (Settings → Wi-Fi): "switch to mobile data" when Wi-Fi looks weak can take the phone off Wi-Fi
  with mobile data on; turn it off for these nights.
- **The VPN app**: with **Always-on** and **Block connections without VPN**, the laptop may not reach the phone. Let
  the VPN bypass the local network (LAN), or turn lockdown off. The Phone section reminds you when a VPN is on (an app
  cannot see the lockdown setting itself).
- **EEG Tracker** itself, as for every night: battery saver No restrictions, Autostart on.
- **The router**: a fixed address for the phone (a DHCP reservation) keeps the laptop's commands working.

### Owner step: connect the laptop by one scan, then a night (2 minutes; the first night doubles as the phone test)

1. Phone and laptop on your home Wi-Fi. On the laptop, in the repo folder, run `python3 scripts/phone_link.py` (or
   ask the assistant to run it). It shows a square code. Leave that window open.
2. Open the phone's camera and point it at the code. Tap the link the camera shows; the browser opens a page with
   **Open EEG Tracker**: tap it (it often opens the app by itself).
3. The app asks **Connect to this laptop?** with the laptop's name: tap **Connect**. It switches Share on Wi-Fi on
   and says **Connected**. The laptop window says "Paired", then copies the phone's files every 2 minutes; the live
   pages are at `http://localhost:8770/` on the laptop. Raw nights land in `_local/recordings/`, everything else in
   `_local/phone/`.
4. Start the night as usual. The notification says "shared on Wi-Fi at <address>". Sleep. In the morning, Stop and
   leave the app open for a few minutes: sharing stays on for 15 minutes so the laptop gets the end of the night.
5. **What to tell the assistant after the first night**: did the camera open the link, and did **Open EEG Tracker**
   open the app by itself or only after a tap? Did the laptop window keep printing lines all night with the phone's
   screen off, or "No answer" for long stretches? Was the phone on the charger? (The night's `.log` has the phone
   battery once a minute and the phone's Wi-Fi at every change:
   `scripts/phone_night_check.py` turns them into "Wi-Fi off from ... to ...".)

Next time: nothing to do while the tray runs (or run `python3 scripts/phone_link.py` again) with **Share on Wi-Fi**
on: the laptop finds the phone by itself, no scan. If the app is new or forgot the laptop, scan a new code.

Good to know:

- The code stays the same until you tap **New code**; the paired laptop does not need it. For the commands by hand,
  give it as `EEG_PHONE_TOKEN=<code>` (never on the command line, where other programs can read it).
- Away from home (a friend's, a hotel) the sheet says **Paused on this Wi-Fi**: tap **Share here for 12 hours** to
  let the paired laptop copy there; **Stop sharing here** ends it. Only on a Wi-Fi you trust.
- Between nights the phone answers while the app is open or a session runs (no notification of its own, row 678).
  The app keeps the screen on for the first 15 minutes.
  During a night it answers with the screen off, as long as the phone keeps its Wi-Fi (the settings above).
- During a night the laptop's **Re-check contact** button does nothing: the phone checks contact once, at the start
  (DECISIONS row 52). The Sleep page and the morning result are the laptop's own jobs and use the laptop's files,
  which `pull_phone.py` keeps filled.
- If the phone's address changes (the router gave it a new one), the main screen and the sheet show the new one
  within a minute, and at home the paired laptop finds it within 10 minutes; nothing to restart then. Laptop commands
  started by hand need the new address. A fixed address for the phone in the router avoids this. **Forget this
  laptop** on the sheet refuses it from then on.
- Did the code expire before you scanned it? Press Enter in the laptop window for a new one. Each code works once.
- A VPN on the phone can stop the scan from reaching the laptop: turn it off for the scan, or let it bypass the local
  network.
- By hand, without the scan (the sheet shows both commands whole): the live pages with
  `EEG_PHONE_TOKEN=<code> python3 scripts/page_server.py --recorder http://<address>`, the copy with
  `EEG_PHONE_TOKEN=<code> python3 scripts/pull_phone.py http://<address>`. Markers and acks need the pairing.
- Without Wi-Fi but with a cable: `adb forward tcp:8765 tcp:8765`, then use `http://127.0.0.1:8765` as the address
  (or `python3 scripts/phone_link.py --phone-at http://127.0.0.1:8765` after a scan). When the sheet says the address
  is **not found**, it shows this way with the commands already on `127.0.0.1`.
- The address comes from Android's own list of networks (a VPN app or mobile data on at the same time does not hide
  it), with the phone's interface list as a fallback; the phone answers only devices on its Wi-Fi network and the
  cable, never mobile data or a VPN (DECISIONS rows 560-564). If the address stays "not found" while the phone is on
  Wi-Fi, `adb logcat -d -s eeg_tracker flutter` shows what each source returned.
- Export data stays the full, checked hand-over (and the only one that works without Wi-Fi). Files the laptop
  already mirrored are found "already here" by `import_phone.py`.

What else it is useful for:

- **Your own signal on a big screen**: the live page on the laptop or a TV browser while you fit the headband.
- **The laptop's sound pages driven by the phone's recording**: `sound.html` and `beats.html` read the same live
  stream, so the laptop's speakers can follow a night or a session the phone records.
- **A continuous backup during the night**: if the phone dies at 5 a.m., the laptop has the night up to the last
  2 minutes.
- **Other EEG tools**: `EEG_PHONE_TOKEN=<code> uv run --no-project --with pylsl python scripts/lsl_bridge.py --url
  http://<address>/stream` re-publishes the phone's signal as Lab Streaming Layer streams (MNE-LSL, OpenViBE, LabRecorder).
- Meditation, the check-in, the dream catcher and sound sessions are served live too while they record.

## Storage (what the app keeps on this phone; More, Storage)

The owner (2026-11-20): "move data off the phone whenever possible… I want to just live my day and have the recording
saved." Raw recordings are the bulk (about 18 MB an hour of headband, less once packed after a day), so they leave the
phone once your laptop holds a copy it has **checked**: after it copies a file over Share on Wi-Fi, the paired laptop
reads its copy again from its own disk and tells the phone the copy is byte for byte the same (`scripts/pull_phone.py`
and `scripts/phone_link.py` do it by themselves; DECISIONS 690-699, `../docs/phone-link.md`).

- **By itself:** while a laptop is paired, a raw recording leaves the phone **3 days** after the laptop checked it,
  between nights, never while something records, never before last night's sleep report is made. Per kind (sleep
  nights, work sessions, check-ins, the DIY board, the dream catcher's spoken answers) you can pick 3 days, 1 week,
  1 month or Never. **Only deletes recordings your laptop has checked. Nothing that's only on this phone.** Right
  before, the phone asks the laptop to prove it still holds those exact bytes (random parts of each file); no proof
  at that moment, nothing is deleted, and a laptop that lost a file gets it copied again (DECISIONS 756).
- **The statistics always stay:** sleep reports (stages and minutes), Trends, check-in results, session summaries,
  transcripts, every setting and each recording's notes (its log, header and markers). Every page that shows them
  works as before; a page that needs the raw signal says "This night's raw recording is on the laptop now" (Score
  again on a report from an older scorer, the lucid cues' search for dream signals, playing a spoken answer).
- **The page** shows the space as one bar by kind (tap a part to open it), the phone's free space, what the laptop
  holds checked copies of, the kinds with their sizes, **Clear selected** (only what the laptop has checked; the cache
  too, which the app makes again) and, at the bottom in red, the **Danger zone**: what is only on this phone, which
  you can delete there by hand after two questions. Nothing there is ever deleted by itself.
- On the laptop nothing is ever deleted; `_local/phone/acks.jsonl` lists every file the laptop vouched for, and a
  night whose raw files left the phone is marked "moved from phone" by `scripts/catalog.py`.

### Owner step: check that a night left the phone (5 minutes, 4 days after pairing)

1. Leave the laptop's `python3 scripts/phone_link.py` running (or the tray, once it hosts the link) with Share on
   Wi-Fi on; its window prints "told the phone N files are safe here".
2. Four days later open **More, Storage**: **On the laptop** has grown, and the oldest nights no longer count in
   **Sleep nights, raw recordings**. Their sleep reports are still on the Night tab and in Trends.
3. On the laptop: `python3 scripts/catalog.py` lists those nights with "moved from phone"; their `.f32` files are in
   `_local/recordings/`.
4. Tell the assistant if a page says something odd where the raw recording used to be.

## Export a night

The recordings stay inside the app. To get one night out on its own (Export data above takes everything):

1. Stop the night (Export is hidden while recording).
2. Scroll down to **Your data** and tap **Export a night**.
3. Tap the night you want.
4. Android's folder picker opens. Pick a folder, or make a new one (for example `Download/EEG`; Android
   does not allow `Download` itself), then tap **Use this folder** and **Allow**.
5. The app copies the night into a new folder there, named like `eeg-night-2026-11-18`, and says how many
   files it copied.

From there: `adb pull /sdcard/Download/EEG/eeg-night-2026-11-18/`, a USB cable, or pick your Syncthing
folder in step 4. The night also stays in the app. There is no Delete button yet; Settings > Apps >
EEG Tracker > Storage > Clear data deletes every night (about 160 MB each).

## Logs, usage and battery (More, "How the app runs")

Three pages under **More** show what the app writes about itself, all in the app's private `files/logs/` folder
(DECISIONS rows 710-719; what is kept and how to delete it: [docs/app-logging.md](../docs/app-logging.md)):

- **App log**: every part of the app's lines of the last 7 days (the recorder's drops and reconnects with their
  times and causes, Share on Wi-Fi going on and off and what the laptop copied, scoring and packing times, sessions,
  auto-start's checks, errors with the screen they happened on and what was running). Filter **All / Problems /
  Errors** and by part of the app; tap a line for its facts and stack. **Copy** puts the lines shown on the clipboard;
  **Share the log** opens Android's share sheet with the last 3 days' files (to send to the assistant).
- **How I use the app**: the switch **Record how I use the app** (on; only inside this app, never what you type, never
  sent anywhere), then for today, 7 or 30 days: time in the app, each screen's time, the features that ran, the most
  tapped controls, the pages never opened, scrolling, hints and questions (shown, answered, ignored; whether a break
  followed a break hint; how often auto-start guessed right), screens that stutter, start-up time and storage per folder.
- **Battery**: what costs the phone's battery, feature by feature (the Signal tab, a night with the headband link,
  Share on Wi-Fi, sessions, scoring, ...), in mAh an hour with one plain sentence each (how much is the screen, how
  much the app's own processor time), every combination measured, the phone with the app closed, and the headband:
  its battery per recording without the gauge's stuck values, its contact over the day and its link's drops.
  **Measure battery** (on) reads Android's battery numbers every 1-2 minutes while the app is open or something
  runs, every minute in a night; it wakes nothing.

Everything also reaches the laptop with **Export data** and **Share on Wi-Fi** (`_local/phone/logs/`), so the
assistant can read the same records. For more detail the assistant can use Android's own battery history from the
laptop (the guide in [docs/app-logging.md](../docs/app-logging.md)).

### Owner step: a day and a night with the records on, then a look (5 minutes)

1. Nothing to switch on: use the app as usual for a day and a night (a session or the Signal tab helps).
2. Next day open **More**, **Battery**: read "What costs the most" and the headband's line for the night.
3. Open **How I use the app**: look at Screens, Most tapped and Not opened.
4. Open **App log**, tap **Problems**; if there is anything, tap **Share the log** and send it to the assistant.
5. Tell the assistant:
   - Which feature costs the most, and does that match what you feel about the battery?
   - Anything in "Not opened" you want gone, or something you open often that should be easier to reach?
   - Any screen marked "stutters", and any error in the log?

## First phone test (1 hour, screen off)

From `docs/research/android-overnight-ble-xiaomi.md` section 8. Nothing here has run on a phone yet.

1. `adb install -r eeg_tracker-recorder.apk`, open the app, fix every row under "Phone" (Nearby devices,
   battery optimisation, notifications; on Xiaomi also Autostart and Battery saver: No restrictions),
   lock the app in Recents.
2. Headband on, Start night. Accept a pairing prompt if Android shows one. Check the contact words.
3. `adb shell dumpsys activity services io.github.utof.eeg_tracker` shows `ForegroundService` with
   `isForeground=true` and type `connectedDevice`; `adb shell dumpsys power | grep -i ForegroundService`
   shows the wake lock.
4. Screen off, unplug USB (or `adb shell dumpsys battery unplug`), wait 60 minutes.
5. Wake the phone: the strip should be full, data age about 1 s. Stop. Note the battery drop.
6. Export the night to `Download/EEG` (above), then `adb pull /sdcard/Download/EEG/` and run
   `scripts/to_bdf.py` on the `.f32` files: expect at least 99.9 % of the expected samples and no gap.
7. Collect `adb shell am get-standby-bucket io.github.utof.eeg_tracker` and
   `adb logcat -b events -d | grep -i -E "am_kill|am_proc_died"`.
8. Drop test (T3(d)), 5 minutes: start a night, screen off, carry the headband to another room for 60 s,
   bring it back, wait 3 minutes. Stop, export, and look in the `.log` files for `reconnect try`. A line
   `(direct to ...): connected` means reconnecting without a scan works on this phone; if only `(scan)`
   lines connect, or the app restarted itself, tell the assistant (DECISIONS row 49).

If the headband is not found without location permission (test T0), see DECISIONS row 54.

### Extra checks for the same session

These settle the open questions of the research report (`_local/research/2026-11-18-07-app-tech-and-data-pass2.md`,
step 2). All take a few minutes.

1. **Which phone is it?** Run `adb shell getprop ro.product.model` once and write the answer in your notes
   (Xiaomi 11T or 12T). Also `adb shell getprop bluetooth.core.gap.le.conn.min.limit` (it may print nothing).
2. **Does the drop test survive deep sleep?** Right before the drop test (step 8 above), put the phone into
   Android's deep-sleep state on purpose: with the night recording, the screen off and the phone
   unplugged from the charger (`adb shell dumpsys battery unplug` if the USB cable has to stay in), run
   `adb shell dumpsys deviceidle force-idle`. It prints `Now forced in to idle mode`. Do the walk-away, then
   leave the idle state with `adb shell dumpsys deviceidle unforce` (or `adb shell dumpsys battery reset`
   if you used `battery unplug`). In the `.log` look for `reconnect try ... (direct to ...): connected`. If
   only scans connect, or nothing does, tell the assistant: that decides whether the Companion Device
   Manager is needed.
3. **Link speed (3-minute Bluetooth log with one walk-away).**
   1. On the phone: Settings > About phone, tap "OS version" 7 times (or "MIUI/HyperOS version") until it
      says you are a developer. Then Settings > Additional settings > Developer options > turn on
      **Enable Bluetooth HCI snoop log** (the wording may be "Bluetooth HCI snoop log"; set it to
      "Enabled" or "Enabled filtered"). Switch Bluetooth off and on once so the log starts clean.
   2. Start a night, headband on. Wait 1 minute. Carry the headband out of range for about 30 seconds and
      bring it back, then wait until the `.log` says `reconnected`. About 3 minutes in all. Press Stop.
   3. Take the log off the phone. Easiest: `adb bugreport hci-bugreport.zip` and open
      `FS/data/misc/bluetooth/logs/btsnoop_hci.log` inside it. Or, if the phone lets `adb` read it,
      `adb pull /data/misc/bluetooth/logs/btsnoop_hci.log` (or `/sdcard/btsnoop_hci.log` on some Xiaomi
      builds; try `adb shell ls /data/misc/bluetooth/logs/ /sdcard/ | grep -i snoop`).
   4. Keep the file. The assistant opens it in Wireshark and filters `hci_evt.code == 0x3e` for "LE
      Connection Update Complete" to read the interval (15 ms means the fast link).
   5. Turn the snoop log off again (it grows).
4. **Where to read the new lines.** In each night's `.log`, after you export it (above; the app's own folder
   is not readable by `adb` on a release build):
   - `phone battery 87% charge 3612345 uAh current -310250 uA unplugged temp 31.2 C` once a minute while
     recording. Charge counter is the real drain meter (uAh = 1/1000 mAh); the sign of the current depends
     on the phone, so ignore it. `plugged usb` means the cable was in: that night is not a drain
     measurement.
   - `packets: 7200000 samples, missing 0 in 0 gaps, repeated 2, longest gap 0 samples` every 10 minutes,
     at the end of each run (before `total samples`) and, as `end of night, packets: ...`, at the very end.
     It counts the whole night so far. "Missing" is numbers skipped inside a run; the hole made by a
     reconnect is not in it (see the `drop` and `reconnected` lines for that). "Repeated" is a sample with
     the same number as the one before, or an older one.
   - `phone battery summary: 8% in 8.0 h = 1.00 %/h, 320 mAh = 40 mAh/h` as the last lines of the night.
     The report's estimate is 1-2 % an hour; for a fair number unplug the phone, no charger all night, and
     if you can, do one 3-hour run with the app idle and one recording for comparison.
5. **Many drops in one night with BrainBit's SDK (about 40 minutes).** After every drop the recorder leaves the
   lost sensor object alone and makes a new one (DECISIONS row 49). Nothing frees the old one: the SDK's only
   way to free it (`dispose`, which ends in its native `freeSensor`) is a call on a headband that is out of
   range, and on the laptop such calls crashed the SDK. If the SDK keeps one Bluetooth client per sensor,
   Android's limit of about 30 per app would stop every reconnect after about 30 drops in one app process.
   (Our own connection does not have this: a lost headband object closes its own link.)
   1. The "own connection" switch off. Start a night, screen on, phone on the charger.
   2. `adb shell dumpsys bluetooth_manager > bt-00.txt`
   3. 35 times: switch the headband off, wait until the notification says "Reconnecting", switch it on, wait
      until it says "Recording" again (about a minute each time). After every 10th:
      `adb shell dumpsys bluetooth_manager > bt-10.txt` (then `bt-20.txt`, `bt-30.txt`, `bt-35.txt`).
   4. `adb logcat -d > logcat.txt`, then Stop and export the night.
   5. What to look at: in each `bt-*.txt`, the section `GATT Client Map`: its `Entries:` number and how many
      entries name `io.github.utof.eeg_tracker`. One more for each drop means every lost sensor keeps its
      client. In the night's `.log` files: count the `drop (` lines, and note the drop after which
      `reconnect try ... failed` lines pile up (errors with `133`, `GATT`, `no resources` or `too many`).
      In `logcat.txt`: `grep -i -E "registerClient|too many|no resources|status=133" logcat.txt`.
   6. Tell the assistant either way. A count that grows with each drop means the lost sensors must be freed
      once the next one records, which first needs its own crash test; a flat count means nothing to do.
