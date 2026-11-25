// The sheet after Stop, "What was this recording?" (Record first, DECISIONS 890-891, 908-910): when it is shown, what
// it already knows from the spans, and what Save writes. The chips, their rules and the tags' fields are the shared
// package's (packages/shared_labels, stop_sheet.dart); here is eeg_tracker's side: the recording, its spans, the
// Archive's tags file, the confirm questions it settles, and the sleep span a "Slept 23:50-07:10" makes.
import 'dart:convert';
import 'dart:io';

import 'package:shared_labels/shared_labels.dart';

import '../archive/tags.dart';
import '../confirm/questions.dart';
import '../recorder/header.dart' show tryHeader;
import '../recorder/nights.dart' show RecordingsAt, dataEndOf, stemTime;
import 'span.dart';
import 'span_log.dart';

/// The sheet is skipped by itself when what you pressed while recording covers this share of it and no question
/// waits (a planning value, DECISIONS 890).
const double stopSheetSkipCover = 0.9;

/// The chip a pressed span already answers.
const Map<String, String> chipOfSpanKind = {'sleep': 'night_sleep', 'nap': 'nap', 'work': 'working', 'meditate': 'meditating'};

/// What the sheet is about.
class StopSheetPlan {
  const StopSheetPlan({required this.recording, required this.start, required this.end, this.spans = const []});
  final String recording;
  final DateTime start, end;
  final List<Span> spans;

  Duration get length => end.difference(start);

  /// The chips already answered by spans you pressed: shown as done, not asked again.
  Set<String> get done => {
    for (final s in spans)
      if (s.source == 'owner_button') ?chipOfSpanKind[s.kind],
  };

  /// The share of the recording that pressed spans cover (overlaps counted once).
  double get covered {
    final total = length.inSeconds;
    if (total <= 0) return 0;
    final parts = [
      for (final s in spans)
        if (s.source == 'owner_button')
          (s.start.isBefore(start) ? start : s.start, (s.end ?? end).isAfter(end) ? end : (s.end ?? end)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var seconds = 0;
    DateTime? upTo;
    for (final (a, b) in parts) {
      final from = upTo != null && upTo.isAfter(a) ? upTo : a;
      if (b.isAfter(from)) {
        seconds += b.difference(from).inSeconds;
        upTo = b;
      }
    }
    return seconds / total;
  }

  /// No sheet: what was pressed says it all, and [questions] (the confirm batch for this recording) is empty.
  bool skips({required int questions}) => covered >= stopSheetSkipCover && questions == 0;

  /// "Work 11:05-12:40 · Meditate 12:45-13:00"; null with nothing marked.
  String? get marked {
    String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (spans.isEmpty) return null;
    return [for (final s in spans) '${spanWord(s.kind)} ${hm(s.start)}-${hm(s.end ?? end)}'].join(' · ');
  }
}

/// The plan for recording [recording] that started at [startMs]: its end is its last saved sample, its spans its
/// file's. Null when it has no data and no spans (nothing to ask about).
StopSheetPlan? stopSheetPlan(Directory filesDir, String recording, int startMs) {
  final rec = Directory('${filesDir.path}/recordings');
  final start = DateTime.fromMillisecondsSinceEpoch(startMs);
  var end = start;
  if (rec.existsSync()) {
    for (final f in rec.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.f32') || stemTime(name) == null || name.compareTo(recording) < 0) continue;
      if (tryHeader(f)?.recording != recording) continue;
      final e = dataEndOf(f);
      if (e != null && e.isAfter(end)) end = e;
    }
  }
  final spans = readSpans(spansFileOf(Directory('${filesDir.path}/spans'), recording)).spans;
  for (final s in spans) {
    if (s.end != null && s.end!.isAfter(end)) end = s.end!;
  }
  if (!end.isAfter(start)) return null;
  return StopSheetPlan(recording: recording, start: start, end: end, spans: spans);
}

/// Which recording's sheet was already answered or skipped (`files/spans/stop-sheet.json`): the Record tab offers the
/// sheet as a card for the last recording until then.
class StopSheetSeen {
  StopSheetSeen(this.filesDir);
  final Directory filesDir;
  File get _file => File('${filesDir.path}/spans/stop-sheet.json');

  String? get last {
    try {
      final j = jsonDecode(_file.readAsStringSync());
      return j is Map && j['recording'] is String ? j['recording'] as String : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void mark(String recording, {required bool saved, DateTime? at}) {
    try {
      _file.parent.createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({'recording': recording, 'saved': saved, 'at': isoLocal(at ?? DateTime.now())}), flush: true);
      tmp.renameSync(_file.path);
    } on FileSystemException {
      // asked again next time
    }
  }
}

/// Save: each pick becomes a tag of the recording (the Archive shows it, the laptop reads it as a truth row), the
/// confirm questions it already answers are settled, and a "Slept" or "Napped" with times makes a sleep span when
/// [sleepReports] says so for that pick. False when the tags could not be saved (nothing else is done then).
bool saveStopSheet(
  Directory filesDir,
  StopSheetPlan plan, {
  required List<StopPick> picks,
  String words = '',
  ConfirmQuestions? confirm,
  Set<String> sleepReports = const {},
  DateTime? made,
}) {
  final at = made ?? DateTime.now();
  final tags = [
    for (final t in stopSheetTags(start: plan.start, end: plan.end, picks: picks, words: words, made: at))
      ?ManualTag.fromJson(t),
  ];
  if (tags.isEmpty) return true;
  final store = TagStore(filesDir);
  if (!store.saveTags(plan.recording, [...store.tags(plan.recording), ...tags])) return false;
  for (final p in picks) {
    final label = Label.of(p.label);
    if (label == null) continue;
    final from = p.timed ? p.start! : plan.start, to = p.timed ? p.end! : plan.end;
    if (stopChipOf(p.label)?.whole ?? false) {
      confirm?.settle(plan.recording, Labels.asleep, plan.start, plan.end, answer: Answer.no);
    } else if (p.timed) {
      // without times a chip only says "at some point": it cannot say yes to a stretch the app found
      confirm?.settle(plan.recording, label, from, to);
    }
    if (p.timed && sleepReports.contains(p.label) && (stopChipOf(p.label)?.sleep ?? false)) {
      try {
        SpanLog(Directory('${filesDir.path}/spans')).add(
          plan.recording,
          kind: p.label == 'nap' ? 'nap' : 'sleep',
          start: from,
          end: to,
          source: 'owner_confirmed',
        );
      } on FileSystemException {
        // the tag is saved; the report can be asked for again from the Archive
      }
    }
  }
  return true;
}

/// A Yes on a sleep estimate (the confirm questions, wherever it was answered): a sleep span, source
/// `owner_confirmed` with the estimate's id, so that stretch gets its report (DECISIONS 889, 1016). Its times are the
/// ones you set when [answer] has them ("Yes, but the times are off"), else the detector's; a span this estimate
/// already has is corrected to them (a new line of the same span). Nothing for another label or an estimate without
/// a recording; false when it could not be written (the recording still runs: [active] is its id; the next
/// [sweepConfirmedSleep] writes it). The span says only that the stretch gets a report: whether its times are yours
/// is the answer's to say (the laptop's truth table reads the answer, never this span).
/// **Which recording** (DECISIONS 1028): the one that holds the stretch's start, by its id (a file set from before
/// Record first is its own recording), found from the files; the estimate's own `recording` (the first file of the
/// night's report, which may be an awake evening recording hours before) only when no file set holds any of it. A
/// span this estimate has under another recording is filed again where it belongs (the old one says `removed`,
/// `moved_to`). A span of this estimate that you took away in the Archive is not made again.
bool confirmedSleep(Directory filesDir, Estimate e, {Answered? answer, String? Function()? active, RecordingsAt? sets}) =>
    _fileYes(filesDir, e, answer: answer, active: active, sets: sets) != _Filed.waiting;

enum _Filed { same, wrote, waiting }

_Filed _fileYes(Directory filesDir, Estimate e, {Answered? answer, String? Function()? active, RecordingsAt? sets}) {
  final named = e.recording;
  if (named == null || named.isEmpty || !e.label.sameAs(Labels.asleep)) return _Filed.same;
  final yours = answer != null && answer.timesConfirmed;
  final start = yours ? answer.start! : e.start, end = yours ? answer.end! : e.end;
  final spansDir = Directory('${filesDir.path}/spans');
  final home = (sets ?? RecordingsAt(Directory('${filesDir.path}/recordings'))).holding(start, end) ?? named;
  final log = SpanLog.screen(spansDir, active: active ?? () => null);
  try {
    final files = spansIn(spansDir);
    // taken away by you ("Not sleep"): the Yes stands in the answers, the stretch stays away
    if (files.values.any((f) => f.removed.any((s) => s.estimate == e.id && s.movedTo == null))) return _Filed.same;
    final has = [for (final f in files.values) ...f.spans.where((s) => s.estimate == e.id)];
    var here = has.where((s) => s.recording == home).lastOrNull;
    var wrote = false;
    if (here == null) {
      final from = has.lastOrNull; // filed under another recording before: the same stretch, moved
      here = log.add(
        home,
        kind: from?.kind ?? (e.label.id == 'nap' ? 'nap' : 'sleep'),
        start: start,
        end: end,
        source: 'owner_confirmed',
        estimate: e.id,
      );
      wrote = true;
    } else if (here.start != start || here.end != end) {
      log.write(here = here.withTimes(start, end));
      wrote = true;
    }
    for (final s in has) {
      if (s.id == here.id) continue;
      log.write(s.asRemoved(true, movedTo: here.id));
      wrote = true;
    }
    return wrote ? _Filed.wrote : _Filed.same;
  } on SpansBusy {
    return _Filed.waiting;
  } on FileSystemException {
    return _Filed.waiting;
  }
}

/// Every Yes on a sleep estimate that has no span yet gets it now ([confirmedSleep], safe to repeat): a Yes tapped in
/// the notification is written by Android without the app's hook, and a Yes given while that recording still ran
/// could not be written into the recorder's file. A span filed under a recording that does not hold its hours (the
/// app did that until 2026-11-25) is filed again under the right one here, once. Run at the app's start, when it
/// comes to the front and after Stop. [written]: Yeses whose span was made, corrected or moved now; [waiting]: Yeses
/// whose recording still runs.
({int written, int waiting}) sweepConfirmedSleep(Directory filesDir, {String? Function()? active}) {
  final ConfirmState state;
  try {
    state = ConfirmStore(filesDir).read();
  } catch (_) {
    return (written: 0, waiting: 0);
  }
  final sets = RecordingsAt(Directory('${filesDir.path}/recordings'));
  var written = 0, waiting = 0;
  for (final a in state.answers.entries) {
    final e = state.estimates[a.key];
    if (e == null || a.value.answer != Answer.yes) continue;
    switch (_fileYes(filesDir, e, answer: a.value, active: active, sets: sets)) {
      case _Filed.wrote:
        written++;
      case _Filed.waiting:
        waiting++;
      case _Filed.same:
    }
  }
  return (written: written, waiting: waiting);
}
