// The app's own small Android channel (PhoneChannel.kt). Registered in both Flutter engines: the
// screen's and the recorder service's, so the recorder can find its folder and log the power state.
import 'package:flutter/services.dart';

import 'recorder/battery.dart';
import 'recorder/headband.dart';

const MethodChannel _channel = MethodChannel('eeg_tracker/phone');

/// Only in the screen's engine: the folder picker needs the Activity (MainActivity.kt, NightExport.kt).
const MethodChannel _export = MethodChannel('eeg_tracker/export');

/// Only in the screen's engine: window flags of MainActivity (meditation and the dream catcher keep the screen on;
/// the dream catcher also dims it).
const MethodChannel _window = MethodChannel('eeg_tracker/window');

/// What an export copied.
typedef ExportResult = ({int files, int bytes, String folder});

/// Phone settings that decide whether a night survives, read in one go.
class PhoneSnapshot {
  const PhoneSnapshot(this._m);
  final Map<Object?, Object?> _m;

  int get sdkInt => (_m['sdkInt'] as num?)?.toInt() ?? 0;
  bool get ignoringBatteryOptimizations => _m['ignoringBatteryOptimizations'] == true;
  bool get backgroundRestricted => _m['backgroundRestricted'] == true;
  bool get notificationsEnabled => _m['notificationsEnabled'] != false;
  bool get powerSaveMode => _m['powerSaveMode'] == true;
  bool get bluetoothOn => _m['bluetoothOn'] != false;

  /// 10 active, 20 working set, 30 frequent, 40 rare, 45 restricted; null below Android 9.
  int? get standbyBucket => (_m['standbyBucket'] as num?)?.toInt();

  /// HyperOS or MIUI version name when the phone is a Xiaomi, else null.
  String? get xiaomiOs => (_m['hyperOs'] as String?) ?? (_m['miui'] as String?);
}

class Phone {
  /// The app's private `files/recordings` folder, created if missing. Other apps cannot read it; only
  /// [exportNight] copies anything out.
  static Future<String?> recordingsDir() => _channel.invokeMethod<String>('recordingsDir');

  /// Lets the owner pick a folder with the system picker, then copies [paths] (files of the recordings
  /// folder only) into a new subfolder [folder] there. Null when the picker was closed without a choice.
  static Future<ExportResult?> exportNight(List<String> paths, String folder) async {
    final r = await _export.invokeMapMethod<String, Object?>('exportNight', {'paths': paths, 'folder': folder});
    if (r == null) return null;
    return (
      files: (r['files'] as num?)?.toInt() ?? 0,
      bytes: (r['bytes'] as num?)?.toInt() ?? 0,
      folder: r['folder'] is String ? r['folder'] as String : folder,
    );
  }

  /// Keeps the screen on (or lets it sleep again) while the app is in front.
  static Future<void> keepScreenOn({required bool on}) => _window.invokeMethod<void>('keepScreenOn', {'on': on});

  /// Turns this window's brightness down to the lowest (the dream catcher in bed), or back to the phone's setting.
  static Future<void> dimScreen({required bool on}) => _window.invokeMethod<void>('dim', {'on': on});

  static Future<PhoneSnapshot> snapshot() async =>
      PhoneSnapshot(await _channel.invokeMethod<Map<Object?, Object?>>('snapshot') ?? const {});

  /// Opens a settings page: `batteryOptimization`, `appDetails`, `notifications`, `bluetooth`,
  /// `batterySaver`, `xiaomiAutostart`, `xiaomiBatterySaver`. Falls back to the app's details page.
  static Future<bool> openSettings(String page) async =>
      await _channel.invokeMethod<bool>('openSettings', {'page': page}) ?? false;

  /// Earlier process exits since [sinceMs] (Android 11+), one readable line each.
  static Future<List<String>> exitReasons(int sinceMs) async =>
      (await _channel.invokeListMethod<String>('exitReasons', {'sinceMs': sinceMs})) ?? const [];

  /// The phone's battery now: level, charge counter, current, charger, temperature (BatteryManager).
  static Future<PhoneBattery?> battery() async =>
      PhoneBattery.fromMap(await _channel.invokeMapMethod<Object?, Object?>('battery'));

  /// Schedules the foreground service to start again in [delayMs], then ends this process.
  static Future<void> restartProcess(int delayMs) =>
      _channel.invokeMethod<void>('restartProcess', {'delayMs': delayMs});
}

/// [PhoneProbe] for the recorder isolate.
class ChannelPhoneProbe implements PhoneProbe {
  @override
  Future<String?> powerLine() async {
    final s = await Phone.snapshot();
    String yn(bool v) => v ? 'yes' : 'no';
    return 'android ${s.sdkInt}, battery-opt exempt ${yn(s.ignoringBatteryOptimizations)}, '
        'background restricted ${yn(s.backgroundRestricted)}, power save ${yn(s.powerSaveMode)}, '
        'standby bucket ${s.standbyBucket ?? '?'}, notifications ${yn(s.notificationsEnabled)}'
        '${s.xiaomiOs != null ? ', xiaomi ${s.xiaomiOs}' : ''}';
  }

  @override
  Future<PhoneBattery?> battery() => Phone.battery();

  @override
  Future<List<String>> exitReasons(int sinceMs) => Phone.exitReasons(sinceMs);
}
