// The walking pass over one finished recording (DECISIONS 800-809), the way the Archive's detectors' pass works
// (archive/seen.dart): every channel its header names joined on the clock (sleep/night_signal.dart), sample by sample
// through the walking detector (detector.dart), with the phone's step counter lines of its `.log` files
// (`phone steps N`, written once a minute while recording, recorder/night_recorder.dart). Kept in
// `files/walking/<id>.walk.json` (docs/data-format.md "Walking"), the format scripts/walks.py writes on the laptop,
// with the size and modified time of every file it read, so it runs again only when one changed or the detector did.
// The walk file stays when the raw signal leaves the phone: it is a result, like a sleep report. Plain Dart; the
// Archive runs it in a background isolate.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../cache/file_summaries.dart' show SummaryIndex, fileKey;
import '../recorder/header.dart' show HeaderError, MissingSites, readHeader;
import '../recorder/packed.dart' show rawOnDisk;
import '../sleep/night_signal.dart' show joinLayout;
import 'detector.dart';

const String walkFormat = 'eeg-tracker-walking';
const int walkFileVersion = 1;

/// The walk files' folder in `files/`.
const String walkFolder = 'walking';
const String walkSuffix = '.walk.json';

/// A `.log` line with the phone's step counter (steps since the phone started), and its state line.
final RegExp stepLine = RegExp(r'^(\S+) phone steps (\d+)\s*$');
final RegExp stepStateLine = RegExp(r'^\S+ phone step counter: (.+?)\s*$');

/// The step counter's readings (unix seconds, steps) and its last state ("on", "no permission", ...) in [logs].
({List<(double, int)> readings, String? state}) logSteps(List<File> logs) {
  final readings = <(double, int)>[];
  String? state;
  for (final f in logs) {
    String text;
    try {
      text = f.readAsStringSync();
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
    for (final line in const LineSplitter().convert(text)) {
      final m = stepLine.firstMatch(line);
      if (m != null) {
        final t = DateTime.tryParse(m.group(1)!);
        final c = int.tryParse(m.group(2)!);
        if (t != null && c != null) readings.add((t.millisecondsSinceEpoch / 1000, c));
        continue;
      }
      final s = stepStateLine.firstMatch(line);
      if (s != null) state = s.group(1);
    }
  }
  readings.sort((a, b) => a.$1.compareTo(b.$1));
  return (readings: readings, state: state);
}

double? _r1(double? v) => v == null || v.isNaN ? null : (v * 10).round() / 10;

String _iso(DateTime t) {
  final l = t.toLocal(), o = l.timeZoneOffset;
  String two(int v) => v.toString().padLeft(2, '0');
  final sign = o.isNegative ? '-' : '+', m = o.inMinutes.abs();
  return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}T${two(l.hour)}:${two(l.minute)}:'
      '${two(l.second)}$sign${two(m ~/ 60)}:${two(m % 60)}';
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
double? _num(Object? v) => v is num ? v.toDouble() : null;

/// One stretch of a walk as the file keeps it.
class WalkStretch {
  const WalkStretch({required this.kind, required this.start, required this.end, required this.steps, this.pace, this.confidence});
  final StretchKind kind;
  final DateTime start, end;
  final int steps;
  final double? pace;
  final String? confidence;

  Duration get length => end.difference(start);
}

/// One walk (stretches under 10 minutes apart) as the file keeps it.
class WalkSummary {
  const WalkSummary({
    required this.start,
    required this.end,
    required this.walkingMin,
    required this.stoppedMin,
    required this.steps,
    this.pace,
    required this.stretches,
  });
  final DateTime start, end;
  final double walkingMin, stoppedMin;
  final int steps;
  final double? pace;
  final List<WalkStretch> stretches;
}

/// What a walk file holds (docs/data-format.md "Walking").
class WalkResult {
  const WalkResult({
    required this.recording,
    required this.start,
    required this.channels,
    required this.sampleRate,
    required this.windows,
    this.phoneCounter,
    required this.walkingMin,
    required this.headbandSteps,
    this.pace,
    this.confidence,
    required this.walks,
    required this.minutes,
    this.json = const {},
  });

  final String recording;
  final DateTime start;
  final List<String> channels;
  final num sampleRate;
  final int windows;

  /// The step counter's last state line in the logs ("on", "no permission", "no sensor", "off"); null: none.
  final String? phoneCounter;
  final double walkingMin;
  final int headbandSteps;
  final double? pace;
  final String? confidence;
  final List<WalkSummary> walks;
  final List<WalkMinute> minutes;

  /// The file's own content (what [fromJson] read, or [walkFileOf] made).
  final Map<String, Object?> json;

  /// The minutes' steps by where they came from.
  int stepsFrom(String source) => minutes.where((m) => m.source == source).fold(0.0, (s, m) => s + m.steps).round();

  static WalkResult? fromJson(Object? j) {
    if (j is! Map || j['format'] != walkFormat || j['version'] != walkFileVersion) return null;
    final start = _time(j['start']), ch = j['channels'], walks = j['walks'], mins = j['minutes'];
    if (start == null || ch is! List || walks is! List || mins is! List || j['recording'] is! String) return null;
    WalkStretch? stretch(Object? s) {
      if (s is! Map) return null;
      final kind = StretchKind.values.where((k) => k.name == s['kind']).firstOrNull;
      final a = _time(s['start']), b = _time(s['end']);
      if (kind == null || a == null || b == null) return null;
      return WalkStretch(
        kind: kind,
        start: a,
        end: b,
        steps: (_num(s['steps']) ?? 0).round(),
        pace: _num(s['pace']),
        confidence: s['confidence'] is String ? s['confidence'] as String : null,
      );
    }

    final out = <WalkSummary>[];
    for (final w in walks) {
      if (w is! Map) continue;
      final a = _time(w['start']), b = _time(w['end']), st = w['stretches'];
      if (a == null || b == null || st is! List) continue;
      out.add(
        WalkSummary(
          start: a,
          end: b,
          walkingMin: _num(w['walking_min']) ?? 0,
          stoppedMin: _num(w['stopped_min']) ?? 0,
          steps: (_num(w['steps']) ?? 0).round(),
          pace: _num(w['pace']),
          stretches: [for (final s in st) ?stretch(s)],
        ),
      );
    }
    final rows = <WalkMinute>[];
    for (final r in mins) {
      if (r is! List || r.length < 9 || r[0] is! int || r[7] is! String) continue;
      rows.add(
        WalkMinute(
          t: r[0] as int,
          walkS: _num(r[1]) ?? 0,
          runS: _num(r[2]) ?? 0,
          hbSteps: _num(r[3]) ?? 0,
          hbPace: _num(r[4]),
          phone: _num(r[5]),
          steps: _num(r[6]) ?? 0,
          source: r[7] as String,
          walkingS: _num(r[8]) ?? 0,
        ),
      );
    }
    return WalkResult(
      recording: j['recording'] as String,
      start: start,
      channels: [for (final c in ch) if (c is String) c],
      sampleRate: _num(j['sample_rate']) ?? 0,
      windows: (_num(j['windows']) ?? 0).toInt(),
      phoneCounter: j['phone_counter'] is String ? j['phone_counter'] as String : null,
      walkingMin: _num(j['walking_min']) ?? 0,
      headbandSteps: (_num(j['headband_steps']) ?? 0).round(),
      pace: _num(j['pace']),
      confidence: j['confidence'] is String ? j['confidence'] as String : null,
      walks: out,
      minutes: rows,
      json: Map<String, Object?>.from(j),
    );
  }
}

/// The walk file's content for a recording [id] whose joined signal starts at [startUnix] (a whole second); the same
/// fields as scripts/walks.py writes.
Map<String, Object?> walkFileOf(
  String id,
  int startUnix,
  List<String> names,
  num rate,
  WalkFound found,
  List<WalkMinute> rows,
  String? phoneState,
) {
  final ws = found.windows;
  const hop = WalkRule.hopS;
  DateTime at(int i, {bool end = false}) =>
      DateTime.fromMillisecondsSinceEpoch(((startUnix + ws[i].t + (end ? hop / 2 : -hop / 2)) * 1000).round());
  Map<String, Object?> stretch(Stretch s) => {
    'kind': s.kind.name,
    'start': _iso(at(s.first)),
    'end': _iso(at(s.last, end: true)),
    'min': _r1(s.seconds / 60),
    'steps': s.steps.round(),
    'pace': _r1(s.pace),
    'score': _r1(s.score),
    'confidence': s.confidence,
  };
  final clear = [
    for (final s in found.moving)
      for (var i = s.first; i <= s.last; i++)
        if (ws[i].walks) i,
  ];
  double? medianOf(List<double> v) {
    if (v.isEmpty) return null;
    final s = [...v]..sort();
    final i = (s.length - 1) * 0.5, lo = i.floor();
    return lo + 1 < s.length ? s[lo] + (s[lo + 1] - s[lo]) * (i - lo) : s[lo];
  }

  final score = medianOf([for (final i in clear) ws[i].score]);
  final check = walkCheck(rows);
  var phone = 0.0, headband = 0.0;
  for (final r in rows) {
    if (r.source == 'phone') phone += r.steps;
    if (r.source == 'headband') headband += r.steps;
  }
  final start = DateTime.fromMillisecondsSinceEpoch(startUnix * 1000);
  return {
    'format': walkFormat,
    'version': walkFileVersion,
    'detector': walkDetector,
    'recording': id,
    'start': _iso(start),
    'end': _iso(start.add(Duration(milliseconds: (((ws.isEmpty ? 0 : ws.last.t + WalkRule.windowS / 2)) * 1000).round()))),
    'channels': names,
    'sample_rate': rate,
    'windows': ws.length,
    'read_windows': ws.where((w) => w.read).length,
    'phone_counter': phoneState,
    'walking_min': _r1(found.moving.fold(0.0, (t, s) => t + s.seconds) / 60),
    'running_min': _r1(found.moving.where((s) => s.kind == StretchKind.running).fold(0.0, (t, s) => t + s.seconds) / 60),
    'headband_steps': found.moving.fold(0.0, (t, s) => t + s.steps).round(),
    'pace': _r1(medianOf([for (final i in clear) ws[i].pace])),
    'confidence': score == null ? null : walkConfidence(score),
    'steps': (phone + headband).round(),
    'steps_phone': phone.round(),
    'steps_headband': headband.round(),
    'check': {
      'paired': check.paired,
      'right': check.right,
      'headband_steps': _r1(check.hbSteps),
      'phone_steps': _r1(check.phoneSteps),
    },
    'walks': [
      for (final w in found.walks)
        {
          'start': _iso(at(w.stretches.first.first)),
          'end': _iso(at(w.stretches.last.last, end: true)),
          'walking_min': _r1(w.walkingS / 60),
          'stopped_min': _r1(w.stoppedS / 60),
          'steps': w.steps.round(),
          'pace': _r1(w.pace),
          'stops': w.stretches.where((s) => s.kind == StretchKind.stopped).length,
          'stretches': [for (final s in w.stretches) stretch(s)],
        },
    ],
    'minutes': [
      for (final r in rows)
        [r.t, _r1(r.walkS), _r1(r.runS), _r1(r.hbSteps), _r1(r.hbPace), _r1(r.phone), _r1(r.steps), r.source, _r1(r.walkingS)],
    ],
  };
}

/// Why the pass cannot read [f32Files], in words; null when it can. Any layout and number of channels, at a whole
/// number of samples a second from 50 up (the band-pass reaches 20 Hz); every set must hold the first one's channels.
String? whyNotWalked(List<File> f32Files) {
  if (f32Files.isEmpty) return 'No raw signal on the phone.';
  List<String>? names;
  num? rate;
  for (final f in f32Files) {
    try {
      final h = readHeader(f);
      if (h.sampleRate is! int && h.sampleRate != h.sampleRate.roundToDouble()) {
        return 'Walking reads a whole number of samples a second; this recording has ${h.sampleRate}.';
      }
      if (h.sampleRate < 50) return 'Walking needs 50 samples a second or more; this recording has ${h.sampleRate}.';
      if (rate != null && h.sampleRate != rate) return 'Its file sets were recorded at different rates.';
      rate = h.sampleRate;
      names ??= h.names;
      h.pick(names, who: 'Walking');
    } on HeaderError catch (e) {
      return e.message;
    } on MissingSites catch (e) {
      return e.message;
    }
  }
  return null;
}

/// The pass over a recording's `.f32` files (oldest first, plain names): the walk file's content; null without a
/// whole window of samples. Throws [MissingSites] or [HeaderError] for a recording it cannot read ([whyNotWalked]
/// says so first).
Map<String, Object?>? walkRecording(String id, List<File> f32Files) {
  final head = readHeader(f32Files.first);
  final rate = head.sampleRate.round();
  final layout = joinLayout(f32Files, names: head.names, who: 'Walking', rate: rate);
  final det = WalkWindows(head.names.length, rate);
  layout.forEachRow((row, missing) => det.push(row, missing: missing));
  if (det.windows.isEmpty) return null;
  final found = findWalks(det.windows);
  final logs = [for (final f in f32Files) File('${f.path.substring(0, f.path.length - 4)}.log')];
  final (:readings, :state) = logSteps(logs);
  final rows = walkMinutes(found, layout.startUnix, phoneMinutes(readings));
  return walkFileOf(id, layout.startUnix, head.names, head.sampleRate, found, rows, state);
}

/// The key of what the pass reads: the detector, and every raw file's, index's and log's name, size and modified time.
String walkKeyOf(List<File> f32Files) {
  final parts = <String>[walkDetector];
  for (final f in f32Files) {
    final stem = f.path.substring(0, f.path.length - 4);
    for (final g in [rawOnDisk(f), File('$stem.idx'), File('$stem.log')]) {
      if (g == null) continue;
      final k = fileKey(g);
      if (k != null) parts.add('${g.uri.pathSegments.last} ${k.size} ${k.modifiedUs}');
    }
  }
  return parts.join('\n');
}

File walkFileFor(Directory filesDir, String id) => File('${filesDir.path}/$walkFolder/$id$walkSuffix');

/// What the Archive keeps of a pass: the result, or why there is none.
typedef Walked = ({WalkResult? walk, String? why});

/// The kept pass of recording [id] when its files are those it read and its detector this one; null otherwise.
Walked? keptWalk(Directory filesDir, String id, List<File> f32Files) {
  try {
    final j = jsonDecode(walkFileFor(filesDir, id).readAsStringSync());
    if (j is! Map || j['key'] != walkKeyOf(f32Files) || j['detector'] != walkDetector) return null;
    return (walk: WalkResult.fromJson(j), why: j['why'] is String ? j['why'] as String : null);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Runs the pass when nothing current is kept for these files, and keeps it (with why not, when it cannot run).
Walked walkAndKeep(Directory filesDir, String id, List<File> f32Files) {
  final kept = keptWalk(filesDir, id, f32Files);
  if (kept != null) return kept;
  final key = walkKeyOf(f32Files);
  var why = whyNotWalked(f32Files);
  Map<String, Object?>? data;
  if (why == null) {
    try {
      data = walkRecording(id, f32Files);
      if (data == null) why = 'Under 10 seconds of signal.';
    } on MissingSites catch (e) {
      why = e.message;
    } on HeaderError catch (e) {
      why = e.message;
    } on FileSystemException catch (e) {
      return (walk: null, why: 'Could not read the recording: ${e.message}'); // not kept: try again next time
    }
  }
  final content = data ?? {'format': walkFormat, 'version': walkFileVersion, 'detector': walkDetector, 'recording': id, 'why': why};
  final f = walkFileFor(filesDir, id);
  try {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode({...content, 'key': key}), flush: true);
    tmp.renameSync(f.path);
  } on FileSystemException {
    // worked out again next time
  }
  return (walk: data == null ? null : WalkResult.fromJson(data), why: why);
}

/// [walkAndKeep] in a background isolate: plain paths in, plain data out.
Future<Walked> walkInBackground(String filesPath, String id, List<String> f32Paths) => Isolate.run(
  () => walkAndKeep(Directory(filesPath), id, [for (final p in f32Paths) File(p)]),
  debugName: 'walking',
);

/// What each kept walk file says, by recording id: its key and detector (to tell whether it is current), its result
/// (null when the pass could not run) and why not. Read through a summary index; the results stay valid after the raw
/// signal left the phone.
Map<String, ({String? key, String? detector, WalkResult? walk, String? why})> keptWalks(Directory filesDir) {
  final index = SummaryIndex(File('${filesDir.path}/cache/walking-index.json'), version: walkFileVersion);
  final sums = index.summaries(Directory('${filesDir.path}/$walkFolder'), walkSuffix, (f) {
    final j = jsonDecode(f.readAsStringSync());
    return j is Map && j['version'] == walkFileVersion ? j : null;
  });
  final out = <String, ({String? key, String? detector, WalkResult? walk, String? why})>{};
  for (final e in sums.entries) {
    final v = e.value;
    if (v is! Map) continue;
    final id = e.key.substring(0, e.key.length - walkSuffix.length);
    out[id] = (
      key: v['key'] is String ? v['key'] as String : null,
      detector: v['detector'] is String ? v['detector'] as String : null,
      walk: WalkResult.fromJson(v),
      why: v['why'] is String ? v['why'] as String : null,
    );
  }
  return out;
}
