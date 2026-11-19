# eeg_tracker

An open-source app for getting the most out of affordable EEG: sleep, daily brain measures, break hints,
brain-reactive sound and honest long-term statistics. Works first with the BrainBit Black headband, then with
a build-it-yourself ADS1299 helmet ([hardware and guides](https://github.com/utof/eeg_ads1299_lab)), then others.

**Status: day one.** So far: a decisions log, a laptop recorder for the BrainBit and first sleep scoring. Not a medical device.

- [DECISIONS.md](DECISIONS.md): every choice made so far, its alternatives, and what would change it.
- [ROADMAP.md](ROADMAP.md): the owner's wishes, what each honestly becomes, and the status of every feature.
- [docs/data-format.md](docs/data-format.md): raw recordings, night files and the events other apps can read.
- `app/`: the Android recorder (Flutter): one tap starts the night, files in the same format as the
  laptop's. Unit-tested; not yet compiled to an APK or run on a phone; see [app/README.md](app/README.md).
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

**Lucid dream cues** (phone app, off unless turned on; an experiment, evidence weak): an evening practice pairs a
soft cue with "am I dreaming?"; in the second half of the night the night recorder plays it when the live sleep
model reads dream sleep with the eyes moving, within strict limits, and stops on any stir. In the morning three
questions and a search of the night for left-right-left-right eye signals. Some nights are silent on purpose, so
after 12 nights the app can test whether the sound did anything for you. Rule and signal finder:
`analysis/lucid_cues.py`, `analysis/lucid_signals.py` (Python references, line-by-line Dart ports in `app/lib/lucid/`);
how to use it and the owner step in [app/README.md](app/README.md) ("Lucid dream cues").

**Why we believe each feature (evidence notes).** Every feature has a short note in
[docs/evidence/](docs/evidence/README.md): what the research says, where the data supports it and where it does
not, how the app uses it, the sources, and the libraries and models with their licences. Each carries one grade
for this headband: strong, some, weak or none. The pages open them from a round "i" button, and the phone app will
bundle the same files. After editing a note, run `python3 scripts/evidence_to_js.py` (it writes
`scripts/web/evidence.js`; tests: `node --test tests/web/evidence.test.mjs`).

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
first. Tested on a fake board only; the board is not assembled yet. See [docs/diy-board.md](docs/diy-board.md).

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
