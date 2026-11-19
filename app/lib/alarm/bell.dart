// The phone's own alarm clock for the smart alarm (DECISIONS 233-236): Android's AlarmManager alarm clock at the
// window's end, set at Start, plus the ringer (WakeAlarm.kt, WakeService.kt, AlarmActivity.kt). The live scorer can
// only bring that alarm forward ("ring now"); it can never take it away, so the owner is woken by the window's end
// even if the app, the model or the headband is gone. Reached through the "eeg_tracker/alarm" channel, registered in
// both Flutter engines (the screen's and the night recorder's service).
import 'package:flutter/services.dart';

import '../nap/rules.dart' show NapRule;
import '../sound/synth.dart' show cueLevel, cuePartials, toneGain;
import 'rule.dart';

/// How the ringer rises: the nap coach's three notes ([NapRule.wakeSteps] times the first volume, a step every
/// [NapRule.wakeEveryS]), then the phone's own alarm sound after [loudAfterS], until "I'm awake" or [giveUpS] more.
abstract final class Ring {
  /// The first notes' volume, against the phone's alarm volume: the nap coach's first cue (DECISIONS 175), 0.175.
  static double get firstVolume => toneGain(cuePartials, cueLevel);
  static const int loudAfterS = 180;
  static const int giveUpS = 600;

  static List<double> get volumes => [for (final k in NapRule.wakeSteps) (firstVolume * k).clamp(0.0, 1.0)];
}

/// The early ring, as the night recorder's live scorer sees it.
abstract interface class AlarmBell {
  /// Brings the phone's alarm forward to now. False when there is nothing to bring forward (no alarm set, already
  /// ringing, or "I'm awake" already tapped).
  Future<bool> ringNow(String reason);
}

class ChannelAlarmBell implements AlarmBell {
  @override
  Future<bool> ringNow(String reason) => AlarmClock.bringForward(reason);
}

/// What the phone's alarm is doing (WakeAlarm.kt `state`).
class AlarmClockState {
  const AlarmClockState(this._m);
  final Map<Object?, Object?> _m;

  int? _ms(String k) {
    final v = _m[k];
    return v is num && v > 0 ? v.toInt() : null;
  }

  /// The window's end of the alarm set (unix ms); null when none is set.
  int? get endMs => _ms('endMs');
  int? get startMs => _ms('startMs');
  int? get ringingSinceMs => _ms('ringingSinceMs');

  /// `smart`, `window end` or `backup` (the re-ring after a stopped app).
  String? get ringBy => _m['ringBy'] as String?;
  String? get reason => _m['reason'] as String?;
  int? get loudSinceMs => _ms('loudSinceMs');
  int? get awakeMs => _ms('awakeMs');
  int? get gaveUpMs => _ms('gaveUpMs');

  /// Ringing now (not yet "I'm awake", not given up).
  bool get ringing => ringingSinceMs != null && awakeMs == null && gaveUpMs == null;

  /// The phone allows exact alarms (Android 12+: `USE_EXACT_ALARM` or the "Alarms & reminders" setting).
  bool get exact => _m['exact'] != false;

  /// The ring may open its full-screen page over the lock screen (Android 14: "full screen notifications").
  bool get fullScreen => _m['fullScreen'] != false;
  bool get notifications => _m['notifications'] != false;
  int? get alarmVolume => (_m['alarmVolume'] as num?)?.toInt();
  int? get alarmVolumeMax => (_m['alarmVolumeMax'] as num?)?.toInt();

  /// The phone's alarm volume is all the way down.
  bool get silent => alarmVolume == 0;
}

/// The "eeg_tracker/alarm" channel. Every call fails soft: no Android (tests) gives an empty state.
abstract final class AlarmClock {
  static const MethodChannel _channel = MethodChannel('eeg_tracker/alarm');

  /// Sets the phone's alarm at [plan]'s end (replacing any earlier one) and how it will ring.
  static Future<AlarmClockState> schedule(AlarmPlan plan) => _state('schedule', {
    'endMs': plan.endMs,
    'startMs': plan.startMs,
    'volumes': Ring.volumes,
    'everyS': NapRule.wakeEveryS,
    'loudAfterS': Ring.loudAfterS,
    'giveUpS': Ring.giveUpS,
  });

  /// Takes the alarm away (and stops it if it rings).
  static Future<AlarmClockState> cancel() => _state('cancel');

  /// "I'm awake": stops the sound and the alarm.
  static Future<AlarmClockState> awake() => _state('awake');

  static Future<AlarmClockState> state() => _state('state');

  static Future<bool> bringForward(String reason) async =>
      await _channel.invokeMethod<bool>('bringForward', {'reason': reason}) ?? false;

  /// Opens the phone's setting for [page]: `exact` (Alarms & reminders) or `fullScreen`.
  static Future<void> openSetting(String page) async {
    try {
      await _channel.invokeMethod<void>('openSetting', {'page': page});
    } on PlatformException {
      // the settings page does not exist on this phone
    } on MissingPluginException {
      // not Android
    }
  }

  static Future<AlarmClockState> _state(String method, [Map<String, Object?>? args]) async {
    try {
      return AlarmClockState(await _channel.invokeMethod<Map<Object?, Object?>>(method, args) ?? const {});
    } on MissingPluginException {
      return const AlarmClockState({});
    }
  }
}
