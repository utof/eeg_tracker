// The work session's break hints (ROADMAP row 35, DECISIONS 443-445): the laptop's break-hint rules
// (docs/break-hints.md, scripts/break_hints.py) on the time the headband is worn, plus a hint when drowsiness stays up.
//
// - Worn time counts while the headband sends a usable signal and you are not on a break. The headband off (or no
//   usable signal) under 5 minutes only pauses the count; 5 minutes or more is a break from the moment it went off.
//   "On a break" / "Back" taps make a break too; one of 5 minutes or more resets the stretch, a shorter one pauses.
// - A hint after 60 worn minutes in a stretch; each of today's hints that no break followed adds 15 minutes (counted
//   once it was snoozed or its 30-minute window closed).
// - A hint when the drowsiness level read getting drowsy or drowsy in 8 of the last 12 epochs (6 minutes), or the
//   eyes were closed in 6 of them.
// - At most 4 hints a day (a day runs 04:00 to 04:00, earlier sessions included), at least 45 minutes apart, none in
//   the quiet hours 23:00-08:00. Snooze brings one hint back 20 minutes later (the spacing does not apply; a break
//   cancels it). A break of 5 minutes or more that starts within 30 minutes of a hint marks it "break taken".
// - Each break keeps the drowsiness median just before it and over the first 5 minutes after it.
// Pure: no clock of its own, no files.
import 'dart:math' as math;

import 'drowsiness.dart';

abstract final class BreakRule {
  static const double firstMin = 60, backoffMin = 15, gapMin = 45, snoozeMin = 20, breakMin = 5, takenWindowMin = 30;
  static const int maxPerDay = 4, dayStartHour = 4, quietFrom = 23, quietTo = 8;

  /// Drowsiness: getting drowsy or more in 8 of the last 12 epochs; eyes closed in 6 of them.
  static const int recentEpochs = 12, drowsyEpochs = 8, closedEpochs = 6;

  /// After a break: the drowsiness median once this many epochs have passed (the level's own 5-minute window).
  static const int afterEpochs = 10, afterMaxEpochs = 20;
}

enum HintReason { stretch, drowsy, eyesClosed, snooze }

enum HintAnswer { onBreak, snoozed, notNow }

enum BreakSource { tapped, headbandOff }

/// The 04:00-to-04:00 day a moment belongs to.
DateTime workDay(DateTime t) {
  final s = t.subtract(const Duration(hours: BreakRule.dayStartHour));
  return DateTime(s.year, s.month, s.day);
}

bool inQuietHours(DateTime t) => t.hour >= BreakRule.quietFrom || t.hour < BreakRule.quietTo;

class WorkHint {
  WorkHint({
    required this.at,
    required this.reason,
    required this.activeMin,
    required this.thresholdMin,
    required this.level,
    this.answer,
    this.answeredAt,
    this.taken = false,
  });

  final DateTime at;
  final HintReason reason;

  /// Worn minutes of the stretch, and the threshold then.
  final double activeMin, thresholdMin;
  final DrowsyLevel level;
  HintAnswer? answer;
  DateTime? answeredAt;

  /// A break of 5 minutes or more started within 30 minutes of it.
  bool taken;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'reason': reason.name,
    'active_min': (activeMin * 10).round() / 10,
    'threshold_min': thresholdMin,
    'level': levelKey(level),
    'answer': answer?.name,
    'answered_at': answeredAt?.toIso8601String(),
    'taken': taken,
  };

  static WorkHint fromJson(Map<String, Object?> j) => WorkHint(
    at: DateTime.parse(j['at']! as String),
    reason: HintReason.values.firstWhere((r) => r.name == j['reason'], orElse: () => HintReason.stretch),
    activeMin: (j['active_min'] as num?)?.toDouble() ?? 0,
    thresholdMin: (j['threshold_min'] as num?)?.toDouble() ?? BreakRule.firstMin,
    level: levelOf(j['level'] as String?),
    answer: HintAnswer.values.where((a) => a.name == j['answer']).firstOrNull,
    answeredAt: j['answered_at'] is String ? DateTime.tryParse(j['answered_at']! as String) : null,
    taken: j['taken'] == true,
  );
}

class WorkBreak {
  WorkBreak({required this.start, required this.source, this.before, this.beforeLevel});
  final DateTime start;
  final BreakSource source;
  DateTime? end;

  /// The drowsiness median just before, and over the first 5 minutes after (null: not known).
  final double? before;
  final DrowsyLevel? beforeLevel;
  double? after;
  DrowsyLevel? afterLevel;
  int _epochsAfter = 0;

  double get minutes => end == null ? 0 : end!.difference(start).inMilliseconds / 60000;

  /// Long enough to reset the stretch.
  bool get counts => minutes >= BreakRule.breakMin;

  Map<String, Object?> toJson() => {
    'start': start.toIso8601String(),
    'end': end?.toIso8601String(),
    'source': source.name,
    'before': before == null ? null : (before! * 1000).round() / 1000,
    'before_level': beforeLevel == null ? null : levelKey(beforeLevel!),
    'after': after == null ? null : (after! * 1000).round() / 1000,
    'after_level': afterLevel == null ? null : levelKey(afterLevel!),
  };
}

/// One "how sharp do you feel?" tap (the sharp-hours scale, 1 Foggy to 5 Very sharp).
class WorkRating {
  const WorkRating(this.at, this.value, this.hint);
  final DateTime at;
  final int value;

  /// Index of the hint it answered, or null when tapped on its own.
  final int? hint;

  Map<String, Object?> toJson() => {'at': at.toIso8601String(), 'value': value, 'hint': hint};
}

class BreakPlanner {
  /// [earlier]: hints of earlier sessions (any days; only today's count).
  BreakPlanner({List<WorkHint> earlier = const []}) : _earlier = List.of(earlier);

  final List<WorkHint> _earlier;
  final List<WorkHint> hints = [];
  final List<WorkBreak> breaks = [];
  final List<WorkRating> ratings = [];

  /// Worn seconds in all, and in the stretch since the last break that counted.
  double activeS = 0, stretchS = 0;
  DateTime? _last;
  DateTime? _offSince;
  DateTime? snoozeDue;
  WorkBreak? _open;
  final List<DrowsyLevel> _levels = [];
  final List<bool> _closed = [];
  double? _window;

  bool get onBreak => _open != null;
  WorkBreak? get currentBreak => _open;
  double get stretchMin => stretchS / 60;

  /// The headband has sent no usable signal since then (null: it has).
  DateTime? get offSince => _offSince;

  List<WorkHint> _today(DateTime now) => [
    for (final h in [..._earlier, ...hints])
      if (workDay(h.at) == workDay(now)) h,
  ]..sort((a, b) => a.at.compareTo(b.at));

  int hintsToday(DateTime now) => _today(now).length;

  /// Each 30 s epoch of the drowsiness level.
  void epoch(DrowsyLevel level, {required bool eyesClosed, double? window}) {
    _levels.add(level);
    _closed.add(eyesClosed);
    if (_levels.length > BreakRule.recentEpochs) {
      _levels.removeAt(0);
      _closed.removeAt(0);
    }
    if (window != null || level == DrowsyLevel.unknown) _window = window;
    for (final b in breaks) {
      if (b.end == null || b.after != null || b._epochsAfter >= BreakRule.afterMaxEpochs) continue;
      b._epochsAfter++;
      if (b._epochsAfter >= BreakRule.afterEpochs && window != null) {
        b.after = window;
        b.afterLevel = level;
      }
    }
  }

  /// The minutes of a stretch before a hint now: 60, plus 15 for each of today's hints no break followed.
  double thresholdMin(DateTime now) {
    var n = 0;
    for (final h in _today(now)) {
      if (h.taken) continue;
      final closed = now.difference(h.at).inMilliseconds / 60000 > BreakRule.takenWindowMin;
      if (closed || h.answer == HintAnswer.snoozed) n++;
    }
    return BreakRule.firstMin + BreakRule.backoffMin * n;
  }

  /// Call every few seconds. [worn]: the headband sends a usable signal now. Returns a hint to show, if any.
  WorkHint? tick(DateTime now, {required bool worn}) {
    final last = _last;
    final dt = last == null ? 0.0 : math.max(0, now.difference(last).inMilliseconds / 1000).toDouble();
    _last = now;
    final open = _open;
    if (open != null) {
      if (open.source == BreakSource.headbandOff && worn) _close(now);
      return null;
    }
    if (!worn) {
      final off = _offSince ??= now;
      if (now.difference(off).inMilliseconds / 60000 >= BreakRule.breakMin) {
        _offSince = null;
        _begin(off, BreakSource.headbandOff);
      }
      return null;
    }
    final wasOff = _offSince != null;
    _offSince = null;
    if (!wasOff) {
      activeS += dt;
      stretchS += dt;
    }
    return _maybeHint(now);
  }

  WorkHint? _maybeHint(DateTime now) {
    if (inQuietHours(now)) return null;
    final today = _today(now);
    if (today.length >= BreakRule.maxPerDay) return null;
    final due = snoozeDue;
    if (due != null && !now.isBefore(due)) {
      snoozeDue = null;
      return _show(now, HintReason.snooze);
    }
    final last = today.isEmpty ? null : today.last;
    if (last != null && now.difference(last.at).inMilliseconds / 60000 < BreakRule.gapMin) return null;
    final up = _levels.where((l) => l == DrowsyLevel.gettingDrowsy || l == DrowsyLevel.drowsy).length;
    if (up >= BreakRule.drowsyEpochs) return _show(now, HintReason.drowsy);
    if (_closed.where((c) => c).length >= BreakRule.closedEpochs) return _show(now, HintReason.eyesClosed);
    final thr = thresholdMin(now);
    if (stretchMin >= thr) return _show(now, HintReason.stretch, thr);
    return null;
  }

  WorkHint _show(DateTime now, HintReason reason, [double? thr]) {
    final level = _levels.isEmpty ? DrowsyLevel.unknown : _levels.last;
    final h = WorkHint(at: now, reason: reason, activeMin: stretchMin, thresholdMin: thr ?? thresholdMin(now), level: level);
    hints.add(h);
    // a drowsy reason is not repeated by the same epochs: the next one needs fresh ones
    if (reason == HintReason.drowsy || reason == HintReason.eyesClosed) {
      _levels.clear();
      _closed.clear();
    }
    return h;
  }

  /// The answer to the newest hint: On a break starts one, Snooze brings it back in 20 minutes.
  void answer(HintAnswer a, DateTime now) {
    if (hints.isEmpty) return;
    final h = hints.last
      ..answer = a
      ..answeredAt = now;
    switch (a) {
      case HintAnswer.onBreak:
        startBreak(now);
      case HintAnswer.snoozed:
        snoozeDue = now.add(Duration(seconds: (BreakRule.snoozeMin * 60).round()));
      case HintAnswer.notNow:
        break;
    }
    assert(identical(h, hints.last));
  }

  /// "On a break" tapped (or a hint answered so).
  void startBreak(DateTime now, {BreakSource source = BreakSource.tapped}) {
    if (_open != null) return;
    _begin(now, source);
    _last = now;
  }

  void _begin(DateTime at, BreakSource source) {
    snoozeDue = null;
    final b = WorkBreak(start: at, source: source, before: _window, beforeLevel: _levels.isEmpty ? null : _levels.last);
    breaks.add(b);
    _open = b;
  }

  /// "Back" tapped (a headband-off break ends by itself when the signal comes back).
  void endBreak(DateTime now) {
    if (_open == null) return;
    _close(now);
    _last = now;
  }

  void _close(DateTime now) {
    final b = _open!..end = now;
    _open = null;
    _offSince = null;
    if (!b.counts) return;
    stretchS = 0;
    for (final h in hints) {
      final since = b.start.difference(h.at).inMilliseconds / 60000;
      if (since >= 0 && since <= BreakRule.takenWindowMin) h.taken = true;
    }
  }

  /// A "how sharp do you feel?" tap: it answers the newest hint when that came within 30 minutes.
  void rate(int value, DateTime now) {
    if (value < 1 || value > 5) throw ArgumentError.value(value, 'value', '1 to 5');
    int? hint;
    if (hints.isNotEmpty && now.difference(hints.last.at).inMilliseconds / 60000 <= BreakRule.takenWindowMin) {
      hint = hints.length - 1;
    }
    ratings.add(WorkRating(now, value, hint));
  }

  Map<String, Object?> toJson() => {
    'active_min': (activeS / 6).round() / 10,
    'hints': [for (final h in hints) h.toJson()],
    'breaks': [for (final b in breaks) b.toJson()],
    'ratings': [for (final r in ratings) r.toJson()],
  };
}
