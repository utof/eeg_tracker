// Walking minutes and steps per day (Trends' day, 04:00 to 04:00) from the kept walk files (pass.dart; DECISIONS
// 800-809), the same rules as scripts/day_summary.py on the laptop:
//   - every clock minute counts once, from the walk file of the longest recording that has it;
//   - minutes inside a night the owner said someone else wore the headband for are left out ("Was this you?");
//   - walking minutes: the minutes' walking seconds (the phone's 60 where it counted 60 steps or more);
//   - steps: the phone's where it counted, else the headband's estimate; while the check against the phone
//     (detector.dart walkCheck, over every paired minute so far) has failed, the headband's estimate is left out and
//     only the phone's steps count;
//   - a day gets a value only when it has a walking minute (walking) or a step (steps): a day of sleep is no
//     "0 minutes walked".
import 'dart:io';

import '../trends/days.dart' show dayKey;
import 'detector.dart';
import 'pass.dart';

class WalkDays {
  const WalkDays({required this.minutes, required this.steps, required this.phoneSteps, required this.headbandSteps, required this.check});

  /// Day -> walking minutes, steps counted, and of them the phone's and the headband's.
  final Map<String, double> minutes, steps, phoneSteps, headbandSteps;

  /// The headband's pace against the phone's step counter, over every paired minute so far.
  final WalkCheck check;

  bool get headbandHidden => check.status == CheckStatus.failed;

  /// Where a day's steps came from, in words: "your phone", "the headband", "your phone and the headband".
  String sourceOf(String day) {
    final p = (phoneSteps[day] ?? 0) > 0, h = (headbandSteps[day] ?? 0) > 0 && !headbandHidden;
    return p && h ? 'your phone and the headband' : (p ? 'your phone' : (h ? 'the headband' : 'none'));
  }
}

/// The minutes of [results] once each (the longest recording's first), outside [notMine] spans.
List<WalkMinute> uniqueMinutes(Iterable<WalkResult> results, {List<(DateTime, DateTime)> notMine = const []}) {
  final ordered = [...results]..sort((a, b) {
    final c = b.windows.compareTo(a.windows);
    return c != 0 ? c : a.recording.compareTo(b.recording);
  });
  final taken = <int, WalkMinute>{};
  bool mine(int t) {
    final at = DateTime.fromMillisecondsSinceEpoch(t * 1000);
    return !notMine.any((s) => !at.isBefore(s.$1) && at.isBefore(s.$2));
  }

  for (final r in ordered) {
    for (final m in r.minutes) {
      if (!taken.containsKey(m.t) && mine(m.t)) taken[m.t] = m;
    }
  }
  return [for (final k in taken.keys.toList()..sort()) taken[k]!];
}

WalkDays walkDays(Iterable<WalkResult> results, {List<(DateTime, DateTime)> notMine = const []}) {
  final rows = uniqueMinutes(results, notMine: notMine);
  final check = walkCheck(rows);
  final hidden = check.status == CheckStatus.failed;
  final walking = <String, double>{}, phone = <String, double>{}, headband = <String, double>{};
  for (final m in rows) {
    final day = dayKey(DateTime.fromMillisecondsSinceEpoch(m.t * 1000));
    walking[day] = (walking[day] ?? 0) + m.walkingS / 60;
    if (m.source == 'phone') phone[day] = (phone[day] ?? 0) + m.steps;
    if (m.source == 'headband') headband[day] = (headband[day] ?? 0) + m.steps;
  }
  final steps = <String, double>{};
  for (final d in {...phone.keys, ...headband.keys}) {
    final s = (phone[d] ?? 0) + (hidden ? 0 : (headband[d] ?? 0));
    if (s > 0) steps[d] = s;
  }
  return WalkDays(
    minutes: {
      for (final e in walking.entries)
        if (e.value >= 1) e.key: e.value,
    },
    steps: steps,
    phoneSteps: phone,
    headbandSteps: headband,
    check: check,
  );
}

/// [walkDays] of the phone's own walk files (`files/walking/`, beside [recordingsDir]), the nights someone else wore
/// the headband for ([notMine]) left out.
WalkDays readWalkDays(String recordingsDir, {List<(DateTime, DateTime)> notMine = const []}) {
  final files = Directory(recordingsDir).parent;
  return walkDays([for (final k in keptWalks(files).values) ?k.walk], notMine: notMine);
}
