// What a recording's page needs beyond the list (DECISIONS 700-709): the night's sleep stages, the work sessions'
// breaks, meetings and drowsiness, every session in its time, your tags and the detectors' kept pass; and a few seconds
// of its raw signal for the zoomed view. Plain Dart; the page reads both in a background isolate.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../recorder/header.dart' show RecordingHeader, tryHeader;
import '../recorder/packed.dart' show openRaw;
import '../sleep/night_signal.dart' show Run, runsOf;
import 'bands.dart';
import 'items.dart';
import 'seen.dart';
import 'tags.dart';

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// Spans from a list of `{start, end}` objects (also `from`/`to`), skipping what cannot be read.
List<(DateTime, DateTime)> _spans(Object? v) => [
  if (v is List)
    for (final x in v)
      if (x is Map)
        if ((_time(x['start']) ?? _time(x['from'])) case final s?)
          if ((_time(x['end']) ?? _time(x['to'])) case final e?)
            if (e.isAfter(s)) (s, e),
];

/// A work session's file read for the timeline; null when it cannot be read.
WorkDetail? readWork(File f) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    if (j is! Map) return null;
    final s = _time(j['start']), e = _time(j['end']);
    if (s == null || e == null) return null;
    final epochs = <({DateTime at, String level, bool closed})>[];
    final raw = j['epochs'];
    if (raw is List) {
      for (final x in raw) {
        if (x is! Map) continue;
        final num? sec = x['s'] is num ? x['s'] as num : null;
        final at = _time(x['at']) ?? (sec == null ? null : s.add(Duration(milliseconds: (sec * 1000).round())));
        if (at == null) continue;
        epochs.add((at: at, level: x['level'] is String ? x['level'] as String : 'unknown', closed: x['eyes_closed'] == true));
      }
    }
    return WorkDetail(start: s, end: e.isBefore(s) ? s : e, breaks: _spans(j['breaks']), meetings: _spans(j['meetings']), epochs: epochs);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// A report's stages; null when it has none.
ReportStages? readStages(File report) {
  try {
    final j = jsonDecode(report.readAsStringSync());
    if (j is! Map || j['scored'] != true) return null;
    final s = _time(j['data_start']), st = j['stages'];
    return s == null || st is! String || st.isEmpty ? null : (start: s, stages: st);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Everything the page draws, but the detectors' pass when none is kept for the recording's files as they are.
class RecordingDetail {
  const RecordingDetail({required this.input, required this.rawPaths, required this.passKept});
  final TimelineInput input;

  /// The `.f32` files with samples on the phone (plain names), for the pass and the raw view.
  final List<String> rawPaths;

  /// The pass is kept for these files (or there is nothing to pass over).
  final bool passKept;
}

/// The page's data for [item]; [sessions]: every session the list knows (those in its time are drawn).
RecordingDetail loadDetail(Directory filesDir, ArchiveItem item, List<SessionFile> sessions) {
  final raw = item.rawFiles(filesDir);
  final inTime = [
    for (final s in {...item.sessions, ...sessions})
      if (!s.start.isAfter(item.end) && !s.end.isBefore(item.start)) s,
  ]..sort((a, b) => a.start.compareTo(b.start));
  final work = [
    for (final s in inTime)
      if (s.kind == ArchiveKind.work) ?readWork(File('${filesDir.path}/${s.path}')),
  ];
  final report = item.report;
  final kept = raw.isEmpty ? null : keptSeen(filesDir, item.id, raw);
  return RecordingDetail(
    input: TimelineInput(
      seen: kept?.seen,
      seenWhy: kept?.why ?? (raw.isEmpty ? null : whyNotSeen(raw)),
      stages: report == null ? null : readStages(File('${filesDir.path}/${report.path}')),
      work: work,
      sessions: inTime,
      tags: TagStore(filesDir).tags(item.id),
    ),
    rawPaths: [for (final f in raw) f.path],
    passKept: raw.isEmpty || kept != null,
  );
}

/// Some seconds of a recording's raw signal: every channel of the file set holding [RawWindow.start], in µV, sample
/// after sample (channel by channel within a sample), unbroken (one run of its `.idx`).
class RawWindow {
  const RawWindow({
    required this.names,
    required this.rate,
    required this.start,
    required this.values,
    required this.lead,
    this.note,
    this.next,
    this.previous,
  });

  final List<String> names;
  final int rate;

  /// The first sample shown (after [lead]).
  final DateTime start;
  final Float32List values;

  /// Samples before [start] read so the filters settle (not shown).
  final int lead;

  /// Why less than asked was read ("No signal here: ..."), or null.
  final String? note;

  /// The nearest signal after and before the asked moment, when it fell in a gap.
  final DateTime? next, previous;

  int get channels => names.length;
  int get samples => values.length ~/ math.max(1, channels);
}

/// [seconds] of signal from [at] (and [leadSeconds] before it for the filters), from the file sets [f32Paths]
/// (plain names, oldest first). In a gap: what is shown is empty and [RawWindow.next] / [RawWindow.previous] say where
/// signal is.
RawWindow readWindow(List<String> f32Paths, DateTime at, int seconds, {int leadSeconds = 2}) {
  final t = at.millisecondsSinceEpoch / 1000;
  ({Run run, RecordingHeader h})? hit;
  double? next, previous;
  for (final p in f32Paths) {
    final f = File(p);
    final h = tryHeader(f);
    if (h == null) continue;
    final List<Run> runs;
    try {
      runs = runsOf(f, names: h.names, who: 'The archive');
    } on Object {
      continue;
    }
    for (final r in runs) {
      final end = r.t0 + r.count / h.sampleRate;
      if (t >= r.t0 && t < end) hit ??= (run: r, h: h);
      if (r.t0 > t && (next == null || r.t0 < next)) next = r.t0;
      if (end <= t && (previous == null || end > previous)) previous = end;
    }
  }
  DateTime? when(double? s) => s == null ? null : DateTime.fromMillisecondsSinceEpoch((s * 1000).round());
  if (hit == null) {
    return RawWindow(
      names: const [],
      rate: 250,
      start: at,
      values: Float32List(0),
      lead: 0,
      note: 'No signal at this moment: the headband was away, off or not yet recording.',
      next: when(next),
      previous: when(previous == null ? null : previous - seconds),
    );
  }
  final r = hit.run, h = hit.h;
  final rate = h.sampleRate.round();
  final width = h.count, rb = h.recordBytes;
  final atIdx = ((t - r.t0) * rate).floor();
  final from = math.max(0, atIdx - leadSeconds * rate);
  final to = math.min(r.count, atIdx + seconds * rate);
  final n = math.max(0, to - from);
  final out = Float32List(n * width);
  final f = openRaw(r.file);
  var got = 0;
  try {
    f.setPositionSync((r.first + from) * rb);
    final bytes = f.readSync(n * rb);
    final view = ByteData.sublistView(bytes);
    got = bytes.length ~/ rb;
    for (var k = 0; k < got; k++) {
      for (var c = 0; c < width; c++) {
        out[k * width + c] = view.getFloat32(k * rb + 4 + 4 * c, Endian.little) * 1e6;
      }
    }
  } finally {
    f.closeSync();
  }
  final shown = got - (atIdx - from);
  return RawWindow(
    names: h.names,
    rate: rate,
    start: DateTime.fromMillisecondsSinceEpoch(((r.t0 + atIdx / rate) * 1000).round()),
    values: got == n ? out : Float32List.sublistView(out, 0, got * width),
    lead: atIdx - from,
    note: shown < seconds * rate ? 'The signal stops after ${(math.max(0, shown) / rate).toStringAsFixed(1)} s here (a gap).' : null,
    next: when(next),
    previous: when(previous),
  );
}
