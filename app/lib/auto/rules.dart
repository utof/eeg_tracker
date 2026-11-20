// What you are doing when the headband is found on (DECISIONS 603): rules on the phone's context, no model and no EEG.
// The laptop decides "working" (its tray's ActivityWatch rule), the clock and the phone decide "night", anything else
// is "other". The headband's detectors (eyes closed, drowsy, asleep, jaw, movement, off) only confirm after a start,
// in the session they run in; nothing here reads electrodes, so it suits any headband or helmet.
import 'bedtime.dart';
import 'store.dart';

/// The laptop's latest word on a work session (its tray; laptop.dart).
class LaptopWork {
  const LaptopWork({required this.working, required this.at, this.meeting});
  final bool working;
  final DateTime at;

  /// The laptop's session is in a meeting (a call app holds the microphone, or a meeting window is in front; DECISIONS
  /// 660-666); null: the word did not say (an older tray).
  final bool? meeting;
}

/// What the phone knows without any permission, read when the check runs.
class PhoneContext {
  const PhoneContext({
    required this.now,
    this.charging = false,
    this.screenOn = true,
    this.screenOffSince,
    this.dnd = false,
    this.laptop,
    this.nextAlarm,
  });

  final DateTime now;
  final bool charging, screenOn;

  /// When the screen last went off; null when not known (the app was not running then).
  final DateTime? screenOffSince;

  /// Do Not Disturb is on.
  final bool dnd;
  final LaptopWork? laptop;

  /// The phone's next alarm clock, if any (logged; not a rule yet).
  final DateTime? nextAlarm;
}

/// Planning values of the rules (labelled assumptions, DECISIONS 603).
abstract final class KindRule {
  /// "Evening" from this hour (the bedtime window covers the hours after midnight).
  static const int eveningFromHour = 20;

  /// The screen off at least this long, while charging, in the evening.
  static const Duration screenOffFor = Duration(minutes: 2);

  /// A laptop signal older than this no longer counts.
  static const Duration laptopFresh = Duration(minutes: 15);
}

class KindGuess {
  const KindGuess(this.kind, this.reasons);
  final WearKind kind;

  /// Short plain words, for the log and the question.
  final List<String> reasons;
}

KindGuess guessKind(PhoneContext c, UsualNight w) {
  final laptop = c.laptop;
  if (laptop != null && laptop.working && c.now.difference(laptop.at) <= KindRule.laptopFresh) {
    return const KindGuess(WearKind.work, ['laptop: work session']);
  }
  if (w.contains(c.now)) return KindGuess(WearKind.night, ['bedtime window (${w.windowText})']);
  final evening = c.now.hour >= KindRule.eveningFromHour;
  if (evening && c.charging && !c.screenOn) {
    final off = c.screenOffSince;
    final long = off == null || c.now.difference(off) >= KindRule.screenOffFor;
    if (long) {
      return KindGuess(WearKind.night, [
        off == null ? 'charging, screen off' : 'charging, screen off ${c.now.difference(off).inMinutes} min',
      ]);
    }
  }
  if (evening && c.dnd) return const KindGuess(WearKind.night, ['Do Not Disturb on']);
  return const KindGuess(WearKind.other, ['outside the bedtime window, no work signal from the laptop']);
}
