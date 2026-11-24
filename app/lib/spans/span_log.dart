// The one writer of the spans files (Record first, DECISIONS 884): lines are added, never rewritten, and each is on
// storage before the call returns. While a recording runs only the recorder's engine writes its file; the screen
// writes once it has stopped ("Not sleep", a sleep stretch confirmed later) and is refused before that.
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;
import 'span.dart';

/// The screen tried to write the spans of the recording that is running.
class SpansBusy implements Exception {
  const SpansBusy(this.recording);
  final String recording;

  @override
  String toString() => 'Recording $recording is still running: its spans are the recorder\'s to write.';
}

class SpanLog {
  /// The recorder's log.
  SpanLog(this.dir, {DateTime Function()? clock}) : _now = clock ?? DateTime.now, active = null;

  /// The screen's log: [active] gives the id of the recording that runs now (from the recorder's saved state), or
  /// null; writing that recording's file throws [SpansBusy].
  SpanLog.screen(this.dir, {required String? Function() this.active, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final Directory dir;
  final DateTime Function() _now;
  final String? Function()? active;

  File fileOf(String recording) => spansFileOf(dir, recording);

  SpansFile read(String recording) => readSpans(fileOf(recording));

  /// Adds [span]'s line (its state now) to its recording's file.
  void write(Span span) => _add(span.recording, span.toLine(_now()));

  /// A new span of [recording], numbered after the ones its file holds, written at once.
  Span add(
    String recording, {
    required String kind,
    required DateTime start,
    DateTime? end,
    required String source,
    String? endedBy,
    String? estimate,
    String? session,
    bool startedRecording = false,
  }) {
    var n = 0;
    for (final s in read(recording).spans) {
      final k = int.tryParse(s.id.substring(s.id.lastIndexOf('-') + 1)) ?? 0;
      if (k > n) n = k;
    }
    final span = Span(
      id: '$recording-${n + 1}',
      kind: kind,
      label: spanLabels[kind],
      start: start,
      end: end,
      source: source,
      endedBy: end == null ? null : (endedBy ?? 'owner'),
      estimate: estimate,
      session: session,
      startedRecording: startedRecording,
    );
    write(span);
    return span;
  }

  /// The Archive's "Not sleep" for an old recording ([sleep] false), or taking it back ([sleep] true).
  void reviewed(String recording, {required bool sleep, List<String> sets = const [], List<String> hides = const []}) =>
      _add(recording, {
        'v': 1,
        'reviewed': sleep ? 'sleep' : 'no_sleep',
        if (!sleep) 'sets': sets,
        if (!sleep) 'hides': hides,
        'made': isoLocal(_now()),
      });

  void _add(String recording, Map<String, Object?> line) {
    final active = this.active;
    if (active != null && active() == recording) throw SpansBusy(recording);
    dir.createSync(recursive: true);
    final f = fileOf(recording);
    // a kill in the middle of a write leaves a half last line: the next line starts on its own
    var lead = '';
    if (f.existsSync()) {
      final len = f.lengthSync();
      if (len > 0) {
        final r = f.openSync();
        try {
          r.setPositionSync(len - 1);
          if (r.readByteSync() != 10) lead = '\n';
        } finally {
          r.closeSync();
        }
      }
    }
    f.writeAsStringSync('$lead${jsonEncode(line)}\n', mode: FileMode.append, flush: true);
  }
}
