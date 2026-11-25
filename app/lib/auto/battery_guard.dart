// The headband battery guard (DECISIONS 605, 946): the night comes first. The drain per hour of streaming is the one
// battery rule's (headband/battery_estimate.dart `BandBatteryRule`: 11 %, measured on the owner's headband), the
// charge it counts with is the same estimate the headband card shows; a 15 % margin and 4 hours to charge are planning
// values. A night is never refused (a short night beats none), only warned about. A daytime session (work, other) may
// run while the headband keeps enough for tonight: with bedtime 4 hours away or more it may go down to the margin but
// ends 4 hours before bedtime (time to charge); later it may use only what is above tonight's need (night hours x the
// drain + 15 %, at most a full charge).
// A night is warned about only when the battery would not reach the usual wake-up (no margin there: it is a guess).
// Under 40 minutes is not worth starting. Without a battery reading it is allowed, and the log says so.
//
// Since DECISIONS 1010 the guard ONLY WARNS (`BatteryRule.onlyWarns`): the numbers above are an estimate nobody has
// measured on this headband, so they decide a "Charge the headband for tonight" notice and nothing else. No session
// is refused, none is given an end, no recording is stopped. Set the constant to false for the stopping rule above.
import '../headband/battery_estimate.dart' show BandBatteryRule;
import 'bedtime.dart';
import 'store.dart';

abstract final class BatteryRule {
  /// true (the chosen default): the estimate only warns; false: it refuses and ends daytime sessions as written above.
  static const bool onlyWarns = true;

  static const double marginPct = 15;
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

/// What a whole usual night takes, with the margin, at most a full charge (an 8-hour night: 8 x 11 + 15 is over 100,
/// so 100 %).
int nightNeedPct(UsualNight w) {
  final need = (w.nightHours * BandBatteryRule.drainPctPerHour + BatteryRule.marginPct).ceil();
  return need > 100 ? 100 : need;
}

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
    if (batteryPct >= toWake * BandBatteryRule.drainPctPerHour) return const BatteryVerdict(allowed: true);
    final hours = (batteryPct / BandBatteryRule.drainPctPerHour).floor();
    return BatteryVerdict(
      allowed: true,
      note: 'headband at $batteryPct %: about $hours h, the night needs about ${toWake.round()} h',
    );
  }
  final toBed = w.hoursToBed(now);
  final chargeH = BatteryRule.chargeTime.inMinutes / 60;
  final double hours;
  if (toBed >= chargeH) {
    final byBattery = (batteryPct - BatteryRule.marginPct) / BandBatteryRule.drainPctPerHour;
    hours = byBattery < toBed - chargeH ? byBattery : toBed - chargeH;
  } else {
    hours = (batteryPct - nightNeedPct(w)) / BandBatteryRule.drainPctPerHour;
  }
  final limit = Duration(minutes: (hours * 60).floor());
  if (limit < BatteryRule.minSession) {
    return BatteryVerdict(allowed: onlyWarns, note: 'Charge the headband for tonight.', charge: true);
  }
  return BatteryVerdict(allowed: true, limit: onlyWarns ? null : limit);
}
