// The confirmation questions on disk (DECISIONS 860-869), in the app's private folder next to the recordings:
//   files/confirm/estimates.jsonl  one line per estimate a detector registered (estimate.dart)
//   files/confirm/answers.jsonl    one line per answer: {"estimate_id", "answer": "yes" | "no" | "skip" | "undo", "at",
//                                  "via": "card" | "notification" | "stop_sheet"}, or a few words you added:
//                                  {"estimate_id", "note", "at"}. Written by the app and by the notification's
//                                  buttons (ConfirmPrompts.kt), which work while the app is closed.
//   files/confirm/asks.jsonl       one line per batch that went out as a notification ({"at", "estimates": [ids],
//                                  "why": {id: word}}), and what the Android side did with it ({"at", "event", "batch"})
//   files/confirm/armed.json       the batch waiting for its moment (written whole)
//   files/confirm/settings.json    the switch, how many questions, how many batches a day, the quiet hours
//   files/confirm/labels.tsv       your Yes and No answers as truth labels (labels.dart), rebuilt whole
// Lines are only ever added. The first Yes, No or Not sure for an estimate stands; "undo" takes it back, as if never
// answered. Times are local with their UTC offset. Export data and Share on Wi-Fi take the folder with everything
// else, so answers given offline reach the laptop with the next copy. Plain Dart.
import 'dart:convert';
import 'dart:io';

import 'time.dart';
import 'estimate.dart';
import 'vocabulary.dart';

const String confirmFolder = 'confirm';

/// The confirm folder in the app's `files/`.
Directory confirmDirFor(Directory filesDir) => Directory('${filesDir.path}/$confirmFolder');

enum Answer {
  yes('Yes'),
  no('No'),
  skip('Not sure');

  const Answer(this.word);

  /// The button's word.
  final String word;

  static Answer? of(Object? s) => values.where((a) => a.name == s).firstOrNull;
}

/// Where an answer was given.
enum AnswerVia {
  card('card'),
  notification('notification'),
  stopSheet('stop_sheet');

  const AnswerVia(this.wire);
  final String wire;
}

/// An estimate's standing answer.
class Answered {
  const Answered(this.answer, this.at, this.via, {this.note});
  final Answer answer;
  final DateTime at;
  final String via;

  /// The few words you added, or null.
  final String? note;
}

class ConfirmSettings {
  const ConfirmSettings({this.on = true, this.perBatch = 4, this.perDay = 3, this.quietStartMin = 22 * 60, this.quietEndMin = 8 * 60});

  /// Off: no notification and no card; estimates are still kept.
  final bool on;

  /// Questions in a batch (3 to 5) and notification batches a day (1 to 6).
  final int perBatch, perDay;

  /// The quiet hours, minutes of the day; no notification between them (the card in the app is always there).
  final int quietStartMin, quietEndMin;

  ConfirmSettings copyWith({bool? on, int? perBatch, int? perDay, int? quietStartMin, int? quietEndMin}) => ConfirmSettings(
    on: on ?? this.on,
    perBatch: perBatch ?? this.perBatch,
    perDay: perDay ?? this.perDay,
    quietStartMin: quietStartMin ?? this.quietStartMin,
    quietEndMin: quietEndMin ?? this.quietEndMin,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'on': on,
    'per_batch': perBatch,
    'per_day': perDay,
    'quiet_start_min': quietStartMin,
    'quiet_end_min': quietEndMin,
  };

  static ConfirmSettings fromJson(Object? j) {
    if (j is! Map) return const ConfirmSettings();
    int within(Object? v, int lo, int hi, int or) => v is int && v >= lo && v <= hi ? v : or;
    const d = ConfirmSettings();
    return ConfirmSettings(
      on: j['on'] != false,
      perBatch: within(j['per_batch'], 3, 5, d.perBatch),
      perDay: within(j['per_day'], 1, 6, d.perDay),
      quietStartMin: within(j['quiet_start_min'], 0, 1439, d.quietStartMin),
      quietEndMin: within(j['quiet_end_min'], 0, 1439, d.quietEndMin),
    );
  }
}

/// The batch waiting for its notification.
class Armed {
  const Armed(this.at, this.ids, [this.why = const {}]);
  final DateTime at;
  final List<String> ids;
  final Map<String, String> why;
}

/// Everything the files say, read once.
class ConfirmState {
  ConfirmState({required this.estimates, required this.answers, required this.notified, required this.batches});

  /// By id, in the order registered.
  final Map<String, Estimate> estimates;

  /// The standing answer of each answered estimate.
  final Map<String, Answered> answers;

  /// Estimates that already went out in a notification batch: never in a second one.
  final Set<String> notified;

  /// When each notification batch went out, oldest first.
  final List<DateTime> batches;

  bool answered(String id) => answers.containsKey(id);

  /// Answers that are labels (Yes or No) for [label].
  int labelsOf(Label label) =>
      answers.entries.where((a) => a.value.answer != Answer.skip && estimates[a.key]?.label == label).length;
}

class ConfirmStore {
  ConfirmStore(this.filesDir);
  final Directory filesDir;

  Directory get dir => confirmDirFor(filesDir);
  File get estimatesFile => File('${dir.path}/estimates.jsonl');
  File get answersFile => File('${dir.path}/answers.jsonl');
  File get asksFile => File('${dir.path}/asks.jsonl');
  File get armedFile => File('${dir.path}/armed.json');
  File get settingsFile => File('${dir.path}/settings.json');
  File get labelsFile => File('${dir.path}/labels.tsv');

  static List<Object?> _lines(File f) {
    final out = <Object?>[];
    List<String> lines;
    try {
      lines = f.readAsLinesSync();
    } on FileSystemException {
      return out;
    }
    for (final l in lines) {
      if (l.trim().isEmpty) continue;
      try {
        out.add(jsonDecode(l));
      } on FormatException {
        // a line cut short by a full disk or a killed app: the others still count
      }
    }
    return out;
  }

  void _append(File f, Map<String, Object?> line) {
    dir.createSync(recursive: true);
    f.writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append, flush: true);
  }

  void _whole(File f, String text) {
    dir.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(f.path);
  }

  ConfirmState read() {
    final estimates = <String, Estimate>{};
    for (final j in _lines(estimatesFile)) {
      final e = Estimate.fromJson(j);
      if (e != null) estimates.putIfAbsent(e.id, () => e);
    }
    final answers = <String, Answered>{};
    final notes = <String, String>{};
    for (final j in _lines(answersFile)) {
      if (j is! Map || j['estimate_id'] is! String) continue;
      final id = j['estimate_id'] as String;
      if (j['note'] is String) {
        notes[id] = cleanNote(j['note'] as String);
        continue;
      }
      if (j['answer'] == 'undo') {
        answers.remove(id);
        notes.remove(id);
        continue;
      }
      final a = Answer.of(j['answer']);
      final at = DateTime.tryParse('${j['at']}')?.toLocal();
      if (a == null || at == null || answers.containsKey(id)) continue;
      answers[id] = Answered(a, at, j['via'] is String ? j['via'] as String : AnswerVia.card.wire);
    }
    for (final n in notes.entries) {
      final a = answers[n.key];
      if (a != null && n.value.isNotEmpty) answers[n.key] = Answered(a.answer, a.at, a.via, note: n.value);
    }
    final notified = <String>{};
    final batches = <DateTime>[];
    for (final j in _lines(asksFile)) {
      if (j is! Map || j['estimates'] is! List) continue;
      final at = DateTime.tryParse('${j['at']}')?.toLocal();
      if (at == null) continue;
      batches.add(at);
      notified.addAll((j['estimates'] as List).whereType<String>());
    }
    batches.sort();
    return ConfirmState(estimates: estimates, answers: answers, notified: notified, batches: batches);
  }

  /// A detector's one call: keeps [found] as estimates (those not kept before) and returns how many were new.
  int register(Iterable<Estimate> found) {
    final have = read().estimates;
    var n = 0;
    for (final e in found) {
      if (have.containsKey(e.id)) continue;
      have[e.id] = e;
      _append(estimatesFile, e.toJson());
      n++;
    }
    return n;
  }

  /// Your answer to an estimate's question. An estimate already answered keeps its first answer (undo it first).
  void answer(String estimateId, Answer a, {AnswerVia via = AnswerVia.card, DateTime? at}) =>
      _append(answersFile, {'estimate_id': estimateId, 'answer': a.name, 'at': isoLocal(at ?? DateTime.now()), 'via': via.wire});

  /// Takes the estimate's answer back: it is asked again.
  void undo(String estimateId, {DateTime? at}) =>
      _append(answersFile, {'estimate_id': estimateId, 'answer': 'undo', 'at': isoLocal(at ?? DateTime.now()), 'via': AnswerVia.card.wire});

  /// A few words of your own beside the answer.
  void note(String estimateId, String words, {DateTime? at}) =>
      _append(answersFile, {'estimate_id': estimateId, 'note': cleanNote(words), 'at': isoLocal(at ?? DateTime.now())});

  ConfirmSettings settings() {
    try {
      return ConfirmSettings.fromJson(jsonDecode(settingsFile.readAsStringSync()));
    } on FileSystemException {
      return const ConfirmSettings();
    } on FormatException {
      return const ConfirmSettings();
    }
  }

  void saveSettings(ConfirmSettings s) => _whole(settingsFile, jsonEncode(s.toJson()));

  Armed? armed() {
    try {
      final j = jsonDecode(armedFile.readAsStringSync());
      final at = j is Map ? DateTime.tryParse('${j['at']}')?.toLocal() : null;
      if (j is! Map || at == null || j['estimates'] is! List) return null;
      final why = j['why'];
      return Armed(at, (j['estimates'] as List).whereType<String>().toList(), {
        if (why is Map)
          for (final e in why.entries)
            if (e.value is String) '${e.key}': e.value as String,
      });
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void saveArmed(Armed? a) {
    if (a == null) {
      if (armedFile.existsSync()) armedFile.deleteSync();
      return;
    }
    _whole(armedFile, jsonEncode({'at': isoLocal(a.at), 'estimates': a.ids, 'why': a.why}));
  }

  /// The armed batch's moment has come: it went out (or the phone held it back), so its estimates never go into
  /// another notification. Returns true when there was one.
  bool settleArmed(DateTime now) {
    final a = armed();
    if (a == null || a.at.isAfter(now)) return false;
    _append(asksFile, {'at': isoLocal(a.at), 'via': 'notification', 'estimates': a.ids, 'why': a.why});
    saveArmed(null);
    return true;
  }

  void writeLabels(String tsv) => _whole(labelsFile, tsv);
}

/// A note as kept: one line, single spaces, at most 200 characters.
String cleanNote(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 200 ? t.substring(0, 200).trimRight() : t;
}
