# eeg_tracker

An open-source app for getting the most out of affordable EEG: sleep, daily brain measures, break hints,
brain-reactive sound and honest long-term statistics. Works first with the BrainBit Black headband, then with
a build-it-yourself ADS1299 helmet ([hardware and guides](https://github.com/utof/eeg_ads1299_lab)), then others.

**Status (2026-11-19).** The phone app is built and tested on made-up data, a fake headband and an emulator. It is
on branch `feat/app-line` (every app feature combined; `main` does not have it yet). A release APK is about 52 MB
(arm64). The first builds are on the owner's phone, but most features have not had their first real try yet: the
owner's steps are in [app/README.md](app/README.md) and in the app's **Try these** page. Not a medical device.

## What it does today

### On the phone (Android app, `app/`)

Each line says what it does. In brackets: how well the research backs it **for this headband**
(strong, some, weak, none; one note per feature in [docs/evidence/](docs/evidence/README.md), opened by the round
**i** button). "Built" means the code and tests are done; the phone tries are still waiting for the owner.

- **Nights and sleep stages**: one tap records the night with the screen off; after Stop the phone scores sleep
  stages and shows a sleep report (time asleep, deep, dream, wake-ups, a chart, jaw and movement counts). The
  stages match the laptop's on every scored epoch of the test nights. A **Dream sleep check** in each report says
  how much dream sleep was scored against the usual share and checks it against eye movements: dream sleep may be
  under-counted on this headband (7-10 % on the first phone nights). (some)
- **Sleep so far**: while the night still records, **See sleep so far** shows the chart and totals up to a few minutes
  ago, scoring only what is new since the last look; marked as provisional, since the report after Stop scores the
  whole night together. (some)
- **Smart alarm**: wakes you at a light-sleep moment inside a window you choose, never in deep sleep, and always by
  the window's end. (weak)
- **Nap coach**: a nap that ends before deep sleep or at the length you pick. (some)
- **Dream catcher**: as you drift off it asks what you are thinking, records your answer, and lets you drift again;
  after the session the phone writes the answers out as text (Russian and English, a one-time 671 MB download). (some)
- **Lucid dream cues**: soft sounds in dream sleep, with silent nights mixed in so the app can test whether they
  did anything. An experiment. (weak)
- **Memory cues in deep sleep**: an evening memory task (objects at places), soft sounds in deep sleep for half of
  it, and a morning test; silent nights and a hidden half let the app test whether the sounds helped. Never on a
  lucid-cue night. Off until you switch it on. (weak)
- **Morning check-in and Trends**: a 5-minute eyes-closed / eyes-open check, plus your own ratings, and your
  numbers next to yesterday and your usual, with 14-day lines. (check-in: strong; trends: some)
- **Work session**: headband on while you work; it shows alert / getting drowsy / drowsy, hints at a break, and keeps a
  drowsiness trend per day. Mental fatigue itself is not measured. (some)
- **Meditation**: sound that follows your alpha rhythm, silent minutes at the end, a report, and a learning verdict
  after 8 sessions (checked again at 12). (weak)
- **Alpha-theta training**: a slow eyes-closed practice with a safety checklist; "practice, not treatment". (weak)
- **Replay check**: an off-by-default test of whether the live feedback beats a replay of an old one. (some)
- **Sounds for states**: calm sound for falling asleep, relaxing, a break or focus; it measures whether you got
  there, fades out when you fall asleep, and after weeks compares the sounds you used. An optional fair test draws
  the sound by chance each day. (sounds: weak; the fair test: some)
- **Sharp hours**: a few one-tap "how sharp are you?" questions a day, and after about 3 weeks your best times of
  day, "seen together, not tested". Off until you switch it on. (some)
- **Study reminders**: study in the evening, try to recall it in the morning. Off until you switch it on. (some)
- **"Unusual for you" card**: one plain sentence when a number of yours has been outside your usual 2 days in a row;
  silent for the first 28 days. (some)
- **Self-experiments**: pick a question and a number; random days for 4-8 weeks; a sealed answer with a range at the
  end, marked "tested" apart from "seen together". (some)
- **"Was this you?"**: a soft question when someone else seems to have worn the headband, so a borrowed headband
  does not spoil your trends. A weak check, tested only on made-up people. (weak)
- **Hands-free controls**: a double jaw clench or a look left then right as a switch during sessions. Off by
  default. (some)
- **Export data**: copies everything the app keeps to a folder you pick (with a checksum list) for the laptop.
- **Share on Wi-Fi**: the laptop watches the phone's recording live and copies its files during the night. Off by
  default, home Wi-Fi only. **Connecting is one scan**: the laptop shows a QR code (`scripts/phone_link.py`), the
  phone's camera opens the app, **Connect**; after that the phone tells the laptop where it is by itself.
- **Packing old nights**: raw recordings nothing has written for a day are packed (lossless, checked) to save space;
  every page and the laptop read them as before.
- **Our own headband connection (test switch)**: our own Bluetooth code instead of BrainBit's library; BrainBit's
  stays the default until the 15-minute probe has passed on the real headband.
- **The DIY board (test)**: records the self-built ADS1299 board over Wi-Fi. The board is not assembled yet, so this
  has only met a fake board and shows its test signal, not EEG.
- **Try these**: one page that walks the owner through each feature's first try, in order, and ticks some by itself.
- **Logs, usage and battery** (More): the app's own log of every part (errors with their screen, the headband's drops
  and reconnects, scoring times, what the laptop copied), how you use the app (screens, taps, features, hints; a
  switch, only inside the app, never sent anywhere) and what costs battery, feature by feature, in plain sentences,
  with the headband's own battery. All in the app's private folder; Export data takes it to the laptop
  ([docs/app-logging.md](docs/app-logging.md)).
- **Signal tab and the bottom bar** (Night, Sessions, Signal, Trends, More): a 3D head you can turn with each
  electrode's contact, live traces per electrode in µV, and the raw data; it reads the night's or a session's stream,
  never a second connection.
- **When I put the headband on** (automatic recording, first phase): the app notices the headband on your head (a
  10-second contact check when you open the app, in your bedtime window, or when the paired headband comes near),
  guesses night or work, and asks "Start the night?" by default; Automatic and Do nothing per kind in Settings. Not
  now writes nothing; Yes keeps the minutes since the check. Never during a recording or a session.

### On the laptop

- **Recorder** for the BrainBit (`scripts/record_night.sh`) with live check pages, **sleep report** and **morning
  check-in** pages, a Lab Streaming Layer bridge, and **brain-reactive sound** (a bench for the phone's version).
- **Break hints** from ActivityWatch with no headband (`scripts/break_hints.py`). (some)
- **Work sessions in the tray** (`python3 scripts/tray.py`): an icon in the panel notices when you start working
  (it asks first, or starts by itself when sure, or only when you press Start), counts breaks, ends the session
  after 30 min away, and gives the break hints; one file per session. ([docs/laptop-tray.md](docs/laptop-tray.md))
- **Tools for the phone's files**: `import_phone.py`, `phone_night_check.py`, `catalog.py`, `pull_phone.py`
  (below), and `pack_old.py`, which packs raw recordings older than a day (both sides pack: lossless, checked).
- **Pairing with the phone** (`python3 scripts/phone_link.py`, also the tray's **Pair phone…**): a QR code to scan,
  then the phone's files copied every 2 minutes and its live pages at `http://localhost:8770/`.
  ([docs/phone-link.md](docs/phone-link.md))
- **Every day's numbers for utof_tracker** (`python3 scripts/export_events.py --daily`): one event per day with what
  the phone's Trends page shows, for the owner's life tracker. ([docs/utof-interface.md](docs/utof-interface.md))
- **The same scoring and detectors in Python**: the phone's rules were written and checked there first (`analysis/`).

## Files in this repository

- [DECISIONS.md](DECISIONS.md): every choice made so far, its alternatives, and what would change it.
- [ROADMAP.md](ROADMAP.md): the owner's wishes, what each honestly becomes, the status of every feature, and what comes next.
- [docs/data-format.md](docs/data-format.md): raw recordings, night files and the events other apps can read.
- [docs/evidence/](docs/evidence/README.md): one short evidence note per feature.
- `app/`: the Android app (Flutter); owner steps, build and emulator notes in [app/README.md](app/README.md).
- `scripts/record_night.sh`: records a BrainBit on Linux until Ctrl+C (needs BrainBit's `libneurosdk2.so`
  and libc++ in `~/.local/lib/neurosdk2`). Live check page on port 8765.
- `scripts/break_hints.py`: soft "take a break" hints from ActivityWatch, no headband needed ([docs/break-hints.md](docs/break-hints.md)).
- `scripts/import_phone.py`: brings the phone app's **Export data** folder onto the laptop (Syncthing or
  `adb pull`), checks every file against its checksum list, raw nights into `_local/recordings/`, the rest into
  `_local/phone/` ([app/README.md](app/README.md), "Export data").
- `scripts/phone_night_check.py`: did the phone record the night well? After the import,
  `uv run --project analysis python scripts/phone_night_check.py 2026-11-19 --compare 2026-11-17` (the evening
  dates) prints every gap with its reason, lost packets, restarts by Android, both batteries, contact, the phone's
  sleep report and a plain verdict with the top three things to fix. Works on a laptop night too; plain `python3`
  skips only the signal numbers. Reads files only.
- `scripts/catalog.py`: one table of every night on the laptop (laptop, phone and DIY-board nights: files, hours, missing
  minutes, the sleep report's numbers, morning check-in) and the SHA-256 of every file, so the next run says what
  grew, changed or went missing; `--check` re-hashes everything. Reads the data only; writes `_local/catalog/`.
- `scripts/pack_old.py`: run it daily (`python3 scripts/pack_old.py`; `--dry-run` only says what it would do). Packs
  every raw `.f32` nothing has written for a day into `.f32.xz` (lossless, about 61 % smaller; checked to unpack to
  the same bytes before the `.f32` goes). Every script reads either form; the phone packs its own (`.f32.gz`).

Next morning, join the night's files and score sleep (AnySleep + YASA; neither is validated on BrainBit yet):

```bash
scripts/get_anysleep.sh                       # once: AnySleep code and weights (MIT, ~310 MB)
uv run --project analysis python scripts/to_bdf.py _local/recordings/2026-11-18-*.f32 -o night.bdf
uv run --project analysis python scripts/score_sleep.py night.bdf   # night.sleep.json + night.hypnogram.png
python3 scripts/export_events.py night.sleep.json    # eeg_sleep_night event for utof_tracker
```

A night over 14 hours is scored the way the phone scores every night (two passes with the app's ONNX models), so
the laptop's and the phone's reports give the same stages.

**Sleep page (automatic report).** After waking, open `http://localhost:8765/sleep.html` (the "Sleep" button on the
check page) while the recorder runs. If there are newer recordings than the last report, it scores them by itself
(about 3 minutes; `scripts/sleep_report.py`, started by the recorder under `systemd-run` with a 3500 MB memory cap)
and then shows total sleep, each sleep period (asleep, deep / dream / light, wake-ups over 5 minutes, missing
minutes) and the chart. A night is the recordings chained together, named by the evening's date; a late-morning
sleep after the night lands in the same report. By hand: `uv run --project analysis python scripts/sleep_report.py`
(writes `_local/nights/<date>.report.json` with the night's `.bdf`, `.sleep.json` and chart, and exports the event).

Morning check-in (about 5 minutes): while the recorder runs, open `http://localhost:8765/morning.html`
(`?short=1` for 60 s phases). After Save, the page works the result out by itself (about 30 s: the recorder runs
`morning_check.py` and `export_events.py`, memory-capped like the sleep report) and shows the numbers next to your
earlier mornings; the Sleep page shows the newest one too. By hand:

```bash
uv run --project analysis python scripts/morning_check.py _local/recordings   # <start>.morning.json + summary
python3 scripts/export_events.py _local/recordings/*.morning.json             # eeg_morning_check events
```

**Every day's numbers for utof_tracker** (the owner's life tracker), after the phone's files are on the laptop
(`pull_phone.py` or `import_phone.py`): `python3 scripts/export_events.py --daily` writes one `eeg_day` event per day
(every Trends number, sleep stages, what was left out and why), the nights and the check-ins into
`_local/export/events/`; re-running adds only what changed. utof_tracker reads that folder itself. The contract:
[docs/utof-interface.md](docs/utof-interface.md).

Tests (no headband): `uv run --project analysis --with pytest pytest analysis/tests` (add `-m "not slow"` to skip
the 2.5-minute fake-headband run) and `node --test tests/js/*.test.mjs`.

**One headband, many readers.** The headband allows one Bluetooth connection, so the recorder owns it, always
records to disk, and shares the data: `GET /stream` (server-sent events: every batch of samples in µV and every
marker) can have any number of readers, and `scripts/lsl_bridge.py` re-publishes it as Lab Streaming Layer streams
for standard EEG tools (MNE-LSL, OpenViBE, LabRecorder):

```bash
uv run --no-project --with pylsl python scripts/lsl_bridge.py   # LSL streams "BrainBit" (EEG) and "BrainBit-markers"
```

No headband? `PYTHONPATH=tests/fake_neurosdk python3 scripts/record_night.py --port 8765` runs the recorder on a fake
signal (alpha that switches every minute, jaw bursts, blinks). Pages in `scripts/web/` are served by name; they can
`POST /marker` with a text body to mark a moment (it becomes a BDF annotation).

Brain-reactive sound: with the recorder running, open `http://localhost:8765/sound.html` (rain softens and a drone
warms as eyes-closed alpha rises above your own line; a tight jaw, a blink or drifting toward sleep pauses the bells).
It reads the live stream, answers in about 0.3 s in training mode, and also has a demo signal. See
[docs/brain-sound.md](docs/brain-sound.md). JS tests: `node --test tests/web/*.test.mjs`.

**Hands-free controls** (phone app, off unless switched on in Settings): a firm double jaw clench or a look left, then
right, as a switch during sessions (pause the sound, mark a moment, answer the dream catcher), with a 90-second
calibration for your own head. The rules: `analysis/hands_free.py` (the reference) and `app/lib/detectors/gestures.dart`
(the phone's line-by-line port); false triggers on a recorded night in [docs/detectors.md](docs/detectors.md); how
to use it and the owner step in [app/README.md](app/README.md) ("Hands-free controls").

**Unusual for you** (phone app, the assistant's proposal, on unless switched off on the Trends page): after 28 silent
days it says in one plain sentence when your sleep length, sleepiness, mood, tension or reaction time has been
outside your own usual on 2 days in a row (Stanford's NightSignal rule), never as a notification and never as a
diagnosis. The rules: `analysis/unusual.py` (the reference) and `app/lib/unusual/detector.dart` (the phone's
line-by-line port); the back-test on made-up people: `analysis/validate_unusual.py` (about 0.8 false cards a month);
how to use it and the owner step in [app/README.md](app/README.md) ("Unusual for you").

**Sharp hours** (phone app, the assistant's proposal, off unless switched on in Trends): a few one-tap "how sharp do
you feel?" questions a day at random waking moments, two with a 1-minute reaction test, never during a night or a
session; after 3 weeks and about 60 answers, your answers by time of day, hours since waking and sleep pressure, with
ranges, "seen together, not tested". Code in `app/lib/sharp/`; files in [docs/data-format.md](docs/data-format.md);
how to use it, switch it off and the owner step in [app/README.md](app/README.md) ("Sharp hours"). Computer focus
sessions from ActivityWatch are not part of it yet: a later laptop importer could read ActivityWatch's local REST API
(`aw-server`, port 5600), count focus sessions the way the research found valid (runs of related work of 35-60 minutes,
counted, never summed as hours) per 2-hour block of each 04:00-04:00 day, and write them beside the phone's imported
`_local/phone/sharp-hours/` files for the laptop's statistics (DECISIONS row 289).

**Study reminders** (phone app, the assistant's proposal, off unless switched on in Settings): a nudge to study in the
evening, 1 to 2 hours before your usual bedtime, and to try recalling it in the morning before looking, with a one-tap
"studied tonight?" and "how much do you recall?" kept on the phone; never during a night recording or a session. The
evidence is one small study (grade some). Code in `app/lib/study/`, sharing the Sharp hours alarms; files in
[docs/data-format.md](docs/data-format.md); how to use it and the owner step in [app/README.md](app/README.md)
("Study reminders"); DECISIONS rows 400-401.

**Lucid dream cues** (phone app, off unless turned on; an experiment, evidence weak): an evening practice pairs a
soft cue with "am I dreaming?"; in the second half of the night the night recorder plays it when the live sleep
model reads dream sleep with the eyes moving, within strict limits, and stops on any stir. In the morning three
questions and a search of the night for left-right-left-right eye signals. Some nights are silent on purpose, so
after 12 nights the app can test whether the sound did anything for you. Rule and signal finder:
`analysis/lucid_cues.py`, `analysis/lucid_signals.py` (Python references, line-by-line Dart ports in `app/lib/lucid/`);
how to use it and the owner step in [app/README.md](app/README.md) ("Lucid dream cues").

**Was this you?** (phone app, the assistant's proposal, on unless switched off in Settings): after 10 check-ins (or
10 nights) on 5 different days, it asks "Was it you?" on the check-in's result or the sleep report when a recording's
eyes-closed alpha (speed, strength, background slope at O1/O2) looks clearly unlike your usual; "Someone else" (also
offered by hand on every recording) keeps it out of the trends, the unusual card and experiments, written into that
recording's file, never deleted. A weak check, tested only on made-up people (no other people's EEG at hand): about one
false question in 5-10 months of daily recordings, and only 2-4 in 10 other wearers noticed. The rule:
`analysis/wearer_check.py` (the reference) and `app/lib/wearer/check.dart` (the phone's line-by-line port); the
back-test: `analysis/validate_wearer.py`; how to use it, switch it off and the owner step in
[app/README.md](app/README.md) ("Was this you?").

**Why we believe each feature (evidence notes).** Every feature has a short note in
[docs/evidence/](docs/evidence/README.md): what the research says, where the data supports it and where it does
not, how the app uses it, the sources, and the libraries and models with their licences. Each carries one grade
for this headband: strong, some, weak or none. The pages and the phone app open them from a round "i" button (the app bundles the same files).
After editing a note, run `python3 scripts/evidence_to_js.py` (it writes `scripts/web/evidence.js`; tests:
`node --test tests/web/evidence.test.mjs`).

**Our own headband connection (no BrainBit SDK).** `scripts/brainbit_ble.py` talks to the BrainBit Black over
Bluetooth itself (Python + bleak), so recording needs no closed library, never unpairs other Bluetooth devices and
survives drops without restarting. Not yet tried on the real headband: run the 15-minute probe first
(`uv run --no-project --python 3.12 --with bleak==3.1.0 python scripts/ble_probe.py`), then record with
`DRIVER=ble scripts/record_night.sh`. The phone app has the same driver behind a switch ("Headband connection" on
the night screen: the probe, then "Use our own connection (test)"); BrainBit's SDK stays its default until the probe
has passed. See [docs/own-ble-driver.md](docs/own-ble-driver.md).

**The DIY ADS1299 board.** `DRIVER=diy scripts/record_night.sh` records the owner's self-built board
(eeg_ads1299_lab's bench firmware, its "E9" frames over USB serial or Wi-Fi) into `_local/recordings-diy/` with the
same files, live pages and LSL bridge. It only reads from the board: answer the board's prompts in a serial terminal
first. The phone app records it too, over Wi-Fi ("Headband connection", **DIY board (test)**: files in its own
`recordings-diy/` folder; the sleep report, check-in and detectors stay with the BrainBit; app/README.md "The DIY
board"). Tested on a fake board only; the board is not assembled yet. See [docs/diy-board.md](docs/diy-board.md).

BrainBit's NeuroSDK2 core is a closed binary from BrainBit; it is not part of this repository.

MIT licence.

### Pages that stay up while the recorder reconnects

The recorder restarts itself after every Bluetooth drop and for every contact re-check, and its pages go away for
20-40 s each time. `python3 scripts/page_server.py` (port 8770) never restarts: it serves the pages itself and
passes live data through from the recorder, answering "reconnecting" while the recorder is away. Use
`http://<laptop>:8770/` instead of port 8765. It answers the Sleep page and the morning result itself, so they
work while the headband is off or charging (the recorder has no page server then).

### The phone as the recorder

The phone app records nights too, and with **Share on Wi-Fi** switched on (off by default; app/README.md) it answers
the same routes as the laptop recorder: `python3 scripts/page_server.py --recorder http://<phone>:8765 --token <code>`
shows these pages on the phone's recording, and `python3 scripts/pull_phone.py http://<phone>:8765 --token <code>`
mirrors its files into `_local/` every 2 minutes while it records, checked against the phone's SHA-256 list.
Local network only, a code on every request, plain HTTP (not encrypted: home Wi-Fi only; DECISIONS rows 220-229).
