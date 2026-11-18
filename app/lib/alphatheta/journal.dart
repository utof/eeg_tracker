// Alpha-theta's own notebook, `files/alpha-theta/journal.json` in the app's private folder next to the sessions
// (no backup takes it): the screening date, consent and stop plan, whether the mode is paused and why, the
// decision after 10 sessions, and per session the check-in, the after-session answers and the alertness check.
// The sessions themselves are `<stamp>.alphatheta.json` and `<stamp>.session.json` beside it (meditation/store.dart).
import 'dart:convert';
import 'dart:io';

import 'rules.dart';

class AtProfile {
  const AtProfile({
    this.screened,
    this.consented,
    this.contact = '',
    this.grounding = defaultGrounding,
    this.pausedWhy,
    this.pausedAt,
    this.decidedPast10,
  });

  /// When the screening was answered with no "yes" (null: not yet).
  final DateTime? screened;
  final DateTime? consented;

  /// The stop plan: someone to call, and what grounds you.
  final String contact;
  final String grounding;
  final String? pausedWhy;
  final DateTime? pausedAt;
  final DateTime? decidedPast10;

  bool get ready => screened != null && consented != null;
  bool get paused => pausedWhy != null;

  AtProfile copyWith({
    DateTime? screened,
    DateTime? consented,
    String? contact,
    String? grounding,
    String? pausedWhy,
    DateTime? pausedAt,
    bool resume = false,
    DateTime? decidedPast10,
  }) => AtProfile(
    screened: screened ?? this.screened,
    consented: consented ?? this.consented,
    contact: contact ?? this.contact,
    grounding: grounding ?? this.grounding,
    pausedWhy: resume ? null : pausedWhy ?? this.pausedWhy,
    pausedAt: resume ? null : pausedAt ?? this.pausedAt,
    decidedPast10: decidedPast10 ?? this.decidedPast10,
  );

  Map<String, Object?> toJson() => {
    'screened': screened?.toIso8601String(),
    'consented': consented?.toIso8601String(),
    'contact': contact,
    'grounding': grounding,
    'pausedWhy': pausedWhy,
    'pausedAt': pausedAt?.toIso8601String(),
    'decidedPast10': decidedPast10?.toIso8601String(),
  };

  static AtProfile fromJson(Object? j) {
    if (j is! Map) return const AtProfile();
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v) : null;
    String str(Object? v, String d) => v is String ? v : d;
    return AtProfile(
      screened: t(j['screened']),
      consented: t(j['consented']),
      contact: str(j['contact'], ''),
      grounding: str(j['grounding'], defaultGrounding),
      pausedWhy: j['pausedWhy'] is String ? j['pausedWhy'] as String : null,
      pausedAt: t(j['pausedAt']),
      decidedPast10: t(j['decidedPast10']),
    );
  }
}

/// One session's notes. [stem]: the saved session's files (null when it ended before there was anything to
/// keep). Reaction medians in ms.
class AtEntry {
  const AtEntry({
    required this.at,
    required this.before,
    this.beforeMs,
    this.stem,
    this.complete = false,
    this.after,
    this.alertMs,
    this.alertOk,
  });
  final DateTime at;
  final CheckIn before;
  final int? beforeMs;
  final String? stem;
  final bool complete;
  final AfterSession? after;
  final int? alertMs;
  final bool? alertOk;

  AtEntry copyWith({String? stem, bool? complete, AfterSession? after, int? alertMs, bool? alertOk}) => AtEntry(
    at: at,
    before: before,
    beforeMs: beforeMs,
    stem: stem ?? this.stem,
    complete: complete ?? this.complete,
    after: after ?? this.after,
    alertMs: alertMs ?? this.alertMs,
    alertOk: alertOk ?? this.alertOk,
  );

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'before': before.toJson(),
    'beforeMs': beforeMs,
    'stem': stem,
    'complete': complete,
    'after': after?.toJson(),
    'alertMs': alertMs,
    'alertOk': alertOk,
  };

  static AtEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}'), before = CheckIn.fromJson(j['before']);
    if (at == null || before == null) return null;
    int? ms(Object? v) => v is int && v > 0 ? v : null;
    return AtEntry(
      at: at,
      before: before,
      beforeMs: ms(j['beforeMs']),
      stem: j['stem'] is String ? j['stem'] as String : null,
      complete: j['complete'] == true,
      after: AfterSession.fromJson(j['after']),
      alertMs: ms(j['alertMs']),
      alertOk: j['alertOk'] is bool ? j['alertOk'] as bool : null,
    );
  }
}

class AtJournal {
  AtJournal(this.dir);
  final Directory dir;
  File get _file => File('${dir.path}/journal.json');

  AtProfile profile = const AtProfile();
  List<AtEntry> entries = [];

  /// Reads the notebook; a missing or damaged file starts empty (screening again: safer than trusting it).
  void load() {
    try {
      final j = jsonDecode(_file.readAsStringSync());
      if (j is! Map) return;
      profile = AtProfile.fromJson(j['profile']);
      final e = j['entries'];
      entries = [
        if (e is List)
          for (final x in e) ?AtEntry.fromJson(x),
      ];
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    }
  }

  void save() {
    dir.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert({
        'version': 1,
        'profile': profile.toJson(),
        'entries': [for (final e in entries) e.toJson()],
      }),
      flush: true,
    );
  }

  /// Sessions that ran to their full length (the length rule and the dose count these).
  int get done => entries.where((e) => e.complete).length;

  /// Your usual reaction time: the before-session tests.
  List<int> get usualMs => [for (final e in entries) ?e.beforeMs];

  List<AfterSession> get afters => [for (final e in entries) ?e.after];

  /// Pauses the mode when a rule says so; returns the reason (also kept in the profile). The after-session
  /// rules are checked once, when the answers come in ([afterSession]); the check-in's at each check-in. So a
  /// resume after talking to someone is not undone by the same old answer.
  String? applyPauseRules(DateTime now, {CheckIn? before, bool afterSession = false}) {
    final why = pauseReason(before: before, afters: afterSession ? afters : const []);
    if (why != null && !profile.paused) profile = profile.copyWith(pausedWhy: why, pausedAt: now);
    return why;
  }
}
