// The live scorer's preparation run over a whole recorded night on the laptop, as the phone would stream it, to check
// it against analysis/live_stager.py on real data and to time it:
//   cd app && dart run tool/live_night.dart <recordings folder> <night, e.g. 2026-11-17> <out.bin> [--every 50]
// Streams the night's samples (lib/recorder/nights.dart groups them, NightLayout.forEachRow holds the gaps) through
// LivePrep and, at every --every-th edge from the 10th, writes the scaled window the model would get (float32
// little-endian, time x 4) to <out.bin>; <out.bin>.json lists each window's edge, first epoch and gap flags, and the
// time per window (copy plus scaling, in this process). Then
//   uv run --project analysis --group onnx python analysis/live_stager.py dart <out.bin> <recordings> <night> --score
// compares them with the reference and scores both.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sleep/live_prep.dart';
import 'package:eeg_tracker/sleep/live_stager.dart' show liveMinEpochs;
import 'package:eeg_tracker/sleep/night_signal.dart';

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln('usage: dart run tool/live_night.dart <recordings folder> <night YYYY-MM-DD> <out.bin> [--every N]');
    exit(2);
  }
  final every = args.length >= 5 && args[3] == '--every' ? int.parse(args[4]) : 50;
  final night = nightsIn(Directory(args[0])).where((n) => n.name == args[1]).firstOrNull;
  if (night == null) {
    stderr.writeln('no night ${args[1]}');
    exit(1);
  }
  final layout = joinLayout(night.recordings);
  final prep = LivePrep();
  final out = File(args[2]).openSync(mode: FileMode.write);
  final windows = <Map<String, Object?>>[];
  final windowMs = <int>[];
  final total = Stopwatch()..start();
  var last = 0;
  try {
    layout.forEachRow((row, missing) {
      prep.push([row[0], row[1], row[2], row[3]], missing: missing);
      final e = prep.epochs;
      if (e == last) return;
      last = e;
      if (e < liveMinEpochs || (e - liveMinEpochs) % every != 0) return;
      final sw = Stopwatch()..start();
      final w = prep.window(e);
      final x = scaleWindow(w);
      windowMs.add(sw.elapsedMilliseconds);
      out.writeFromSync(x.buffer.asUint8List(x.offsetInBytes, x.lengthInBytes));
      windows.add({'edge': w.end, 'first': w.first, 'gap': w.gap});
    });
  } finally {
    out.closeSync();
  }
  final seconds = total.elapsedMilliseconds / 1000;
  windowMs.sort();
  File('${args[2]}.json').writeAsStringSync(jsonEncode({
    'night': night.name,
    'epochs': prep.epochs,
    'windows': windows,
    'prepare_s': seconds,
    'window_ms': {'median': windowMs[windowMs.length ~/ 2], 'max': windowMs.last},
  }));
  stdout.writeln('${night.name}: ${prep.epochs} epochs streamed in ${seconds.toStringAsFixed(1)} s '
      '(${(seconds / prep.epochs * 1000).toStringAsFixed(1)} ms per 30 s epoch); ${windows.length} windows, '
      'copy + scaling median ${windowMs[windowMs.length ~/ 2]} ms, max ${windowMs.last} ms');
}
