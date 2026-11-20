// The pulse pass over one finished recording (DECISIONS 810-819), the way the Archive's detectors' pass works
// (archive/seen.dart): every channel its header names joined on the clock (sleep/night_signal.dart), sample by sample
// through the pulse detector (detector.dart). Kept in `files/pulse/<id>.pulse.json` (docs/data-format.md "Pulse"), the
// format scripts/compare_pulse.py writes on the laptop, with the size and modified time of every raw file it read and
// the detector's version, so it runs again only when one changed. The pulse file stays when the raw signal leaves the
// phone: it is a result, like a sleep report (Storage counts it with the notes, always kept). Plain Dart; the Archive,
// a recording's page and the sleep report run it in a background isolate.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../cache/file_summaries.dart' show SummaryIndex, fileKey;
import '../feedback/features.dart' show median;
import '../recorder/header.dart' show HeaderError, MissingSites, readHeader;
import '../recorder/packed.dart' show rawOnDisk;
import '../sleep/night_signal.dart' show joinLayout;
import 'detector.dart';

const String pulseFormat = 'eeg-tracker-pulse';
const int pulseFileVersion = 1;

/// The pulse files' folder in `files/`.
const String pulseFolder = 'pulse';
const String pulseSuffix = '.pulse.json';

double? _r1(double? v) => v == null || v.isNaN ? null : (v * 10).round() / 10;
double? _r2(double? v) => v == null || v.isNaN ? null : (v * 100).round() / 100;

String _iso(DateTime t) {
  final l = t.toLocal(), o = l.timeZoneOffset;
  String two(int v) => v.toString().padLeft(2, '0');
  final sign = o.isNegative ? '-' : '+', m = o.inMinutes.abs();
  return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}T${two(l.hour)}:${two(l.minute)}:'
      '${two(l.second)}$sign${two(m ~/ 60)}:${two(m % 60)}';
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

/// What a pulse file holds (docs/data-format.md "Pulse").
class PulseResult {
  const PulseResult({
    required this.recording,
    required this.startMs,
    required this.channels,
    required this.sampleRate,
    required this.codes,
    required this.bpm,
    this.conf = const [],
    this.channel = const [],
    this.epochS = PulseRule.epochS,
    this.detector = pulseDetector,
  });

  final String recording;

  /// The first epoch's start, unix ms (the joined recording's first sample, a whole second).
  final int startMs;
  final List<String> channels;
  final num sampleRate;

  /// One [PulseCode] per epoch.
  final String codes;

  /// A minute, per epoch; null without a reading.
  final List<double?> bpm;
  final List<double?> conf;
  final List<int?> channel;
  final double epochS;
  final String detector;

  int get epochs => codes.length;
  int get read => bpm.where((b) => b != null).length;
  double get coverage => epochs == 0 ? 0 : read / epochs;
  DateTime get start => DateTime.fromMillisecondsSinceEpoch(startMs);
  DateTime get end => DateTime.fromMillisecondsSinceEpoch(startMs + (epochs * epochS * 1000).round());
  DateTime epochStart(int i) => DateTime.fromMillisecondsSinceEpoch(startMs + (i * epochS * 1000).round());

  /// The median of the readings; null without one.
  double? get medianBpm {
    final v = [for (final b in bpm) ?b];
    return v.isEmpty ? null : median(v);
  }

  static PulseResult? fromJson(Object? j) {
    if (j is! Map || j['format'] != pulseFormat || j['version'] != pulseFileVersion) return null;
    final start = j['start_ms'], codes = j['codes'], bpm = j['bpm'], ch = j['channels'];
    if (start is! int || codes is! String || bpm is! List || bpm.length != codes.length || ch is! List) return null;
    if (j['recording'] is! String) return null;
    final conf = j['conf'], chan = j['channel'];
    return PulseResult(
      recording: j['recording'] as String,
      startMs: start,
      channels: [for (final c in ch) if (c is String) c],
      sampleRate: _num(j['sample_rate']) ?? 0,
      codes: codes,
      bpm: [for (final b in bpm) _num(b)],
      conf: conf is List && conf.length == codes.length ? [for (final b in conf) _num(b)] : const [],
      channel: chan is List && chan.length == codes.length ? [for (final c in chan) c is int ? c : null] : const [],
      epochS: _num(j['epoch_s']) ?? PulseRule.epochS,
      detector: j['detector'] is String ? j['detector'] as String : '',
    );
  }
}

/// The pulse file's content for a recording [id] whose joined signal starts at [startUnix] (a whole second); the same
/// fields as scripts/compare_pulse.py writes.
Map<String, Object?> pulseFileOf(String id, int startUnix, List<String> names, num rate, List<PulseEpoch> eps) {
  final bpm = [for (final e in eps) e.read ? _r1(e.bpm) : null];
  final vals = [for (final b in bpm) ?b];
  return {
    'format': pulseFormat,
    'version': pulseFileVersion,
    'detector': pulseDetector,
    'recording': id,
    'start': _iso(DateTime.fromMillisecondsSinceEpoch(startUnix * 1000)),
    'start_ms': startUnix * 1000,
    'epoch_s': PulseRule.epochS,
    'channels': names,
    'sample_rate': rate,
    'epochs': eps.length,
    'read': vals.length,
    'coverage': ((eps.isEmpty ? 0 : vals.length / eps.length) * 10000).round() / 10000,
    'median_bpm': vals.isEmpty ? null : _r1(median(vals)),
    'codes': eps.map((e) => e.code).join(),
    'bpm': bpm,
    'conf': [for (final e in eps) e.read ? _r2(e.conf) : null],
    'channel': [for (final e in eps) e.read ? e.channel : null],
  };
}

/// Why the pass cannot read [f32Files], in words; null when it can. Any layout and number of channels, at a whole
/// number of samples a second from 50 up (the band-pass reaches 20 Hz); every set must hold the first one's channels.
String? whyNoPulse(List<File> f32Files) {
  if (f32Files.isEmpty) return 'No raw signal on the phone.';
  List<String>? names;
  num? rate;
  for (final f in f32Files) {
    try {
      final h = readHeader(f);
      if (h.sampleRate is! int && h.sampleRate != h.sampleRate.roundToDouble()) {
        return 'The pulse reads a whole number of samples a second; this recording has ${h.sampleRate}.';
      }
      if (h.sampleRate < 50) return 'The pulse needs 50 samples a second or more; this recording has ${h.sampleRate}.';
      if (rate != null && h.sampleRate != rate) return 'Its file sets were recorded at different rates.';
      rate = h.sampleRate;
      names ??= h.names;
      h.pick(names, who: 'The pulse');
    } on HeaderError catch (e) {
      return e.message;
    } on MissingSites catch (e) {
      return e.message;
    }
  }
  return null;
}

/// The pass over a recording's `.f32` files (oldest first, plain names): the pulse file's content; null without a
/// whole epoch of samples. Throws [MissingSites] or [HeaderError] for a recording it cannot read ([whyNoPulse] says so
/// first).
Map<String, Object?>? pulseRecording(String id, List<File> f32Files) {
  final head = readHeader(f32Files.first);
  final rate = head.sampleRate.round();
  final layout = joinLayout(f32Files, names: head.names, who: 'The pulse', rate: rate);
  final det = PulseEpochs(head.names.length, rate);
  layout.forEachRow((row, missing) => det.push(row, missing: missing));
  final eps = det.finish();
  if (eps.isEmpty) return null;
  return pulseFileOf(id, layout.startUnix, head.names, head.sampleRate, eps);
}

/// The key of what the pass reads: the detector, and every raw file's and index's name, size and modified time.
String pulseKeyOf(List<File> f32Files) {
  final parts = <String>[pulseDetector];
  for (final f in f32Files) {
    final stem = f.path.substring(0, f.path.length - 4);
    for (final g in [rawOnDisk(f), File('$stem.idx')]) {
      if (g == null) continue;
      final k = fileKey(g);
      if (k != null) parts.add('${g.uri.pathSegments.last} ${k.size} ${k.modifiedUs}');
    }
  }
  return parts.join('\n');
}

File pulseFileFor(Directory filesDir, String id) => File('${filesDir.path}/$pulseFolder/$id$pulseSuffix');

/// What a pass gives: the result, or why there is none.
typedef Pulsed = ({PulseResult? pulse, String? why});

/// The pulse file of recording [id] as it is (also one made from raw files since packed or removed); null: none.
PulseResult? readPulse(Directory filesDir, String id) {
  try {
    return PulseResult.fromJson(jsonDecode(pulseFileFor(filesDir, id).readAsStringSync()));
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// The kept pass of recording [id] when its raw files are those it read and its detector this one; null otherwise.
Pulsed? keptPulse(Directory filesDir, String id, List<File> f32Files) {
  try {
    final j = jsonDecode(pulseFileFor(filesDir, id).readAsStringSync());
    if (j is! Map || j['key'] != pulseKeyOf(f32Files) || j['detector'] != pulseDetector) return null;
    return (pulse: PulseResult.fromJson(j), why: j['why'] is String ? j['why'] as String : null);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Runs the pass when nothing current is kept for these files, and keeps it (with why not, when it cannot run).
Pulsed pulseAndKeep(Directory filesDir, String id, List<File> f32Files) {
  final kept = keptPulse(filesDir, id, f32Files);
  if (kept != null) return kept;
  final key = pulseKeyOf(f32Files);
  var why = whyNoPulse(f32Files);
  Map<String, Object?>? data;
  if (why == null) {
    try {
      data = pulseRecording(id, f32Files);
      if (data == null) why = 'Under 30 seconds of signal.';
    } on MissingSites catch (e) {
      why = e.message;
    } on HeaderError catch (e) {
      why = e.message;
    } on FileSystemException catch (e) {
      return (pulse: null, why: 'Could not read the recording: ${e.message}'); // not kept: try again next time
    }
  }
  final content =
      data ?? {'format': pulseFormat, 'version': pulseFileVersion, 'detector': pulseDetector, 'recording': id, 'why': why};
  final f = pulseFileFor(filesDir, id);
  try {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode({...content, 'key': key}), flush: true);
    tmp.renameSync(f.path);
  } on FileSystemException {
    // worked out again next time
  }
  return (pulse: data == null ? null : PulseResult.fromJson(data), why: why);
}

/// [pulseAndKeep] in a background isolate: plain paths in, plain data out.
Future<Pulsed> pulseInBackground(String filesPath, String id, List<String> f32Paths) => Isolate.run(
  () => pulseAndKeep(Directory(filesPath), id, [for (final p in f32Paths) File(p)]),
  debugName: 'pulse',
);

/// What each kept pulse file says, by recording id: its key and detector (to tell whether it is current), its span
/// and readings' summary, and why not. Read through a summary index (the files are tens of KB each).
typedef PulseKept = ({String? key, String? detector, int? startMs, int epochs, int read, double? medianBpm, String? why});

Map<String, PulseKept> keptPulses(Directory filesDir) {
  final index = SummaryIndex(File('${filesDir.path}/cache/pulse-index.json'), version: pulseFileVersion);
  final sums = index.summaries(Directory('${filesDir.path}/$pulseFolder'), pulseSuffix, (f) {
    final j = jsonDecode(f.readAsStringSync());
    if (j is! Map || j['version'] != pulseFileVersion) return null;
    return {
      'key': j['key'],
      'detector': j['detector'],
      'start_ms': j['start_ms'],
      'epochs': j['epochs'],
      'read': j['read'],
      'median_bpm': j['median_bpm'],
      'why': j['why'],
    };
  });
  final out = <String, PulseKept>{};
  for (final e in sums.entries) {
    final v = e.value;
    if (v is! Map) continue;
    final id = e.key.substring(0, e.key.length - pulseSuffix.length);
    out[id] = (
      key: v['key'] is String ? v['key'] as String : null,
      detector: v['detector'] is String ? v['detector'] as String : null,
      startMs: v['start_ms'] is int ? v['start_ms'] as int : null,
      epochs: v['epochs'] is int ? v['epochs'] as int : 0,
      read: v['read'] is int ? v['read'] as int : 0,
      medianBpm: _num(v['median_bpm']),
      why: v['why'] is String ? v['why'] as String : null,
    );
  }
  return out;
}

/// The readings of every pulse file overlapping [startMs] .. [startMs] + [n] epochs, on that clock (a sleep report's);
/// null when no pulse file covers any of it.
List<double?>? pulseOnClock(Directory filesDir, int startMs, int n, {Map<String, PulseKept>? kept}) {
  final endMs = startMs + n * PulseRule.epochS * 1000;
  List<double?>? out;
  for (final MapEntry(key: id, value: k) in (kept ?? keptPulses(filesDir)).entries) {
    final s = k.startMs;
    if (s == null || k.epochs == 0 || s >= endMs || s + k.epochs * PulseRule.epochS * 1000 <= startMs) continue;
    final p = readPulse(filesDir, id);
    if (p == null) continue;
    final a = pulseAligned(p.startMs, p.bpm, startMs, n, epochS: p.epochS);
    out ??= List<double?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      out[i] ??= a[i];
    }
  }
  return out;
}
