// The minutes kept in memory while the app asks (DECISIONS 604): from the check that found the headband on until your
// answer, up to 15 minutes, never on disk. "Yes" writes them as the night's first run, named after the first sample
// and with every batch's arrival time, so the night starts when you really put the headband on (the fitness watches'
// "credit from the start"); the night recorder's own runs follow and join the same night (recorder/nights.dart).
// "Not now", no answer, or a start by hand drops them: nothing is written.
import 'dart:io';

import '../recorder/chunk_writer.dart';
import 'store.dart';

class Preroll {
  Preroll({this.cap = AutoRule.askFor});

  /// Batches arriving later than this after the first are dropped.
  final Duration cap;
  final List<(DateTime, List<Sample>)> _batches = [];
  int _samples = 0;
  bool _full = false;

  int get samples => _samples;

  /// The cap was reached: later batches are dropped.
  bool get full => _full;

  DateTime? get first => _batches.isEmpty ? null : _batches.first.$1;

  /// From the first batch's arrival to the last's.
  Duration get span => _batches.isEmpty ? Duration.zero : _batches.last.$1.difference(_batches.first.$1);

  void add(DateTime arrival, List<Sample> batch) {
    if (batch.isEmpty || _full) return;
    final f = first;
    if (f != null && arrival.difference(f) > cap) {
      _full = true;
      return;
    }
    _batches.add((arrival, List.of(batch)));
    _samples += batch.length;
  }

  void clear() {
    _batches.clear();
    _samples = 0;
    _full = false;
  }

  /// Writes the kept batches as one run file set (`.f32`, `.idx`, `.log` with [notes]) in [dir] and forgets them.
  /// Returns its stem; null when nothing was kept (and then nothing is created).
  String? write(Directory dir, List<(DateTime, String)> notes) {
    final f = first;
    if (f == null) return null;
    final w = ChunkWriter.open(dir, f);
    try {
      for (final (t, line) in notes) {
        w.log(line, at: t);
      }
      for (final (t, b) in _batches) {
        w.addBatch(t, b);
      }
    } finally {
      w.close();
    }
    clear();
    return w.stem;
  }
}
