// The smart alarm's smoke test on a device (app/README.md, "Emulator smoke test"; DECISIONS 230-231): an entry point
// of its own that runs the real night recorder service (flutter_foreground_task, its own Flutter engine) with a
// replayed headband (the shared one, lib/headband/replay.dart) instead of the BrainBit, and the real smart alarm inside
// it: AnySleep's ONNX runs opened in the service's engine, the early ring through the phone's alarm clock, the ringer.
// It never is part of the app: build it with `-t tool/alarm_smoke.dart`, then reinstall the app.
//
// Put a recording into `files/smoke/` first (any `.f32` of the app's format; adb root and the app's owner, as for a
// night) and, if wanted, `files/smoke/plan.json`:
//   {"mode": "night", "startInMin": 35, "windowMin": 10, "speed": 2, "skipS": 330}
//     the recorder replays the files at `speed` times real time from `skipS` seconds in; the window opens
//     `startInMin` minutes after the start, so the model (an hour before it) runs from the first sample;
//     with `"lucidAfterMin": 3, "lucidModelBeforeMin": 2` the lucid dream cues are switched on too (a made-up
//     loudness) with their cue hours from 3 minutes after the start and their model 2 minutes before: with a later
//     window (`"startInMin": 70`) the cues start the night's one live model and the alarm joins it (DECISIONS 330);
//   {"mode": "killed", "endInMin": 3}
//     only the phone's alarm, `endInMin` minutes ahead: kill the process (`adb shell kill -9`), it must still ring.
// `SMOKE` lines go to logcat (the service's from its own engine), `EegWake` lines are the ringer's.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/alarm/bell.dart';
import 'package:eeg_tracker/alarm/live_alarm.dart';
import 'package:eeg_tracker/alarm/notes.dart';
import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/headband/replay.dart';
import 'package:eeg_tracker/lucid/bell.dart';
import 'package:eeg_tracker/lucid/live_cues.dart';
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/phone.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/recorder_service.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/sleep/night_scorer.dart';
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
    final lucidAfter = (cfg['lucidAfterMin'] as num?)?.toInt();
    if (lucidAfter != null) {
      final store = LucidStore(lucidDirFor(rec));
      store.setLevel(0.05, now);
      store.setOn(true, now);
      _say('lucid cues on: cue hours from $lucidAfter min, the model ${cfg['lucidModelBeforeMin'] ?? 2} min before');
    }
    await File('$files/smoke/config.json').writeAsString(jsonEncode({
      'speed': (cfg['speed'] as num?)?.toDouble() ?? 2,
      'skipS': (cfg['skipS'] as num?)?.toDouble() ?? 0,
      'lucidAfterMin': lucidAfter,
      'lucidModelBeforeMin': (cfg['lucidModelBeforeMin'] as num?)?.toInt() ?? 2,
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
  NightScorer? shared;
  final started = DateTime.now();
  Timer.periodic(const Duration(seconds: 20), (_) {
    final n = shared;
    if (n != null) debugPrint('SMOKE scorer: loads ${n.loads}, running ${n.stager != null}, used by ${n.users}');
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
      alarm: (dir, scorer) {
        shared = scorer;
        return (plan) => made = smartAlarm(dir, plan, scorer);
      },
      cues: (dir, scorer) => (nightStartMs) {
        final cfg = jsonDecode(File('${Directory(dir).parent.path}/smoke/config.json').readAsStringSync()) as Map;
        final after = (cfg['lucidAfterMin'] as num?)?.toInt();
        if (after == null) return lucidCuesWith(dir, scorer)(nightStartMs);
        final store = LucidStore(lucidDirFor(dir));
        final cues = LiveCues.open(
          store: store,
          nightStartMs: nightStartMs,
          scorer: scorer,
          bell: ChannelCueBell(),
          now: DateTime.now(),
          cuesAfter: Duration(minutes: after),
          modelBefore: Duration(minutes: (cfg['lucidModelBeforeMin'] as num?)?.toInt() ?? 2),
        );
        if (cues != null) ensureCueWav(store.cueWav);
        return cues;
      },
    ),
  );
}

/// The shared replay headband (lib/headband/replay.dart) on `files/smoke/`'s recordings at the plan's speed, made on
/// the first search (the folder is only known then).
class _ReplayFinder implements HeadbandFinder {
  ReplayFinder? _replay;

  Future<ReplayFinder> _open() async {
    final made = _replay;
    if (made != null) return made;
    final rec = await Phone.recordingsDir();
    final files = Directory(rec!).parent.path;
    final cfg = jsonDecode(File('$files/smoke/config.json').readAsStringSync()) as Map<String, dynamic>;
    final f32 = Directory('$files/smoke').listSync().whereType<File>().where((f) => f.path.endsWith('.f32')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return _replay = ReplayFinder(
      ReplayPlan(files: f32, speed: (cfg['speed'] as num).toDouble(), fromS: (cfg['skipS'] as num).toDouble()),
    );
  }

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    return (await _open()).find(scanFor, onFound: onFound);
  }

  @override
  Future<Headband> connectDirect(BandId id) async => (await _open()).connectDirect(id);
}
