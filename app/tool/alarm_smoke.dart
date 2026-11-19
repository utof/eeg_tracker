// The smart alarm's smoke test on a device (app/README.md, "Emulator smoke test"; DECISIONS 230-231): an entry point
// of its own that runs the real night recorder service (flutter_foreground_task, its own Flutter engine) with a
// replayed headband instead of the BrainBit, and the real smart alarm inside it: AnySleep's ONNX runs opened in the
// service's engine, the early ring through the phone's alarm clock, the ringer. It never is part of the app: build it
// with `-t tool/alarm_smoke.dart`, then reinstall the app.
//
// Put a recording into `files/smoke/` first (any `.f32` of the app's format; adb root and the app's owner, as for a
// night) and, if wanted, `files/smoke/plan.json`:
//   {"mode": "night", "startInMin": 35, "windowMin": 10, "speed": 2, "skipS": 330}
//     the recorder replays the files at `speed` times real time from `skipS` seconds in; the window opens
//     `startInMin` minutes after the start, so the model (an hour before it) runs from the first sample;
//   {"mode": "killed", "endInMin": 3}
//     only the phone's alarm, `endInMin` minutes ahead: kill the process (`adb shell kill -9`), it must still ring.
// `SMOKE` lines go to logcat (the service's from its own engine), `EegWake` lines are the ringer's.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/alarm/bell.dart';
import 'package:eeg_tracker/alarm/live_alarm.dart';
import 'package:eeg_tracker/alarm/notes.dart';
import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/phone.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/recorder_service.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

final ValueNotifier<List<String>> _lines = ValueNotifier(const []);

void _say(String line) {
  debugPrint('SMOKE $line');
  _lines.value = [..._lines.value.take(200), line];
}

String _memory() {
  try {
    final status = File('/proc/self/status').readAsLinesSync();
    String grab(String key) => status.firstWhere((l) => l.startsWith(key), orElse: () => '$key ?').split(':').last.trim();
    return 'rss ${grab('VmRSS')}, peak ${grab('VmHWM')}';
  } catch (_) {
    return 'memory unknown';
  }
}

String _hms(DateTime t) => t.toIso8601String().substring(11, 19);

Future<Map<String, dynamic>> _config(String files) async {
  try {
    return jsonDecode(File('$files/smoke/plan.json').readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return const {};
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<List<String>>(
            valueListenable: _lines,
            builder: (_, lines, _) => ListView(padding: const EdgeInsets.all(16), children: [for (final l in lines) Text(l)]),
          ),
        ),
      ),
    ),
  );
  try {
    final rec = await Phone.recordingsDir();
    if (rec == null) throw StateError('no app folder');
    final files = Directory(rec).parent.path;
    final cfg = await _config(files);
    await writeWakeNotes(rec);
    initRecorderService();
    await FlutterForegroundTask.requestNotificationPermission();
    final now = DateTime.now();
    if (cfg['mode'] == 'killed') {
      final end = now.add(Duration(minutes: (cfg['endInMin'] as num?)?.toInt() ?? 3));
      final st = await AlarmClock.schedule(AlarmPlan(endMs: end.millisecondsSinceEpoch, windowMin: 1));
      _say('killed mode: the phone\'s alarm at ${_hms(end)} (exact ${st.exact}, full screen ${st.fullScreen}); '
          'now kill this process; ${_memory()}');
      return;
    }
    final startIn = (cfg['startInMin'] as num?)?.toInt() ?? 35;
    final windowMin = (cfg['windowMin'] as num?)?.toInt() ?? 10;
    final plan = AlarmPlan(
      endMs: now.add(Duration(minutes: startIn + windowMin)).millisecondsSinceEpoch,
      windowMin: windowMin,
    );
    final st = await AlarmClock.schedule(plan);
    _say('night mode: window ${_hms(DateTime.fromMillisecondsSinceEpoch(plan.startMs))}-'
        '${_hms(DateTime.fromMillisecondsSinceEpoch(plan.endMs))}, the phone\'s alarm set (exact ${st.exact}, '
        'full screen ${st.fullScreen}, alarm volume ${st.alarmVolume}/${st.alarmVolumeMax}); ${_memory()}');
    await File('$files/smoke/config.json').writeAsString(jsonEncode({
      'speed': (cfg['speed'] as num?)?.toDouble() ?? 2,
      'skipS': (cfg['skipS'] as num?)?.toDouble() ?? 0,
    }));
    FlutterForegroundTask.addTaskDataCallback((data) {
      final s = RecorderStatus.fromMap(data);
      final a = s?.alarm;
      if (s == null || DateTime.now().second % 15 != 0) return;
      _say('screen: ${s.phase.name}, ${s.minutesRecorded.toStringAsFixed(1)} min recorded, alarm ${a?.phase} '
          'stage ${a?.stage} why ${a?.why} ${a?.note ?? ''}; screen engine ${_memory()}');
    });
    final r = await startRecorderService(rec, alarm: plan, callback: alarmSmokeEntryPoint);
    _say('service start: ${r.runtimeType}');
    Timer.periodic(const Duration(seconds: 30), (_) async {
      final c = await AlarmClock.state();
      _say('phone alarm: ringing since ${c.ringingSinceMs} by ${c.ringBy}, loud ${c.loudSinceMs}, awake ${c.awakeMs}');
    });
  } catch (e, st) {
    _say('FAIL $e $st');
  }
}

/// The recorder service with the replayed headband; it reports the live model from inside its own engine.
@pragma('vm:entry-point')
void alarmSmokeEntryPoint() {
  LiveAlarm? made;
  final started = DateTime.now();
  Timer.periodic(const Duration(seconds: 20), (_) {
    final s = made?.stager;
    final c = s == null || s.calls.isEmpty ? null : s.calls.last;
    final t = s?.callTimes;
    debugPrint(
      'SMOKE service +${DateTime.now().difference(started).inSeconds} s: alarm ${made?.live.phase.name ?? 'not made'}, '
      'calls ${s?.calls.length ?? 0}${c == null ? '' : ', last ${c.ms} ms (scaling ${c.prepMs} ms) on ${c.epochs} epochs '
          'with ${c.runs} runs'}${t == null ? '' : ', median ${t.median} ms, max ${t.max} ms'}, mode ${s?.mode.name}, '
      'stage ${s == null || s.stages.isEmpty ? '-' : s.stages.last.stage}, wake ${made?.live.wake?.why.name}; '
      'process ${_memory()}',
    );
  });
  FlutterForegroundTask.setTaskHandler(
    RecorderTaskHandler(
      finder: () => _ReplayFinder(),
      alarm: (dir) => (plan) => made = smartAlarm(dir, plan),
    ),
  );
}

class _ReplayFinder implements HeadbandFinder {
  bool _given = false;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (_given) return null;
    _given = true;
    final rec = await Phone.recordingsDir();
    final files = Directory(rec!).parent.path;
    final cfg = jsonDecode(File('$files/smoke/config.json').readAsStringSync()) as Map<String, dynamic>;
    final f32 = Directory('$files/smoke').listSync().whereType<File>().where((f) => f.path.endsWith('.f32')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    onFound?.call('Replay', -50);
    return _ReplayBand(f32, speed: (cfg['speed'] as num).toDouble(), skipS: (cfg['skipS'] as num).toDouble());
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('replay: no reconnects');
}

/// Streams the recordings' samples in 0.25 s batches (of signal time) at [speed] times real time.
class _ReplayBand implements Headband {
  _ReplayBand(this.files, {required this.speed, required this.skipS});
  final List<File> files;
  final double speed;
  final double skipS;
  RandomAccessFile? _f;
  int _file = -1;
  Timer? _timer;
  int _sent = 0;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();

  bool _next() {
    _f?.closeSync();
    _f = null;
    while (++_file < files.length) {
      _f = files[_file].openSync();
      if (_file == 0) _f!.setPositionSync((skipS * 250).round() * recordBytes);
      return true;
    }
    return false;
  }

  List<Sample> _read(int n) {
    final out = <Sample>[];
    while (out.length < n) {
      final f = _f;
      if (f == null && !_next()) break;
      final bytes = _f!.readSync((n - out.length) * recordBytes);
      if (bytes.length < recordBytes) {
        if (!_next()) break;
        continue;
      }
      final b = ByteData.sublistView(bytes);
      for (var o = 0; o + recordBytes <= bytes.length; o += recordBytes) {
        out.add((
          pack: b.getUint32(o, Endian.little),
          o1: b.getFloat32(o + 4, Endian.little),
          o2: b.getFloat32(o + 8, Endian.little),
          t3: b.getFloat32(o + 12, Endian.little),
          t4: b.getFloat32(o + 16, Endian.little),
        ));
      }
    }
    return out;
  }

  @override
  String get name => 'Replay';
  @override
  String get address => '00:00';
  @override
  String get serial => 'replay';
  @override
  int? get rssi => -50;
  @override
  BandId get id => const BandId(name: 'Replay', address: '00:00', family: 'replay');
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  @override
  Future<void> startSignal() async {
    _timer?.cancel();
    var due = 0.0;
    final sw = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      // the samples due by now at [speed] times real time, in batches of 0.25 s of signal (about the headband's)
      due = sw.elapsedMicroseconds / 1e6 * speed * 250;
      while (_sent + 62 <= due) {
        final b = _read(62);
        if (b.isEmpty) {
          _timer?.cancel();
          debugPrint('SMOKE replay: the files ran out after ${_sent ~/ 250} s');
          return;
        }
        _sent += b.length;
        if (_signal.hasListener) _signal.add(b);
      }
    });
  }

  @override
  Future<void> stopSignal() async => _timer?.cancel();
  @override
  Future<void> startResist() async =>
      Timer(const Duration(milliseconds: 50), () => _resist.add({'O1': 4e5, 'O2': 6e5, 'T3': 1.2e6, 'T4': 1.5e6}));
  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async {
    _timer?.cancel();
    _f?.closeSync();
  }
}
