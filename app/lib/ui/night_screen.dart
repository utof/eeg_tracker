// The app's one screen: start and stop the night, see that it is being recorded, fix phone settings.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../alarm/bell.dart';
import '../alarm/notes.dart';
import '../alarm/rule.dart' show AlarmPlan;
import '../dream/store.dart';
import '../export/store.dart';
import '../headband/diy/settings.dart';
import '../phone.dart';
import 'experiments_screen.dart' show currentExperiment;
import 'experiments_view.dart' show experimentLine;
import '../morning/store.dart';
import '../nap/store.dart';
import '../recorder/headband.dart';
import '../recorder/nights.dart';
import '../recorder/packed.dart' show packInBackground, packOldRecordings;
import '../recorder/recorder_service.dart';
import '../recorder/status.dart';
import '../session_keeper.dart' show KeepSpec, PhoneSessionKeeper;
import '../share/control.dart';
import '../share/isolate.dart' show shareAddress;
import '../sleep/onnx_runs.dart';
import '../sleep/report.dart';
import '../sleep/scorer.dart';
import 'alarm_view.dart';
import '../sharp/prompts.dart' show ChannelSharpPhone;
import '../study/arm.dart' show rearmPrompts;
import 'dream_screen.dart';
import 'dream_view.dart' show clock;
import 'evidence_sheet.dart' show showEvidence;
import 'export_screen.dart';
import 'hands_free_screen.dart' show SettingsScreen;
import 'lights_off_view.dart';
import 'meditation_screen.dart';
import 'lucid_screen.dart';
import 'memory_cues_screen.dart';
import 'nap_screen.dart';
import 'nap_view.dart' show endWords;
import 'morning_screen.dart';
import 'morning_section.dart';
import 'nearby.dart';
import 'own_ble_screen.dart' show phoneWifiAddress;
import 'night_strip.dart';
import 'night_view.dart';
import 'phone_checks.dart';
import 'pair_dialog.dart';
import 'share_sheet.dart';
import 'sleep_report_screen.dart';
import 'sleep_scoring.dart';
import 'states_screen.dart';
import 'work_screen.dart';
import 'theme.dart';
import 'trends_screen.dart';

const String _xiaomiDoneKey = 'xiaomiChecked';

/// Title, sentence and tone for the status block. Pure, so it is tested without a phone. [diy]: the DIY board is
/// chosen (its words, and this phone's Wi-Fi address for them).
({String title, String sentence, Tone tone}) describeNight({
  required RecorderStatus? status,
  required bool running,
  required int nowMs,
  required int quietMs,
  NightState? last,
  ({String? address})? diy,
}) {
  if (diy != null) {
    final words = _diyWords(status: status, running: running, nowMs: nowMs, quietMs: quietMs, address: diy.address);
    if (words != null) return words;
  }
  if (!running) {
    final hadNight = last != null && last.samples > 0;
    return (
      title: 'Ready',
      sentence: hadNight
          ? 'Last night is saved. Put the headband on to start a new one.'
          : 'Put the headband on and switch it on, then start the night.',
      tone: Tone.calm,
    );
  }
  final s = status;
  if (s == null) return (title: 'Starting', sentence: 'Waiting for the recorder.', tone: Tone.calm);
  if (quietMs > 15000) {
    return (
      title: 'Not answering',
      sentence: 'The recorder has not reported for ${quietMs ~/ 1000} s. What it recorded so far is saved.',
      tone: Tone.problem,
    );
  }
  final note = s.note;
  switch (s.phase) {
    case Phase.searching:
    case Phase.reconnecting:
      final first = s.phase == Phase.searching;
      if (note.startsWith('cannot write')) {
        return (
          title: 'Cannot save',
          sentence: 'The phone refused to write the files. Is storage full?',
          tone: Tone.problem,
        );
      }
      if (note.contains('stuck')) {
        return (
          title: 'Restarting',
          sentence: 'Bluetooth got stuck, so the recorder restarts itself.',
          tone: Tone.caution,
        );
      }
      if (note.contains('not found')) {
        return (
          title: first ? 'Searching' : 'Reconnecting',
          sentence: 'Headband not found yet. Is it switched on and charged? The app keeps looking.',
          tone: Tone.caution,
        );
      }
      if (note.startsWith('could not connect')) {
        return (
          title: first ? 'Searching' : 'Reconnecting',
          sentence: 'Could not connect. Trying again.',
          tone: Tone.caution,
        );
      }
      return first
          ? (title: 'Searching', sentence: 'Looking for the headband.', tone: Tone.calm)
          : (
              title: 'Reconnecting',
              sentence: 'The headband dropped out. Everything recorded is saved; looking for it again.',
              tone: Tone.caution,
            );
    case Phase.connecting:
      return (title: 'Connecting', sentence: 'Found the headband. Connecting.', tone: Tone.calm);
    case Phase.checkingContact:
      return (title: 'Checking contact', sentence: 'Keep still for a few seconds.', tone: Tone.calm);
    case Phase.recording:
      final age = s.lastDataMs == null ? null : (nowMs - s.lastDataMs!) ~/ 1000;
      if (age == null || age < 5) {
        return (title: 'Recording', sentence: 'All is well. You can put the phone down.', tone: Tone.live);
      }
      if (age < 40) {
        return (
          title: 'Recording',
          sentence: 'No data for $age s. The recorder is restarting the stream.',
          tone: Tone.caution,
        );
      }
      return (title: 'No data', sentence: 'No data for $age s. The recorder will reconnect.', tone: Tone.problem);
    case Phase.stopping:
      return (title: 'Stopping', sentence: 'Saving the files.', tone: Tone.calm);
    case Phase.idle:
      return (title: 'Stopped', sentence: 'The recorder has stopped.', tone: Tone.calm);
  }
}

/// The DIY board's words where they differ from the headband's; null: the headband's words fit.
({String title, String sentence, Tone tone})? _diyWords({
  required RecorderStatus? status,
  required bool running,
  required int nowMs,
  required int quietMs,
  required String? address,
}) {
  final at = address ?? 'this phone';
  if (!running) {
    return (
      title: 'Ready',
      sentence: 'Start the board and answer its prompts, then start the night. It sends to $at over Wi-Fi.',
      tone: Tone.calm,
    );
  }
  final s = status;
  if (s == null || quietMs > 15000) return null;
  final note = s.note;
  switch (s.phase) {
    case Phase.searching:
    case Phase.reconnecting:
      if (note.startsWith('cannot write') || note.contains('stuck')) return null;
      if (note.startsWith('could not connect: ')) {
        return (title: 'Listening', sentence: note.substring('could not connect: '.length), tone: Tone.caution);
      }
      if (note.contains('not found')) {
        return (
          title: 'Listening',
          sentence: 'No frames from the board yet. Is it on this Wi-Fi, sending to $at, and past its prompts? The app '
              'keeps listening.',
          tone: Tone.caution,
        );
      }
      return s.phase == Phase.searching
          ? (title: 'Listening', sentence: 'Waiting for the board\'s frames on UDP port 9000.', tone: Tone.calm)
          : (
              title: 'Listening',
              sentence: 'The board stopped or restarted. Everything recorded is saved; a new file set starts when its '
                  'frames come back.',
              tone: Tone.caution,
            );
    case Phase.connecting:
    case Phase.checkingContact:
      return (title: 'Board found', sentence: 'Its frames are arriving.', tone: Tone.calm);
    case Phase.recording:
      final age = s.lastDataMs == null ? null : (nowMs - s.lastDataMs!) ~/ 1000;
      if (age == null || age < 5) {
        final b = s.board;
        final what = switch (b?.mode) {
          'test' => 'the board\'s test signal',
          'short' => 'the board\'s shorted inputs',
          'synthetic' => 'made-up data from the board',
          _ => 'the board',
        };
        return (
          title: 'Recording',
          sentence: b == null || b.notEeg ? 'Recording $what. It is not EEG.' : 'Recording $what.',
          tone: Tone.live,
        );
      }
      if (age < 40) {
        return (title: 'Recording', sentence: 'No frames for $age s. Is the board still sending?', tone: Tone.caution);
      }
      return (title: 'No data', sentence: 'No frames for $age s. A new file set starts when they come back.', tone: Tone.problem);
    case Phase.stopping:
    case Phase.idle:
      return null;
  }
}

class NightScreen extends StatefulWidget {
  const NightScreen({super.key, this.links});

  /// Where a laptop's pair link arrives (pair_dialog.dart); null = the app's channel.
  final PairInbox? links;

  @override
  State<NightScreen> createState() => _NightScreenState();
}

class _NightScreenState extends State<NightScreen> with WidgetsBindingObserver {
  RecorderStatus? _status;
  int? _statusAtMs;
  int _resumedAtMs = DateTime.now().millisecondsSinceEpoch;
  bool _running = false;
  bool _busy = false;
  PhoneSnapshot _phone = const PhoneSnapshot({});
  bool _nearby = true;
  bool _xiaomiDone = false;
  NightState? _last;
  String? _dir;
  List<NightFiles> _nights = const [];
  Timer? _clock;
  int _ticks = 0;
  Completer<void>? _stopped;
  SleepScoring? _scoring;
  int? _lightsOffSentMs;
  String? _dreamLine;
  String? _napLine;
  String? _lucidLine;
  String? _memoryLine;
  String? _checkedInAt, _experiment, _unusual;
  Pending? _pending;
  AlarmSetup _alarm = const AlarmSetup();
  AlarmClockState _clockState = const AlarmClockState({});

  /// "Headband: DIY board (test)" (DECISIONS rows 360-369), and this phone's Wi-Fi address for its words.
  DiyBoardSettings _diy = const DiyBoardSettings();
  String? _address;

  /// Share on Wi-Fi (DECISIONS rows 220-229): the setting, and the app's own server between nights.
  late final ShareControl _share = ShareControl(
    load: loadShareConfig,
    save: saveShareConfig,
    sendToRecorder: FlutterForegroundTask.sendDataToTask,
    keepScreenOn: (on) => Phone.keepScreenOn(on: on),
    keepAlive: (on, offAtMs) => PhoneSessionKeeper.keepInBackground(
      on ? KeepSpec(title: 'Sharing on Wi-Fi', text: shareKeepText(offAtMs), focus: false) : null,
      onStop: () => unawaited(_share.setOn(false)),
    ),
  )..addListener(_onScoring);

  /// Pairing with a laptop by one scan (DECISIONS rows 530-539): its QR code opens the app with a pair link.
  late final PairInbox _links = widget.links ?? ChannelPairInbox();
  bool _pairing = false;

  bool get _front => ModalRoute.of(context)?.isCurrent ?? true;

  String? get _filesDir => _dir == null ? null : Directory(_dir!).parent.path;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {}); // data age and the current half hour move on
      if (++_ticks % 5 == 0) unawaited(_refreshRunning());
      // Its time may be up, or Android may have ended the recorder: once a minute is enough.
      if (_ticks % 60 == 0) unawaited(_share.sync(night: _running, filesDir: _filesDir, front: _front));
      // the phone's alarm: is it ringing (the wake face), was "I'm awake" tapped elsewhere
      if (_ticks % 2 == 0 && (_running || _clockState.endMs != null)) unawaited(_refreshAlarm());
    });
    unawaited(_refresh());
    _links.onOpen = () => unawaited(_takeLink());
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_takeLink()));
  }

  Future<void> _takeLink() async {
    if (_pairing) return;
    _pairing = true;
    try {
      final raw = await _links.take();
      if (raw != null && mounted) await confirmPairing(context, raw, (link) => _share.pair(link));
    } catch (_) {
      // no channel (tests, a desktop harness): nothing to open
    } finally {
      _pairing = false;
    }
  }

  @override
  void dispose() {
    _scoring?.removeListener(_onScoring);
    _links.onOpen = null;
    _share.dispose();
    _clock?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumedAtMs = DateTime.now().millisecondsSinceEpoch;
      unawaited(_refresh());
    }
  }

  void _onData(Object data) {
    if (data is Map && data['kind'] == 'stopped') {
      _stopped?.complete();
      return;
    }
    final shared = shareStatusFrom(data);
    if (shared != null) {
      _share.onRecorderStatus(shared);
      return;
    }
    final s = RecorderStatus.fromMap(data);
    if (s == null || !mounted) return;
    setState(() {
      _status = s;
      _statusAtMs = DateTime.now().millisecondsSinceEpoch;
    });
  }

  /// Why the night's sleep scoring must not run now, or null.
  String? _scoringStop({bool? running}) {
    if (running ?? _running) return 'a night records';
    if (dreamSessionRunning || soundSessionRunning || napSessionRunning || PhoneSessionKeeper.held) {
      return 'a session runs';
    }
    return null;
  }

  void _onScoring() {
    if (mounted) setState(() {});
  }

  /// The newest night's report, or what the scorer is doing; a stopped scoring of a newer night comes first.
  SleepSummary? _sleepSummary() {
    final sc = _scoring;
    if (sc == null) return null;
    if (sc.night != null) return SleepSummary(nightOf: sc.night!, scoringStep: sc.step ?? 'Starting');
    final reports = sc.reports;
    final newest = reports.isEmpty ? null : reports.first;
    final stuck = sc.blocked.keys.toList()..sort();
    if (stuck.isNotEmpty && (newest == null || stuck.last.compareTo(newest.nightOf) >= 0)) {
      return SleepSummary(nightOf: stuck.last, blocked: sc.blocked[stuck.last]);
    }
    if (newest == null) return null;
    return SleepSummary(
      nightOf: newest.nightOf,
      scored: newest.scored,
      asleepMin: newest.asleepMin,
      periods: newest.periods.length,
    );
  }

  Future<void> _openSleep(String nightOf) async {
    final sc = _scoring;
    if (sc == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SleepReportScreen(scoring: sc, nightOf: nightOf),
      ),
    );
  }

  Future<void> _refreshRunning() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted && running != _running) setState(() => _running = running);
  }

  /// Packs the raw recordings nothing has written for a day (DECISIONS 540-549), after the sleep scorer: between
  /// nights, one file at a time off the screen's thread. It stops before the next file as soon as a night or a session
  /// records, the scorer runs again, the app leaves the screen or another page is in front. One run at a time.
  static Future<void>? _packing;

  void _packOld(String dir) {
    _packing ??= packOldRecordings(Directory(dir).parent, busy: _packingMustWait, pack: packInBackground)
        .then((run) {
          if (run.failed.isNotEmpty) debugPrint('packing: ${run.failed.length} not packed: ${run.failed.first.$2}');
        })
        .whenComplete(() => _packing = null);
  }

  Future<bool> _packingMustWait() async {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return true;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return true;
    if (nightScoringBusy || dreamSessionRunning || soundSessionRunning || napSessionRunning || workSessionRunning) {
      return true;
    }
    return FlutterForegroundTask.isRunningService;
  }

  Future<void> _refresh() async {
    final phone = await _safe(Phone.snapshot, const PhoneSnapshot({}));
    final nearby = await nearbyAllowed(phone.sdkInt);
    final running = await FlutterForegroundTask.isRunningService;
    final last = await loadNight();
    final xiaomiDone = await FlutterForegroundTask.getData<bool>(key: _xiaomiDoneKey) ?? false;
    final dir = _dir ?? await _safe<String?>(Phone.recordingsDir, null);
    final nights = dir == null || running ? const <NightFiles>[] : _listNights(dir);
    final checkedInAt = dir == null ? null : _checkedInToday(dir);
    final alarm = dir == null ? const AlarmSetup() : AlarmSetupStore.forRecordings(dir).read();
    final diy = _readDiy(dir);
    final address = diy.useDiy ? await phoneWifiAddress() : null;
    final clockState = await _safe(AlarmClock.state, const AlarmClockState({}));
    if (running) FlutterForegroundTask.sendDataToTask(statusCommand);
    if (dir != null && _scoring == null) {
      _scoring = SleepScoring(
        SleepScorer(
          recordingsDir: Directory(dir),
          store: NightReportStore(nightsDirFor(dir)),
          openRun: (run) => OnnxStageRun.open(run, modelsDir: modelsDirFor(dir), threads: nightScoringThreads),
          closeRun: (run) => (run as OnnxStageRun).close(),
          log: debugPrint,
        ),
        stopFor: _scoringStop,
        waitFor: () => _share.copying ? 'the laptop copies files' : null,
      )..addListener(_onScoring);
    }
    // Last night is scored on the phone once it has ended (DECISIONS rows 97 and 583): a short while after the app
    // opens, never while a night records or a session runs; it goes on from where it stopped. Then the recordings
    // nothing has written for a day are packed (DECISIONS 540-549).
    if (_scoringStop(running: running) == null) {
      _scoring?.runSoon(then: dir == null ? null : () => _packOld(dir));
    }
    final dreamLine = dir == null ? null : _lastDream(dir);
    final napLine = dir == null ? null : _lastNap(dir);
    final lucidLine = dir == null ? null : lucidNightLine(dir);
    final memoryLine = dir == null ? null : memoryNightLine(dir);
    final pending = dir == null || running ? null : await _pendingExport(dir);
    String? experiment;
    try {
      experiment = dir == null ? null : experimentLine(currentExperiment(dir, DateTime.now()));
    } catch (_) {
      // a line of text is never worth breaking the night screen
    }
    final unusual = dir == null || running ? null : await _unusualLine(dir);
    // the sharp-hours questions (DECISIONS row 283): the moments ahead, handed to the phone at every start and return
    if (dir != null) unawaited(rearmPrompts(dir, ChannelSharpPhone(), DateTime.now()).catchError((Object _) {}));
    await _share.sync(night: running, filesDir: dir == null ? null : Directory(dir).parent.path, front: _front);
    if (!mounted) return;
    setState(() {
      _nights = nights;
      _phone = phone;
      _nearby = nearby;
      _running = running;
      _last = last;
      _xiaomiDone = xiaomiDone;
      _dir = dir;
      _dreamLine = dreamLine;
      _napLine = napLine;
      _lucidLine = lucidLine;
      _memoryLine = memoryLine;
      _checkedInAt = checkedInAt;
      _experiment = experiment;
      _unusual = unusual;
      _pending = pending;
      _alarm = alarm;
      _clockState = clockState;
      _diy = diy;
      _address = address;
    });
  }

  static DiyBoardSettings _readDiy(String? dir) {
    try {
      return dir == null ? const DiyBoardSettings() : DiyBoardStore(diyBoardDirFor(dir)).load();
    } catch (_) {
      return const DiyBoardSettings();
    }
  }

  Future<void> _refreshAlarm() async {
    final st = await _safe(AlarmClock.state, _clockState);
    if (mounted) setState(() => _clockState = st);
  }

  /// The alarm line's button: the setup sheet between nights, Turn off for a phone alarm left from a stopped night,
  /// Alarm off during a night (it asks first).
  Future<void> _onAlarm() async {
    final dir = _dir;
    if (_running) {
      final end = _status?.alarm?.endMs ?? _clockState.endMs;
      if (end == null || !await confirmAlarmOff(context, end)) return;
      await _safe(AlarmClock.cancel, _clockState);
      FlutterForegroundTask.sendDataToTask(alarmOffCommand);
      unawaited(_refreshAlarm());
      return;
    }
    if (_pendingClock) {
      await _safe(AlarmClock.cancel, _clockState);
      unawaited(_refreshAlarm());
      return;
    }
    final next = await showAlarmSheet(context, _alarm, onInfo: () => showEvidence(context, 'smart-alarm'));
    if (next == null || !mounted) return;
    setState(() => _alarm = next);
    try {
      if (dir != null) AlarmSetupStore.forRecordings(dir).write(next);
    } catch (e) {
      _say('The alarm setting could not be saved: $e');
    }
  }

  Future<void> _awake() async {
    final st = await _safe(AlarmClock.awake, _clockState);
    if (mounted) setState(() => _clockState = st);
  }

  /// A phone alarm still set from a night that was stopped before it rang.
  bool get _pendingClock {
    final end = _clockState.endMs;
    return !_running && end != null && end > DateTime.now().millisecondsSinceEpoch && _clockState.awakeMs == null;
  }

  /// Sets the phone's alarm for tonight (before the recorder starts, so it rings whatever happens to the recorder)
  /// and says what on the phone could stop it; returns the plan for the recorder, or null without one.
  Future<AlarmPlan?> _setAlarmClock(String? dir) async {
    final plan = _alarm.planAt(DateTime.now());
    if (plan == null) {
      if (_pendingClock) await _safe(AlarmClock.cancel, _clockState);
      return null;
    }
    try {
      if (dir != null) await writeWakeNotes(dir);
    } catch (_) {
      // without the notes file the ringer uses the phone's own alarm sound
    }
    try {
      final st = await AlarmClock.schedule(plan);
      _clockState = st;
      final at = DateTime.fromMillisecondsSinceEpoch(plan.endMs);
      final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
      if (!st.exact) {
        _say('The phone does not allow exact alarms, so it may ring a few minutes after $hm. Allow "Alarms & '
            'reminders" for EEG Tracker in the phone\'s settings.');
        await AlarmClock.openSetting('exact');
      } else if (st.silent) {
        _say('The phone\'s alarm volume is off: turn it up, or the alarm at $hm will be silent.');
      } else if (!st.fullScreen) {
        _say('The alarm will ring, but cannot show "I\'m awake" over the lock screen: allow full-screen '
            'notifications for EEG Tracker.');
        await AlarmClock.openSetting('fullScreen');
      }
    } catch (e) {
      _say('The phone\'s alarm could not be set ($e). Set one in the Clock app.');
    }
    return plan;
  }

  /// The "Unusual for you" line, only while there is a card (DECISIONS 290-299), worked out off the screen's thread.
  static Future<String?> _unusualLine(String dir) async {
    try {
      return await Isolate.run(() => unusualToday(dir, DateTime.now()).mainLine);
    } catch (_) {
      return null; // a line of text is never worth breaking the night screen
    }
  }

  /// What the next export would copy (sizes and times only), read off the screen's thread.
  static Future<Pending?> _pendingExport(String dir) async {
    final files = Directory(dir).parent.path;
    try {
      return await Isolate.run(() => pendingExport(Directory(files)));
    } catch (_) {
      return null;
    }
  }

  /// The nap coach's newest nap in a line, when it is under a day old.
  static String? _lastNap(String dir) {
    try {
      final naps = NapStore(napDirFor(dir)).list();
      if (naps.isEmpty) return null;
      final s = naps.first;
      if (DateTime.now().difference(s.start) > const Duration(hours: 24)) return null;
      return 'Last nap: ${nightLabel(s.start)} ${clock(s.start)}, ${s.lengthMin} min, ${endWords(s)}.';
    } catch (_) {
      return null;
    }
  }

  /// The dream catcher's newest session in a line, when it is under a day old.
  static String? _lastDream(String dir) {
    try {
      final sessions = DreamStore(dreamDirFor(dir)).list();
      if (sessions.isEmpty) return null;
      final s = sessions.first;
      if (DateTime.now().difference(s.start) > const Duration(hours: 24)) return null;
      final n = s.answers;
      return 'Last session: ${n == 1 ? '1 answer' : '$n answers'}, ${nightLabel(s.start)} ${clock(s.start)}.';
    } catch (_) {
      return null;
    }
  }

  static String? _checkedInToday(String dir) {
    try {
      return checkedInTodayAt(MorningStore(morningsDirFor(dir)).list(), DateTime.now());
    } catch (_) {
      return null;
    }
  }

  static Future<T> _safe<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }

  Future<bool> _requestNearby() => requestNearby(_phone.sdkInt);

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      // the DIY board comes over Wi-Fi: no Bluetooth needed, but a Wi-Fi address the board can send to
      final diy = _readDiy(_dir).useDiy;
      if (diy) {
        if (await phoneWifiAddress() == null) {
          _say('Connect the phone to the Wi-Fi the board sends to, then start the night.');
          return;
        }
      } else if (!await nearbyAllowed(_phone.sdkInt) && !await _requestNearby()) {
        _say('Allow Nearby devices first: without it the headband cannot be found.');
        return;
      }
      if (_phone.sdkInt >= 33) await FlutterForegroundTask.requestNotificationPermission();
      final phone = await _safe(Phone.snapshot, _phone);
      if (!diy && !phone.bluetoothOn) {
        _say('Turn Bluetooth on, then start the night.');
        await Phone.openSettings('bluetooth');
        return;
      }
      if (!phone.ignoringBatteryOptimizations) {
        // The system dialog; recording starts anyway, and the warning stays until it is allowed.
        await _safe(() => Phone.openSettings('batteryOptimization'), false);
      }
      final dir = _dir ?? await _safe<String?>(Phone.recordingsDir, null);
      _scoring?.halt(); // the night comes first: scoring stops at its next model call and goes on after Stop
      final plan = await _setAlarmClock(dir);
      await _share.beforeNight(); // the recorder serves during the night: the app lets go of the port
      final result = await startRecorderService(dir, alarm: plan);
      if (result is ServiceRequestFailure) _say('The recorder did not start: ${result.error}');
      _status = null;
      _statusAtMs = null;
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_refresh());
    }
  }

  /// Lights off: a marker in the night and the drift-off detector from here. The first tap of a night is instant; a
  /// later one asks, since it moves the night's comparison (DECISIONS 180).
  Future<void> _lightsOff() async {
    final first = _status?.lightsOffMs ?? _lightsOffSentMs;
    if (first != null && !await confirmLightsOffAgain(context, DateTime.fromMillisecondsSinceEpoch(first))) return;
    if (!mounted || !_running) return;
    setState(() => _lightsOffSentMs = DateTime.now().millisecondsSinceEpoch);
    FlutterForegroundTask.sendDataToTask(lightsOffCommand);
  }

  Future<void> _stop() async {
    final end = _clockState.endMs;
    final rings = end != null && end > DateTime.now().millisecondsSinceEpoch && _clockState.awakeMs == null;
    final at = rings ? DateTime.fromMillisecondsSinceEpoch(end) : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the night?'),
        content: Text(
          'Recording ends. The files are kept.${at == null ? '' : ' The alarm still rings at '
              '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep recording')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      _stopped = Completer<void>();
      FlutterForegroundTask.sendDataToTask(stopCommand);
      // The recorder closes its files and the headband first; then the service goes.
      await _stopped!.future.timeout(const Duration(seconds: 25), onTimeout: () {});
      await FlutterForegroundTask.stopService();
      await _share.afterStop(); // 15 more minutes, so the laptop gets the end of the night
    } finally {
      _stopped = null;
      _lightsOffSentMs = null;
      if (mounted) setState(() => _busy = false);
      unawaited(_refresh());
    }
  }

  static List<NightFiles> _listNights(String dir) {
    try {
      return nightsIn(Directory(dir));
    } catch (_) {
      return const [];
    }
  }

  /// Export: the owner picks a night, then a folder (system picker); the night's files are copied there.
  Future<void> _export() async {
    final nights = _nights;
    if (nights.isEmpty) return;
    final night = await showModalBottomSheet<NightFiles>(
      context: context,
      showDragHandle: true,
      backgroundColor: Night.surfaceHigh,
      builder: (c) => _NightPicker(nights: nights),
    );
    if (night == null || !mounted) return;
    try {
      final r = await Phone.exportNight([for (final f in night.files) f.path], night.folderName);
      if (r == null) return; // picker closed
      _say('Copied ${r.files} files (${_mb(r.bytes)}) into the new folder "${r.folder}".');
    } on PlatformException catch (e) {
      _say('Export failed: ${e.message ?? e.code}');
    }
  }

  /// Export data: everything new, from its own page, only between nights (DECISIONS rows 150-156).
  Future<void> _exportData() async {
    if (_running) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ExportScreen()));
    unawaited(_refresh());
  }

  Future<void> _setShare(bool on) async {
    await _share.setOn(on);
    if (on && mounted) await _shareDetails();
  }

  /// The address, the code and the QR code for the laptop.
  Future<void> _shareDetails() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Night.surfaceHigh,
    builder: (c) => ListenableBuilder(
      listenable: _share,
      builder: (c, _) {
        final at = shareAddress(_share.status);
        return ShareSheet(
          model: ShareSheetModel(
            address: at?.substring(0, at.lastIndexOf(':')),
            port: _share.config.port,
            token: _share.config.token,
            until: DateTime.fromMillisecondsSinceEpoch(_share.config.offAtMs),
            night: _running,
            laptop: _share.config.laptop,
          ),
          onNewToken: _share.newToken,
          onForgetLaptop: _share.forgetLaptop,
        );
      },
    ),
  );

  /// Meditation owns the headband while it runs, so it starts only between nights (DECISIONS row 75).
  Future<void> _meditate() async {
    if (_running) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MeditationScreen()));
    unawaited(_refresh());
  }

  /// The dream catcher holds the headband too, so it also starts only between nights (DECISIONS row 110).
  Future<void> _dream() async {
    if (_running) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DreamScreen()));
    unawaited(_refresh());
  }

  /// The nap coach holds the headband too, so it also starts only between nights (DECISIONS row 173).
  Future<void> _nap() async {
    if (_running) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NapScreen()));
    unawaited(_refresh());
  }

  /// The work session holds the headband too, so it also starts only between nights (DECISIONS 447).
  Future<void> _work() async {
    if (_running) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkScreen()));
    unawaited(_refresh());
  }

  /// Lucid dream cues: the practice and the morning questions need no headband (DECISIONS 308).
  Future<void> _lucid() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LucidScreen()));
    unawaited(_refresh());
  }

  /// Memory cues: the evening task and the morning test need no headband (DECISIONS 508).
  Future<void> _memory() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MemoryCuesScreen()));
    unawaited(_refresh());
  }

  /// The check-in owns the headband while it runs, so it too starts only between nights.
  Future<void> _checkIn() async {
    if (_running) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MorningScreen()));
    unawaited(_refresh());
  }

  /// Settings: the hands-free switch and its calibration (DECISIONS 248); the calibration itself waits for Stop.
  Future<void> _settings() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

  Future<void> _trends() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrendsScreen(recordingsDir: _dir)));

  /// Sound for states: with the headband between nights, by its timer alone during one (DECISIONS row 130).
  Future<void> _sound() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StatesScreen()));
    unawaited(_refresh());
  }

  Future<void> _fix(FixAction a) async {
    switch (a) {
      case FixAction.requestNearby:
        await _requestNearby();
      case FixAction.requestNotifications:
        final p = await FlutterForegroundTask.requestNotificationPermission();
        if (p != NotificationPermission.granted) await Phone.openSettings('notifications');
      case FixAction.bluetoothSettings:
        await Phone.openSettings('bluetooth');
      case FixAction.batteryOptimisation:
        await Phone.openSettings('batteryOptimization');
      case FixAction.appDetails:
        await Phone.openSettings('appDetails');
      case FixAction.batterySaver:
        await Phone.openSettings('batterySaver');
      case FixAction.xiaomiAutostart:
        await Phone.openSettings('xiaomiAutostart');
      case FixAction.xiaomiBatterySaver:
        await Phone.openSettings('xiaomiBatterySaver');
      case FixAction.xiaomiDone:
        await FlutterForegroundTask.saveData(key: _xiaomiDoneKey, value: true);
    }
    await _refresh();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  NightViewModel _model() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = _running ? _status : null;
    final quiet = _statusAtMs == null || now - _resumedAtMs < 5000 ? 0 : now - _statusAtMs!;
    final diy = _diy.useDiy;
    final d = describeNight(
      status: s,
      running: _running,
      nowMs: now,
      quietMs: quiet,
      last: _last,
      diy: diy ? (address: _address) : null,
    );
    final last = _last;
    final showLast = !_running && last != null && last.samples > 0;
    final List<StripRow> rows;
    if (s != null && s.nightStartMs > 0) {
      rows = stripRows(startMs: s.nightStartMs, endMs: now, slots: s.slots, live: true);
    } else if (showLast && last.slots.isNotEmpty) {
      final end = (last.slots.keys.reduce((a, b) => a > b ? a : b) + 1) * slotMs;
      rows = stripRows(startMs: last.startMs, endMs: end, slots: last.slots, live: false);
    } else {
      rows = const [];
    }
    return NightViewModel(
      title: d.title,
      sentence: d.sentence,
      tone: d.tone,
      running: _running,
      busy: _busy,
      minutes: s != null ? s.minutesRecorded : (showLast ? last.samples / sampleRateHz / 60 : null),
      dataAgeSeconds: s?.lastDataMs == null ? null : ((now - s!.lastDataMs!) ~/ 1000).clamp(0, 1 << 30),
      coverage: showLast && rows.isNotEmpty ? nightCoverage(rows) : null,
      stripTitle: _running ? 'Tonight' : 'Last night',
      rows: rows,
      battery: s?.battery,
      rssi: s?.rssi,
      contactOhms: s?.contactOhms ?? (showLast ? last.contactOhms : const {}),
      checks: phoneChecks(phone: _phone, nearbyAllowed: _nearby, xiaomiDone: _xiaomiDone, bluetooth: !diy),
      nightsOnPhone: _nights.length,
      exportLine: _running || _pending == null
          ? null
          : exportLine(
              lastComplete: _pending!.lastComplete,
              pendingFiles: _pending!.files,
              pendingBytes: _pending!.bytes,
              now: DateTime.now(),
            ),
      sleep: _running ? null : _sleepSummary(),
      dreamLine: _dreamLine,
      lightsOffLine: s == null
          ? null
          : lightsOffLine(
              lightsOffMs: s.lightsOffMs ?? _lightsOffSentMs,
              drift: s.drift,
              onsetMs: s.driftOnsetMs,
              recording: s.phase == Phase.recording,
            ),
      lightsOffTapped: (s?.lightsOffMs ?? _lightsOffSentMs) != null,
      napLine: _napLine,
      share: _dir == null ? null : _share.line(),
      alarmLine: _alarmLine(s, now),
      alarmAction: _alarmAction(s, now),
      ringing: _clockState.ringing ? (_clockState.reason ?? _windowEndReason()) : null,
      lucidLine: _lucidLine,
      memoryLine: _memoryLine,
      board: s?.board,
      diyNames: diy ? _diy.names : null,
    );
  }

  String _windowEndReason() {
    final end = _clockState.endMs;
    if (end == null) return 'Your alarm.';
    final t = DateTime.fromMillisecondsSinceEpoch(end);
    return 'The end of your window, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}.';
  }

  String? _alarmLine(RecorderStatus? s, int now) {
    if (_running) return alarmNightLine(s?.alarm, nowMs: now);
    if (_pendingClock) {
      final t = DateTime.fromMillisecondsSinceEpoch(_clockState.endMs!);
      return 'The phone\'s alarm still rings at ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}.';
    }
    return alarmSetupLine(_alarm, DateTime.fromMillisecondsSinceEpoch(now));
  }

  String? _alarmAction(RecorderStatus? s, int now) {
    if (_running) {
      final a = s?.alarm;
      final canRing = a != null && a.note != 'Turned off.' && a.phase != 'woke' && now < a.endMs + 20 * 60000;
      return canRing ? 'Alarm off' : null;
    }
    if (_pendingClock) return 'Turn off';
    return _alarm.on ? 'Change' : 'Set alarm';
  }

  @override
  Widget build(BuildContext context) {
    final model = _model();
    final sleep = model.sleep;
    return NightView(
      model: model,
      onStart: _start,
      onStop: _stop,
      onFix: _fix,
      onExport: _export,
      onExportData: _exportData,
      onShare: _busy ? null : _setShare,
      onShareDetails: _shareDetails,
      onMeditate: _meditate,
      onDream: _dream,
      onNap: _nap,
      onLucid: _lucid,
      onMemory: _memory,
      onSound: _sound,
      onWork: _work,
      onSleepReport: sleep == null ? null : () => _openSleep(sleep.nightOf),
      onRetrySleep: sleep == null ? null : () => _scoring?.retry(sleep.nightOf),
      morning: MorningSection(
        doneAt: _checkedInAt,
        onCheckIn: _checkIn,
        onTrends: _trends,
        experiment: _experiment,
        unusual: _unusual,
      ),
      onLightsOff: _lightsOff,
      onSettings: _settings,
      onAlarm: _onAlarm,
      onAwake: _awake,
      onHeadbandPage: () => unawaited(_refresh()),
    );
  }
}

String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(bytes < 1e7 ? 1 : 0)} MB';

/// The nights on the phone, newest first; tapping one returns it.
class _NightPicker extends StatelessWidget {
  const _NightPicker({required this.nights});
  final List<NightFiles> nights;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    String two(int v) => v.toString().padLeft(2, '0');
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Export which night? Next, pick or create a folder, for example Download/EEG.',
              style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
            ),
          ),
          for (final n in nights)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              title: Text('Night of ${nightLabel(n.nightOf)}', style: text.titleMedium),
              subtitle: Text(
                'from ${two(n.start.hour)}:${two(n.start.minute)} · '
                '${n.runs == 1 ? '1 file set' : '${n.runs} file sets'} · ${_mb(n.bytes)}',
                style: text.bodyMedium?.copyWith(color: Night.inkMuted),
              ),
              onTap: () => Navigator.pop(context, n),
            ),
        ],
      ),
    );
  }
}
