# eeg_tracker

An open-source app for getting the most out of affordable EEG: sleep, daily brain measures, break hints,
brain-reactive sound and honest long-term statistics. Works first with the BrainBit Black headband, then with
a build-it-yourself ADS1299 helmet ([hardware and guides](https://github.com/utof/eeg_ads1299_lab)), then others.

**Status: day one.** So far: a decisions log, a laptop recorder for the BrainBit and first sleep scoring. Not a medical device.

- [DECISIONS.md](DECISIONS.md): every choice made so far, its alternatives, and what would change it.
- `scripts/record_night.sh`: records a BrainBit on Linux until Ctrl+C (needs BrainBit's `libneurosdk2.so`
  and libc++ in `~/.local/lib/neurosdk2`). Live check page on port 8765.

Next morning, join the night's files and score sleep (AnySleep + YASA; neither is validated on BrainBit yet):

```bash
scripts/get_anysleep.sh                       # once: AnySleep code and weights (MIT, ~310 MB)
uv run --project analysis python scripts/to_bdf.py _local/recordings/2026-11-18-*.f32 -o night.bdf
uv run --project analysis python scripts/score_sleep.py night.bdf   # night.sleep.json + night.hypnogram.png
```

BrainBit's NeuroSDK2 core is a closed binary from BrainBit; it is not part of this repository.

MIT licence.
