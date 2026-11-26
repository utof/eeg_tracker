// The guesses file (automatic recording, phase 2; DECISIONS 1105-1106, 1113):
// `files/activity/<recording>.guesses.json` holds every mark of "What happened" (happened.dart) with the numbers
// behind it, written whole each time the marks are worked out. Two things read it:
//   - the laptop's data book, for its `guesses.tsv` (each guess, the numbers, your answer where one was asked); no
//     model reads it yet: that needs about 30 answers of each kind;
//   - [restEstimates], for the question "Meditating or resting?": eyes closed and still for 3 minutes or more by day
//     is asked about once (at most one a day, the longest), through the quick checks' own rules. Never inside a
//     stretch you marked as meditation, a sound, sleep, a nap, the dream catcher or a check-in, nor where you tagged
//     the recording yourself: you already said what that was. No sound and no session is ever started from here.
// Plain Dart on plain files, fit for a background isolate.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:shared_labels/shared_labels.dart';

import '../archive/detail.dart' show readStages, readWalk;
import '../archive/items.dart' show ArchiveItem;
import '../archive/seen.dart';
import '../archive/tags.dart';
import '../auto/bedtime.dart';
import '../auto/store.dart' show AutoStore;
import '../cache/file_summaries.dart' show fileKey;
import '../spans/span.dart';
import '../walking/pass.dart' show walkFileFor;
import 'happened.dart';

const int guessesVersion = 1;
const String guessesFolder = 'activity';
const String guessesSuffix = '.guesses.json';

/// The version of the "eyes closed and still" rule behind the question (an estimate's `version`).
const String restVersion = 'rest-v1';

File guessesFileFor(Directory filesDir, String id) => File('${filesDir.path}/$guessesFolder/$id$guessesSuffix');

/// What a guesses file holds.
typedef Guesses = ({String recording, List<Mark> marks, List<Map<String, double?>> numbers});

double? _round(double? v) => v == null ? null : (v * 1000).round() / 1000;

/// Whole numbers as integers, as the laptop's tables write them.
Object? _plain(double? v) {
  final r = _round(v);
  return r == null ? null : (r == r.roundToDouble() ? r.toInt() : r);
}

/// Minutes from the usual bedtime to [t]'s clock time, between -720 and 719 (-598: 9 h 58 before bedtime).
int minutesFromBedtime(DateTime t, UsualNight usual) => ((t.hour * 60 + t.minute - usual.bedMin + 720) % 1440 + 1440) % 1440 - 720;

/// [t]'s clock time is inside the usual night (bedtime to waking).
bool inUsualNight(DateTime t, UsualNight usual) {
  final span = ((usual.wakeMin - usual.bedMin) % 1440 + 1440) % 1440;
  return ((t.hour * 60 + t.minute - usual.bedMin) % 1440 + 1440) % 1440 < span;
}

/// Writes the file of recording [id] whole (a temporary file, then renamed over it). [key]: what the marks were made
/// from ([guessesKey]), so they are made again only when that changed. Never throws.
void writeGuesses(
  Directory filesDir,
  String id,
  List<Mark> marks, {
  RecordingSeen? seen,
  UsualNight? usual,
  required String key,
  DateTime? made,
}) {
  final f = guessesFileFor(filesDir, id);
  try {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid.tmp');
    tmp.writeAsStringSync(
      jsonEncode({
        'version': guessesVersion,
        'recording': id,
        'made': isoLocal(made ?? DateTime.now()),
        'key': key,
        'marks': [
          for (final m in marks)
            {
              'what': m.what.wire,
              'start': isoLocal(m.start),
              'end': isoLocal(m.end),
              'sure': m.sure.word,
              if (usual != null) 'minutes_from_bedtime': minutesFromBedtime(m.start, usual),
              if (usual != null) 'in_bedtime_window': usual.contains(m.start),
              if (seen != null)
                for (final e in markNumbers(m, seen).entries) e.key: _plain(e.value),
            },
        ],
      }),
      flush: true,
    );
    tmp.renameSync(f.path);
  } on FileSystemException {
    // worked out again next time
  }
}

Map<String, Object?>? _read(File f) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    return j is Map<String, Object?> && j['version'] == guessesVersion ? j : null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// The key [f] was made for; null without a readable file.
String? guessesKeyOf(File f) => _read(f)?['key'] as String?;

/// A guesses file's marks and their numbers (in the same order); null when it cannot be read.
Guesses? readGuesses(File f) {
  final j = _read(f);
  final rec = j?['recording'], list = j?['marks'];
  if (rec is! String || list is! List) return null;
  final marks = <Mark>[];
  final numbers = <Map<String, double?>>[];
  for (final x in list) {
    if (x is! Map) continue;
    final what = What.of(x['what']);
    final s = DateTime.tryParse('${x['start']}')?.toLocal(), e = DateTime.tryParse('${x['end']}')?.toLocal();
    final sure = Sure.values.where((v) => v.word == x['sure']).firstOrNull;
    if (what == null || s == null || e == null || sure == null || !e.isAfter(s)) continue;
    marks.add(Mark(what, s, e, sure, ''));
    numbers.add({
      for (final k in x.entries)
        if (k.key is String && k.value is num) k.key as String: (k.value as num).toDouble(),
    });
  }
  return (recording: rec, marks: marks, numbers: numbers);
}

/// What a recording's marks are made from: the kept pass's own key, and the report's and the walk file's size and
/// modified time.
String guessesKey(Directory filesDir, String id, String seenKey, String? reportPath) {
  String of(File f) {
    final k = fileKey(f);
    return k == null ? '-' : '${k.size} ${k.modifiedUs}';
  }

  return [
    'v$guessesVersion',
    seenKey,
    'walk ${of(walkFileFor(filesDir, id))}',
    'report ${reportPath == null ? '-' : of(File('${filesDir.path}/$reportPath'))}',
  ].join('\n');
}

/// Works out and keeps the guesses of [item] when its detectors' pass is kept and the file is not already made from
/// the same pass, report and walk file. True when a file was written. A recording whose pass has not run yet (or whose
/// raw signal left the phone) is left as it is.
bool keepGuesses(Directory filesDir, ArchiveItem item, {UsualNight? usual, DateTime? now}) {
  final raw = item.rawFiles(filesDir);
  if (raw.isEmpty) return false;
  var kept = keptSeen(filesDir, item.id, raw);
  // a layout the pass cannot read gets the marks that need none (asleep, walking)
  if (kept == null && whyNotSeen(raw) != null) kept = (seen: null, why: null);
  if (kept == null) return false;
  final report = item.report;
  final key = guessesKey(filesDir, item.id, seenKeyOf(raw), report?.path);
  if (guessesKeyOf(guessesFileFor(filesDir, item.id)) == key) return false;
  final to = item.end.isAfter(item.start) ? item.end : item.start.add(const Duration(minutes: 1));
  final marks = happenedMarks(
    seen: kept.seen,
    stages: report == null ? null : readStages(File('${filesDir.path}/${report.path}')),
    walk: readWalk(filesDir, item.id),
    from: item.start,
    to: to,
  );
  writeGuesses(filesDir, item.id, marks, seen: kept.seen, usual: usual, key: key, made: now);
  return true;
}

/// The usual night as the watcher knows it (auto/bedtime.dart): set by hand, else from the recorded nights, else
/// 23:00 to 07:00.
UsualNight usualNightOf(Directory filesDir, DateTime now) => usualNight(
  recordedNights(Directory('${filesDir.path}/recordings'), now),
  AutoStore(Directory('${filesDir.path}/auto-start')).settings(),
);

/// [keepGuesses] in a background isolate, with the usual night read there.
Future<bool> keepGuessesInBackground(String filesPath, ArchiveItem item) => Isolate.run(() {
  final dir = Directory(filesPath);
  final now = DateTime.now();
  return keepGuesses(dir, item, usual: usualNightOf(dir, now), now: now);
}, debugName: 'activity-guesses');

/// The stretches you marked that already say what closed eyes were (span.dart kinds).
const Set<String> saidKinds = {'meditate', 'alpha_theta', 'sound', 'nap', 'sleep', 'dream_catcher', 'check_in'};

/// The day a stretch belongs to for "at most one a day": it runs from 04:00 to 04:00, as the quick checks' own day.
DateTime restDay(DateTime t) {
  final d = t.subtract(const Duration(hours: ConfirmRule.dayStartsHour));
  return DateTime(d.year, d.month, d.day);
}

/// One estimate per day for the question "Meditating or resting?", from the guesses files written in the last three
/// days: the longest "Eyes closed, resting" mark of each day that lies outside the usual night [usual], outside what
/// you marked ([saidKinds]) and outside your own tags. Its label is what the detector does know (`eyes_closed`); the
/// card offers the two words (shared_labels `isChoice`).
List<Estimate> restEstimates(Directory filesDir, {required UsualNight usual, DateTime? now}) {
  final at = now ?? DateTime.now();
  final dir = Directory('${filesDir.path}/$guessesFolder');
  if (!dir.existsSync()) return const [];
  final spansDir = Directory('${filesDir.path}/spans');
  final tags = TagStore(filesDir);
  final best = <DateTime, Estimate>{};
  final files = [
    for (final f in dir.listSync().whereType<File>())
      if (f.path.endsWith(guessesSuffix)) f,
  ]..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    try {
      if (at.difference(f.lastModifiedSync()) > const Duration(days: 3)) continue;
    } on FileSystemException {
      continue;
    }
    final g = readGuesses(f);
    if (g == null) continue;
    List<Span>? spans;
    List<ManualTag>? tagged;
    for (final (i, m) in g.marks.indexed) {
      if (m.what != What.resting) continue;
      final middle = m.start.add(m.length ~/ 2);
      if (inUsualNight(middle, usual)) continue;
      spans ??= readSpans(spansFileOf(spansDir, g.recording)).spans;
      if (spans.any((s) => saidKinds.contains(s.kind) && s.start.isBefore(m.end) && (s.end ?? at).isAfter(m.start))) continue;
      tagged ??= tags.tags(g.recording);
      if (tagged.any((t) => overlapShare(m.start, m.end, t.start, t.end) >= ConfirmRule.sameShare)) continue;
      final e = Estimate(
        detector: restDetector,
        version: restVersion,
        label: Labels.eyesClosed,
        start: m.start,
        end: m.end,
        recording: g.recording,
        confidence: g.numbers[i]['eyes_closed_share']?.clamp(0.0, 1.0),
        made: at,
      );
      final day = restDay(e.start), old = best[day];
      if (old == null || e.length > old.length) best[day] = e;
    }
  }
  return [for (final d in best.keys.toList()..sort()) best[d]!];
}

/// [found] without the rest estimates of a day that already has one in [known] (a question asked stands: a longer
/// stretch found later that day adds no second one).
List<Estimate> oneRestADay(List<Estimate> found, Iterable<Estimate> known) {
  final days = {
    for (final e in known)
      if (isChoice(e)) restDay(e.start): e.id,
  };
  return [
    for (final e in found)
      if (!isChoice(e) || (days[restDay(e.start)] ?? e.id) == e.id) e,
  ];
}
