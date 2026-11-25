// The headband battery guard (DECISIONS 605): the night comes first. BrainBit is rated "up to 10 hours" (one user
// reports less), so planning values are 10 % an hour while streaming, a 15 % margin, and 4 hours to charge. A night is
// never refused (a short night beats none), only warned about. A daytime session (work, other) may run while the
// headband keeps enough for tonight: with bedtime 4 hours away or more it may go down to the margin but ends 4 hours
// before bedtime (time to charge); later it may use only what is above tonight's need (night hours x 10 % + 15 %).
// A night is warned about only when the battery would not reach the usual wake-up (no margin there: it is a guess).
// Under 40 minutes is not worth starting. Without a battery reading it is allowed, and the log says so.
//
// Since DECISIONS 1010 the guard ONLY WARNS (`BatteryRule.onlyWarns`): the numbers above are an estimate nobody has
// measured on this headband, so they decide a "Charge the headband for tonight" notice and nothing else. No session
// is refused, none is given an end, no recording is stopped. Set the constant to false for the stopping rule above.
import 'bedtime.dart';
import 'store.dart';

abstract final class BatteryRule {
  /// true (the chosen default): the estimate only warns; false: it refuses and ends daytime sessions as written above.
  static const bool onlyWarns = true;

  static const double drainPctPerHour = 10, marginPct = 15;
  static const Duration chargeTime = Duration(hours: 4);
  static const Duration minSession = Duration(minutes: 40);
}

class BatteryVerdict {
  const BatteryVerdict({required this.allowed, this.limit, this.note, this.charge = false});
  final bool allowed;

  /// Too little is left for tonight: say "charge the headband" (once a day). With `onlyWarns` this is all it does.
  final bool charge;

  /// An allowed daytime session stops itself after this long; null: no limit (a night, or the battery not known).
  final Duration? limit;

  /// Plain words for the log, the question or the notice; null when there is nothing to say.
  final String? note;
}

/// What a whole usual night takes, with the margin (an 8-hour night: 95 %).
int nightNeedPct(UsualNight w) => (w.nightHours * BatteryRule.drainPctPerHour + BatteryRule.marginPct).ceil();

BatteryVerdict guardBattery(
  WearKind kind,
  int? batteryPct,
  DateTime now,
  UsualNight w, {
  bool onlyWarns = BatteryRule.onlyWarns,
}) {
  if (batteryPct == null) return const BatteryVerdict(allowed: true, note: 'headband battery not known');
  if (kind == WearKind.night) {
    final toWake = w.hoursToWake(now);
    if (batteryPct >= toWake * BatteryRule.drainPctPerHour) return const BatteryVerdict(allowed: true);
    final hours = (batteryPct / BatteryRule.drainPctPerHour).floor();
    return BatteryVerdict(
      allowed: true,
      note: 'headband at $batteryPct %: about $hours h, the night needs about ${toWake.round()} h',
    );
  }
  final toBed = w.hoursToBed(now);
  final chargeH = BatteryRule.chargeTime.inMinutes / 60;
  final double hours;
  if (toBed >= chargeH) {
    final byBattery = (batteryPct - BatteryRule.marginPct) / BatteryRule.drainPctPerHour;
    hours = byBattery < toBed - chargeH ? byBattery : toBed - chargeH;
  } else {
    hours = (batteryPct - nightNeedPct(w)) / BatteryRule.drainPctPerHour;
  }
  final limit = Duration(minutes: (hours * 60).floor());
  if (limit < BatteryRule.minSession) {
    return BatteryVerdict(allowed: onlyWarns, note: 'Charge the headband for tonight.', charge: true);
  }
  return BatteryVerdict(allowed: true, limit: onlyWarns ? null : limit);
}
