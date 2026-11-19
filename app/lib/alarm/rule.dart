// The smart alarm's rule (DECISIONS 230-232), pure and clock-free: the live stages and the time each was handed out
// in, "wake now, and why" out. The Python reference is analysis/smart_alarm.py; both read the hand-worked cases in
// test/fixtures/smart_alarm_cases.json.
//
// You set "wake me by" a time and a window that ends there. The live sleep model (sleep/live_stager.dart: AnySleep
// every 30 s on the last 60 minutes, the stage of the epoch 2 minutes behind) runs from an hour before the window.
// Inside the window it wakes you at the first epoch read as light sleep (N1, N2), dream sleep (R) or awake (W), but
// never within 10 minutes after an epoch read as deep sleep (N3): waking out of deep sleep is what leaves you
// groggy, and the live reading is a little behind and sometimes calls deep sleep light. Lost epochs never wake you.
// If no such moment comes, the window's end wakes you whatever the stage: that is a plain system alarm set at Start,
// so it rings even when the app or the model is gone.
import '../sleep/live_stager.dart' show LiveStage;
import '../sleep/periods.dart' show gapStage;

abstract final class AlarmRule {
  /// Windows on offer (minutes before the wake-by time) and the one picked first.
  static const List<int> windowsMin = [15, 20, 30, 45];
  static const int defaultWindowMin = 30;

  /// The live sleep model starts this long before the window (its window is 60 minutes; battery: not all night).
  static const int scoreBeforeMin = 60;

  /// No wake from an epoch that starts less than this long after the end of an epoch read as deep sleep.
  static const int deepGuardMin = 10;

  /// [deepGuardMin] in epochs: an epoch e may wake you when e > lastDeep + [deepGuardEpochs].
  static const int deepGuardEpochs = deepGuardMin * 2;
}

/// Why the alarm woke you.
enum AlarmWhy {
  /// Light sleep (N1 or N2) inside the window.
  light,

  /// Dream sleep (REM) inside the window.
  dream,

  /// Read as awake inside the window.
  awake,

  /// No such moment came: the window's end.
  windowEnd,
}

/// The words in files and reports (`window end` for [AlarmWhy.windowEnd]).
String alarmWhyName(AlarmWhy w) => w == AlarmWhy.windowEnd ? 'window end' : w.name;

AlarmWhy? alarmWhyFromName(String? s) => AlarmWhy.values.where((w) => alarmWhyName(w) == s).firstOrNull;

/// The alarm set for one night: wake by [endMs] (unix ms), at the earliest [windowMin] minutes before.
class AlarmPlan {
  AlarmPlan({required this.endMs, required this.windowMin}) {
    if (windowMin <= 0 || windowMin > 120) throw ArgumentError.value(windowMin, 'windowMin', 'must be 1-120 minutes');
  }

  final int endMs;
  final int windowMin;

  int get startMs => endMs - windowMin * 60000;

  /// When the live sleep model starts.
  int get scoreFromMs => startMs - AlarmRule.scoreBeforeMin * 60000;

  Map<String, Object?> toJson() => {'endMs': endMs, 'windowMin': windowMin};

  /// Null for anything that is not a plan.
  static AlarmPlan? fromJson(Object? j) {
    if (j is! Map || j['endMs'] is! int || j['windowMin'] is! int) return null;
    try {
      return AlarmPlan(endMs: j['endMs'] as int, windowMin: j['windowMin'] as int);
    } on ArgumentError {
      return null;
    }
  }

  /// The next [hour]:[minute] after [now] as the wake-by time (today or tomorrow, local time).
  static AlarmPlan next({required DateTime now, required int hour, required int minute, required int windowMin}) {
    var end = DateTime(now.year, now.month, now.day, hour, minute);
    if (!end.isAfter(now)) end = DateTime(now.year, now.month, now.day + 1, hour, minute);
    return AlarmPlan(endMs: end.millisecondsSinceEpoch, windowMin: windowMin);
  }
}

/// A wake decided by the rule: when, why, and for a stage wake the epoch read (its start, unix ms) and its stage.
class AlarmWake {
  const AlarmWake({required this.atMs, required this.why, this.epoch, this.epochStartMs, this.stage, this.confidence, this.behind});
  final int atMs;
  final AlarmWhy why;
  final int? epoch;
  final int? epochStartMs;
  final String? stage;
  final double? confidence;
  final int? behind;
}

class AlarmRules {
  AlarmRules({required this.startMs, required this.endMs});
  AlarmRules.of(AlarmPlan plan) : this(startMs: plan.startMs, endMs: plan.endMs);

  /// The window, unix ms: [startMs] inclusive, [endMs] exclusive.
  final int startMs, endMs;

  /// The newest epoch read as deep sleep, once seen.
  int? lastDeep;

  /// Set once the rule has decided.
  AlarmWake? wake;

  /// Feeds the next live stage (epoch order), handed out at [nowMs]; [epochStartMs] is that epoch's start. The wake
  /// when this one starts it, else null.
  AlarmWake? stage(LiveStage s, {required int nowMs, int? epochStartMs}) {
    if (wake != null) return null;
    if (s.stage == 'N3') {
      lastDeep = s.epoch;
      return null;
    }
    if (s.stage == gapStage || nowMs < startMs || nowMs >= endMs) return null;
    final d = lastDeep;
    if (d != null && s.epoch - d <= AlarmRule.deepGuardEpochs) return null;
    final why = switch (s.stage) {
      'N1' || 'N2' => AlarmWhy.light,
      'R' => AlarmWhy.dream,
      'W' => AlarmWhy.awake,
      _ => null,
    };
    if (why == null) return null;
    return wake = AlarmWake(
      atMs: nowMs,
      why: why,
      epoch: s.epoch,
      epochStartMs: epochStartMs,
      stage: s.stage,
      confidence: s.confidence,
      behind: s.behind,
    );
  }

  /// The window's end, once reached without a wake.
  AlarmWake? due(int nowMs) {
    if (wake != null || nowMs < endMs) return null;
    return wake = AlarmWake(atMs: endMs, why: AlarmWhy.windowEnd);
  }
}
