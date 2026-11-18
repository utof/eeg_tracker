// The phone's preprocessing run on the laptop, for checking it on a real night against the laptop's own:
//   cd app && dart run tool/prep_night.dart <recordings folder> <night, e.g. 2026-11-17> <out.bin>
// Groups the folder's recordings into nights as the app does (lib/recorder/nights.dart), prepares the named night
// (lib/sleep/prep.dart) and writes <out.bin> (float32 little-endian, epochs * 3840 x 4, time-major: the model's
// input) and <out.bin>.json (start, epochs, gap flags, files, timings). scripts/export_anysleep_onnx.py
// --dart-input compares it with score_sleep.prepare on the night's BDF and scores it the phone's way.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sleep/prep.dart';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln('usage: dart run tool/prep_night.dart <recordings folder> <night YYYY-MM-DD> <out.bin>');
    exit(2);
  }
  final nights = nightsIn(Directory(args[0]));
  final night = nights.where((n) => n.name == args[1]).firstOrNull;
  if (night == null) {
    stderr.writeln('no night ${args[1]}; nights: ${nights.map((n) => n.name).join(', ')}');
    exit(1);
  }
  final watch = Stopwatch()..start();
  final input = prepareNight(night.recordings, progress: (s) => stdout.writeln('${watch.elapsed.inSeconds} s: $s'));
  if (input == null) {
    stderr.writeln('under 5 minutes');
    exit(1);
  }
  final seconds = watch.elapsedMilliseconds / 1000;
  final out = File(args[2]).openSync(mode: FileMode.write);
  try {
    for (var e = 0; e < input.epochs; e += 120) {
      final block = input.interleaved(e, e + 120 > input.epochs ? input.epochs : e + 120);
      out.writeFromSync(block.buffer.asUint8List(block.offsetInBytes, block.lengthInBytes));
    }
  } finally {
    out.closeSync();
  }
  File('${args[2]}.json').writeAsStringSync(jsonEncode({
    'night': night.name,
    'files': [for (final f in night.recordings) f.uri.pathSegments.last],
    'start_unix': input.startUnix,
    'epochs': input.epochs,
    'gap': input.gap,
    'recorded_samples': input.recordedSamples,
    'missing_samples': input.missingSamples,
    'percentiles_uv': input.percentiles,
    'prepare_seconds': seconds,
  }));
  stdout.writeln('${night.name}: ${night.recordings.length} recordings, ${input.epochs} epochs, '
      '${(input.missingSamples / 250 / 60).toStringAsFixed(1)} min missing, prepared in ${seconds.toStringAsFixed(1)} s');
}
