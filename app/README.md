# EEG Tracker: Android recorder

Records a BrainBit headband all night on an Android phone. One screen: Start night, Stop, the state,
minutes recorded, seconds since the last data, a half-hour strip of what was saved, battery, signal,
contact per channel, and phone settings that could stop the recording.

- Files: `<stamp>.f32/.idx/.log` in the app's private folder (other apps cannot read it), the same format as
  `scripts/record_night.py` (`docs/data-format.md`); join a night with `scripts/to_bdf.py`. Only "Export a
  night" copies them out (below; DECISIONS rows 53 and 56). Android backups and phone-to-phone transfers
  skip the app completely (row 57), so a new phone starts empty: export what you want to keep first.
- Recorder: a foreground service of type `connectedDevice` (`lib/recorder/recorder_service.dart`) whose
  isolate owns the BrainBit session (`lib/recorder/night_recorder.dart`, rules in DECISIONS row 17 and rows 49-54).
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

## If the headband drops out

The app saves what it has and reconnects by itself: first straight to the same headband (no Bluetooth scan,
because Android blocks scans while the screen is off), after 2, 5, 10, 30 s and then every minute; every
third try is a short scan instead. Each try is written in the night's `.log` with its time (`drop`,
`reconnect try`, `reconnected`), so gaps can be marked later. It never stops trying until you press Stop.

## Export a night

The recordings stay inside the app. To get one night out:

1. Stop the night (Export is hidden while recording).
2. Scroll down to **Recordings** and tap **Export a night**.
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
