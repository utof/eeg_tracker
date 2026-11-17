# eeg_tracker

An open-source app for getting the most out of affordable EEG: sleep, daily brain measures, break hints,
brain-reactive sound and honest long-term statistics. Works first with the BrainBit Black headband, then with
a build-it-yourself ADS1299 helmet ([hardware and guides](https://github.com/utof/eeg_ads1299_lab)), then others.

**Status: day one.** So far: a decisions log and a laptop recorder for the BrainBit. Not a medical device.

- [DECISIONS.md](DECISIONS.md): every choice made so far, its alternatives, and what would change it.
- `scripts/record_night.sh`: records a BrainBit on Linux until Ctrl+C (needs BrainBit's `libneurosdk2.so`
  and libc++ in `~/.local/lib/neurosdk2`).

BrainBit's NeuroSDK2 core is a closed binary from BrainBit; it is not part of this repository.

MIT licence.
