// The work session's break hints (ROADMAP row 35, DECISIONS 443-445): the laptop's break-hint rules
// (docs/break-hints.md, scripts/break_hints.py) on the time the headband is worn, plus a hint when drowsiness stays up.
//
// - Worn time counts while the headband sends a usable signal and you are not on a break (on a monotonic clock when
//   the caller gives one, so a change of the phone's clock is not worn time). The headband off (or no usable signal)
//   under 5 minutes only pauses the count; 5 minutes or more is a break from the moment it went off.
//   "On a break" / "Back" taps make a break too; one of 5 minutes or more resets the stretch, a shorter one pauses.
//   A tapped break whose Back was forgotten ends by itself: once the headband was off for a minute or more during it
//   and has then been worn 2 minutes (it ends when it came back), or after 20 minutes' worth of readable half
//   minutes with the headband on.
// - A hint after 60 worn minutes in a stretch; each of today's hints that no break followed adds 15 minutes (counted
//   once it was snoozed or its 30-minute window closed).
// - A hint when the drowsiness level read getting drowsy or drowsy in 8 of the last 12 epochs (6 minutes), or the
//   eyes were closed in 6 of them; only epochs since the last break count (none from before or during one).
// - At most 4 hints a day (a day runs 04:00 to 04:00, earlier sessions included), at least 45 minutes apart, none in
//   the quiet hours 23:00-08:00. Snooze brings one hint back 20 minutes later (the spacing does not apply; a break of
//   5 minutes or more cancels it). A break of 5 minutes or more that starts within 30 minutes of a hint marks it
//   "break taken". A hint is answered only within those 30 minutes.
// - Each break keeps the drowsiness median just before it (for the headband off: before it went off) and over the
//   first 5 minutes after it.
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

  /// A tapped break ends by itself (Back forgotten): the headband off at least [autoOffMin] during it, then worn
  /// [autoWornMin] (the break ends when it came back); or [autoReadEpochs] readable half minutes (20 minutes) of it.
  static const double autoOffMin = 1, autoWornMin = 2;
  static const int autoReadEpochs = 40;
}

enum HintReason { stretch, drowsy, eyesClosed, snooze }

enum HintAnswer { onBreak, snoozed, notNow }

enum BreakSource { tapped, headbandOff }

/// How a break ended: Back tapped, by itself after a forgotten Back, the signal back after a headband-off break, Stop.
enum BreakEnd { back, auto, signal, stop }

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
  BreakEnd? endSource;

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
    'end_source': endSource?.name,
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
  /// [earlier]: hints of earlier sessions (any days; only today's count). [carriedStretchMin]: the stretch of a session
  /// that ended under 5 minutes before this one began (a restart is not a break).
  BreakPlanner({List<WorkHint> earlier = const [], double carriedStretchMin = 0})
    : _earlier = List.of(earlier),
      stretchS = carriedStretchMin * 60;

  final List<WorkHint> _earlier;
  final List<WorkHint> hints = [];
  final List<WorkBreak> breaks = [];
  final List<WorkRating> ratings = [];

  /// Worn seconds in all, and in the stretch since the last break that counted.
  double activeS = 0;
  double stretchS;
  DateTime? _last;
  Duration? _lastMono;
  DateTime? _offSince;
  DateTime? snoozeDue;
  WorkBreak? _open;

  /// The epochs since the last break (none from before or during one), for the drowsiness hints.
  final List<DrowsyLevel> _levels = [];
  final List<bool> _closed = [];
  double? _window;
  DrowsyLevel? _lastLevel;

  /// The level when the headband went off (a headband-off break's "before").
  double? _offWindow;
  DrowsyLevel? _offLevel;

  /// A tapped break: since when the headband is off now, whether it was off long enough, since when it is back on,
  /// and its readable epochs.
  DateTime? _breakOffSince, _breakBackAt;
  bool _breakWasOff = false;
  int _breakRead = 0;

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
    if (_open == null) {
      _levels.add(level);
      _closed.add(eyesClosed);
      if (_levels.length > BreakRule.recentEpochs) {
        _levels.removeAt(0);
        _closed.removeAt(0);
      }
    } else if (_open!.source == BreakSource.tapped && level != DrowsyLevel.unknown && !eyesClosed) {
      _breakRead++;
    }
    if (window != null || level == DrowsyLevel.unknown) _window = window;
    _lastLevel = level;
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

  /// Call every few seconds. [worn]: the headband sends a usable signal now. [mono]: a monotonic clock's reading
  /// (only differences count), for the worn time; without it the wall clock [now] is used. Returns a hint to show.
  WorkHint? tick(DateTime now, {required bool worn, Duration? mono}) {
    final last = _last, lastMono = _lastMono;
    final step = mono != null && lastMono != null ? (mono - lastMono).inMilliseconds : last == null ? 0 : now.difference(last).inMilliseconds;
    final dt = math.max(0, step / 1000).toDouble();
    _last = now;
    _lastMono = mono;
    final open = _open;
    if (open != null) {
      if (open.source == BreakSource.headbandOff) {
        if (worn) _close(now, BreakEnd.signal);
      } else {
        _forgotten(now, worn, dt);
      }
      return null;
    }
    if (!worn) {
      if (_offSince == null) {
        _offWindow = _window;
        _offLevel = _lastLevel;
      }
      final off = _offSince ??= now;
      if (now.difference(off).inMilliseconds / 60000 >= BreakRule.breakMin) {
        _offSince = null;
        _begin(off, BreakSource.headbandOff, before: _offWindow, beforeLevel: _offLevel);
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

  /// A tapped break whose Back was forgotten: it ends by itself once the headband, off for a minute or more during
  /// it, has been worn again for 2 minutes (then at the moment it came back, and those minutes are worn time), or
  /// after 20 minutes' worth of readable half minutes of it.
  void _forgotten(DateTime now, bool worn, double dt) {
    if (!worn) {
      _breakBackAt = null;
      final off = _breakOffSince ??= now;
      if (now.difference(off).inMilliseconds / 60000 >= BreakRule.autoOffMin) _breakWasOff = true;
      return;
    }
    _breakOffSince = null;
    if (_breakRead >= BreakRule.autoReadEpochs) return _close(now, BreakEnd.auto);
    if (!_breakWasOff) return;
    final back = _breakBackAt ??= now;
    final wornS = now.difference(back).inMilliseconds / 1000;
    if (wornS < BreakRule.autoWornMin * 60) return;
    _close(back, BreakEnd.auto);
    activeS += wornS;
    stretchS += wornS;
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

  /// The answer to the newest hint, within its 30 minutes (a later one answers nothing): On a break starts one
  /// (also without a hint to answer), Snooze brings it back in 20 minutes.
  void answer(HintAnswer a, DateTime now) {
    final h = hints.lastOrNull;
    final fresh = h != null && now.difference(h.at).inMilliseconds / 60000 <= BreakRule.takenWindowMin;
    if (fresh) {
      h
        ..answer = a
        ..answeredAt = now;
    }
    switch (a) {
      case HintAnswer.onBreak:
        startBreak(now);
      case HintAnswer.snoozed:
        if (fresh) snoozeDue = now.add(Duration(seconds: (BreakRule.snoozeMin * 60).round()));
      case HintAnswer.notNow:
        break;
    }
  }

  /// "On a break" tapped (or a hint answered so).
  void startBreak(DateTime now, {BreakSource source = BreakSource.tapped}) {
    if (_open != null) return;
    _begin(now, source);
    _last = now;
  }

  void _begin(DateTime at, BreakSource source, {double? before, DrowsyLevel? beforeLevel}) {
    final tapped = source == BreakSource.tapped;
    final b = WorkBreak(start: at, source: source, before: tapped ? _window : before, beforeLevel: tapped ? _lastLevel : beforeLevel);
    breaks.add(b);
    _open = b;
    _forget();
    _breakOffSince = null;
    _breakBackAt = null;
    _breakWasOff = false;
    _breakRead = 0;
  }

  /// The drowsiness hints count only epochs since the last break.
  void _forget() {
    _levels.clear();
    _closed.clear();
  }

  /// "Back" tapped (a headband-off break ends by itself when the signal comes back). [how]: Stop ends it too.
  void endBreak(DateTime now, {BreakEnd how = BreakEnd.back}) {
    if (_open == null) return;
    _close(now, how);
    _last = now;
  }

  void _close(DateTime now, BreakEnd how) {
    final b = _open!
      ..end = now
      ..endSource = how;
    _open = null;
    _offSince = null;
    _forget();
    if (!b.counts) return;
    snoozeDue = null;
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
    'stretch_min': (stretchS / 6).round() / 10,
    'hints': [for (final h in hints) h.toJson()],
    'breaks': [for (final b in breaks) b.toJson()],
    'ratings': [for (final r in ratings) r.toJson()],
  };
}
