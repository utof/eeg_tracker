# eeg_tracker

An open-source app for getting the most out of affordable EEG: sleep, daily brain measures, break hints,
brain-reactive sound and honest long-term statistics. Works first with the BrainBit Black headband, then with
a build-it-yourself ADS1299 helmet ([hardware and guides](https://github.com/utof/eeg_ads1299_lab)), then others.

**Status: day one.** So far: a decisions log, a laptop recorder for the BrainBit and first sleep scoring. Not a medical device.

- [DECISIONS.md](DECISIONS.md): every choice made so far, its alternatives, and what would change it.
- [ROADMAP.md](ROADMAP.md): the owner's wishes, what each honestly becomes, and the status of every feature.
- [docs/data-format.md](docs/data-format.md): raw recordings, night files and the events other apps can read.
- `scripts/record_night.sh`: records a BrainBit on Linux until Ctrl+C (needs BrainBit's `libneurosdk2.so`
  and libc++ in `~/.local/lib/neurosdk2`). Live check page on port 8765.
- `scripts/break_hints.py`: soft "take a break" hints from ActivityWatch, no headband needed ([docs/break-hints.md](docs/break-hints.md)).

Next morning, join the night's files and score sleep (AnySleep + YASA; neither is validated on BrainBit yet):

```bash
scripts/get_anysleep.sh                       # once: AnySleep code and weights (MIT, ~310 MB)
uv run --project analysis python scripts/to_bdf.py _local/recordings/2026-11-18-*.f32 -o night.bdf
uv run --project analysis python scripts/score_sleep.py night.bdf   # night.sleep.json + night.hypnogram.png
python3 scripts/export_events.py night.sleep.json    # eeg_sleep_night event for utof_tracker
```

Morning check-in (about 5 minutes): while the recorder runs, open `http://localhost:8765/morning.html`
(`?short=1` for 60 s phases), then:

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
warms as eyes-closed alpha rises; jaw clench pauses the bells). It also has a demo signal. See
[docs/brain-sound.md](docs/brain-sound.md). JS tests: `node --test tests/web/*.test.mjs`.

BrainBit's NeuroSDK2 core is a closed binary from BrainBit; it is not part of this repository.

MIT licence.
