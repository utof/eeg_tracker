// "Was this you?" over the app's own files (DECISIONS rows 370-379): the phone's scored nights (their report's
// `wearer_signal`) and check-ins (their result's `back`) become the recordings check.dart judges, the owner's answers
// are kept in those same files (`wearer`: `answer`, `at`), and the words the sleep report and the check-in's result
// show. Worked out again whenever one of those pages opens; while the check is on, each recording's first verdict
// goes into the log once. Never a medical or identity claim: it says the signal looks unlike your usual and asks.
import 'dart:math' as math;

import '../morning/store.dart';
import '../sleep/report.dart';
import 'check.dart';
import 'store.dart';

export 'store.dart' show WearerStore, wearerDirFor;

String _key(String kind, String id) => '$kind:$id';

/// A night (with a `wearer_signal`: scored since the check exists) or a check-in as the check sees it.
List<WearerRecording> wearerRecordings(List<SleepReport> nights, List<MorningRecord> mornings) => [
  for (final r in nights)
    if (reportSignal(r.json['wearer_signal']) case (final s, final why) when s != null || why != null)
      WearerRecording(id: r.nightOf, kind: kindNight, time: r.dataStart, day: r.nightOf, signal: s, why: why, answer: r.wearerAnswer),
  for (final m in mornings)
    if (checkInSignal(m.json) case (final s, final why))
      WearerRecording(id: m.id, kind: kindCheckIn, time: m.start, day: m.day, signal: s, why: why, answer: m.wearerAnswer),
];

/// Every recording's verdict, the answers and signals by `kind:id`, and how far each kind has learned.
class WearerResult {
  const WearerResult({
    required this.on,
    this.verdicts = const {},
    this.answers = const {},
    this.signals = const {},
    this.counts = const {},
  });

  final bool on;
  final Map<String, WearerVerdict> verdicts;
  final Map<String, String> answers;
  final Map<String, WearerSignal> signals;

  /// Accepted recordings and their different days per kind, after all of them.
  final Map<String, ({int have, int days})> counts;

  WearerVerdict? of(String kind, String id) => verdicts[_key(kind, id)];

  ({int have, int days}) learning(String kind) => counts[kind] ?? (have: 0, days: 0);

  /// The kind has learned enough to speak.
  bool ready(String kind) => learning(kind).have >= enrolN && learning(kind).days >= enrolDays;
}

/// Judges the app's nights and check-ins; while the check is on, logs each recording's first verdict once. A log that
/// cannot be written never stops the page (the verdicts are worked out again next time).
WearerResult refreshWearer(String recordingsDir, DateTime now) {
  final store = WearerStore(wearerDirFor(recordingsDir));
  if (!store.on) return const WearerResult(on: false);
  final recs = wearerRecordings(
    NightReportStore(nightsDirFor(recordingsDir)).all(),
    MorningStore(morningsDirFor(recordingsDir)).list(),
  );
  final byKey = {for (final r in recs) _key(r.kind, r.id): r};
  final verdicts = <String, WearerVerdict>{};
  final joined = <String, ({int have, Set<String> days})>{};
  for (final v in judgeWearer(recs)) {
    final k = _key(v.kind, v.id), r = byKey[k]!;
    verdicts[k] = v;
    final j = joined[v.kind] ?? (have: 0, days: <String>{});
    joined[v.kind] = joinsProfile(v.state, r.answer) ? (have: j.have + 1, days: {...j.days, r.day}) : j;
  }
  final result = WearerResult(
    on: true,
    verdicts: verdicts,
    answers: {
      for (final r in recs)
        if (r.answer != null) _key(r.kind, r.id): r.answer!,
    },
    signals: {
      for (final r in recs)
        if (r.signal != null) _key(r.kind, r.id): r.signal!,
    },
    counts: {for (final e in joined.entries) e.key: (have: e.value.have, days: e.value.days.length)},
  );
  try {
    final done = store.logged();
    store.append([
      for (final v in verdicts.values)
        if (!done.contains(_key(v.kind, v.id)))
          {
            'judged': isoLocal(now),
            ...v.toJson(),
            'signal': result.signals[_key(v.kind, v.id)],
            'answer': result.answers[_key(v.kind, v.id)],
          },
    ]);
  } on Object {
    // the log is a record for later; the page goes on without it
  }
  return result;
}

/// The owner's answer for one recording ([answer] `me`, `someone else`, or null to take it back): kept in the night's
/// report or the check-in's result (nothing else in the file changes) and noted in the events. Throws when the
/// recording's file is not there.
void answerWearer(String recordingsDir, String kind, String id, String? answer, DateTime now) {
  Map<String, Object?> tagged(Map<String, Object?> json) {
    final out = Map<String, Object?>.of(json);
    if (answer == null) {
      out.remove('wearer');
    } else {
      out['wearer'] = {'answer': answer, 'at': isoLocal(now)};
    }
    return out;
  }

  if (kind == kindNight) {
    final store = NightReportStore(nightsDirFor(recordingsDir));
    final r = store.read(id) ?? (throw StateError('no report for the night of $id'));
    store.write(tagged(r.json).cast<String, dynamic>());
  } else {
    final store = MorningStore(morningsDirFor(recordingsDir));
    final m = store.list().where((m) => m.id == id).firstOrNull ?? (throw StateError('no check-in $id'));
    store.save(tagged(m.json), m.start);
  }
  WearerStore(wearerDirFor(recordingsDir)).event(now, 'answer', {'kind': kind, 'id': id, 'answer': answer});
}

// ---------------------------------------------------------------- the words

/// The line on the sleep report or the check-in's result: [text] (with [question] the two answers under it, the only
/// state in ink), [detail] and [note] in muted words, and which small action it offers.
class WearerLine {
  const WearerLine({
    required this.text,
    this.detail,
    this.note,
    this.question = false,
    this.canSaySomeoneElse = false,
    this.canUndo = false,
  });
  final String text;
  final String? detail, note;
  final bool question, canSaySomeoneElse, canUndo;
}

String _unit(String kind, {bool plural = false}) =>
    kind == kindNight ? (plural ? 'nights' : 'night') : (plural ? 'check-ins' : 'check-in');

String _whyWords(String kind, String? why) => switch (why) {
  whyLightsOff => 'Not checked: Lights off was not tapped.',
  whyPeak => 'Not checked: no clear alpha rhythm with eyes closed.',
  whyClean when kind == kindNight => 'Not checked: too little clean awake signal after Lights off.',
  whyClean => 'Not checked: too little clean signal with eyes closed.',
  _ => 'Not checked.',
};

String _power(double log10) {
  final v = math.pow(10, log10).toDouble();
  return v < 1 ? v.toStringAsFixed(1) : '${v.round()}';
}

/// The number furthest from the profile, in plain words.
String? _biggest(WearerVerdict v, WearerSignal? s) {
  final f = v.biggest, z = f == null ? null : v.z[f], u = f == null ? null : v.usual[f];
  if (f == null || z == null || u == null || s == null || s[f] == null) return null;
  final x = s[f]!;
  return switch (f) {
    'iaf' => 'Its alpha rhythm was ${z > 0 ? 'faster' : 'slower'} than yours usually is: '
        '${x.toStringAsFixed(1)} Hz, usually about ${u.toStringAsFixed(1)}.',
    'alpha' => 'Its alpha was ${z > 0 ? 'stronger' : 'weaker'} than yours usually is: ${_power(x)} µV², usually '
        'about ${_power(u)}.',
    _ => 'Its background signal was ${z > 0 ? 'flatter' : 'steeper'} than yours usually is.',
  };
}

/// The words for one recording, or null when the check is off or has nothing to say about it.
WearerLine? wearerLine(WearerResult r, String kind, String id) {
  if (!r.on) return null;
  final v = r.of(kind, id);
  if (v == null) return null;
  final answer = r.answers[_key(kind, id)];
  if (answer == answerSomeoneElse) {
    return WearerLine(
      text: 'Someone else wore the headband: this ${_unit(kind)} is left out of your trends, the unusual card and '
          'experiments.',
      canUndo: true,
    );
  }
  if (answer == answerMe) {
    return const WearerLine(text: 'You said this was you. It now counts toward what your brain looks like.', canUndo: true);
  }
  return switch (v.state) {
    WearerState.notLikeYou => WearerLine(
      text: "This doesn't look like your usual brain signal. Was it you?",
      detail: _biggest(v, r.signals[_key(kind, id)]),
      note: 'Loose contact, a moved headband, alcohol or a short night can change it too.',
      question: true,
    ),
    WearerState.likeYou => const WearerLine(text: 'Looks like your usual brain signal.', canSaySomeoneElse: true),
    WearerState.learning => WearerLine(
      text: v.have < enrolN
          ? 'Learning what your brain looks like: ${v.have} of $enrolN ${_unit(kind, plural: true)}.'
          : 'Learning what your brain looks like: ${v.have} ${_unit(kind, plural: true)} so far, on ${v.days} of the '
              '$enrolDays different days it needs.',
      canSaySomeoneElse: true,
    ),
    WearerState.unchecked => WearerLine(text: _whyWords(kind, v.why), canSaySomeoneElse: true),
  };
}

/// The Settings line: off, or how far each kind has learned.
String wearerStatus(WearerResult r) {
  if (!r.on) return 'Off. Nothing is checked; earlier answers still keep those recordings out of your trends.';
  String part(String kind) {
    final c = r.learning(kind);
    if (r.ready(kind)) return '${_unit(kind, plural: true)}: checked';
    return '${_unit(kind, plural: true)}: learning, ${c.have} of $enrolN';
  }

  final s = '${part(kindCheckIn)}; ${part(kindNight)}.';
  return 'On. ${s[0].toUpperCase()}${s.substring(1)}';
}
