// The work session's drowsiness level on recorded data, on the laptop (DECISIONS 440-442):
//   cd app && dart run tool/work_check.dart <recordings folder> <file prefix, e.g. 2026-11-18> <sleep.json>
//          HH:MM:SS-HH:MM:SS[@HH:MM:SS] ...
// Joins every `<prefix>*.f32` on the clock (as the night report does), runs the shared detectors over all of it and,
// for each window, a fresh drowsiness level whose baseline is the window's first scored minutes (from the time after
// `@`, else the window's start): what a work session started at that moment would have shown. Prints each epoch with
// the sleep model's stage of that 30 s (the laptop's AnySleep in sleep.json), then the share of each level per stage
// and per 10 minutes. Reads only; writes nothing.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/work/breaks.dart';
import 'package:eeg_tracker/work/drowsiness.dart';

class _Window {
  _Window(this.label, this.from, this.to, this.d);
  final String label;
  final int from, to; // seconds of the joined signal
  final WorkDrowsiness d;
  final List<(WorkEpoch, String)> rows = [];
}

int _clockS(String hms, DateTime day) {
  final p = hms.split(':').map(int.parse).toList();
  return DateTime(day.year, day.month, day.day, p[0], p[1], p.length > 2 ? p[2] : 0).millisecondsSinceEpoch ~/ 1000;
}

String _hms(int unix) {
  final t = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

void main(List<String> args) {
  if (args.length < 4) {
    stderr.writeln('usage: dart run tool/work_check.dart <recordings> <prefix> <sleep.json> HH:MM:SS-HH:MM:SS[@HH:MM:SS] ...');
    exit(2);
  }
  final files = Directory(args[0])
      .listSync()
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last.startsWith(args[1]) && f.path.endsWith('.f32'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final layout = joinLayout(files);
  final start = layout.startUnix;
  final day = DateTime.fromMillisecondsSinceEpoch(start * 1000);

  // AnySleep's stage per 30 s, by clock second
  final sleep = jsonDecode(File(args[2]).readAsStringSync()) as Map<String, dynamic>;
  final stageAt = <int, String>{};
  for (final e in (sleep['epochs'] as List).cast<Map<String, dynamic>>()) {
    final t = DateTime.parse(e['t'] as String).millisecondsSinceEpoch ~/ 1000;
    stageAt[t ~/ 30] = e['anysleep'] as String;
  }
  String stage(int unix) => stageAt[unix ~/ 30] ?? stageAt[(unix ~/ 30) - 1] ?? '?';

  final windows = <_Window>[];
  for (final w in args.skip(3)) {
    final at = w.split('@');
    final span = at[0].split('-');
    var from = _clockS(span[0], day) - start;
    var to = _clockS(span[1], day) - start;
    if (from < 0) from += 86400;
    if (to <= from) to += 86400;
    final base = at.length > 1 ? _clockS(at[1], day) - start : from;
    windows.add(_Window(w, base, to, WorkDrowsiness()));
  }

  var moveCursor = 0;
  late Detectors det;
  det = Detectors(
    onSecond: (s) {
      var moves = 0;
      while (moveCursor < det.eyeMoves.length && det.eyeMoves[moveCursor].i ~/ 250 <= s.k) {
        if (det.eyeMoves[moveCursor].i ~/ 250 == s.k) moves++;
        moveCursor++;
      }
      for (final w in windows) {
        if (s.k < w.from || s.k >= w.to) continue;
        final before = w.d.epochs.length;
        w.d.second(workInputOf(s, eyeMoves: moves));
        if (w.d.epochs.length > before) {
          final e = w.d.epochs.last;
          w.rows.add((e, stage(start + w.from + e.startS)));
        }
      }
    },
  );
  layout.forEachRow((row, missing) => det.push(row, missing: missing));
  det.finish();

  for (final w in windows) {
    stdout.writeln('\n== window ${w.label} (baseline from ${_hms(start + w.from)})');
    final b = w.d.baseline;
    stdout.writeln('baseline: ${b == null ? 'never complete' : jsonEncode(b.toJson())} at +${w.d.calibratedAtS}s');
    stdout.writeln('time      stage clean blk mov closed   a      still   (t)    (s)    index  window level');
    String f(double? v) => v == null ? '   -  ' : v.toStringAsFixed(2).padLeft(6);
    for (final (e, st) in w.rows) {
      stdout.writeln(
        '${_hms(start + w.from + e.startS)}  ${st.padRight(4)}  ${e.cleanS.toString().padLeft(3)}  '
        '${e.blinks.toString().padLeft(3)} ${e.eyeMoves.toString().padLeft(3)}  ${e.eyesClosed ? 'yes' : ' - '}   '
        '${f(e.a)} ${f(e.still)} ${f(e.t)} ${f(e.s)} ${f(e.index)} ${f(e.window)}  ${levelWords[e.level]}'
        '${e.eyeBadS > 0 ? '  (eye-bad ${e.eyeBadS} s)' : ''}',
      );
    }
    // share of each level by stage
    final byStage = <String, Map<DrowsyLevel, int>>{};
    for (final (e, st) in w.rows) {
      final m = byStage.putIfAbsent(st, () => {});
      m[e.level] = (m[e.level] ?? 0) + 1;
    }
    stdout.writeln('levels by stage (epochs): ${byStage.map((k, v) => MapEntry(k, v.map((l, n) => MapEntry(levelKey(l), n))))}');
    final closed = w.rows.where((r) => r.$1.eyesClosed).length;
    final scored = w.rows.where((r) => r.$1.scored).length;
    stdout.writeln('epochs ${w.rows.length}, scored $scored, eyes closed $closed');
    // the break planner on the same epochs, worn all along, its clock moved to 10:00 (out of the quiet hours)
    final p = BreakPlanner();
    final shift = DateTime(day.year, day.month, day.day, 10).millisecondsSinceEpoch ~/ 1000 - (start + w.from);
    for (final (e, _) in w.rows) {
      p.epoch(e.level, eyesClosed: e.eyesClosed, window: e.window);
      final at = DateTime.fromMillisecondsSinceEpoch((start + w.from + e.startS + 30 + shift) * 1000);
      final h = p.tick(at, worn: true);
      if (h != null) stdout.writeln('hint (${h.reason.name}) at ${_hms(start + w.from + e.startS + 30)}');
    }
  }
}
