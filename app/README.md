# EEG Tracker: Android recorder and meditation

Records a BrainBit headband all night on an Android phone. The main screen: Start night, Stop, the state,
minutes recorded, seconds since the last data, a half-hour strip of what was saved, battery, signal,
contact per channel, and phone settings that could stop the recording. Between nights, the **Morning** section
opens the **morning check-in** and the **trends** page (below), and **Meditate** opens a guided eyes-closed
session whose sound follows your alpha rhythm (below); from there, **Alpha-theta** training and the **replay
check** (both below). Also between nights, the **Dream catcher** asks what is on your mind as you drift off and
records your answers (below).

- Files: `<stamp>.f32/.idx/.log` in the app's private folder (other apps cannot read it), the same format as
  `scripts/record_night.py` (`docs/data-format.md`); join a night with `scripts/to_bdf.py`. Only "Export a
  night" copies them out (below; DECISIONS rows 53 and 56). Android backups and phone-to-phone transfers
  skip the app completely (row 57), so a new phone starts empty: export what you want to keep first.
- Recorder: a foreground service of type `connectedDevice` (`lib/recorder/recorder_service.dart`) whose
  isolate owns the BrainBit session (`lib/recorder/night_recorder.dart`, rules in DECISIONS row 17 and rows 49-54).
- Screen: `lib/ui/`, design in `../DESIGN.md`.
- Meditation: `lib/feedback/` (the laptop page's feedback core in Dart), `lib/sound/` (flutter_soloud),
  `lib/meditation/` (session and report), `lib/ui/meditation_*.dart`; DECISIONS rows 72-77.
- Sleep report: `lib/sleep/` and `lib/ui/sleep_*.dart`, scored on the phone after Stop (below); DECISIONS rows 95-99.
- Replay check: `lib/training/` (schedule, frozen plan, replay, results), `lib/ui/training_settings_screen.dart`,
  `lib/ui/check_views.dart`, `lib/ui/replay_results_screen.dart`; DECISIONS rows 100-103.
- Alpha-theta: `lib/alphatheta/` (rules, engine, notebook), `lib/sound/alpha_theta_sound.dart`,
  `lib/ui/alpha_theta_*.dart`; DECISIONS rows 104-107.
- Dream catcher: `lib/dream/` (rounds, answer end, files, headband link, session), `lib/sound/dream_sound.dart`,
  `lib/ui/dream_*.dart`; DECISIONS rows 110-116.
- Morning check-in and trends: `lib/morning/` (the laptop's `morning_check.py` in Dart, the session, the files),
  `lib/trends/` (days, your usual, sleep pressure, the forecast gate), `lib/ui/morning_*.dart`,
  `lib/ui/trends_*.dart`; DECISIONS rows 120-129.

## Build and test

```bash
source ~/.local/share/linsa/env.sh         # Flutter, Android SDK, Java on the owner's laptop
flutter pub get
flutter analyze
flutter test --concurrency=1               # writer, recorder rules (fake headband), screen states
flutter build apk --release --target-platform android-arm64
```

`flutter test` also renders the night screen in four states, the meditation screen in eleven, the sleep report in
eight, the replay check's and alpha-theta's pages in nineteen, the dream catcher in thirteen and the
check-in, trends and Morning section in eighteen to `build/screens/*.png` (normal and 130 % text).
`test/dream_test.dart` runs whole dream catcher sessions on a fake
headband whose alpha fades and comes back, with a fake microphone. `test/morning_cross_check_test.dart` checks the
check-in's numbers against a fixture made by the laptop's Python (`test/fixtures/make_morning_fixture.py`); with
`MORNING_F32=<check-in .f32> MORNING_JSON=<its .morning.json>` it also runs a whole recorded check-in.
`test/sleep_prep_test.dart` checks the sleep model's input against a fixture made by the laptop's Python
(`test/fixtures/make_sleep_fixture.py`). The meditation tests stream a synthetic headband through whole
sessions; `test/feedback_cross_check_test.dart` checks the Dart core against a session made by the JavaScript
core (`node app/test/fixtures/make_js_session.mjs` from the repo root remakes it after a change to the JS core).

The first build on the owner's laptop (2026-11-18) took about 5 minutes and fits under
`systemd-run --user --scope -p MemoryMax=4500M`. Release builds work: `flutter build apk --release
--target-platform android-arm64` (39 MB with the sleep model: 18 MB of models, ONNX Runtime's library 11 MB
compressed; only the named ABI is packaged and native libraries are compressed, `android/app/build.gradle.kts`;
`android/app/proguard-rules.pro` keeps ONNX Runtime's Java classes). The neurosdk2 1.0.21 plugin shrinks its own release build without keep
rules, which stripped its `Neurosdk2Plugin` class; `android/build.gradle.kts` builds that one plugin unshrunk.

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
   The screen stays on; keep the app open (locking the phone can stop the session).
6. A third tone ends the session. The report shows minutes settled, bells, restless moments (jaw, blinks,
   movement), drifting moments, a line of how calm the sound was, and how this session compares with earlier
   ones (a range from the 4th session). **Stop** ends early and keeps what there was (not during calibration).

The **i** button shows what the research says (`docs/evidence/meditation-feedback.md`): a guided practice, not
a treatment, and no "meditation depth" is measured. Each session is kept in the app's private folder,
`files/meditations/<time>.meditation.json` (the summary) and `<time>.session.json` (every sample and decision,
in the laptop page's session format, so it can be replayed). They are not exported yet.

If the headband drops out, the countdown pauses ("No signal") and the app reconnects by itself.

## Sleep report

After **Stop** the app scores the night on the phone (AnySleep, the laptop's sleep model, three runs; DECISIONS
rows 95-99). The main screen then shows last night's time asleep under the strip; **Sleep report** opens the
night: time asleep and time not recorded, a chart of the stages on the clock (missing data hatched amber, sleep
periods numbered), each period's start and end, deep, dream and light sleep, wake-ups over 5 minutes and missing
minutes, and the past nights. It is a first guess: the model is not validated on this headband (the **i** button
shows `docs/evidence/sleep-scoring.md`). It also runs when the app is opened between nights, for any night whose
report is missing or 10+ minutes behind, and never while a night records.

- Code: `lib/sleep/` (preparation as `scripts/score_sleep.py`, the model, sleep periods as
  `scripts/sleep_report.py`, the report file), `lib/ui/sleep_*.dart`. Models: `assets/models/` (see its README
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
   "Scored on this phone in ..." (that is the measured time).
4. Tell the assistant: hours recorded, the time it took, and whether the phone got warm or the app closed. If it
   says scoring stopped, tap **Try again** once and report what happens. With USB debugging on, also send
   `adb shell dumpsys meminfo io.github.utof.eeg_tracker | head -40` taken during "Sleep model, run 2 of 3".

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
`docs/data-format.md`); not exported yet. The **i** button shows `docs/evidence/morning-check-in.md`.

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
   the sound fades over about 10 seconds.
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

Keep the app open with the screen on during a session: locking the phone can stop it (Android stops the
microphone for apps in the background). Files, app-private like the meditations: `files/dream-catcher/<time>.dream.json`
(the rounds, the drift-off detector's epochs) and `<time>-r<n>.wav` (your answers), your prompts in
`files/dream-catcher/prompts/`. The session's EEG is a normal recording in `files/recordings/` with every question
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
