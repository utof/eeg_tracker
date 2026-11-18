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

Next morning, join the night's files and score sleep (AnySleep + YASA; neither is validated on BrainBit yet):

```bash
scripts/get_anysleep.sh                       # once: AnySleep code and weights (MIT, ~310 MB)
uv run --project analysis python scripts/to_bdf.py _local/recordings/2026-11-18-*.f32 -o night.bdf
uv run --project analysis python scripts/score_sleep.py night.bdf   # night.sleep.json + night.hypnogram.png
python3 scripts/export_events.py night.sleep.json    # eeg_sleep_night event for utof_tracker
```

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
`DRIVER=ble scripts/record_night.sh`. See [docs/own-ble-driver.md](docs/own-ble-driver.md).

BrainBit's NeuroSDK2 core is a closed binary from BrainBit; it is not part of this repository.

MIT licence.

### Pages that stay up while the recorder reconnects

The recorder restarts itself after every Bluetooth drop and for every contact re-check, and its pages go away for
20-40 s each time. `python3 scripts/page_server.py` (port 8770) never restarts: it serves the pages itself and
passes live data through from the recorder, answering "reconnecting" while the recorder is away. Use
`http://<laptop>:8770/` instead of port 8765. It answers the Sleep page and the morning result itself, so they
work while the headband is off or charging (the recorder has no page server then).
