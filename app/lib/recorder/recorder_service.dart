// The foreground service (type connectedDevice only, never dataSync: DECISIONS row 2) and its
// TaskHandler isolate, which owns the whole BrainBit session and the file writer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../phone.dart';
import '../share/isolate.dart';
import '../share/protocol.dart';
import 'brainbit.dart';
import '../handsfree/store.dart' show nightGestures;
import 'headband.dart';
import 'live_drift.dart';
import 'night_recorder.dart';
import 'status.dart';

const int _serviceId = 4711;
const String _nightKey = 'night';
const String _dirKey = 'recordingsDir';

/// Messages from the screen to the recorder.
const String stopCommand = 'stop';
const String statusCommand = 'status';

/// The night screen's Lights off (live_drift.dart): a marker in the recording, the drift-off detector from here.
const String lightsOffCommand = 'lightsOff';

/// Share on Wi-Fi (DECISIONS rows 220-229): the saved setting, and the messages about it. The screen sends
/// `{'kind': 'share', 'config': {...}}` when the switch moves during a night; the recorder answers with
/// [shareMessage] whenever the server comes up, moves or stops.
const String shareKey = 'share';

Future<ShareConfig> loadShareConfig() async =>
    ShareConfig.decode(await FlutterForegroundTask.getData<String>(key: shareKey));

Future<void> saveShareConfig(ShareConfig c) => FlutterForegroundTask.saveData(key: shareKey, value: c.encode());

Map<String, Object?> shareMessage(ShareStatus s) => {
  'kind': 'share',
  'up': s.up,
  'addresses': s.addresses,
  'port': s.port,
  'note': s.note,
};

ShareStatus? shareStatusFrom(Object? data) {
  if (data is! Map || data['kind'] != 'share' || data.containsKey('config')) return null;
  final a = data['addresses'], p = data['port'], n = data['note'];
  return (
    up: data['up'] == true,
    addresses: [
      if (a is List)
        for (final x in a)
          if (x is String) x,
    ],
    port: p is int ? p : sharePort,
    note: n is String ? n : '',
  );
}

/// Sent by the recorder once its files are closed after [stopCommand].
const Map<String, Object> stoppedMessage = {'kind': 'stopped'};

void initRecorderService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'night_recording',
      channelName: 'Night recording',
      channelDescription: 'Shown while the headband is recording',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      // The recorder keeps its own 1 s clock; no repeat events needed.
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false, // a reboot ends the night; never resume silently
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true, // partial wake lock only while the service runs
      allowWifiLock: false,
      allowAutoRestart: true, // restart after a system kill (needs the battery-optimisation exemption)
      stopWithTask: false, // keep recording when the app is swiped from Recents
    ),
  );
}

/// Starts the service. [recordingsDir] is remembered as a fallback for the recorder isolate.
Future<ServiceRequestResult> startRecorderService(String? recordingsDir) async {
  if (recordingsDir != null) await FlutterForegroundTask.saveData(key: _dirKey, value: recordingsDir);
  if (await FlutterForegroundTask.isRunningService) return const ServiceRequestSuccess();
  return FlutterForegroundTask.startService(
    serviceId: _serviceId,
    serviceTypes: [ForegroundServiceTypes.connectedDevice],
    notificationTitle: 'EEG Tracker',
    notificationText: 'Looking for the headband',
    callback: recorderEntryPoint,
  );
}

Future<NightState> loadNight() async => _PrefsNightStore().load();

@pragma('vm:entry-point')
void recorderEntryPoint() => FlutterForegroundTask.setTaskHandler(RecorderTaskHandler());

class RecorderTaskHandler extends TaskHandler {
  NightRecorder? _recorder;
  BrainBitFinder? _finder;
  Phase? _shownPhase;
  int _shownAtMs = 0;
  bool _stopping = false;

  /// Share on Wi-Fi. Everything about it goes through [_sharing], which swallows every error: the recorder
  /// above never waits for it and never sees it fail.
  ShareHost? _share;
  String? _filesDir;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final dir = await _recordingsDir();
    _filesDir = Directory(dir).parent.path;
    final finder = BrainBitFinder();
    _finder = finder;
    final recorder = NightRecorder(
      finder: finder,
      dir: Directory(dir),
      store: _PrefsNightStore(),
      probe: ChannelPhoneProbe(),
      onStatus: _onStatus,
      onStuck: _restartProcess,
      // the owner's hands-free double clench, read when the detector starts (DECISIONS 247)
      watch: () => LiveDrift(handsFree: nightGestures(Directory(dir).parent)),
    );
    _recorder = recorder;
    unawaited(recorder.run(restartedBySystem: starter == TaskStarter.system));
    unawaited(_sharing(() async => _applyShare(await loadShareConfig())));
  }

  Future<void> _sharing(Future<void> Function() what) async {
    try {
      await what().timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Starts, restarts or stops the server to match [config].
  Future<void> _applyShare(ShareConfig config) async {
    await _share?.stop();
    _share = null;
    final files = _filesDir;
    if (_stopping || files == null || !config.activeAt(DateTime.now().millisecondsSinceEpoch)) {
      FlutterForegroundTask.sendDataToMain(shareMessage(shareDown));
      return;
    }
    final host = _share = ShareHost(
      filesDir: files,
      onLog: (line) => _recorder?.note(line),
      onMarker: (text) => _recorder?.addMarker(text),
      onChange: (s) {
        FlutterForegroundTask.sendDataToMain(shareMessage(s));
        _shownAtMs = 0; // the notification's next line says where it is shared
      },
      wifiLock: (on) => Phone.wifiLock(on: on),
    );
    final r = _recorder;
    if (r != null) host.setLive(r.status.toMap(nowMs: DateTime.now().millisecondsSinceEpoch));
    await host.start(config);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {
    if (data == stopCommand) {
      unawaited(_stop(endNight: true));
    } else if (data == statusCommand) {
      final r = _recorder;
      if (r != null) _send(r.status);
      FlutterForegroundTask.sendDataToMain(shareMessage(_share?.status ?? shareDown));
    } else if (data == lightsOffCommand) {
      final r = _recorder;
      if (r != null) {
        r.lightsOff();
        _send(r.status);
      }
    } else if (data is Map && data['kind'] == 'share') {
      unawaited(_sharing(() => _applyShare(ShareConfig.fromJson(data['config']))));
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Destroyed without the screen's Stop (system kill, timeout): keep the night for the restart.
    await _stop(endNight: false);
  }

  Future<void> _stop({required bool endNight}) async {
    if (_stopping) return;
    _stopping = true;
    final r = _recorder;
    // Sharing in the background: its port is free again within about 4 s, while the recorder saves and stops.
    unawaited(_sharing(() async => _share?.stop()));
    await r?.stop(endNight: endNight);
    // The scanner kept for direct reconnects goes too, unless a headband was left out of range.
    _finder?.dispose(anyLost: r == null || !r.finished || r.abandoned.isNotEmpty);
    FlutterForegroundTask.sendDataToMain(stoppedMessage);
  }

  void _onStatus(RecorderStatus s) {
    _send(s);
    final now = DateTime.now().millisecondsSinceEpoch;
    _share?.setLive(s.toMap(nowMs: now));
    if (s.phase != _shownPhase || now - _shownAtMs >= 10000) {
      _shownPhase = s.phase;
      _shownAtMs = now;
      unawaited(FlutterForegroundTask.updateService(notificationText: notificationText(s, _share?.status)));
    }
  }

  void _send(RecorderStatus s) =>
      FlutterForegroundTask.sendDataToMain(s.toMap(nowMs: DateTime.now().millisecondsSinceEpoch));

  Future<void> _restartProcess(String reason) async {
    try {
      await Phone.restartProcess(5000).timeout(const Duration(seconds: 5));
    } catch (_) {}
    exit(3); // reached only if the native call could not end the process
  }

  static Future<String> _recordingsDir() async {
    try {
      final d = await Phone.recordingsDir();
      if (d != null) return d;
    } catch (_) {}
    final saved = await FlutterForegroundTask.getData<String>(key: _dirKey);
    return saved ?? '/data/user/0/io.github.utof.eeg_tracker/files/recordings'; // Context.getFilesDir()
  }
}

/// The notification's line; while sharing is on it says so, with the address.
String notificationText(RecorderStatus s, [ShareStatus? share]) {
  final line = _phaseText(s);
  if (share == null || !share.up) return line;
  final at = shareAddress(share);
  return '$line · shared on Wi-Fi${at == null ? '' : ' at $at'}';
}

String _phaseText(RecorderStatus s) {
  final minutes = s.minutesRecorded.floor();
  return switch (s.phase) {
    Phase.recording => 'Recording · $minutes min',
    Phase.searching => 'Looking for the headband',
    Phase.connecting => 'Connecting to the headband',
    Phase.checkingContact => 'Checking contact',
    Phase.reconnecting => 'Reconnecting · $minutes min saved',
    Phase.stopping => 'Stopping',
    Phase.idle => 'Idle',
  };
}

class _PrefsNightStore implements NightStore {
  @override
  Future<NightState> load() async {
    final raw = await FlutterForegroundTask.getData<String>(key: _nightKey);
    if (raw == null) return const NightState();
    try {
      return NightState.fromJson(jsonDecode(raw));
    } catch (_) {
      return const NightState();
    }
  }

  @override
  Future<void> save(NightState state) async {
    await FlutterForegroundTask.saveData(key: _nightKey, value: jsonEncode(state.toJson()));
  }
}
