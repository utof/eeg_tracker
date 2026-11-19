// The app's own small Android channel (PhoneChannel.kt). Registered in both Flutter engines: the
// screen's and the recorder service's, so the recorder can find its folder and log the power state.
import 'dart:io';

import 'package:flutter/services.dart';

import 'export/exporter.dart';
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

/// The folder Export data writes into: the system picker's grant and how to show it (`Download/EEG`).
typedef ExportFolder = ({String uri, String label});

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

  /// The system folder picker for Export data; the app keeps the grant until another folder is picked. Null when
  /// the picker was closed without a choice.
  static Future<ExportFolder?> pickExportFolder() async {
    final r = await _export.invokeMapMethod<String, Object?>('pickFolder');
    final uri = r?['uri'], label = r?['label'];
    return uri is String && label is String ? (uri: uri, label: label) : null;
  }

  /// Whether the app may still write to the picked folder (the grant can be taken back in the phone's settings).
  static Future<bool> exportFolderUsable(String uri) async =>
      await _export.invokeMethod<bool>('folderUsable', {'uri': uri}) ?? false;

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

  /// Share on Wi-Fi during a night: holds (or lets go of) a Wi-Fi lock, so Wi-Fi keeps answering with the screen
  /// off (PhoneChannel.kt). Works from the recorder's engine too.
  static Future<void> wifiLock({required bool on}) => _channel.invokeMethod<void>('wifiLock', {'on': on});

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

/// [ExportTarget] through the folder grant of the system picker (DataExport.kt); only in the screen's engine.
class ChannelExportTarget implements ExportTarget {
  ChannelExportTarget(this.uri);
  final String uri;

  static Future<T> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _export.invokeMethod<T>(method, args) as T;
    } on PlatformException catch (e) {
      throw ExportFailure(e.message ?? e.code);
    }
  }

  static Copied _copied(Object? r) {
    if (r is! Map || r['bytes'] is! num || r['sha256'] is! String) throw const ExportFailure('the folder gave no answer');
    return (bytes: (r['bytes'] as num).toInt(), sha256: r['sha256'] as String);
  }

  @override
  Future<void> open() => _call<void>('open', {'uri': uri});

  @override
  Future<Copied> copy(File source, String path) async =>
      _copied(await _call<Object?>('copy', {'source': source.path, 'path': path}));

  @override
  Future<Copied> write(String path, List<int> bytes) async =>
      _copied(await _call<Object?>('write', {'path': path, 'bytes': Uint8List.fromList(bytes)}));

  @override
  Future<void> close() => _call<void>('close');
}
