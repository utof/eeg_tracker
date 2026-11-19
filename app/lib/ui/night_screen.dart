// The app's one screen: start and stop the night, see that it is being recorded, fix phone settings.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../dream/store.dart';
import '../export/store.dart';
import '../phone.dart';
import 'experiments_screen.dart' show currentExperiment;
import 'experiments_view.dart' show experimentLine;
import '../morning/store.dart';
import '../nap/store.dart';
import '../recorder/headband.dart';
import '../recorder/nights.dart';
import '../recorder/recorder_service.dart';
import '../recorder/status.dart';
import '../share/control.dart';
import '../share/isolate.dart' show shareAddress;
import '../sleep/onnx_runs.dart';
import '../sleep/report.dart';
import '../sleep/scorer.dart';
import '../sharp/prompts.dart' show ChannelSharpPhone, rearmSharp;
import '../sharp/store.dart' show SharpStore, sharpDirFor;
import 'dream_screen.dart';
import 'dream_view.dart' show clock;
import 'export_screen.dart';
import 'hands_free_screen.dart' show SettingsScreen;
import 'lights_off_view.dart';
import 'meditation_screen.dart';
import 'nap_screen.dart';
import 'nap_view.dart' show endWords;
import 'morning_screen.dart';
import 'morning_section.dart';
import 'nearby.dart';
import 'night_strip.dart';
import 'night_view.dart';
import 'phone_checks.dart';
import 'share_sheet.dart';
import 'sleep_report_screen.dart';
import 'sleep_scoring.dart';
import 'states_screen.dart';
import 'theme.dart';
import 'trends_screen.dart';

const String _xiaomiDoneKey = 'xiaomiChecked';

/// Title, sentence and tone for the status block. Pure, so it is tested without a phone.
({String title, String sentence, Tone tone}) describeNight({
  required RecorderStatus? status,
  required bool running,
  required int nowMs,
  required int quietMs,
  NightState? last,
}) {
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

class NightScreen extends StatefulWidget {
  const NightScreen({super.key});

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
  String? _checkedInAt, _experiment;
  Pending? _pending;

  /// Share on Wi-Fi (DECISIONS rows 220-229): the setting, and the app's own server between nights.
  late final ShareControl _share = ShareControl(
    load: loadShareConfig,
    save: saveShareConfig,
    sendToRecorder: FlutterForegroundTask.sendDataToTask,
    keepScreenOn: (on) => Phone.keepScreenOn(on: on),
  )..addListener(_onScoring);

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
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _scoring?.removeListener(_onScoring);
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

  Future<void> _refresh() async {
    final phone = await _safe(Phone.snapshot, const PhoneSnapshot({}));
    final nearby = await nearbyAllowed(phone.sdkInt);
    final running = await FlutterForegroundTask.isRunningService;
    final last = await loadNight();
    final xiaomiDone = await FlutterForegroundTask.getData<bool>(key: _xiaomiDoneKey) ?? false;
    final dir = _dir ?? await _safe<String?>(Phone.recordingsDir, null);
    final nights = dir == null || running ? const <NightFiles>[] : _listNights(dir);
    final checkedInAt = dir == null ? null : _checkedInToday(dir);
    if (running) FlutterForegroundTask.sendDataToTask(statusCommand);
    if (dir != null && _scoring == null) {
      _scoring = SleepScoring(
        SleepScorer(
          recordingsDir: Directory(dir),
          store: NightReportStore(nightsDirFor(dir)),
          openRun: (run) => OnnxStageRun.open(run, modelsDir: modelsDirFor(dir)),
          closeRun: (run) => (run as OnnxStageRun).close(),
        ),
      )..addListener(_onScoring);
    }
    // Last night is scored on the phone once it has ended (DECISIONS row 97); never while a night records, nor
    // while a dream catcher session writes its recording.
    if (!running && !dreamSessionRunning && !soundSessionRunning && !napSessionRunning) unawaited(_scoring?.run());
    final dreamLine = dir == null ? null : _lastDream(dir);
    final napLine = dir == null ? null : _lastNap(dir);
    final pending = dir == null || running ? null : await _pendingExport(dir);
    String? experiment;
    try {
      experiment = dir == null ? null : experimentLine(currentExperiment(dir, DateTime.now()));
    } catch (_) {
      // a line of text is never worth breaking the night screen
    }
    // the sharp-hours questions (DECISIONS row 283): the moments ahead, handed to the phone at every start and return
    if (dir != null) unawaited(rearmSharp(SharpStore(sharpDirFor(dir)), ChannelSharpPhone(), DateTime.now()).catchError((Object _) {}));
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
      _checkedInAt = checkedInAt;
      _experiment = experiment;
      _pending = pending;
    });
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
      if (!await nearbyAllowed(_phone.sdkInt) && !await _requestNearby()) {
        _say('Allow Nearby devices first: without it the headband cannot be found.');
        return;
      }
      if (_phone.sdkInt >= 33) await FlutterForegroundTask.requestNotificationPermission();
      final phone = await _safe(Phone.snapshot, _phone);
      if (!phone.bluetoothOn) {
        _say('Turn Bluetooth on, then start the night.');
        await Phone.openSettings('bluetooth');
        return;
      }
      if (!phone.ignoringBatteryOptimizations) {
        // The system dialog; recording starts anyway, and the warning stays until it is allowed.
        await _safe(() => Phone.openSettings('batteryOptimization'), false);
      }
      await _share.beforeNight(); // the recorder serves during the night: the app lets go of the port
      final result = await startRecorderService(_dir ?? await _safe<String?>(Phone.recordingsDir, null));
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the night?'),
        content: const Text('Recording ends. The files are kept.'),
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
          ),
          onNewToken: _share.newToken,
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
    final d = describeNight(status: s, running: _running, nowMs: now, quietMs: quiet, last: _last);
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
      checks: phoneChecks(phone: _phone, nearbyAllowed: _nearby, xiaomiDone: _xiaomiDone),
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
    );
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
      onSound: _sound,
      onSleepReport: sleep == null ? null : () => _openSleep(sleep.nightOf),
      onRetrySleep: sleep == null ? null : () => _scoring?.retry(sleep.nightOf),
      morning: MorningSection(doneAt: _checkedInAt, onCheckIn: _checkIn, onTrends: _trends, experiment: _experiment),
      onLightsOff: _lightsOff,
      onSettings: _settings,
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
