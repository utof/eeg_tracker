# Noise flags and cleaning

## What it does

Marks each stretch of signal as good, degraded or missing (lost contact, a flat line, huge swings, muscle noise),
keeps bad stretches out of the numbers, and plans to clean only the flagged stretches, lightly. The raw recording
is always kept unchanged.

## Evidence for this headband: some

Simple rules for size, flatness and muscle noise are standard, and the headband's maker publishes its own
thresholds; no 2025-2026 learned cleaner has been tested on a four-electrode dry headband.

## What the research says

- BrainBit's own software flags artefacts (noise from muscles, movement or contact) with published thresholds:
  110 µV, a limit on fast-wave power, and an alert after 4 seconds. It flags but does not clean.
- ZUNA (2026), the best-known new "cleaning" model, is a 380-million-parameter generator that redraws the
  stretches you mark as bad from the other channels. Its papers tested only caps with 32 or more electrodes, and
  its makers say the output is imputed (guessed) data, not measurement.
- GEDAI, another 2026 cleaner, was the only one that helped a real task in a nine-method benchmark, but version
  1.5 was caught cutting alpha by 77.5% in a dirty recording while its own quality score missed it.
- Cleaning less works better: SPAR-EEG treats only artefact-heavy stretches with two classical tools and made
  alpha clearer in dry-electrode recordings during exercise.
- A learned denoiser tuned to rebuild the signal lowered a later classifier's accuracy (0.547 against 0.612 on
  the raw data); only 3 of 199 single-channel methods were ever checked for leaving clean signal usable.

## Where the data does not support it

- No learned cleaner (ZUNA, GEDAI, iPSD) has been tested on four dry electrodes; the app does not use them on your
  data.
- A cleaned stretch is a repair, not a measurement, and a stretch redrawn by a generator is a guess.
- The thresholds are planning values until real recordings with this headband recalibrate them.

## How the app uses this

- Morning check-in: 2-second pieces are dropped if they swing over 150 µV after filtering to 1-40 Hz, are flat
  (under 0.5 µV), or are three times noisier than the rest of the phase.
- Sleep scoring: a 30-second stretch missing over 5 s is not scored; missing data never becomes "awake" or "deep".
- Brain sound: a channel is unusable with no contact, a flat line, or a swing over 300 µV within 1 s; muscle and
  blink checks block rewards.
- Planned default for every feature: remove slow drift and 50 Hz mains hum, flag each channel-second, clean only
  flagged spans with ATAR (a wavelet method) or a simple rebuild, keep flagged stretches out of trend numbers,
  keep the raw file.
- Any cleaner must pass one test before use: on clean stretches, eyes-closed alpha at O1/O2 moves less than about
  0.5 dB and the eyes-closed to eyes-open ratio stays within about 10%, while jaw-clench noise at T3/T4 falls.
  ZUNA and GEDAI are only compared on the laptop.

## Sources

- [BrainBit SDK: artefact rules](https://sdk.brainbit.com/lib-emotions)
- [ZUNA paper](https://arxiv.org/html/2602.18478v1)
- [ZUNA1.1 paper](https://arxiv.org/html/2607.27308v1)
- [ARQA audit of GEDAI](https://doi.org/10.21203/rs.3.rs-11118324/v1)
- [Nine-method cleaning benchmark (Hajhassani 2026)](https://arxiv.org/abs/2609.31195)
- [SPAR-EEG: clean only the bad stretches](https://doi.org/10.1109/tnsre.2026.3734253)
- [Ultra-compact denoisers](https://arxiv.org/abs/2606.08594)
- [Scoping review of single-channel cleaning](https://doi.org/10.1088/1741-2552/aeb0ce)
- [iPSD v2](https://arxiv.org/html/2605.06724v2)

## Libraries and models

- This project's own flagging rules (MIT).
- [spkit ATAR](https://spkit.github.io/modules/generated/spkit.eeg.ATAR.html) (MIT): wavelet cleaning of flagged
  stretches (planned).
- [meegkit](https://github.com/nbara/python-meegkit) (BSD-3): mains-hum removal and other classical cleaning.
- [ZUNA](https://github.com/Zyphra/zuna) (Apache-2.0): laptop comparison only.
- [pygedai](https://pypi.org/project/pygedai/) (non-commercial licence): laptop comparison only.

Checked: 2026-11-18
