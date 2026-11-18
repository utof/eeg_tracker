// The live sleep scorer's speed on a device (app/README.md, "Emulator smoke test"): an entry point of its own that
// streams 61 minutes of a synthetic signal through the real live scorer (lib/sleep/live_stager.dart: the window copied,
// scaled in a background isolate, AnySleep's three ONNX runs on the plugin's thread) as fast as the phone allows,
// one model call per new epoch, and writes `BENCH` lines to logcat and the screen: the time per call at 5, 15, 30,
// 45 and 60 minutes of window, the scaling's share, and the process's peak memory. No headband needed. It is never
// part of the app: build it with `-t tool/live_bench.dart` (a release build times what the phone runs).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/phone.dart';
import 'package:eeg_tracker/sleep/live_prep.dart' show inputEpochSamples;
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:eeg_tracker/sleep/onnx_runs.dart';
import 'package:flutter/material.dart';

final ValueNotifier<List<String>> _lines = ValueNotifier(const []);

void _say(String line) {
  debugPrint(line);
  _lines.value = [..._lines.value, line];
}

String _peakMemory() {
  try {
    final status = File('/proc/self/status').readAsLinesSync();
    String grab(String key) => status.firstWhere((l) => l.startsWith(key), orElse: () => '$key ?').split(':').last.trim();
    return 'peak ${grab('VmHWM')}, now ${grab('VmRSS')}';
  } catch (_) {
    return 'memory unknown';
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
  _say('BENCH start; ${_peakMemory()}');
  try {
    final rec = await Phone.recordingsDir();
    if (rec == null) throw StateError('no app folder');
    final models = modelsDirFor(rec);
    final stager = LiveStager(
      model: RunsLiveModel(
        open: (run) => OnnxStageRun.open(run, modelsDir: models),
        closeRun: (run) => (run as OnnxStageRun).close(),
      ),
      slow: const Duration(minutes: 10), // measure, never step down
    );
    final rnd = math.Random(7);
    var k = 0;
    final report = {10, 30, 60, 90, 120};
    final total = Stopwatch()..start();
    for (var e = 0; e < 122; e++) {
      for (var i = 0; i < inputEpochSamples; i++, k++) {
        final t = k / 250;
        stager.push([
          12000 + 20 * math.sin(2 * math.pi * 10 * t) + 15 * (rnd.nextDouble() - 0.5),
          -8000 + 20 * math.sin(2 * math.pi * 10 * t + 1) + 15 * (rnd.nextDouble() - 0.5),
          20000 + 30 * math.sin(2 * math.pi * 0.8 * t) + 15 * (rnd.nextDouble() - 0.5),
          -15000 + 30 * math.sin(2 * math.pi * 0.8 * t + 2) + 15 * (rnd.nextDouble() - 0.5),
        ]);
      }
      await stager.idle();
      final c = stager.calls.isEmpty ? null : stager.calls.last;
      if (c != null && report.contains(c.epochs) && c.edge == e) {
        _say('BENCH window ${c.epochs ~/ 2} min (${c.epochs} epochs): ${c.ms} ms per check with ${c.runs} runs '
            '(scaling ${c.prepMs} ms); ${_peakMemory()}');
      }
      if (stager.mode != LiveMode.full) _say('BENCH stepped down: ${stager.why}');
    }
    final t = stager.callTimes!;
    _say('BENCH done: ${stager.calls.length} checks in ${(total.elapsedMilliseconds / 1000).toStringAsFixed(0)} s, '
        'median ${t.median} ms, max ${t.max} ms; ${_peakMemory()}');
    await stager.close();
  } catch (e) {
    _say('BENCH FAIL $e');
  }
}
