# shared_labels

The parts of "what really happened" that eeg_tracker and utof_tracker share (DECISIONS 860-869). Pure Dart and Flutter
widgets; nothing here knows a headband, a detector or either app's screens.

| Piece | File | What |
|---|---|---|
| Vocabulary | `lib/src/vocabulary.dart`, `vocabulary.g.dart` | every label, kind, source and confidence, generated from `scripts/truth_vocabulary.tsv` (`python3 scripts/gen_shared_labels.py`) |
| Estimate | `lib/src/estimate.dart` | what a detector thinks happened over a stretch of clock time, and its question ("Did you walk 19:08-21:14?") |
| Store | `lib/src/store.dart` | the files: `estimates.jsonl`, `answers.jsonl`, `asks.jsonl`, `armed.json`, `settings.json`, `labels.tsv`, `estimates.tsv` |
| Exports | `lib/src/labels.dart` | answers as truth rows (`labels.tsv`, the schema of `scripts/truth.py`) and every estimate with its answer (`estimates.tsv`), tab-separated: what the laptop, another app or pandas reads |
| Queue | `lib/src/queue.dart` | which estimates to ask about and when |
| Widgets | `lib/src/widgets.dart` | `ConfirmBatch` (Yes / No / Not sure per question) and `ConfirmCard` |

The golden files in `test/fixtures/confirm/` are checked by this package's tests, by the app's
(`app/test/confirm_test.dart`) and by the laptop's reader (`analysis/tests/test_confirm.py`): all three must make the
same rows from the same two files.

Tests: `flutter test` in this folder.
