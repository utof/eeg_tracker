// The app's side of the headband watcher (AutoWatch.kt): Android's companion pairing and presence events, the bedtime
// checks' alarms, the check service (AutoWatchService.kt) that runs the watcher in its own engine, and the launches
// its notifications ask for. Every call is harmless where the channel is missing (tests, a desktop harness).
import 'package:flutter/services.dart';

/// What this phone allows, as AutoWatch.kt reads it.
class WatchStatus {
  const WatchStatus(this._m);
  final Map<Object?, Object?> _m;

  int get sdkInt => (_m['sdkInt'] as num?)?.toInt() ?? 0;

  /// The phone has companion pairing (Android 8+) and presence events (Android 12+).
  bool get companionSupported => _m['companion'] == true;
  bool get presenceSupported => _m['presence'] == true;

  /// The headband is paired with the app through companion pairing, and Android watches for it.
  bool get paired => _m['paired'] == true;
  bool get observing => _m['observing'] == true;
  String? get pairedName => _m['name'] as String?;

  /// `near`, `away`, or null (no event yet).
  String? get presence => _m['presence_state'] as String?;
  DateTime? get presenceAt => _ms(_m['presence_at']);

  bool get batteryExempt => _m['batteryExempt'] == true;
  bool get notificationsOn => _m['notifications'] != false;

  /// HyperOS or MIUI version on a Xiaomi.
  String? get xiaomiOs => _m['xiaomi'] as String?;

  /// Android refused to start a check from the background (the time it did), or null.
  DateTime? get refusedAt => _ms(_m['refused_at']);

  /// The last check service start, and the last trigger it ran.
  DateTime? get lastCheckAt => _ms(_m['last_check_at']);
  String? get lastTrigger => _m['last_trigger'] as String?;

  /// The bedtime checks armed: the next one, or null.
  DateTime? get nextBedtimeCheck => _ms(_m['next_bedtime']);

  static DateTime? _ms(Object? v) => v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

  /// Background checks can start: Android watches the headband for the app, or the app may run in the background.
  bool get canCheckInBackground => (paired && observing) || batteryExempt;
}

/// What a notification tap opened the app for.
class AutoLaunch {
  const AutoLaunch({required this.action, this.quiet = true, this.limit, this.kind});

  /// `work` (start a work session), `settings` (the auto-start page, from the offer).
  final String action;
  final bool quiet;
  final Duration? limit;
  final String? kind;
}

abstract final class AutoChannel {
  static const MethodChannel _ch = MethodChannel('eeg_tracker/auto');

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<WatchStatus> status() async =>
      WatchStatus(await _call<Map<Object?, Object?>>('status') ?? const <Object?, Object?>{});

  /// Opens Android's companion pairing dialog for the headband (only from the app's screen). An error in words, or
  /// null when it is paired and watched.
  static Future<String?> pair() async {
    try {
      final r = await _ch.invokeMethod<String>('pair');
      return r == null || r == 'ok' ? null : r;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on MissingPluginException {
      return 'not on this platform';
    }
  }

  static Future<void> forget() => _call<void>('forget');

  /// Asks for a check now ([reason]: `opened`, `now`, `laptop`); AutoWatch.kt decides whether one starts.
  static Future<void> requestCheck(String reason) => _call<void>('check', {'reason': reason});

  /// Lets go of a headband the watcher holds (it may be asking): call before a start by hand.
  static Future<void> release() => _call<void>('release');

  /// The app's screen holds the headband with a connection that is neither a night nor a session (the Signal tab's
  /// own, DECISIONS 595): no check starts while [on] (AutoWatch.kt `busyReason`).
  static Future<void> screenHolds(bool on) => _call<void>('screenHolds', {'on': on});

  /// Arms the bedtime checks ([at], the next 24 hours); none when every kind is "Do nothing".
  static Future<void> armBedtime(List<DateTime> at) =>
      _call<void>('armBedtime', {'at': [for (final t in at) t.millisecondsSinceEpoch]});

  /// The launch a notification tap asked for, once; null for none.
  static Future<AutoLaunch?> takeLaunch() async {
    final m = await _call<Map<Object?, Object?>>('takeLaunch');
    final action = m?['action'];
    if (m == null || action is! String) return null;
    final limit = m['limitMin'];
    return AutoLaunch(
      action: action,
      quiet: m['quiet'] != false,
      limit: limit is num && limit > 0 ? Duration(minutes: limit.toInt()) : null,
      kind: m['kind'] as String?,
    );
  }

  /// Tells AutoWatch.kt that the work page took its launch (the watcher waits for this before it asks instead).
  static Future<void> workOpened() => _call<void>('workOpened');

  /// A tap on a notification while the app runs: [onLaunch] takes it.
  static void listen(void Function() onLaunch) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'launch') onLaunch();
    });
  }
}
