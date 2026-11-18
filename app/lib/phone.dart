// The app's own small Android channel (PhoneChannel.kt). Registered in both Flutter engines: the
// screen's and the recorder service's, so the recorder can find its folder and log the power state.
import 'package:flutter/services.dart';

import 'recorder/headband.dart';

const MethodChannel _channel = MethodChannel('eeg_tracker/phone');

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
  /// `Android/media/<applicationId>/recordings`, created if missing (reachable by adb pull and Syncthing).
  static Future<String?> recordingsDir() => _channel.invokeMethod<String>('recordingsDir');

  static Future<PhoneSnapshot> snapshot() async =>
      PhoneSnapshot(await _channel.invokeMethod<Map<Object?, Object?>>('snapshot') ?? const {});

  /// Opens a settings page: `batteryOptimization`, `appDetails`, `notifications`, `bluetooth`,
  /// `batterySaver`, `xiaomiAutostart`, `xiaomiBatterySaver`. Falls back to the app's details page.
  static Future<bool> openSettings(String page) async =>
      await _channel.invokeMethod<bool>('openSettings', {'page': page}) ?? false;

  /// Earlier process exits since [sinceMs] (Android 11+), one readable line each.
  static Future<List<String>> exitReasons(int sinceMs) async =>
      (await _channel.invokeListMethod<String>('exitReasons', {'sinceMs': sinceMs})) ?? const [];

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
  Future<List<String>> exitReasons(int sinceMs) => Phone.exitReasons(sinceMs);
}
