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
- Since 2026-11-19 the graph also opens up AnySleep's channel weighting, for the phone's two-pass scorer
  (`analysis/two_pass.py`, DECISIONS rows 260-264). Inputs `keep` (2,): the first and end epoch whose features
  count in the sums; `means` (4, 1037): the averages to weigh the channels by; `use_means` (1,): 0 = the input's
  own averages (AnySleep as it is; `means` is not used), 1 = `means`. Outputs `sums` (4, 1037): each skip
  connection's features summed over the kept epochs, per channel; `counts` (1037,): how many samples each sum
  covers. With `use_means` 0 the logits are the earlier export's, bit for bit (checked on random inputs).
- ONNX opset 17, for ONNX Runtime 1.28 (`flutter_onnxruntime` 1.9.0 on the phone, the same version in the check).
- Weights stored as float16 and cast back to float32 when a model loads: 6.5 MB per run instead of 12.9 MB, so
  the three runs fit under 20 MB (19.5 MB; with the two-pass inputs and outputs, and the tracer's inner value names
  shortened, a run is 60 kB smaller than before). The arithmetic stays float32.
- Two small changes keep a call's memory and time as before (DECISIONS row 264): each encoder level waits for its
  skip connection (it adds a clamped 0), so ONNX Runtime frees each four-channel feature map at once instead of
  keeping all 13 (about 265 MB instead of 143 MB for the longest piece); and the kept epochs' sums are the whole
  sums less the two context slices (a MatMul with a mask was slower than the rest of the model).
- Two lines of the model that depend on the input length are rewritten as tensor arithmetic for the export only
  (the odd-length pad and the decoder crop); otherwise the tracer fixes them to the traced length and other
  lengths come out wrong (by up to 0.3 in the logits; found and fixed while exporting).

## Checks (the owner's night of 2026-11-17: 12.9 h, 58 recordings)

| Check | Result |
|---|---|
| Random inputs of 10, 11, 13, 37, 64, 121 epochs, ONNX vs the unchanged PyTorch model | largest logit difference 0.008 (float32 weights: 0.000005); the same with the input's own averages fed back through `means` |
| 3 hours of the night, the laptop's input, mean probability of the 3 runs, ONNX vs PyTorch | largest difference 0.0017, mean 0.00016; same stage in 323 of 323 epochs |
| The whole night the phone's way vs the laptop's one pass (2026-11-19: two passes over 64-minute pieces on the 16-epoch grid) | same stage in 1330 of 1330 epochs; asleep 387.0, deep 42.5, dream 114.0, light 230.5 min, 2 periods, 8 wake-ups, as the laptop; mean probabilities within 0.00003 of the models run over the whole night at once |
| The same on the two other recorded nights (5.4 and 6.2 h) | 569 of 569 and 705 of 705 epochs, every report number the laptop's |
| Before (2026-11-18: 1-hour pieces with 15 minutes of context, each weighed by its own averages) | 96.6, 96.7 and 97.7 % of epochs on the three nights; on 2026-11-17 asleep 382.5, deep 42.0, dream 105.5, light 235.0 min, 7 wake-ups |
| The phone's own preprocessing (Dart, `app/tool/prep_night.dart` on the 58 raw recordings) vs the laptop's (BDF) | same 1549 epochs and gap flags; largest input difference 0.0007 (the BDF's 24-bit steps); scored in two passes, the laptop's stage on every epoch |
| The release app on the x64 emulator, the 58 recordings (same session, memory every 2 s) | the laptop's stage on 1330 of 1330 epochs (the 1-hour pieces: 1285); scoring 99 s (was 69 s), peak 448 MB PSS (was 442 MB) |
| One model call on the longest piece (laptop, 4 threads, no arena; `piece_call` in the export check) | about 0.45 s and 143 MB above the process (the earlier graph on its 180-epoch piece: 0.44 s, 141-147 MB) |
| Time on the laptop (4 threads), whole night, 3 runs | preprocessing 17 s (Dart, JIT), model 30 s in two passes (17 s in 1-hour pieces, 19 s in one pass over the whole night at about 2 GB) |

Why two passes: AnySleep weighs the four channels at each of its 13 skip connections by the features' average over
its whole input, so a 1-hour piece weighed them a little differently than one 12.9-hour pass. Longer pieces or more
context did not help (1.5-3 hours with 30-60 minutes of context: 95.6-97.3 % on the three nights). Feeding each piece
the night's averages alone gave 96.1 %, and the 16-epoch grid alone 97.4 %: AnySleep halves the time axis 12 times
with a left pad on odd lengths, so a piece pools its samples like the whole night only on that grid. Both together
give one pass's numbers (`analysis/two_pass.py`, `analysis/tests/test_two_pass.py`).
