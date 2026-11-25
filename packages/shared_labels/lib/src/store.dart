// The confirmation questions on disk (DECISIONS 860-869), in the app's private folder next to the recordings:
//   files/confirm/estimates.jsonl  one line per estimate a detector registered (estimate.dart)
//   files/confirm/answers.jsonl    one line per answer: {"estimate_id", "answer", "at", "via": "card" | "notification"
//                                  | "stop_sheet"} and, when a card was shown, what the card was: "card" ("normal" |
//                                  "blind": the guess was not shown), "guess" and "confidence" (what the detector
//                                  said), "shown", "seconds" (from shown to answered), "age_min" (how old the stretch
//                                  was when shown). "answer" is one of
//                                    "yes"       it happened; "times_confirmed" false: the stretch's start and end are
//                                                still the detector's, NOT confirmed. true with "start" and "end": you
//                                                looked at the times ("Yes, but the times are off") and set them
//                                    "no"        it did not happen
//                                    "not_sure"  its own answer: no label, never asked again ("skip" reads the same)
//                                    "said"      a blind card: "said" (the label you picked) and / or "words" (yours)
//                                    "undo"      takes the standing answer back
//                                    "not_answered"  no answer came, with "why": "dismissed" (the notification was
//                                                swiped away), "expired" (asked, then too old), "never_seen",
//                                                "short_and_old" (dropped unasked). Never a Yes or a No;
//                                                a real answer given later stands
//                                  or a few words you added: {"estimate_id", "note", "at"}. Written by the app and by
//                                  the notification's buttons (ConfirmPrompts.kt), which work while the app is closed.
//   files/confirm/asks.jsonl       one line per batch that went out as a notification ({"at", "estimates": [ids],
//                                  "why": {id: word}, "blind": [ids made blind by rule]}), what the Android side did
//                                  with it ({"at", "event", "batch"}), and every back-off step with its reason
//                                  ({"at", "event": "backoff", "step", "reason", "until", "hour"})
//   files/confirm/armed.json       the batch waiting for its moment (written whole)
//   files/confirm/settings.json    the switch, how many questions, how many batches a day, the quiet hours
//   files/confirm/labels.tsv       your Yes and No answers as truth labels (labels.dart), rebuilt whole
//   files/confirm/estimates.tsv    every estimate with its answer (labels.dart), rebuilt whole
// Lines are only ever added. The first Yes, No, Not sure or blind-card answer for an estimate stands; "undo" takes it back, as if never
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
  yes('Yes', 'yes'),
  no('No', 'no'),

  /// "Not sure": an answer of its own. Not a label, never asked again, kept out of whatever trains or scores a
  /// detector (asking.md).
  skip('Not sure', 'not_sure'),

  /// A blind card's answer: you said what you were doing without seeing the guess ([Answered.said], [Answered.words]).
  said('Said', 'said');

  const Answer(this.word, this.wire);

  /// The word shown after "Saved:", and the word the files hold.
  final String word, wire;

  /// The three a card with the guess shown offers, in their fixed order.
  static const List<Answer> buttons = [yes, no, skip];

  static Answer? of(Object? s) => values.where((a) => a.wire == s || a.name == s).firstOrNull;
}

/// What a card showed: the guess ("The headband thinks you slept"), or not (a blind card, asking.md).
enum CardKind {
  normal,
  blind;

  static CardKind? of(Object? s) => values.where((k) => k.name == s).firstOrNull;
}

/// Why no answer came. Stored apart from every answer: silence is never a Yes or a No.
enum WhyNot {
  /// The notification was swiped away; the question stays on the app's card.
  dismissed('dismissed'),

  /// It went out in a notification, nobody answered, and it is now too old to ask.
  expired('expired'),

  /// It never went out and is now too old to ask.
  neverSeen('never_seen'),

  /// Dropped unasked: a short stretch that is hours old (nobody remembers it).
  shortAndOld('short_and_old');

  const WhyNot(this.wire);
  final String wire;

  /// The question is closed: not on the card, in no notification (a recording's own stop sheet may still ask).
  bool get closes => this != dismissed;

  static WhyNot? of(Object? s) => values.where((w) => w.wire == s).firstOrNull;
}

/// The last "no answer came" of an estimate.
class NotAnswered {
  const NotAnswered(this.why, this.at, this.via);
  final WhyNot why;
  final DateTime at;
  final String via;
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
  const Answered(
    this.answer,
    this.at,
    this.via, {
    this.note,
    this.card,
    this.said,
    this.words,
    this.start,
    this.end,
    this.shown,
    this.seconds,
    this.ageMin,
    this.guess,
    this.guessConfidence,
  });
  final Answer answer;
  final DateTime at;
  final String via;

  /// The few words you added, or null.
  final String? note;

  /// The card that was shown; null when none was (a stop-sheet chip settled it).
  final CardKind? card;

  /// A blind card: the label you picked (null: only words of your own), and your own words.
  final Label? said;
  final String? words;

  /// "Yes, but the times are off": the start and end you set. Null after a plain Yes, whose times are the detector's.
  final DateTime? start, end;

  /// When the card (or the notification's question) came on screen, the seconds from then to the answer, and how
  /// many minutes old the stretch was then.
  final DateTime? shown;
  final double? seconds;
  final int? ageMin;

  /// What the detector had said when you answered, and how sure it was.
  final String? guess;
  final double? guessConfidence;

  /// You looked at the times and set them. False after a plain Yes: "it happened", not "these times are right".
  bool get timesConfirmed => answer == Answer.yes && start != null && end != null;

  /// Whether a blind card's answer names what the detector thought ([guessed]); null when it is not such an answer or
  /// your words name no label.
  bool? agrees(Label guessed) => answer != Answer.said || said == null ? null : said!.sameAs(guessed);

  Answered withNote(String? note) => Answered(
    answer,
    at,
    via,
    note: note,
    card: card,
    said: said,
    words: words,
    start: start,
    end: end,
    shown: shown,
    seconds: seconds,
    ageMin: ageMin,
    guess: guess,
    guessConfidence: guessConfidence,
  );
}

class ConfirmSettings {
  const ConfirmSettings({
    this.on = true,
    this.perBatch = 4,
    this.perDay = 2,
    this.quietStartMin = 22 * 60,
    this.quietEndMin = 8 * 60,
    this.quietFromSleep = true,
  });

  /// Off: no notification and no card; estimates are still kept.
  final bool on;

  /// Questions in a batch (2 to 4) and notification batches a day (1 or 2): planning values (asking.md).
  final int perBatch, perDay;

  /// The fixed quiet hours, minutes of the day; no notification between them (the card in the app is always there).
  /// Used when [quietFromSleep] is off, and while the app has too few of your nights to know when you sleep.
  final int quietStartMin, quietEndMin;

  /// The quiet hours follow your real sleep: from your usual bedtime until half an hour after you woke (queue.dart
  /// `sleepHabit`).
  final bool quietFromSleep;

  ConfirmSettings copyWith({bool? on, int? perBatch, int? perDay, int? quietStartMin, int? quietEndMin, bool? quietFromSleep}) => ConfirmSettings(
    on: on ?? this.on,
    perBatch: perBatch ?? this.perBatch,
    perDay: perDay ?? this.perDay,
    quietStartMin: quietStartMin ?? this.quietStartMin,
    quietEndMin: quietEndMin ?? this.quietEndMin,
    quietFromSleep: quietFromSleep ?? this.quietFromSleep,
  );

  Map<String, Object?> toJson() => {
    'version': 2,
    'on': on,
    'per_batch': perBatch,
    'per_day': perDay,
    'quiet_start_min': quietStartMin,
    'quiet_end_min': quietEndMin,
    'quiet_from_sleep': quietFromSleep,
  };

  static ConfirmSettings fromJson(Object? j) {
    if (j is! Map) return const ConfirmSettings();
    int within(Object? v, int lo, int hi, int or) => v is int && v >= lo && v <= hi ? v : or;
    const d = ConfirmSettings();
    return ConfirmSettings(
      on: j['on'] != false,
      perBatch: within(j['per_batch'], 2, 4, d.perBatch),
      perDay: within(j['per_day'], 1, 2, d.perDay),
      quietStartMin: within(j['quiet_start_min'], 0, 1439, d.quietStartMin),
      quietEndMin: within(j['quiet_end_min'], 0, 1439, d.quietEndMin),
      quietFromSleep: j['quiet_from_sleep'] != false,
    );
  }
}

/// The batch waiting for its notification.
class Armed {
  const Armed(this.at, this.ids, [this.why = const {}, this.blind = const []]);
  final DateTime at;
  final List<String> ids;
  final Map<String, String> why;

  /// The cards of this batch made blind by rule (backoff.dart: a run of fast Yes answers).
  final List<String> blind;
}

/// A notification batch that went out.
class Push {
  const Push(this.at, this.ids, [this.blind = const []]);
  final DateTime at;
  final List<String> ids, blind;
}

/// A line of asks.jsonl that is not a batch: what the phone did with one (`shown`, `held`, `late`, `skipped`,
/// `dismissed`; [batch] is the batch's moment), or a back-off step (`backoff`: [step], [until], [hour], [reason]).
class AskEvent {
  const AskEvent(this.at, this.event, {this.batch, this.step, this.until, this.hour, this.reason});
  final DateTime at;
  final String event;
  final DateTime? batch, until;
  final String? step, reason;
  final int? hour;
}

/// Everything the files say, read once.
class ConfirmState {
  ConfirmState({
    required this.estimates,
    required this.answers,
    required this.notified,
    required this.batches,
    this.unanswered = const {},
    this.pushes = const [],
    this.events = const [],
    this.forcedBlind = const {},
  });

  /// By id, in the order registered.
  final Map<String, Estimate> estimates;

  /// The standing answer of each answered estimate.
  final Map<String, Answered> answers;

  /// Estimates that already went out in a notification batch: never in a second one.
  final Set<String> notified;

  /// When each notification batch went out, oldest first.
  final List<DateTime> batches;

  /// The notification batches that went out, oldest first ([batches] are their moments), and everything else the
  /// asks file holds.
  final List<Push> pushes;
  final List<AskEvent> events;

  /// Cards made blind by rule (in a batch that went out or the one waiting), beside the 1 in 5 drawn by id.
  final Set<String> forcedBlind;

  /// The last "no answer came" of each estimate that has one. An estimate can be here and in [answers]: the answer
  /// counts.
  final Map<String, NotAnswered> unanswered;

  bool answered(String id) => answers.containsKey(id);

  /// Not answered and closed: too old, or a short stretch that is hours old (store.dart [WhyNot.closes]).
  bool closed(String id) => !answered(id) && (unanswered[id]?.why.closes ?? false);

  /// Answers that are labels (Yes or No) for [label].
  int labelsOf(Label label) => answers.entries
      .where((a) => (a.value.answer == Answer.yes || a.value.answer == Answer.no) && estimates[a.key]?.label == label)
      .length;
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
  File get estimatesTable => File('${dir.path}/estimates.tsv');

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
    final unanswered = <String, NotAnswered>{};
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
      final at = DateTime.tryParse('${j['at']}')?.toLocal();
      final via = j['via'] is String ? j['via'] as String : AnswerVia.card.wire;
      if (j['answer'] == notAnsweredWire) {
        final why = WhyNot.of(j['why']);
        if (why != null && at != null) unanswered[id] = NotAnswered(why, at, via);
        continue;
      }
      final a = Answer.of(j['answer']);
      if (a == null || at == null || answers.containsKey(id)) continue;
      final read = _answered(a, at, via, j);
      if (read != null) answers[id] = read;
    }
    for (final n in notes.entries) {
      final a = answers[n.key];
      if (a != null && n.value.isNotEmpty) answers[n.key] = a.withNote(n.value);
    }
    final notified = <String>{};
    final pushes = <Push>[];
    final events = <AskEvent>[];
    final forced = <String>{...?armed()?.blind};
    for (final j in _lines(asksFile)) {
      if (j is! Map) continue;
      final at = DateTime.tryParse('${j['at']}')?.toLocal();
      if (at == null) continue;
      if (j['estimates'] is List) {
        final blind = j['blind'] is List ? (j['blind'] as List).whereType<String>().toList() : const <String>[];
        pushes.add(Push(at, (j['estimates'] as List).whereType<String>().toList(), blind));
        notified.addAll(pushes.last.ids);
        forced.addAll(blind);
      } else if (j['event'] is String) {
        events.add(
          AskEvent(
            at,
            j['event'] as String,
            batch: DateTime.tryParse('${j['batch']}')?.toLocal(),
            step: j['step'] is String ? j['step'] as String : null,
            until: DateTime.tryParse('${j['until']}')?.toLocal(),
            hour: j['hour'] is int ? j['hour'] as int : null,
            reason: j['reason'] is String ? j['reason'] as String : null,
          ),
        );
      }
    }
    pushes.sort((a, b) => a.at.compareTo(b.at));
    return ConfirmState(
      estimates: estimates,
      answers: answers,
      notified: notified,
      batches: [for (final p in pushes) p.at],
      unanswered: unanswered,
      pushes: pushes,
      events: events,
      forcedBlind: forced,
    );
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

  /// One answer line as the files hold it; null for a line that says nothing (a blind answer with neither a label
  /// nor words).
  static Answered? _answered(Answer a, DateTime at, String via, Map<Object?, Object?> j) {
    final said = Label.of(j['said']);
    final words = j['words'] is String ? cleanNote(j['words'] as String) : '';
    if (a == Answer.said && said == null && words.isEmpty) return null;
    final s = DateTime.tryParse('${j['start']}')?.toLocal(), e = DateTime.tryParse('${j['end']}')?.toLocal();
    final set = a == Answer.yes && j['times_confirmed'] == true && s != null && e != null && e.isAfter(s);
    final sec = j['seconds'], age = j['age_min'], c = j['confidence'];
    return Answered(
      a,
      at,
      via,
      card: CardKind.of(j['card']),
      said: a == Answer.said ? said : null,
      words: a == Answer.said && words.isNotEmpty ? words : null,
      start: set ? s : null,
      end: set ? e : null,
      shown: DateTime.tryParse('${j['shown']}')?.toLocal(),
      seconds: sec is num && sec >= 0 ? sec.toDouble() : null,
      ageMin: age is num && age >= 0 ? age.round() : null,
      guess: j['guess'] is String ? j['guess'] as String : null,
      guessConfidence: c is num && c >= 0 && c <= 1 ? c.toDouble() : null,
    );
  }

  /// Your answer to an estimate's question. An estimate already answered keeps its first answer (undo it first).
  ///
  /// [card] and [shown]: the card that asked and when it came on screen (the line then also keeps the seconds you
  /// took). [estimate]: what was asked about (the line keeps the guess, how sure the detector was and how old the
  /// stretch was). [start] and [end], with a Yes: the times you set yourself ("Yes, but the times are off"); without
  /// them a Yes says only that it happened. [said] and [words]: a blind card's answer ([Answer.said]).
  void answer(
    String estimateId,
    Answer a, {
    AnswerVia via = AnswerVia.card,
    DateTime? at,
    CardKind? card,
    DateTime? shown,
    Estimate? estimate,
    DateTime? start,
    DateTime? end,
    Label? said,
    String? words,
  }) {
    final now = at ?? DateTime.now();
    final own = words == null ? '' : cleanNote(words);
    final set = a == Answer.yes && start != null && end != null && end.isAfter(start);
    _append(answersFile, {
      'estimate_id': estimateId,
      'answer': a.wire,
      'at': isoLocal(now),
      'via': via.wire,
      'card': ?card?.name,
      if (estimate != null) 'guess': estimate.label.id,
      if (estimate != null) 'confidence': estimate.confidence,
      if (shown != null) 'shown': isoLocal(shown),
      if (shown != null) 'seconds': secondsBetween(shown, now),
      if (estimate != null) 'age_min': ageMinutes(estimate, shown ?? now),
      if (a == Answer.yes) 'times_confirmed': set,
      if (set) 'start': isoLocal(start),
      if (set) 'end': isoLocal(end),
      if (a == Answer.said && said != null) 'said': said.id,
      if (a == Answer.said && own.isNotEmpty) 'words': own,
    });
  }

  /// No answer came for [estimateId], and [why]. Kept apart from the answers: never a Yes or a No.
  void notAnswered(String estimateId, WhyNot why, {AnswerVia via = AnswerVia.card, DateTime? at}) => _append(answersFile, {
    'estimate_id': estimateId,
    'answer': notAnsweredWire,
    'why': why.wire,
    'at': isoLocal(at ?? DateTime.now()),
    'via': via.wire,
  });

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
      return Armed(
        at,
        (j['estimates'] as List).whereType<String>().toList(),
        {
          if (why is Map)
            for (final e in why.entries)
              if (e.value is String) '${e.key}': e.value as String,
        },
        j['blind'] is List ? (j['blind'] as List).whereType<String>().toList() : const [],
      );
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
    _whole(armedFile, jsonEncode({'at': isoLocal(a.at), 'estimates': a.ids, 'why': a.why, if (a.blind.isNotEmpty) 'blind': a.blind}));
  }

  /// The armed batch's moment has come: it went out (or the phone held it back), so its estimates never go into
  /// another notification. Returns true when there was one.
  bool settleArmed(DateTime now) {
    final a = armed();
    if (a == null || a.at.isAfter(now)) return false;
    _append(asksFile, {'at': isoLocal(a.at), 'via': 'notification', 'estimates': a.ids, 'why': a.why, if (a.blind.isNotEmpty) 'blind': a.blind});
    saveArmed(null);
    return true;
  }

  /// A back-off step and its reason, kept with the batches (backoff.dart): `pause`, `one_a_day`, `normal`,
  /// `skip_hour`, `blind_batch`.
  void logBackoff(String step, String reason, {required DateTime at, DateTime? until, int? hour}) => _append(asksFile, {
    'at': isoLocal(at),
    'event': 'backoff',
    'step': step,
    'reason': reason,
    if (until != null) 'until': isoLocal(until),
    'hour': ?hour,
  });

  void writeLabels(String tsv) => _whole(labelsFile, tsv);

  void writeEstimates(String tsv) => _whole(estimatesTable, tsv);
}

/// The word of a "no answer came" line.
const String notAnsweredWire = 'not_answered';

/// Seconds from [shown] to [answered], to a tenth; 0 when the clock went back.
double secondsBetween(DateTime shown, DateTime answered) {
  final ms = answered.difference(shown).inMilliseconds;
  return ms <= 0 ? 0 : (ms / 100).round() / 10;
}

/// How many whole minutes old [e]'s stretch was at [at]; 0 while it was not over.
int ageMinutes(Estimate e, DateTime at) {
  final m = at.difference(e.end).inMinutes;
  return m < 0 ? 0 : m;
}

/// A note as kept: one line, single spaces, at most 200 characters.
String cleanNote(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 200 ? t.substring(0, 200).trimRight() : t;
}
