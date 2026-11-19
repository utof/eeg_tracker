// The foreground service (type connectedDevice only, never dataSync: DECISIONS row 2) and its
// TaskHandler isolate, which owns the whole BrainBit session and the file writer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../alarm/bell.dart';
import '../alarm/live_alarm.dart';
import '../alarm/record.dart';
import '../alarm/rule.dart';
import '../phone.dart';
import '../sleep/live_stager.dart';
import '../sleep/onnx_runs.dart';
import 'brainbit.dart';
import 'headband.dart';
import 'night_recorder.dart';
import 'status.dart';

const int _serviceId = 4711;
const String _nightKey = 'night';
const String _dirKey = 'recordingsDir';
const String _alarmKey = 'alarmPlan';

/// Messages from the screen to the recorder.
const String stopCommand = 'stop';
const String statusCommand = 'status';

/// The night screen's Lights off (live_drift.dart): a marker in the recording, the drift-off detector from here.
const String lightsOffCommand = 'lightsOff';

/// The night screen's Alarm off: the smart alarm's live model stops (the screen takes the phone's alarm away).
const String alarmOffCommand = 'alarmOff';

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

/// Starts the service. [recordingsDir] is remembered as a fallback for the recorder isolate; [alarm] is tonight's
/// smart alarm (the screen sets the phone's alarm itself, before this). [callback] is for smoke tests only.
Future<ServiceRequestResult> startRecorderService(
  String? recordingsDir, {
  AlarmPlan? alarm,
  Function callback = recorderEntryPoint,
}) async {
  if (recordingsDir != null) await FlutterForegroundTask.saveData(key: _dirKey, value: recordingsDir);
  if (await FlutterForegroundTask.isRunningService) return const ServiceRequestSuccess();
  if (alarm == null) {
    await FlutterForegroundTask.removeData(key: _alarmKey);
  } else {
    await FlutterForegroundTask.saveData(key: _alarmKey, value: jsonEncode(alarm.toJson()));
  }
  return FlutterForegroundTask.startService(
    serviceId: _serviceId,
    serviceTypes: [ForegroundServiceTypes.connectedDevice],
    notificationTitle: 'EEG Tracker',
    notificationText: 'Looking for the headband',
    callback: callback,
  );
}

/// The smart alarm's live model in the recorder's isolate: AnySleep's runs on ONNX (the plugin is registered in this
/// engine too), the early ring through the phone's alarm, the record beside the recordings.
AlarmWatch Function(AlarmPlan plan) smartAlarmFor(String recordingsDir) => (plan) => smartAlarm(recordingsDir, plan);

LiveAlarm smartAlarm(String recordingsDir, AlarmPlan plan) => LiveAlarm(
  plan: plan,
  model: () => RunsLiveModel(
    open: (run) => OnnxStageRun.open(run, modelsDir: modelsDirFor(recordingsDir)),
    closeRun: (run) => (run as OnnxStageRun).close(),
  ),
  bell: ChannelAlarmBell(),
  store: AlarmStore(alarmsDirFor(recordingsDir)),
);

Future<NightState> loadNight() async => _PrefsNightStore().load();

@pragma('vm:entry-point')
void recorderEntryPoint() => FlutterForegroundTask.setTaskHandler(RecorderTaskHandler());

class RecorderTaskHandler extends TaskHandler {
  RecorderTaskHandler({this.finder, this.alarm = smartAlarmFor});

  /// Only for smoke tests (a replayed headband); null: the BrainBit.
  final HeadbandFinder Function()? finder;

  /// The smart alarm's live model for the recordings folder (a smoke test watches its own).
  final AlarmWatch Function(AlarmPlan plan) Function(String recordingsDir) alarm;
  NightRecorder? _recorder;
  BrainBitFinder? _finder;
  Phase? _shownPhase;
  int _shownAtMs = 0;
  bool _stopping = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final dir = await _recordingsDir();
    final HeadbandFinder finder;
    if (this.finder != null) {
      finder = this.finder!();
    } else {
      final b = BrainBitFinder();
      _finder = b;
      finder = b;
    }
    final recorder = NightRecorder(
      finder: finder,
      dir: Directory(dir),
      store: _PrefsNightStore(),
      probe: ChannelPhoneProbe(),
      onStatus: _onStatus,
      onStuck: _restartProcess,
      alarmPlan: await _alarmPlan(),
      alarm: alarm(dir),
    );
    _recorder = recorder;
    unawaited(recorder.run(restartedBySystem: starter == TaskStarter.system));
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
    } else if (data == lightsOffCommand) {
      final r = _recorder;
      if (r != null) {
        r.lightsOff();
        _send(r.status);
      }
    } else if (data == alarmOffCommand) {
      final r = _recorder;
      if (r != null) {
        r.alarmOff();
        _send(r.status);
      }
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
    await r?.stop(endNight: endNight);
    // The scanner kept for direct reconnects goes too, unless a headband was left out of range.
    _finder?.dispose(anyLost: r == null || !r.finished || r.abandoned.isNotEmpty);
    FlutterForegroundTask.sendDataToMain(stoppedMessage);
  }

  void _onStatus(RecorderStatus s) {
    _send(s);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (s.phase != _shownPhase || now - _shownAtMs >= 10000) {
      _shownPhase = s.phase;
      _shownAtMs = now;
      unawaited(FlutterForegroundTask.updateService(notificationText: _notificationText(s)));
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

  static Future<AlarmPlan?> _alarmPlan() async {
    try {
      final raw = await FlutterForegroundTask.getData<String>(key: _alarmKey);
      return raw == null ? null : AlarmPlan.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
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

String _notificationText(RecorderStatus s) {
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
