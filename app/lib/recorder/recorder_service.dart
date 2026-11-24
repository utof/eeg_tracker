// The foreground service (type connectedDevice only, never dataSync: DECISIONS row 2) and its
// TaskHandler isolate, which owns the whole BrainBit session and the file writer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../alarm/bell.dart';
import '../alarm/live_alarm.dart';
import '../alarm/record.dart';
import '../alarm/rule.dart';
import '../auto/channel.dart' show AutoChannel;
import '../handsfree/store.dart' show nightGestures;
import '../headband/diy/night.dart';
import '../logs/activity.dart' show Activity;
import '../logs/engine.dart' show EngineRecords;
import '../logs/metrics.dart' show Metrics;
import '../lucid/bell.dart' show ChannelCueBell;
import '../cues/night_cues.dart' show CueFactory, oneKindANight;
import '../lucid/live_cues.dart' show lucidCuesFor;
import '../memory_cues/live_cues.dart' show memoryCuesFor;
import '../phone.dart';
import '../start_log.dart';
import '../share/isolate.dart';
import '../share/protocol.dart';
import '../signal/live_tap.dart';
import '../sleep/live_log.dart' show LiveStageLog, liveStagesDirFor;
import '../sleep/live_stager.dart';
import '../sleep/night_scorer.dart';
import '../sleep/onnx_runs.dart';
import '../spans/span.dart' show spansDirFor;
import '../spans/after_restart.dart';
import '../spans/span_log.dart';
import 'brainbit.dart';
import 'chunk_writer.dart' show ChunkWriter;
import 'headband.dart';
import 'live_drift.dart';
import 'night_recorder.dart';
import 'phone_steps.dart' show StepSettings, stepsDirFor;
import 'status.dart';
import 'wifi_watch.dart';

const int _serviceId = 4711;
const String _nightKey = 'night';
const String _dirKey = 'recordingsDir';
const String _alarmKey = 'alarmPlan';

/// A night the headband watcher started (lib/auto, DECISIONS 604): its lines for the night's log. While set, the night
/// runs no lucid cues (no sound starts without a tap); a start by hand removes it.
const String _autoKey = 'autoStart';

/// The recording starts with Sleep (`1`: a sleep span and the sleep kit from its start) or with Record alone (`0`).
const String _sleepKey = 'startSleep';

/// Opens or closes a span of the running recording (Record first, DECISIONS 884): the recorder writes it and answers
/// with its status, which lists the spans.
Map<String, Object?> openSpanCommand(String kind, {String? session}) => {
  'kind': 'span',
  'op': 'open',
  'span_kind': kind,
  'session': ?session,
};
Map<String, Object?> closeSpanCommand(String id, {String by = 'owner'}) => {'kind': 'span', 'op': 'close', 'id': id, 'by': by};

/// Messages from the screen to the recorder.
const String stopCommand = 'stop';
const String statusCommand = 'status';

/// The night screen's Lights off (live_drift.dart): a marker in the recording, the drift-off detector from here.
const String lightsOffCommand = 'lightsOff';

/// The night screen's Alarm off: the smart alarm's live model stops (the screen takes the phone's alarm away).
const String alarmOffCommand = 'alarmOff';

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
  'here': s.here,
  'net': s.net,
  'copied_at_ms': s.copiedAtMs,
  'copied_by': s.copiedBy,
};

ShareStatus? shareStatusFrom(Object? data) {
  if (data is! Map || data['kind'] != 'share' || data.containsKey('config')) return null;
  final a = data['addresses'], p = data['port'], n = data['note'], h = data['here'], net = data['net'];
  final at = data['copied_at_ms'], by = data['copied_by'];
  return (
    up: data['up'] == true,
    addresses: [
      if (a is List)
        for (final x in a)
          if (x is String) x,
    ],
    port: p is int ? p : sharePort,
    note: n is String ? n : '',
    here: h is String ? h : '',
    net: net is String ? net : '',
    copiedAtMs: at is int ? at : 0,
    copiedBy: by is String ? by : '',
  );
}

/// Sleep (or Nap) on the running recording, and Stop sleep (Record first, DECISIONS 904): the recorder opens or closes
/// the sleep span and attaches or detaches the sleep kit; [alarm] is that sleep's smart alarm.
Map<String, Object?> startSleepCommand({String kind = 'sleep', AlarmPlan? alarm}) => {
  'kind': 'sleep',
  'op': 'start',
  'span_kind': kind,
  'alarm': alarm?.toJson(),
};
const Map<String, Object?> stopSleepCommand = {'kind': 'sleep', 'op': 'stop'};

/// Sent by the recorder when it stopped by itself after hours without the headband (DECISIONS 899).
const Map<String, Object> gaveUpMessage = {'kind': 'gaveUp'};

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
/// [autoNotes]: the headband watcher starts the night (its lines for the log); a start by hand first makes the watcher
/// let go of a headband it holds while asking ([fromWatcher]: the watcher's own start, it has let go already).
Future<ServiceRequestResult> startRecorderService(
  String? recordingsDir, {
  AlarmPlan? alarm,
  Function callback = recorderEntryPoint,
  List<String>? autoNotes,
  bool fromWatcher = false,
  bool sleep = true,
}) async {
  if (!fromWatcher) await AutoChannel.release();
  if (recordingsDir != null) await FlutterForegroundTask.saveData(key: _dirKey, value: recordingsDir);
  if (await FlutterForegroundTask.isRunningService) return const ServiceRequestSuccess();
  await FlutterForegroundTask.saveData(key: _sleepKey, value: sleep ? '1' : '0');
  if (autoNotes == null) {
    await FlutterForegroundTask.removeData(key: _autoKey);
  } else {
    await FlutterForegroundTask.saveData(key: _autoKey, value: jsonEncode(autoNotes));
  }
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

/// The night's one live sleep model in the recorder's isolate: AnySleep's runs on ONNX (the plugin is registered in
/// this engine too), shared by the smart alarm and tonight's sound cues (DECISIONS 330). Its start, epochs and end are
/// written down for the screen's "Sleep so far" (sleep/live_log.dart, DECISIONS 640-649).
NightScorer nightScorer(String recordingsDir) => NightScorer(
  model: () => RunsLiveModel(
    open: (run) => OnnxStageRun.open(run, modelsDir: modelsDirFor(recordingsDir)),
    closeRun: (run) => (run as OnnxStageRun).close(),
  ),
  log: LiveStageLog(liveStagesDirFor(recordingsDir)),
);

/// The smart alarm in the recorder's isolate: the night's live model ([scorer]), the early ring through the phone's
/// alarm, the record beside the recordings.
AlarmWatch Function(AlarmPlan plan) smartAlarmFor(String recordingsDir, NightScorer scorer) =>
    (plan) => smartAlarm(recordingsDir, plan, scorer);

LiveAlarm smartAlarm(String recordingsDir, AlarmPlan plan, NightScorer scorer) =>
    LiveAlarm(plan: plan, scorer: scorer, bell: ChannelAlarmBell(), store: AlarmStore(alarmsDirFor(recordingsDir)));

/// Tonight's lucid dream cues in the recorder's isolate when they are on: the night's live model ([scorer]), the
/// phone's media player (DECISIONS 303).
CueFactory lucidCuesWith(String recordingsDir, NightScorer scorer) =>
    lucidCuesFor(recordingsDir, scorer: scorer, bell: ChannelCueBell());

/// Tonight's sound cues, one kind a night: the lucid dream cues when they are on, else the memory cues when they are on
/// (DECISIONS 303, 507); both listen to the night's live model ([scorer]) and play through the phone's media player.
CueFactory nightCuesWith(String recordingsDir, NightScorer scorer) => oneKindANight([
  lucidCuesWith(recordingsDir, scorer),
  memoryCuesFor(recordingsDir, scorer: scorer, bell: ChannelCueBell()),
]);

Future<NightState> loadNight() async => _PrefsNightStore().load();

/// The saved night with a recording that ended without a Stop put right (spans/after_restart.dart): call only while
/// the service does not run. True in the second place: a recording was just ended that way.
Future<(NightState, bool)> loadEndedNight(String? recordingsDir) async {
  final store = _PrefsNightStore();
  final s = await store.load();
  if (recordingsDir == null) return (s, false);
  try {
    final fixed = endedWithoutStop(s, Directory(recordingsDir));
    if (fixed == null) return (s, false);
    await store.save(fixed);
    return (fixed, true);
  } catch (_) {
    return (s, false);
  }
}

@pragma('vm:entry-point')
void recorderEntryPoint() {
  // this engine's log and battery samples while it lives, which is the night (lib/logs, DECISIONS 715)
  EngineRecords.start(engine: 'recorder', recordingsDir: Phone.recordingsDir, power: Phone.powerMap);
  FlutterForegroundTask.setTaskHandler(RecorderTaskHandler());
}

class RecorderTaskHandler extends TaskHandler {
  RecorderTaskHandler({
    this.finder,
    this.alarm = smartAlarmFor,
    this.cues = nightCuesWith,
    this.wifiEvery = wifiWatchEvery,
  });

  /// Only for smoke tests (a replayed headband); null: the BrainBit.
  final HeadbandFinder Function()? finder;

  /// The smart alarm for the recordings folder and the night's live model (a smoke test watches its own).
  final AlarmWatch Function(AlarmPlan plan) Function(String recordingsDir, NightScorer scorer) alarm;

  /// The sound cues for the recordings folder and the night's live model (a smoke test brings their hours forward).
  final CueFactory Function(String recordingsDir, NightScorer scorer) cues;

  /// How often the phone's Wi-Fi is looked at for the night's log (tests look more often).
  final Duration wifiEvery;
  NightRecorder? _recorder;
  BrainBitFinder? _finder;
  Phase? _shownPhase;
  int _shownAtMs = 0;
  bool _stopping = false;

  /// Share on Wi-Fi. Everything about it goes through [_sharing], which swallows every error: the recorder
  /// above never waits for it and never sees it fail.
  ShareHost? _share;
  String? _filesDir;

  /// The DIY board's night (DECISIONS rows 360-369), or null for the BrainBit.
  DiyNight? _diy;

  /// Why this engine holds the Wi-Fi lock (as `recorder`; one lock for the process, PhoneChannel.kt): the DIY board's
  /// datagrams, Share on Wi-Fi.
  bool _wifiDiy = false, _wifiShare = false;

  /// The phone's Wi-Fi in the night's log, from the start to Stop (wifi_watch.dart, DECISIONS 611).
  WifiWatch? _wifiWatch;

  /// Lights off and Alarm off that came before the recorder existed (the first moments of a start): handed to it as
  /// soon as it is made, so a tap the screen already shows as done is never lost.
  DateTime? _lightsOffEarly;
  bool _alarmOffEarly = false;

  /// The Signal view's night tap (lib/signal/live_tap.dart, DECISIONS 595): while the screen renews its lease, the
  /// batches the recorder saves go to the screen too, every 100 ms. The recording never waits for it.
  final NightTapSender _tap = NightTapSender(send: FlutterForegroundTask.sendDataToMain);
  Timer? _tapTimer;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    unawaited(logAppStart('recorder')); // files/app-starts.log (DECISIONS 734)
    final rec = await _recordingsDir();
    final plan = await _alarmPlan();
    final auto = await _autoNotes();
    final sleep = await _startsWithSleep();
    // Stop (or the system's destroy) came while this was starting: it has been answered; no night starts after it.
    if (_stopping) return;
    final diy = _diy = this.finder == null ? diyNightFor(rec) : null;
    final dir = diy?.dir.path ?? rec;
    _filesDir = Directory(rec).parent.path;
    final HeadbandFinder finder;
    if (this.finder != null) {
      finder = this.finder!();
    } else {
      final b = diy == null ? BrainBitFinder(recorder: true) : BrainBitFinder(pick: () async => diy.finder());
      _finder = b;
      finder = b;
    }
    // the night's one live sleep model: none for the DIY board (it reads BrainBit's O1 O2 T3 T4), so neither the smart
    // alarm's model nor the sound cues run with it
    final scorer = diy == null ? nightScorer(rec) : null;
    final recorder = NightRecorder(
      finder: finder,
      dir: Directory(dir),
      store: _PrefsNightStore(),
      probe: ChannelPhoneProbe(),
      // the phone's step counter in the log once a minute, when the owner switched it on (DECISIONS 800-809)
      stepProbe: ChannelStepProbe(StepSettings(stepsDirFor(rec))),
      onStatus: _onStatus,
      onStuck: _restartProcess,
      timing: diy == null ? const RecorderTiming() : diyRecorderTiming,
      // the owner's hands-free double clench, read when the detector starts (DECISIONS 247); none of the BrainBit's
      // detectors for the DIY board (they read O1 O2 T3 T4)
      watch: diy == null ? () => LiveDrift(handsFree: nightGestures(Directory(rec).parent)) : null,
      // one live sleep model for the smart alarm and the sound cues, fed by the recorder (DECISIONS 330)
      scorer: scorer,
      alarmPlan: plan,
      alarm: scorer == null ? null : alarm(rec, scorer),
      // the lucid dream cues or the memory cues, one kind a night: the shared model, the phone's media player
      // (DECISIONS 303, 507); neither in a night the headband watcher started (DECISIONS 604)
      cues: scorer == null || auto != null ? null : cues(rec, scorer),
      startNotes: [...?diy?.notes, if (starter != TaskStarter.system) ...?auto],
      spanLog: SpanLog(spansDirFor(rec)),
      // a sleep started later gets a model of its own: a closed one is not started again
      kit: diy != null
          ? null
          : () {
              final s = nightScorer(rec);
              return (scorer: s, alarm: alarm(rec, s), cues: cues(rec, s));
            },
      onGiveUp: () => unawaited(_giveUp()),
      sleep: sleep,
      sleepSource: auto != null ? 'auto_start' : 'owner_button',
    );
    _recorder = recorder;
    // what this night runs, for the battery samples and the usage log (lib/logs/activity.dart, DECISIONS 715)
    Activity.begin('night');
    if (scorer != null) Activity.begin('live-model');
    if (scorer != null && auto == null) Activity.begin('cues');
    Metrics.band = () {
      final st = _recorder?.status;
      return st == null ? null : {'battery': st.battery, 'rssi': st.rssi, 'phase': st.phase.name};
    };
    // into the night's log, and logcat (tag flutter) for a look at the phone the next morning
    _wifiWatch = WifiWatch(
      read: Phone.wifiState,
      log: (line) {
        recorder.note(line);
        debugPrint('eeg_tracker $line');
      },
      every: wifiEvery,
    )..start();
    final early = _lightsOffEarly;
    if (early != null) recorder.lightsOff(at: early);
    if (_alarmOffEarly) recorder.alarmOff();
    if (diy != null) {
      // the board's datagrams keep arriving with the screen off
      _wifiDiy = true;
      unawaited(_wifi());
    }
    unawaited(recorder.run(restartedBySystem: starter == TaskStarter.system));
    unawaited(_sharing(() async => _applyShare(await loadShareConfig())));
  }

  Future<void> _wifi() async {
    try {
      await Phone.wifiLock(on: _wifiDiy || _wifiShare, who: 'recorder').timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Every step goes after the one before it (a switch moved on, off and on again within seconds must leave one
  /// server, the last one asked for, and none that nobody can stop); none waits longer than 10 s for the one before.
  Future<void> _sharing(Future<void> Function() what) =>
      _shareSteps = _shareSteps.then((_) => what().timeout(const Duration(seconds: 10))).catchError((Object _) {});
  Future<void> _shareSteps = Future<void>.value();

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
      wifiLock: (on) {
        _wifiShare = on;
        return _wifi();
      },
      wifi: Phone.wifiNets,
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
      } else {
        _lightsOffEarly = DateTime.now();
      }
    } else if (data is Map && data['kind'] == 'share') {
      unawaited(_sharing(() => _applyShare(ShareConfig.fromJson(data['config']))));
    } else if (data == alarmOffCommand) {
      final r = _recorder;
      if (r != null) {
        r.alarmOff();
        _send(r.status);
      } else {
        _alarmOffEarly = true;
      }
    } else if (data is Map && data['kind'] == 'sleep') {
      unawaited(_sleepCommand(data));
    } else if (data is Map && data['kind'] == 'span') {
      _spanCommand(data);
    } else if (nightTapLeaseFrom(data) case final on?) {
      _signalTap(on: on);
    }
  }

  Future<void> _sleepCommand(Map<Object?, Object?> data) async {
    final r = _recorder;
    if (r == null || _stopping) return;
    if (data['op'] == 'start') {
      AlarmPlan? plan;
      try {
        plan = data['alarm'] == null ? null : AlarmPlan.fromJson(data['alarm']);
      } catch (_) {}
      final kind = data['span_kind'];
      r.startSleep(kind: kind is String && kind.isNotEmpty ? kind : 'sleep', plan: plan);
      Activity.begin('live-model');
    } else if (data['op'] == 'stop') {
      await r.stopSleep();
      Activity.set('live-model', on: false);
      Activity.set('cues', on: false);
    }
    _send(r.status);
  }

  /// Hours without the headband: the recording is ended as by Stop, and the service goes.
  Future<void> _giveUp() async {
    await _stop(endNight: true);
    FlutterForegroundTask.sendDataToMain(gaveUpMessage);
    await FlutterForegroundTask.stopService();
  }

  void _spanCommand(Map<Object?, Object?> data) {
    final r = _recorder;
    if (r == null || _stopping) return;
    final kind = data['span_kind'], id = data['id'], by = data['by'], session = data['session'];
    if (data['op'] == 'open' && kind is String && kind.isNotEmpty) {
      r.openSpan(kind, session: session is String ? session : null);
    } else if (data['op'] == 'close' && id is String) {
      r.closeSpan(id, by: by is String ? by : 'owner');
    }
    _send(r.status);
  }

  /// The Signal view took or renewed its lease ([on]), or let it go.
  void _signalTap({required bool on}) {
    _tap.lease(on: on && !_stopping);
    if (!_tap.on) return _endTap();
    ChunkWriter.onLive = _tap.add;
    _tapTimer ??= Timer.periodic(nightTapEvery, (_) => _tap.on ? _tap.flush() : _endTap());
  }

  void _endTap() {
    ChunkWriter.onLive = null;
    _tapTimer?.cancel();
    _tapTimer = null;
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Destroyed without the screen's Stop (system kill, timeout): keep the night for the restart.
    await _stop(endNight: false);
  }

  Future<void> _stop({required bool endNight}) async {
    if (_stopping) return;
    _stopping = true;
    _endTap();
    _wifiWatch?.stop();
    final r = _recorder;
    // Sharing in the background: its port is free again within about 4 s, while the recorder saves and stops.
    unawaited(_sharing(() async => _share?.stop()));
    await r?.stop(endNight: endNight);
    // The scanner kept for direct reconnects goes too, unless a headband was left out of range (the DIY board's
    // listener always goes).
    _finder?.dispose(anyLost: r == null || !r.finished || r.abandoned.isNotEmpty);
    if (_wifiDiy) {
      _wifiDiy = false;
      await _wifi();
    }
    FlutterForegroundTask.sendDataToMain(stoppedMessage);
    Metrics.band = null;
    for (final f in const ['headband', 'cues', 'live-model', 'night']) {
      Activity.set(f, on: false);
    }
  }

  void _onStatus(RecorderStatus s) {
    _send(s);
    Activity.set('headband', on: s.phase == Phase.recording); // streaming from the headband (DECISIONS 715)
    final now = DateTime.now().millisecondsSinceEpoch;
    _share?.setLive(s.toMap(nowMs: now));
    if (s.phase != _shownPhase || now - _shownAtMs >= 10000) {
      _shownPhase = s.phase;
      _shownAtMs = now;
      unawaited(
        FlutterForegroundTask.updateService(notificationText: notificationText(s, _share?.status, _diy != null)),
      );
    }
  }

  void _send(RecorderStatus s) =>
      FlutterForegroundTask.sendDataToMain(s.toMap(nowMs: DateTime.now().millisecondsSinceEpoch));

  Future<void> _restartProcess(String reason) => restartAppProcess();

  static Future<AlarmPlan?> _alarmPlan() async {
    try {
      final raw = await FlutterForegroundTask.getData<String>(key: _alarmKey);
      return raw == null ? null : AlarmPlan.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _startsWithSleep() async {
    try {
      return await FlutterForegroundTask.getData<String>(key: _sleepKey) != '0';
    } catch (_) {
      return true;
    }
  }

  /// The watcher's lines when it started this night; null for a start by hand.
  static Future<List<String>?> _autoNotes() async {
    try {
      final raw = await FlutterForegroundTask.getData<String>(key: _autoKey);
      final j = raw == null ? null : jsonDecode(raw);
      return j is List ? [for (final x in j) '$x'] : null;
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

/// The SDK is wedged (night_recorder.dart `onStuck`): the service is started again in 5 s and this process ends.
/// The native call arms the restart alarm and answers at once; it ends the process itself 300 ms later
/// (`Process.killProcess`, PhoneChannel.kt). Dart's own `exit` (which runs the native exit handlers while the
/// engine's and the SDK's threads still run) comes only if the process is still alive [grace] later, or at once when
/// the native call failed. [restart] and [exitProcess] are the phone's and Dart's; tests pass their own.
@visibleForTesting
Future<void> restartAppProcess({
  Future<void> Function(int delayMs) restart = Phone.restartProcess,
  void Function(int code) exitProcess = exit,
  Duration grace = const Duration(seconds: 2),
}) async {
  try {
    await restart(5000).timeout(const Duration(seconds: 5));
    await Future<void>.delayed(grace);
  } catch (_) {}
  exitProcess(3); // reached only if the native call could not end the process
}

/// The notification's line; while sharing is on it says so, with the address. [diy]: the DIY board's words.
String notificationText(RecorderStatus s, [ShareStatus? share, bool diy = false]) {
  final line = diy ? _diyText(s) : _phaseText(s);
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

String _diyText(RecorderStatus s) {
  final minutes = s.minutesRecorded.floor();
  return switch (s.phase) {
    Phase.recording => 'Recording the DIY board · $minutes min · not EEG',
    Phase.searching || Phase.connecting || Phase.checkingContact => 'Listening for the DIY board',
    Phase.reconnecting => 'Listening for the DIY board · $minutes min saved',
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
