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

- Files: `<stamp>.f32/.idx/.log` in the app's private folder (other apps cannot read it), the same format as
  `scripts/record_night.py` (`docs/data-format.md`); join a night with `scripts/to_bdf.py`. Only **Export data**
  (everything the app keeps) and **Export a night** copy anything out (below; DECISIONS rows 53, 56 and 150-156).
  Android backups and phone-to-phone transfers skip the app completely (row 57), so a new phone starts empty:
  export first.
- Export data: `lib/export/` (what leaves the phone, the index, the manifest), `lib/ui/export_*.dart`,
  `android/.../DataExport.kt` (the folder grant), `../scripts/import_phone.py` on the laptop; DECISIONS rows 150-156.
- Recorder: a foreground service of type `connectedDevice` (`lib/recorder/recorder_service.dart`) whose
  isolate owns the BrainBit session (`lib/recorder/night_recorder.dart`, rules in DECISIONS row 17 and rows 49-54).
- Screen: `lib/ui/`, design in `../DESIGN.md`.
- Meditation: `lib/feedback/` (the laptop page's feedback core in Dart), `lib/sound/` (flutter_soloud),
  `lib/meditation/` (session and report), `lib/ui/meditation_*.dart`; DECISIONS rows 72-77.
- Sleep report: `lib/sleep/` and `lib/ui/sleep_*.dart`, scored on the phone after Stop (below); DECISIONS rows 95-99,
  night extras (jaw, movement, signal quality) rows 140-146.
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
- Sound for states: `lib/states/` (presets, stop rule, readout, files, session), `lib/sound/state_synth.dart` (the
  sound, made in the app) and `lib/sound/soloud_state_sound.dart`, `lib/ui/states_*.dart` and `lib/ui/sound_score.dart`;
  DECISIONS rows 130-139.

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
and Morning section in eighteen, sound for states in fourteen, Export data in nine and Headband connection in eleven to `build/screens/*.png`
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

## Emulator smoke test

What `flutter test` cannot reach (ONNX Runtime, SoLoud, the microphone, the folder picker, the foreground service,
NeuroSDK2's native library) runs on an x86_64 Android emulator on the laptop, no phone needed (first run 2026-11-18,
DECISIONS rows 160-161). It found two bugs: Export data could not open (an isolate closure that sent the whole page)
and Android's own files were exported. What it cannot test: the headband (no Bluetooth device), real sound and
microphone (the emulator's host audio is a dummy here), the phone's speed and Xiaomi's background rules.

```bash
source ~/.local/share/linsa/env.sh
export ANDROID_SERIAL=emulator-5554        # always: another device (the phone) may be on USB
# once: an AVD (API 36 google_apis x86_64, 3 GB RAM)
avdmanager create avd -n eeg_smoke -k 'system-images;android-36;google_apis;x86_64' -d pixel_6
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
   a minute per model part), but only with `hw.cpu.ncore=2` in the AVD's `config.ini`: the translator's stand-in
   `/proc/cpuinfo` lists 2 processors, and with 4 cores in sysfs ONNX Runtime's CPU detection (cpuinfo) crashes
   while the library loads, at app start. That crash is the emulator's, not the phone's.
7. **Sessions with the phone locked** (DECISIONS rows 190-197):
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
8. **Share on Wi-Fi** (2026-11-19): switch it on in Your data, read the code from the sheet (`tool/emu.py texts`),
   `adb forward tcp:18765 tcp:8765`, then `curl -H "Authorization: Bearer <code>" http://127.0.0.1:18765/state`
   (401 without the code), `scripts/page_server.py --recorder http://127.0.0.1:18765 --token <code>` and
   `scripts/pull_phone.py http://127.0.0.1:18765 --token <code> --once --dest <scratch>`; Start night (the
   recorder's service serves, status `reconnecting` without a headband), Stop (the app serves again), switch off
   (the port closes). All of it passed; the emulator cannot show Wi-Fi with the screen off or the battery cost.

8. **The smart alarm inside the night recorder** (DECISIONS rows 230-231): `flutter build apk --release
   --target-platform android-x64 -t tool/alarm_smoke.dart`, install with `-g`, put one recording into
   `files/smoke/` (adb root, the app's owner and SELinux label, as in step 1) and optionally `files/smoke/plan.json`
   (`{"mode": "night", "startInMin": 35, "windowMin": 10, "speed": 2, "skipS": 330}`), open the app, lock the phone
   (`adb shell input keyevent 26`). The real recorder service replays the recording at 2x with the real smart alarm:
   `adb logcat | grep -E 'SMOKE|EegWake'` shows the model's calls from inside the service's engine (time per call,
   stage, the process's memory) every 20 s, then the early ring (`EegWake: ringing (smart)`, the notes, after 3
   minutes `loud`); tap **I'm awake** on the page over the lock screen. With `{"mode": "killed", "endInMin": 2}` it
   only sets the phone's alarm: `adb shell kill -9 $(adb shell pidof io.github.utof.eeg_tracker)`, lock, and the
   alarm must still ring 2 minutes later (`EegWake: ringing (window end)`). Reinstall the app afterwards. The
   scripts used on 2026-11-19 are kept in the lane's `_local/emu/` (not in the repository).

8. **The dream catcher's speech to text** (DECISIONS rows 250-257): push a made-up session and its WAVs (the laptop
   check's TTS clips, `_local/stt/check/clips/`, never personal audio) into `files/dream-catcher/` as in step 1, open
   **Dream catcher**, tap **Download (671 MB)** under Answers as text and wait for "Speech model on this phone"; the
   answers are written out at once: `files/dream-catcher/<stamp>-r<n>.text.json` holds the text and `tookS`. Then
   delete `files/nights/*.report.json` and bring the app back to the front: the night is scored again in the same
   process, so both ONNX Runtimes work side by side. On 2026-11-19 (release x86_64 build): the download took about
   100 s and passed its hash check; two Russian and one English answer came out word for word, 0.38 s per second of
   audio (2.0-2.8 s an answer, the model already loaded), the room-hiss answer as "No words heard." in 0.2 s; the
   night scored again afterwards; the app was back to 154 MB (PSS) once the speech isolate had ended.

The night of 2026-11-17 (58 recordings, 12.9 h) scored on the emulator in 99 s with a peak of 438 MB (PSS; 561 MB
RSS) and the same stages as the laptop's ONNX check (96.6 % of epochs agree with the laptop's one-pass scoring; see
`assets/models/README.md`). The emulator's speed is the laptop's, not a phone's.

## Meditate

1. Make sure no night is being recorded (the headband talks to one thing at a time). Put the headband on and
   switch it on. Use wired headphones or the phone's speaker: Bluetooth headphones add about 0.3 s, so the
   sound comes late.
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
6. A third tone ends the session. The report shows minutes settled, bells, restless moments (jaw, blinks,
   movement), drifting moments, a line of how calm the sound was, and how this session compares with earlier
   ones (a range from the 4th session). **Stop** ends early and keeps what there was (not during calibration).

The **i** button shows what the research says (`docs/evidence/meditation-feedback.md`): a guided practice, not
a treatment, and no "meditation depth" is measured. Each session is kept in the app's private folder,
`files/meditations/<time>.meditation.json` (the summary) and `<time>.session.json` (every sample and decision,
in the laptop page's session format, so it can be replayed). **Export data** copies them out (below).

If the headband drops out, the countdown pauses ("No signal") and the app reconnects by itself.

## Sleep report

After **Stop** the app scores the night on the phone (AnySleep, the laptop's sleep model, three runs; DECISIONS
rows 95-99). The main screen then shows last night's time asleep under the strip; **Sleep report** opens the
night: time asleep and time not recorded, a chart of the stages on the clock (missing data hatched amber, sleep
periods numbered), each period's start and end, deep, dream and light sleep, wake-ups over 5 minutes and missing
minutes, and the past nights. It is a first guess: the model is not validated on this headband (the **i** button
shows `docs/evidence/sleep-scoring.md`).

The night extras come from the shared detectors (`lib/detectors/`), run over the same samples in a second background
isolate while the model works: the note under the totals says how much of your sleep was read through noise; a
**Signal** line under the chart marks noisy stretches (amber dots) and stretches with no usable electrode (solid
amber); **Jaw and movement** gives jaw-muscle bursts and movements per hour asleep with the earlier nights' jaw numbers
(a trend, not a teeth-grinding test; its **i** shows `docs/evidence/jaw-and-blinks.md`) and the night hour by hour;
the past nights show "jaw N an hour". If that pass fails, the report is still there without them. It also runs when the app is opened between nights, for any night whose
report is missing or 10+ minutes behind, and never while a night records.

- Code: `lib/sleep/` (preparation as `scripts/score_sleep.py`, the model, sleep periods as
  `scripts/sleep_report.py`, the night extras as `analysis/night_extras.py`, the report file),
  `lib/ui/sleep_*.dart`. Models: `assets/models/` (see its README
  for how they were made and checked). Reports: `files/nights/<date>.report.json` (`docs/data-format.md`).
- If scoring stops (for example the phone runs out of memory), the main screen says so and offers **Try again**;
  it does not retry by itself.
- ONNX Runtime cannot run inside `flutter test`, so the models are checked in Python:
  `uv run --project analysis --group onnx --with pytest pytest analysis/tests/test_anysleep_onnx.py` (from the
  repo root), and on a recorded night with `scripts/export_anysleep_onnx.py --check-only --night ...`.

### Owner step: how long does the phone take? (once, about 15 minutes)

Nothing about the phone's speed or memory has been measured yet. On the laptop a 12.9-hour night took 17 s to
prepare and 26 s for the model; a phone is likely 3-10 times slower.

1. Record a night as usual (or use the first real one). In the morning press **Stop** and leave the app open on
   the main screen, phone on the charger or not (write down which).
2. Note the clock time. The Sleep section says "Scoring the night of ...: Preparing the recording", then "Sleep
   model, run 1 of 3, part 1 of 8" and so on.
3. When the time asleep appears, note the clock time again; open **Sleep report**: the line at the bottom says
   "Scored on this phone in ..." (that is the measured time). If "Counting jaw, movement and signal" showed after
   the model's last part, note for how long: that is the detectors' pass running behind the model.
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

1. Stop the night first. Headband on, switched on; sit comfortably, sound on.
2. On the main screen, **Morning** section: **Morning check-in**, then **Check contact**. Each electrode gets a word
   (good, fair, noisy, not touching). The back two (O1, O2) matter most: part the hair, press, sit still, **Check
   contact again** if needed. Then **Start: eyes closed**.
3. A low tone: eyes closed for 2 minutes (the screen goes dim). A rising pair of tones: look at the dot for 2
   minutes. A last tone ends the recording. Without signal the countdown waits and says so. **Stop** keeps nothing.
4. The questions: sleepiness (1-9, the words of each step shown), mood, tension, yesterday's cups of coffee or
   strong tea (and whether one came in the 8 hours before sleep), drinks of alcohol, caffeine this morning. Then,
   if you like, the 1-minute reaction test (tap when the green dot appears). **Save**.
5. This morning's numbers, each beside yesterday's and your usual (from 7 days), with an arrow and words only when
   a number is beyond your normal spread (from 14 days). **See trends** opens the trends page.

Kept in `files/mornings/` (the result in the laptop's format, and the raw signal with the page's markers;
`docs/data-format.md`); **Export data** copies them out. The **i** button shows `docs/evidence/morning-check-in.md`.

## Trends

**Trends** (Morning section, or after a check-in) shows today's entry: last night's sleep, the morning's numbers,
practice minutes, coffee and alcohol, each with yesterday's value and your usual; then sleep pressure, an estimate
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
your answers), app-private like the meditations; the replay check's files are in `files/replay-check/`.

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
answered. Do not swipe the app away. Files, app-private like the meditations: `files/dream-catcher/<time>.dream.json`
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
4. The screen goes black and dim. Close your eyes; the first minute sets your starting level. One dim word says
   what the app sees (Eyes closed, Resting, Drifting, Asleep), with the minutes and whether the sleep model is on.
   From 5 minutes in the sleep model checks every 30 seconds; if it is too slow, fails, or the signal is lost, the
   line says "timer" and the length alone ends the nap.
5. The wake: the screen comes up and three soft rising notes play, a little louder every 20 seconds. Tap the big
   **I'm awake**. **Stop** (or Back) ends the nap at any time.
6. The report: when you fell asleep (the alpha rule), minutes of light, deep and dream sleep (the live model, a
   first guess), why it woke you, how long you took to tap, and how fast the model was. Earlier naps are below.

Keep the app open with the screen on during a nap: locking the phone can stop it. Files, app-private:
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
   - The last lines of the night's `.log` (`smart alarm: sleep model ... s of the recorder's time`) and whether the
     night's battery drain looked higher than usual.
4. If it rang only at the window's end every time, or never early, Export data: the laptop can replay the night.

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

## Sessions with the phone locked

Sound for states, meditation, alpha-theta and the dream catcher go on when the phone is locked (since 2026-11-19,
DECISIONS rows 190-197). While a session runs, the app shows a notification with the session's name and **Stop**,
also on the lock screen; Android then treats the app like a music player and does not put it to sleep. The night
recording is separate and unchanged.

- **Sound for states**: the screen is not kept on any more. Lock the phone or let it turn off.
  **Screen: Stays on** on the setup page brings the old lit screen back.
- **Meditation, alpha-theta, dream catcher**: the screen still stays on by itself; press the power button if you
  want it dark.
- **Fall asleep, then Record the night**: the night starts by itself on a locked phone. The first time, if the app
  is not yet allowed to run in the background, Start asks for it and that one session keeps its screen on.
- Do not swipe the app away from Recents during a session: that ends it.
- The same Xiaomi settings as for the night matter here (main screen, **Phone**: Autostart, battery "No
  restrictions").

Not tried on a phone yet. On the emulator, with the screen off, the sound engine kept playing and being fed for two
minutes, the microphone recorded real sound, and the night recording started from the locked session
(`tool/screen_off_smoke.dart`, "Emulator smoke test" step 7).

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

## If the headband drops out

With our own connection switched on (above) a short drop is mended inside the same recording; what follows is the
rule for BrainBit's library, and for a headband that stays away longer than 30 s.


The app saves what it has and reconnects by itself: first straight to the same headband (no Bluetooth scan,
because Android blocks scans while the screen is off), after 2, 5, 10, 30 s and then every minute; every
third try is a short scan instead. Each try is written in the night's `.log` with its time (`drop`,
`reconnect try`, `reconnected`), so gaps can be marked later. It never stops trying until you press Stop.

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
a copy of the night within minutes instead of after Stop and Export data. Nothing is sent anywhere by itself, nothing
goes to the internet, and nothing on the phone can be changed or deleted this way.

**Safety, in plain words.** It is your brain data, so: every request needs the code the app shows (12 characters);
only devices on the same local network are answered; it turns itself off 12 hours after you switched it on, and 15
minutes after Stop. It is **not encrypted** (plain HTTP; encryption is deferred, DECISIONS rows 37 and 225): a device
on the same Wi-Fi could listen in, so use it on your home Wi-Fi only, never on a shared or public one. **New code**
on the sheet shuts out every laptop that has the old one.

**It cannot hurt the recording.** The server runs apart from the recorder, which only hands it copies of the samples
and never waits for it. If the server fails, sharing goes off with one line in the night's log and the night goes on
(DECISIONS row 221; tested with servers that crash and hang).

### Owner step: switch it on before a night (2 minutes; the first night doubles as the phone test)

1. Phone on your home Wi-Fi, the laptop on the same one. On the main screen scroll to **Your data** and switch
   **Share on Wi-Fi** on. A sheet shows the **Address** (like `192.168.1.23:8765`), the **Code**, and both as a QR
   code. **Address and code** opens it again.
2. On the laptop, in the repo folder, with the address and code from the sheet (the sheet shows both commands
   whole):
   - the live pages: `python3 scripts/page_server.py --recorder http://<address> --token <code>`, then open
     `http://localhost:8770/` (the live check page; `sound.html`, `beats.html`, `eyes.html` work too);
   - the copy: `python3 scripts/pull_phone.py http://<address> --token <code>`; leave it running. Every 2 minutes
     it prints what it fetched. Raw nights land in `_local/recordings/`, everything else in `_local/phone/`.
3. Start the night as usual. The notification says "shared on Wi-Fi at <address>". Sleep.
4. In the morning, Stop. Leave the app open for a few minutes: sharing stays on for 15 minutes so the laptop gets
   the end of the night, then turns itself off. `pull_phone.py` prints "finished and checked" for the night's files.
5. **What to tell the assistant after the first night** (only the real phone can show these): did `pull_phone.py`
   keep printing lines all night with the phone's screen off, or did it say "no answer" for long stretches? Was the
   phone on the charger? The night's `.log` has the phone battery once a minute, so a night with sharing on against
   one without gives its real cost.

Good to know:

- The code stays the same until you tap **New code**, so the laptop commands stay the same every night. To keep the
  code out of the shell history, set it once: `export EEG_PHONE_TOKEN=<code>`; all three scripts read it.
- Between nights the phone answers only while the app is open on the screen (Android freezes a closed app); the app
  keeps the screen on for the first 15 minutes. During a night it answers with the screen off.
- During a night the laptop's **Re-check contact** button does nothing: the phone checks contact once, at the start
  (DECISIONS row 52). The Sleep page and the morning result are the laptop's own jobs and use the laptop's files,
  which `pull_phone.py` keeps filled.
- If the phone's address changes (the router gave it a new one), the main screen and the sheet show the new one
  within a minute; restart the two laptop commands with it. A fixed address for the phone in the router avoids this.
- Without Wi-Fi but with a cable: `adb forward tcp:8765 tcp:8765`, then use `http://127.0.0.1:8765` as the address.
- Export data stays the full, checked hand-over (and the only one that works without Wi-Fi). Files the laptop
  already mirrored are found "already here" by `import_phone.py`.

What else it is useful for:

- **Your own signal on a big screen**: the live page on the laptop or a TV browser while you fit the headband.
- **The laptop's sound pages driven by the phone's recording**: `sound.html` and `beats.html` read the same live
  stream, so the laptop's speakers can follow a night or a session the phone records.
- **A continuous backup during the night**: if the phone dies at 5 a.m., the laptop has the night up to the last
  2 minutes.
- **Other EEG tools**: `uv run --no-project --with pylsl python scripts/lsl_bridge.py --url http://<address>/stream
  --token <code>` re-publishes the phone's signal as Lab Streaming Layer streams (MNE-LSL, OpenViBE, LabRecorder).
- Meditation, the check-in, the dream catcher and sound sessions are served live too while they record.

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
