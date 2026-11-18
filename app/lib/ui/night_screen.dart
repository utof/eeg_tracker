// The app's one screen: start and stop the night, see that it is being recorded, fix phone settings.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import '../phone.dart';
import '../recorder/headband.dart';
import '../recorder/nights.dart';
import '../recorder/recorder_service.dart';
import '../recorder/status.dart';
import 'night_strip.dart';
import 'night_view.dart';
import 'phone_checks.dart';
import 'theme.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {}); // data age and the current half hour move on
      if (++_ticks % 5 == 0) unawaited(_refreshRunning());
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
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
    final s = RecorderStatus.fromMap(data);
    if (s == null || !mounted) return;
    setState(() {
      _status = s;
      _statusAtMs = DateTime.now().millisecondsSinceEpoch;
    });
  }

  Future<void> _refreshRunning() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted && running != _running) setState(() => _running = running);
  }

  Future<void> _refresh() async {
    final phone = await _safe(Phone.snapshot, const PhoneSnapshot({}));
    final nearby = await _nearbyAllowed(phone.sdkInt);
    final running = await FlutterForegroundTask.isRunningService;
    final last = await loadNight();
    final xiaomiDone = await FlutterForegroundTask.getData<bool>(key: _xiaomiDoneKey) ?? false;
    final dir = _dir ?? await _safe<String?>(Phone.recordingsDir, null);
    final nights = dir == null || running ? const <NightFiles>[] : _listNights(dir);
    if (running) FlutterForegroundTask.sendDataToTask(statusCommand);
    if (!mounted) return;
    setState(() {
      _nights = nights;
      _phone = phone;
      _nearby = nearby;
      _running = running;
      _last = last;
      _xiaomiDone = xiaomiDone;
      _dir = dir;
    });
  }

  static Future<T> _safe<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }

  static Future<bool> _nearbyAllowed(int sdk) async {
    if (sdk >= 31) {
      return await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted;
    }
    return Permission.locationWhenInUse.isGranted;
  }

  Future<bool> _requestNearby() async {
    final sdk = _phone.sdkInt;
    final asked = sdk >= 31 ? [Permission.bluetoothScan, Permission.bluetoothConnect] : [Permission.locationWhenInUse];
    final result = await asked.request();
    if (result.values.every((s) => s.isGranted)) return true;
    if (result.values.any((s) => s.isPermanentlyDenied)) await openAppSettings();
    return false;
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      if (!await _nearbyAllowed(_phone.sdkInt) && !await _requestNearby()) {
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
      final result = await startRecorderService(_dir ?? await _safe<String?>(Phone.recordingsDir, null));
      if (result is ServiceRequestFailure) _say('The recorder did not start: ${result.error}');
      _status = null;
      _statusAtMs = null;
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_refresh());
    }
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
    } finally {
      _stopped = null;
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
    );
  }

  @override
  Widget build(BuildContext context) =>
      NightView(model: _model(), onStart: _start, onStop: _stop, onFix: _fix, onExport: _export);
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
