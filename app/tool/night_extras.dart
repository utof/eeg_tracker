// The phone's night extras run on the laptop, for checking them on a real night against the Python reference:
//   cd app && dart run tool/night_extras.dart <recordings folder> <night, e.g. 2026-11-17> <night.sleep.json> <out.json>
// Groups the folder's recordings into nights as the app does, runs the detectors' pass the scorer runs
// (lib/sleep/extras.dart `seeNight`) and the sleep model's preparation (lib/sleep/prep.dart), first one after the
// other, then side by side in two isolates as the scorer does, and writes the extras for the stages of a laptop
// sleep.json (so both sides use the same stages) with every burst and movement, the times and the peak memory.
// `analysis/night_extras.py` writes the same from the same recordings; compare the two files.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/sleep/periods.dart';
import 'package:eeg_tracker/sleep/prep.dart';

const _kinds = {'jaw': 'jaw', 'oneSided': 'one-sided', 'movement': 'movement'};

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln('usage: dart run tool/night_extras.dart <recordings> <night YYYY-MM-DD> <night.sleep.json> <out.json>');
    exit(2);
  }
  final night = nightsIn(Directory(args[0])).where((n) => n.name == args[1]).firstOrNull;
  if (night == null) {
    stderr.writeln('no night ${args[1]}');
    exit(1);
  }
  final files = night.recordings;
  final watch = Stopwatch()..start();
  final seen = seeNight(files)!;
  final seeS = watch.elapsedMilliseconds / 1000;
  watch.reset();
  final input = prepareNight(files)!;
  final prepS = watch.elapsedMilliseconds / 1000;
  watch.reset();
  final both = await Future.wait([Isolate.run(() => prepareNight(files)!.epochs), Isolate.run(() => seeNight(files)!.quality.length)]);
  final bothS = watch.elapsedMilliseconds / 1000;

  final scored = jsonDecode(File(args[2]).readAsStringSync()) as Map<String, dynamic>;
  final stages = [for (final e in (scored['epochs'] as List).cast<Map<String, dynamic>>()) e['anysleep'] as String];
  final start = DateTime.fromMillisecondsSinceEpoch(joinLayout(files).startUnix * 1000);
  if (DateTime.parse(scored['start'] as String) != start) {
    stderr.writeln('${args[2]} starts at ${scored['start']}, the recordings at $start');
    exit(1);
  }
  final periods = [for (final p in sleepPeriods(stages).periods) (p.first, p.last)];
  final extras = nightExtras(
    quality: seen.quality,
    bursts: seen.bursts,
    moves: seen.moves,
    stages: stages,
    periods: periods,
    firstEdge: firstEdgeS(start),
  );
  final out = {
    'night': night.name,
    'recordings': files.length,
    'epochs': stages.length,
    'model_epochs': input.epochs,
    'first_edge_s': firstEdgeS(start),
    'periods': [for (final (a, b) in periods) [a, b]],
    'detectors_s': seeS,
    'prepare_s': prepS,
    'prepare_and_detectors_side_by_side_s': bothS,
    'side_by_side_epochs': both,
    'peak_mb': ProcessInfo.maxRss ~/ 1048576,
    'extras': extras,
    'bursts': [for (final b in seen.bursts) [b.start, b.end, _kinds[b.kind.name]]],
    'moves': [for (final (a, b) in seen.moves) [a, b]],
  };
  File(args[3]).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  stdout.writeln('${night.name}: ${files.length} recordings, ${stages.length} epochs; detectors ${seeS.toStringAsFixed(1)} s, '
      'preparation ${prepS.toStringAsFixed(1)} s, both side by side ${bothS.toStringAsFixed(1)} s, '
      'peak ${ProcessInfo.maxRss ~/ 1048576} MB');
  stdout.writeln(const JsonEncoder.withIndent(' ').convert({'night': extras['night'], 'asleep': extras['asleep']}));
}
