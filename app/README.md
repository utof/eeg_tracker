# EEG Tracker: Android recorder

Records a BrainBit headband all night on an Android phone. One screen: Start night, Stop, the state,
minutes recorded, seconds since the last data, a half-hour strip of what was saved, battery, signal,
contact per channel, and phone settings that could stop the recording.

- Files: `Android/media/io.github.utof.eeg_tracker/recordings/<stamp>.f32/.idx/.log`, the same format as
  `scripts/record_night.py` (`docs/data-format.md`); join a night with `scripts/to_bdf.py`.
- Recorder: a foreground service of type `connectedDevice` (`lib/recorder/recorder_service.dart`) whose
  isolate owns the BrainBit session (`lib/recorder/night_recorder.dart`, rules in DECISIONS rows 17-23).
- Screen: `lib/ui/`, design in `../DESIGN.md`.

## Build and test

```bash
source ~/.local/share/linsa/env.sh         # Flutter, Android SDK, Java on the owner's laptop
flutter pub get
flutter analyze
flutter test --concurrency=1               # writer, recorder rules (fake headband), screen states
flutter build apk --profile --target-platform android-arm64
```

`flutter test` also renders the screen in four states to `build/screens/*.png` (normal and 130 % text).

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
6. `adb pull /sdcard/Android/media/io.github.utof.eeg_tracker/recordings/` and run `scripts/to_bdf.py` on
   the `.f32` files: expect at least 99.9 % of the expected samples and no gap.
7. Collect `adb shell am get-standby-bucket io.github.utof.eeg_tracker` and
   `adb logcat -b events -d | grep -i -E "am_kill|am_proc_died"`.

If the headband is not found without location permission (test T0), see DECISIONS row 23.
