# The phone's sleep model

`anysleep-run1.onnx`, `anysleep-run2.onnx`, `anysleep-run3.onnx`: the three trained runs of AnySleep (mid fusion)
that the laptop averages in `scripts/score_sleep.py`, exported by `scripts/export_anysleep_onnx.py` (run it from
the repo root with `uv run --project analysis --group onnx`). The app bundles these three files and
`LICENSE-AnySleep.txt`; this README stays out of the APK (pubspec lists the files one by one).

- Source: [AnySleep](https://github.com/dslaborg/AnySleep), code and weights under the MIT licence,
  Copyright (c) 2026 dslaborg, commit 88e13e3. The licence travels with the weights (`LICENSE-AnySleep.txt`,
  also shown under Licences in the app).
- Input `eeg`: float32, (1, samples, 4), O1 O2 T3 T4 at 128 Hz after the 0.3 Hz high-pass and AnySleep's robust
  scaling (`score_sleep.prepare`; on the phone `app/lib/sleep/prep.dart`), samples a multiple of 3840 (30 s).
  Output `logits`: float32, (1, epochs, 5), W N1 N2 N3 R. Any length works.
- ONNX opset 17, for ONNX Runtime 1.28 (`flutter_onnxruntime` 1.9.0 on the phone, the same version in the check).
- Weights stored as float16 and cast back to float32 when a model loads: 6.6 MB per run instead of 12.8 MB, so
  the three runs fit under 20 MB. The arithmetic stays float32.
- Two lines of the model that depend on the input length are rewritten as tensor arithmetic for the export only
  (the odd-length pad and the decoder crop); otherwise the tracer fixes them to the traced length and other
  lengths come out wrong (by up to 0.3 in the logits; found and fixed while exporting).

## Checks (2026-11-18, the owner's night of 2026-11-17: 12.9 h, 58 recordings)

| Check | Result |
|---|---|
| Random inputs of 10, 11, 13, 37, 64, 121 epochs, ONNX vs the unchanged PyTorch model | largest logit difference 0.008 (float32 weights: 0.000005) |
| 3 hours of the night, the laptop's input, mean probability of the 3 runs, ONNX vs PyTorch | largest difference 0.0017, mean 0.00016; same stage in 323 of 323 epochs |
| The whole night the phone's way (1-hour pieces with 15 minutes of context each side) vs the laptop's one pass | same stage in 96.6 % of 1330 epochs; asleep 382.5 vs 387.0 min, deep 42.0 vs 42.5, dream 105.5 vs 114.0, light 235.0 vs 230.5, 2 vs 2 periods, 7 vs 8 wake-ups |
| The phone's own preprocessing (Dart, `app/tool/prep_night.dart` on the 58 raw recordings) vs the laptop's (BDF) | same 1549 epochs and gap flags; largest input difference 0.0007 (the BDF's 24-bit steps); stages identical to the laptop input scored the same way |
| Time on the laptop (4 threads), whole night, 3 runs | preprocessing 17 s (Dart, JIT), model 26 s |

The 3.4 % of epochs that differ come from the pieces, not from ONNX or float16: AnySleep weighs the four channels
by their average over its whole input, so a 1-hour piece weighs them a little differently than one 12.9-hour pass.
Longer pieces or more context did not help (1.5-3 hours with 30-60 minutes of context: 95.6-97.3 % on the three
recorded nights, against 96.6-97.7 % for 1 hour with 15 minutes) and cost memory (about 160 MB of ONNX Runtime
memory per hour of input), so the phone uses the smallest.
