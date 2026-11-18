// The live drift-off detector on a recorded night, on the laptop (DECISIONS 180-184):
//   cd app && dart run tool/live_drift.dart <recordings folder> <night, e.g. 2026-11-17> <night.sleep.json>
//          [HH:MM:SS ...]   (lights-off moments to try as if Lights off had been tapped then)
// For speed as on the phone compile it first: `dart compile exe tool/live_drift.dart -o /tmp/live_drift`.
// 1. Replays every recording batch by batch, with the arrival times of its `.idx` (a file without one: a single
//    batch at its name's time, as the night pass reads it), through the recorder's live
//    detector (lib/recorder/live_drift.dart) and times it: the cost per hour of signal.
// 2. Runs the morning's night pass (lib/sleep/extras.dart `seeNight`) on the same files and compares the onsets.
// 3. Prints the report's `drift_off` against the stages of a laptop sleep.json (lights off from the night's markers,
//    else its first sample), and for each HH:MM:SS given the same comparison with lights off there.
// Reads only; writes nothing.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/live_drift.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sleep/drift.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: dart run tool/live_drift.dart <recordings> <night YYYY-MM-DD> <night.sleep.json> [HH:MM:SS ...]');
    exit(2);
  }
  final night = nightsIn(Directory(args[0])).where((n) => n.name == args[1]).firstOrNull;
  if (night == null) {
    stderr.writeln('no night ${args[1]}');
    exit(1);
  }
  final files = night.recordings;

  // 1. live, batch by batch
  final live = LiveDrift();
  final inAdd = Stopwatch();
  final wall = Stopwatch()..start();
  var batches = 0;
  for (final f in files) {
    final data = ByteData.sublistView(f.readAsBytesSync());
    final idx = File('${f.path.substring(0, f.path.length - 4)}.idx');
    final rows = <(double, int)>[];
    if (idx.existsSync()) {
      final b = ByteData.sublistView(idx.readAsBytesSync());
      for (var o = 0; o + indexBytes <= b.lengthInBytes; o += indexBytes) {
        rows.add((b.getFloat64(o, Endian.little), b.getUint64(o + 8, Endian.little)));
      }
    }
    final records = data.lengthInBytes ~/ recordBytes;
    if (rows.isEmpty) {
      // an early laptop file without an index: one run at the file name's time, as the night pass reads it
      final t = stemTime(f.uri.pathSegments.last)!.millisecondsSinceEpoch / 1000;
      rows.add((t + records / sampleRate, 0));
    }
    for (var k = 0; k < rows.length; k++) {
      final from = rows[k].$2, to = k + 1 < rows.length ? rows[k + 1].$2 : records;
      if (from >= records || to <= from) continue;
      final batch = [
        for (var i = from; i < to; i++)
          (
            pack: data.getUint32(i * recordBytes, Endian.little),
            o1: data.getFloat32(i * recordBytes + 4, Endian.little),
            o2: data.getFloat32(i * recordBytes + 8, Endian.little),
            t3: data.getFloat32(i * recordBytes + 12, Endian.little),
            t4: data.getFloat32(i * recordBytes + 16, Endian.little),
          ),
      ];
      final at = DateTime.fromMicrosecondsSinceEpoch((rows[k].$1 * 1e6).round());
      inAdd.start();
      live.add(at, batch, firstOfFile: k == 0);
      live.takeEvents();
      inAdd.stop();
      batches++;
    }
  }
  final hours = live.samples / sampleRate / 3600;
  final work = inAdd.elapsedMicroseconds / 1e6;

  // 2. the morning's night pass
  final sw = Stopwatch()..start();
  final seen = seeNight(files)!;
  final passS = sw.elapsedMilliseconds / 1000;
  final d = live.driftOff!, n = seen.drift!;

  // 3. against the laptop's stages
  final scored = jsonDecode(File(args[2]).readAsStringSync()) as Map<String, dynamic>;
  final stages = [for (final e in (scored['epochs'] as List).cast<Map<String, dynamic>>()) e['anysleep'] as String];
  final layout = joinLayout(files);
  final start = DateTime.fromMillisecondsSinceEpoch(layout.startUnix * 1000);
  if (DateTime.parse(scored['start'] as String) != start) {
    stderr.writeln('${args[2]} starts at ${scored['start']}, the recordings at $start');
    exit(1);
  }
  final tries = <String, DriftOff>{};
  for (final hhmmss in args.skip(3)) {
    final p = hhmmss.split(':').map(int.parse).toList();
    var t = DateTime(start.year, start.month, start.day, p[0], p[1], p.length > 2 ? p[2] : 0);
    if (t.isBefore(start)) t = t.add(const Duration(days: 1));
    tries[hhmmss] = DriftOff(lightsOffSecond(t.millisecondsSinceEpoch / 1000, layout.startUnix));
  }
  if (tries.isNotEmpty) {
    final det = Detectors(
      onSecond: (s) {
        for (final x in tries.values) {
          if (s.k < x.lightsOff) continue;
          final a = s.backAlpha;
          x.second(s.k, a.alpha, a.clean, s.movement, s.sem, s.blinks);
        }
      },
    );
    layout.forEachRow((row, missing) => det.push(row, missing: missing));
    det.finish();
  }
  Map<String, Object?> brief(Map<String, Object?> r) => {
    for (final k in ['lights_off', 'source', 'onset', 'model_onset', 'onset_min', 'model_onset_min', 'diff_min', 'agree', 'counted'])
      k: r[k],
  };
  final out = {
    'night': night.name,
    'recordings': files.length,
    'batches': batches,
    'signal_h': double.parse(hours.toStringAsFixed(3)),
    'live_work_s': double.parse(work.toStringAsFixed(3)),
    'live_work_s_per_hour': double.parse((work / hours).toStringAsFixed(3)),
    'live_share_of_signal_time': double.parse((work / (hours * 3600)).toStringAsExponential(2)),
    'replay_wall_s': wall.elapsedMilliseconds / 1000,
    'night_pass_s': passS,
    'live_vs_night_pass': {
      'live': {'lights_off_s': d.lightsOff, 'baseline_s': d.baselineDone, 'onset_s': d.onset, 'known_s': d.asleepAt},
      'night_pass': {'lights_off_s': n.lightsOffS, 'baseline_s': n.baselineS, 'onset_s': n.onsetS, 'known_s': n.knownS},
      'same': d.lightsOff == n.lightsOffS && d.baselineDone == n.baselineS && d.onset == n.onsetS && d.asleepAt == n.knownS,
    },
    'report': brief(driftReport(n, stages, start)),
    'if_lights_off_at': {
      for (final e in tries.entries)
        e.key: brief(driftReport(
          DriftSeen(
            lightsOffS: e.value.lightsOff,
            from: LightsOffFrom.button,
            baselineS: e.value.baselineDone,
            drowsyS: e.value.drowsyAt,
            onsetS: e.value.onset,
            knownS: e.value.asleepAt,
          ),
          stages,
          start,
        )),
    },
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
}
