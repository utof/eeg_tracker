// The app's own guess of Lights off, found when a night is scored (DECISIONS 1111-1112): the first second of the first
// run of 60 seconds with the phone's screen off, a clean signal, no blink and no movement.
// - A blink or a movement second starts the count again; a second the signal was not readable (not clean, or one the
//   detectors never handed out, as in a gap) neither counts nor starts it again; a second with the screen on starts it
//   again.
// - The screen is read from the recording's own `.log` (the lines recorder/wifi_watch.dart writes, `... screen off; ...`
//   after the `2026-11-18T02:40:13.123` local time of chunk_writer.dart's logTime). Before the first such line the
//   screen is not known: that counts as "not off" (a second of it does not count) and starts nothing again.
// - The per-second inputs are those the drift-off detector is fed in the same pass (Second: the back alpha's clean
//   flag, movement, blinks); no signal processing of its own.
// - It is written into the report as `auto_lights_off` beside `drift_off` (absent when no run was found) and checked
//   against the owner's tap: of the newest 5 nights that have both, 4 within 5 minutes (the numbers of drift.dart's
//   check). Until then it is shown as one line and used for nothing. There is no Python twin.
import 'dart:io';

import '../detectors/detectors.dart' show Second;
import 'drift.dart' show agreeMin, checkNeeded, checkNights;
import 'report.dart' show SleepReport, isoLocal;

/// Of the report's `auto_lights_off` object.
const int autoLightsOffVersion = 1;

/// The seconds in a row the rule asks for.
const int autoLightsOffRun = 60;

/// The screen going [off] (or on) at unix time [t], from a `.log` line.
typedef ScreenChange = ({double t, bool off});

final RegExp _logLine = RegExp(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?) (.*)$');
final RegExp _screen = RegExp(r'; screen (on|off);');

/// The screen change one `.log` line tells; null for any other line (also "screen ?", when it could not be read).
ScreenChange? screenChangeIn(String line) {
  final m = _logLine.firstMatch(line);
  if (m == null) return null;
  final s = _screen.firstMatch(m.group(2)!);
  final t = DateTime.tryParse(m.group(1)!); // no zone: local time
  if (s == null || t == null) return null;
  return (t: t.microsecondsSinceEpoch / 1e6, off: s.group(1) == 'off');
}

/// Every screen line of the `.log` files beside [f32Files], oldest first. Unreadable files are skipped.
List<ScreenChange> screenChangesIn(List<File> f32Files) {
  final all = <ScreenChange>[];
  for (final f in f32Files) {
    final log = File(f.path.replaceFirst(RegExp(r'\.f32(\.gz)?$'), '.log'));
    try {
      if (!log.existsSync()) continue;
      for (final line in log.readAsLinesSync()) {
        final c = screenChangeIn(line);
        if (c != null) all.add(c);
      }
    } on Object {
      continue; // a log that cannot be read: the screen stays unknown there
    }
  }
  return all..sort((a, b) => a.t.compareTo(b.t));
}

/// Looks for the first run, second by second (seconds counted from the night's first sample, [startUnix]).
class AutoLightsOffFinder {
  AutoLightsOffFinder(Iterable<ScreenChange> changes, this.startUnix)
    : _changes = [...changes]..sort((a, b) => a.t.compareTo(b.t));

  final int startUnix;
  final List<ScreenChange> _changes;
  var _next = 0;

  /// null: not known yet; true: the screen is off.
  bool? _off;
  var _count = 0;
  int _runStart = 0;
  int? _found;

  /// The first second of the first run; null while there is none.
  int? get foundS => _found;

  /// One whole second of the night, in order.
  void second(Second s) => add(k: s.k, clean: s.backAlpha.clean, blink: s.blinks > 0, movement: s.movement);

  void add({required int k, required bool clean, required bool blink, required bool movement}) {
    while (_next < _changes.length && _changes[_next].t <= startUnix + k) {
      _off = _changes[_next++].off;
    }
    if (_found != null || _off == null) return;
    if (_off == false) {
      _count = 0;
      return;
    }
    if (!clean) return;
    if (blink || movement) {
      _count = 0;
      return;
    }
    if (_count == 0) _runStart = k;
    if (++_count >= autoLightsOffRun) _found = _runStart;
  }
}

/// The report's `auto_lights_off` for a run starting at second [foundS] of the night that began at [first]; [tapped]
/// is the unix time of the owner's tap (null without one). Null when there was no run.
Map<String, Object?>? autoLightsOffReport(int? foundS, double? tapped, DateTime first) {
  if (foundS == null) return null;
  final at = first.add(Duration(seconds: foundS));
  return {
    'time': isoLocal(at),
    'second': foundS,
    'tap_diff_min': tapped == null ? null : (at.microsecondsSinceEpoch / 1e6 - tapped) / 60,
    'version': autoLightsOffVersion,
  };
}

/// A report's `auto_lights_off` read back; null when missing or damaged.
class AutoLightsOff {
  const AutoLightsOff({required this.time, required this.second, this.tapDiffMin});

  final DateTime time;
  final int second;

  /// Minutes of the automatic one after the owner's tap (negative: before); null without a tap.
  final double? tapDiffMin;

  static AutoLightsOff? read(Object? json) {
    if (json is! Map) return null;
    try {
      return AutoLightsOff(
        time: DateTime.parse(json['time'] as String).toLocal(),
        second: json['second'] as int,
        tapDiffMin: (json['tap_diff_min'] as num?)?.toDouble(),
      );
    } on Object {
      return null;
    }
  }
}

/// How the automatic one is doing against the owner's tap: [agree] of the newest [nights] nights (at most 5).
class AutoLightsCheck {
  const AutoLightsCheck(this.agree, this.nights);
  final int agree;
  final int nights;

  bool get decided => nights >= checkNights;

  /// 4 of the newest 5 within 5 minutes: it can be trusted.
  bool get trusted => decided && agree >= checkNeeded;
}

/// The check over [reports]: the newest 5 nights with the owner's tap (`drift_off` source `button`) and an automatic
/// Lights off that could be compared to it.
AutoLightsCheck autoLightsCheck(Iterable<SleepReport> reports) {
  final nights = <(String, bool)>[];
  for (final r in reports) {
    final d = r.json['drift_off'];
    final a = AutoLightsOff.read(r.json['auto_lights_off']);
    final diff = a?.tapDiffMin;
    if (d is Map && d['source'] == 'button' && diff != null) nights.add((r.nightOf, diff.abs() <= agreeMin));
  }
  nights.sort((a, b) => b.$1.compareTo(a.$1));
  final newest = nights.take(checkNights).toList();
  return AutoLightsCheck(newest.where((n) => n.$2).length, newest.length);
}
