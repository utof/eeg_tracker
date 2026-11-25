// What you were doing in a recording: the spans file's model and reader (Record first, DECISIONS 880-899;
// docs/data-format.md "What you were doing in a recording"). One file per recording,
// `files/spans/<recording id>.spans.jsonl`, add-only; the last line with a given `span` id is the span. The laptop's
// twin is scripts/spans.py; both are checked against the golden files in tests/contract/spans/.
// The reader's choices where the format doc leaves room are the twin's: a blank line is skipped without being
// counted; a `reviewed` word other than `no_sleep` or `sleep` makes the line skipped; a time without an offset is
// local time; a `paused` pair that does not parse is dropped (the span is kept); `started_recording` that is not
// `true` reads as false; text fields that are not text read as null; `removed` that is not `true` reads as false, and
// `moved_to` is read only beside it.
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;

const String spansSuffix = '.spans.jsonl';

/// `ended_by` of a span nobody ended: its session was gone (the app was closed, its page left) when something else
/// closed it (Stop of the recording, the next activity, End on the Record tab's bar). Its end is not a time the owner
/// stopped doing it (DECISIONS 1017).
const String leftOpen = 'left_open';

/// The kinds whose spans give sleep reports.
const Set<String> sleepKinds = {'sleep', 'nap'};

/// A span kind's label in the shared vocabulary (scripts/truth_vocabulary.tsv); null: none.
const Map<String, String> spanLabels = {
  'sleep': 'in_bed',
  'nap': 'in_bed',
  'work': 'working',
  'meditate': 'meditating',
  'alpha_theta': 'neurofeedback',
  'sound': 'sound_session',
  'dream_catcher': 'resting',
};

/// A span kind in the owner's words (`Sleep`, `Work`); a kind this build does not know shows as its own word.
String spanWord(String kind) => switch (kind) {
  'sleep' => 'Sleep',
  'nap' => 'Nap',
  'work' => 'Work',
  'meditate' => 'Meditate',
  'alpha_theta' => 'Alpha-theta',
  'sound' => 'Sound',
  'dream_catcher' => 'Dream catcher',
  'check_in' => 'Check-in',
  'calibration' => 'Calibration',
  _ => kind.isEmpty ? kind : '${kind[0].toUpperCase()}${kind.substring(1).replaceAll('_', ' ')}',
};

class Span {
  const Span({
    required this.id,
    required this.kind,
    required this.start,
    required this.source,
    this.label,
    this.end,
    this.startedRecording = false,
    this.endedBy,
    this.session,
    this.paused = const [],
    this.estimate,
    this.removed = false,
    this.movedTo,
  });

  /// `<recording id>-<n>`.
  final String id;
  final String kind;
  final String? label;
  final DateTime start;

  /// Null while the span is open.
  final DateTime? end;

  /// `owner_button`, `owner_confirmed`, `auto_start`, `auto_resume` (the app opened it when the headband came back
  /// after the 60-minute rule had ended Sleep, DECISIONS 1015).
  final String source;
  final bool startedRecording;
  final String? endedBy;
  final String? session;
  final List<(DateTime, DateTime?)> paused;
  final String? estimate;

  /// The owner took this stretch away in the Archive ("Not sleep", "Remove this mark"), or it was filed again under
  /// the recording that holds its hours ([movedTo]: the id it has there). A removed span is in no list that counts
  /// ([SpansFile.spans]); its times are kept, so it can be put back with a line without `removed` (DECISIONS 1025).
  final bool removed;
  final String? movedTo;

  bool get closed => end != null;
  bool get isSleep => sleepKinds.contains(kind);

  /// The recording's id (the span id minus its number).
  String get recording => id.contains('-') ? id.substring(0, id.lastIndexOf('-')) : id;

  Span closedAt(DateTime at, String by) => Span(
    id: id,
    kind: kind,
    label: label,
    start: start,
    end: at.isBefore(start) ? start : at,
    source: source,
    startedRecording: startedRecording,
    endedBy: by,
    session: session,
    paused: [for (final p in paused) (p.$1, p.$2 ?? at)],
    estimate: estimate,
    removed: removed,
    movedTo: movedTo,
  );

  /// The same span open again (Undo of an end the app made by itself).
  Span reopened() => Span(
    id: id,
    kind: kind,
    label: label,
    start: start,
    source: source,
    startedRecording: startedRecording,
    session: session,
    paused: paused,
    estimate: estimate,
    removed: removed,
    movedTo: movedTo,
  );

  /// The same span with other times (a confirmed stretch whose times the owner set afterwards).
  Span withTimes(DateTime start, DateTime? end) => Span(
    id: id,
    kind: kind,
    label: label,
    start: start,
    end: end,
    source: source,
    startedRecording: startedRecording,
    endedBy: endedBy,
    session: session,
    paused: paused,
    estimate: estimate,
    removed: removed,
    movedTo: movedTo,
  );

  /// The same span taken away ([removed] true; [movedTo]: it was filed again under that id), or put back.
  Span asRemoved(bool removed, {String? movedTo}) => Span(
    id: id,
    kind: kind,
    label: label,
    start: start,
    end: end,
    source: source,
    startedRecording: startedRecording,
    endedBy: endedBy,
    session: session,
    paused: paused,
    estimate: estimate,
    removed: removed,
    movedTo: removed ? movedTo : null,
  );

  Span withId(String id) => Span(
    id: id,
    kind: kind,
    label: label,
    start: start,
    end: end,
    source: source,
    startedRecording: startedRecording,
    endedBy: endedBy,
    session: session,
    paused: paused,
    estimate: estimate,
    removed: removed,
    movedTo: movedTo,
  );

  /// One line of the spans file ([made]: when it is written).
  Map<String, Object?> toLine(DateTime made) => {
    'v': 1,
    'span': id,
    'kind': kind,
    'label': ?label,
    'start': isoLocal(start),
    'end': end == null ? null : isoLocal(end!),
    'source': source,
    'started_recording': startedRecording,
    'ended_by': ?endedBy,
    'session': ?session,
    if (paused.isNotEmpty)
      'paused': [
        for (final p in paused) [isoLocal(p.$1), p.$2 == null ? null : isoLocal(p.$2!)],
      ],
    'estimate': ?estimate,
    if (removed) 'removed': true,
    if (removed) 'moved_to': ?movedTo,
    'made': isoLocal(made),
  };

  /// The golden files' shape (`*.expected.json`), times as unix seconds.
  Map<String, Object?> toExpected() => {
    'span': id,
    'kind': kind,
    'label': label,
    'start_unix': _unix(start),
    'end_unix': end == null ? null : _unix(end!),
    'source': source,
    'started_recording': startedRecording,
    'ended_by': endedBy,
    'session': session,
    'paused': [
      for (final p in paused) [_unix(p.$1), p.$2 == null ? null : _unix(p.$2!)],
    ],
    'estimate': estimate,
  };

  static Span? fromLine(Map<Object?, Object?> d) {
    final id = _need(d['span']), kind = _need(d['kind']), source = _need(d['source']), start = _time(d['start']);
    final rawEnd = d['end'];
    final end = rawEnd == null ? null : _time(rawEnd);
    if (id == null || kind == null || source == null || start == null || (rawEnd != null && end == null)) return null;
    final pauses = <(DateTime, DateTime?)>[];
    final p = d['paused'];
    if (p is List) {
      for (final pair in p) {
        if (pair is! List || pair.length != 2) continue;
        final a = _time(pair[0]), b = pair[1] == null ? null : _time(pair[1]);
        if (a == null || (pair[1] != null && b == null)) continue;
        pauses.add((a, b));
      }
    }
    return Span(
      id: id,
      kind: kind,
      label: _text(d['label']),
      start: start,
      end: end,
      source: source,
      startedRecording: d['started_recording'] == true,
      endedBy: _text(d['ended_by']),
      session: _text(d['session']),
      paused: pauses,
      estimate: _text(d['estimate']),
      removed: d['removed'] == true,
      movedTo: d['removed'] == true ? _text(d['moved_to']) : null,
    );
  }
}

/// A spans file as read.
class SpansFile {
  SpansFile({
    this.spans = const [],
    this.removed = const [],
    this.reviewed,
    this.sets = const [],
    this.hides = const [],
    this.skipped = 0,
  });

  /// In the order each span first appeared; without the ones taken away.
  final List<Span> spans;

  /// The spans the owner took away, and the ones filed again under another recording ([Span.movedTo]), in the same
  /// order: nothing counts them.
  final List<Span> removed;

  /// `no_sleep` or `sleep` from the last `reviewed` line; null without one.
  final String? reviewed;

  /// The file sets (stems) that are no sleep, and the nights (evening dates) whose report is hidden.
  final List<String> sets;
  final List<String> hides;

  /// Lines skipped (not a span, a half line after a kill).
  final int skipped;

  List<Span> get sleepSpans => [for (final s in spans) if (s.isSleep) s];

  Map<String, Object?> toExpected() => {
    'spans': [for (final s in spans) s.toExpected()],
    'removed': [for (final s in removed) {...s.toExpected(), 'moved_to': s.movedTo}],
    'reviewed': reviewed,
    'sets': sets,
    'hides': hides,
    'skipped': skipped,
  };
}

/// The spans in the text of a spans file.
SpansFile parseSpans(String text) {
  final byId = <String, Span>{}; // keeps the order of first appearance; a later line replaces the value
  String? reviewed;
  var sets = <String>[], hides = <String>[];
  var skipped = 0;
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    Object? d;
    try {
      d = jsonDecode(line);
    } on FormatException {
      d = null;
    }
    if (d is! Map || d['v'] is! num || d['v'] != 1) {
      skipped++;
      continue;
    }
    if (d.containsKey('reviewed')) {
      final r = d['reviewed'];
      if (r != 'no_sleep' && r != 'sleep') {
        skipped++;
        continue;
      }
      reviewed = r as String;
      sets = r == 'sleep' ? [] : _strings(d['sets']);
      hides = r == 'sleep' ? [] : _strings(d['hides']);
      continue;
    }
    final s = Span.fromLine(d);
    if (s == null) {
      skipped++;
    } else {
      byId[s.id] = s;
    }
  }
  return SpansFile(
    spans: [for (final s in byId.values) if (!s.removed) s],
    removed: [for (final s in byId.values) if (s.removed) s],
    reviewed: reviewed,
    sets: sets,
    hides: hides,
    skipped: skipped,
  );
}

/// The spans file [f]; a missing or unreadable one is an empty one.
SpansFile readSpans(File f) {
  try {
    return parseSpans(utf8.decode(f.readAsBytesSync(), allowMalformed: true));
  } on FileSystemException {
    return SpansFile();
  }
}

/// `files/spans/`, beside the recordings folder [recordingsDir] (`files/recordings/`).
/// The ids of the marks taken away in the Archive ("Remove this mark", "Not sleep"; DECISIONS 1025) and not put back:
/// an activity's own file that names one of them (its `span`) is left out of every list (DECISIONS 1042).
Set<String> removedSpanIds(Directory spansDir) => {
  for (final f in spansIn(spansDir).values)
    for (final s in f.removed) s.id,
};

Directory spansDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/spans');

File spansFileOf(Directory spansDir, String recording) => File('${spansDir.path}/$recording$spansSuffix');

/// Every spans file of [spansDir] by recording id, oldest id first.
Map<String, SpansFile> spansIn(Directory spansDir) {
  if (!spansDir.existsSync()) return const {};
  final names = [
    for (final f in spansDir.listSync().whereType<File>())
      if (f.uri.pathSegments.last.endsWith(spansSuffix)) f.uri.pathSegments.last,
  ]..sort();
  return {
    for (final n in names) n.substring(0, n.length - spansSuffix.length): readSpans(File('${spansDir.path}/$n')),
  };
}

num _unix(DateTime t) {
  final us = t.microsecondsSinceEpoch;
  return us % 1000000 == 0 ? us ~/ 1000000 : us / 1e6;
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;
String? _need(Object? v) => v is String && v.isNotEmpty ? v : null;
List<String> _strings(Object? v) => [
  if (v is List)
    for (final x in v)
      if (x is String) x,
];

String _hmOf(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _wordsOf(List<Span> spans) {
  final words = [for (final s in spans) spanWord(s.kind)];
  return words.length < 2 ? words.join() : '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
}

/// The phone notification when the 60-minute rule ended what was marked ([ended]: those spans, closed).
({String title, String text}) spansEndedNotice(List<Span> ended, {required int awayMinutes}) => (
  title: 'Headband off for $awayMinutes minutes',
  text:
      '${_wordsOf(ended)} ${ended.length == 1 ? 'was' : 'were'} ended at ${ended.isEmpty ? '' : _hmOf(ended.first.end!)}, '
      'the last moment with a signal. Still going? Open the app and tap Undo.',
);

/// The Record tab's line for the same ([undoable]: `RecordingLive.undoable`); null when there is nothing to undo.
/// [resumed] (`RecordingLive.resumed`): the app has opened a sleep stretch by itself since; the line says so, and
/// Undo takes that stretch away.
String? undoLine(List<Span> undoable, {Span? resumed}) => resumed != null
    ? 'The headband came back at ${_hmOf(resumed.start)}, so the app marked Sleep again from then (its guess). Not sleeping?'
    : undoable.isEmpty
    ? null
    : '${_wordsOf(undoable)} ended at ${_hmOf(undoable.first.end!)}: the headband was off for an hour. Still going?';

/// The phone notification when the app opened a sleep stretch by itself after the headband came back ([resumed]).
({String title, String text}) sleepResumedNotice(Span resumed) => (
  title: 'Sleep goes on',
  text:
      'The headband is back, so Sleep is marked again from ${_hmOf(resumed.start)} (the app\'s guess). Not sleeping? '
      'Open the app and tap Undo.',
);

/// The phone notification when the recording stopped itself after [awayHours] without the headband.
({String title, String text}) recordingStoppedNotice({required int awayHours}) => (
  title: 'Recording stopped',
  text:
      'No headband for $awayHours hours, so the recording stopped itself. Its files are kept. Open the app to answer '
      '"What was this recording?".',
);

/// The running recording's line under its buttons: what is marked in it, in order ("Recording since 11:02 · Work
/// 11:05-12:40 · Sleep since 23:10"); [sinceMs]: when the recording started (unix ms; 0: unknown).
String spansLine(List<Span> spans, {int sinceMs = 0}) {
  String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final parts = [
    if (sinceMs > 0) 'Recording since ${hm(DateTime.fromMillisecondsSinceEpoch(sinceMs))}',
    for (final s in spans)
      if (s.end == null)
        '${spanWord(s.kind)} since ${hm(s.start)}${s.source == 'auto_resume' ? ' (marked by the app)' : ''}'
      else if (s.end!.isAfter(s.start))
        '${spanWord(s.kind)} ${hm(s.start)}-${hm(s.end!)}',
    if (spans.isEmpty) 'nothing marked, so it is not counted as sleep',
  ];
  return parts.join(' · ');
}
