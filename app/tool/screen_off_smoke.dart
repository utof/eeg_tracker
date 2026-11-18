// The emulator's locked-screen check (app/README.md, "Emulator smoke test"; DECISIONS rows 190-196): an entry point
// of its own, never part of the app. It holds the session service as a session with the headband and the microphone
// would, plays sound for states, and writes one `SMOKE` line to logcat every 5 s, so a gap in the lines after
//   adb shell input keyevent 26        (lock)
// would show a frozen app. With the screen still locked it then records 4 s from the microphone (the dream catcher's
// answer) and starts the night recording (the handover after "fall asleep"), and says how each went.
// Build: flutter build apk --debug --target-platform android-x64 -t tool/screen_off_smoke.dart
import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/dream/record_mic.dart';
import 'package:eeg_tracker/phone.dart';
import 'package:eeg_tracker/recorder/recorder_service.dart';
import 'package:eeg_tracker/session_keeper.dart';
import 'package:eeg_tracker/sound/soloud_state_sound.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Seconds after start: the microphone, the night recording, the end.
const int micAt = 60, nightAt = 80, endAt = 110;

final ValueNotifier<List<String>> _lines = ValueNotifier(const []);

void _say(String line) {
  debugPrint(line);
  _lines.value = [..._lines.value, line];
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  initRecorderService();
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
  final clock = Stopwatch()..start();
  int t() => clock.elapsed.inSeconds;
  final keeper = PhoneSessionKeeper()..onStop = () => _say('SMOKE stop tapped at ${t()} s');
  final canLock = await keeper.hold(const KeepSpec(title: 'Fall asleep', text: 'Smoke test', headband: true, microphone: true));
  _say('SMOKE hold canLock=$canLock');
  final sound = SoloudStateSound();
  try {
    await sound.start(SoundPlan.of(SoundState.relax, minutes: 15), fadeInS: 1);
    _say('SMOKE sound on');
  } catch (e) {
    _say('SMOKE FAIL sound: $e');
  }
  final dir = await Phone.recordingsDir();
  var micDone = false, nightDone = false;
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    final info = sound.info();
    _say('SMOKE tick ${t()} s stalls=${info['stalls']} feedErrors=${info['feedErrors']} deviceFailures=${info['deviceStartFailures']}');
    if (!micDone && t() >= micAt) {
      micDone = true;
      final mic = RecordMic();
      final path = '${Directory.systemTemp.path}/smoke-answer.wav';
      try {
        var loud = 0, heard = 0;
        final levels = mic.levels.listen((db) {
          heard++;
          if (db > -90) loud++;
        });
        await mic.start(path);
        await Future<void>.delayed(const Duration(seconds: 4));
        await mic.stop();
        await levels.cancel();
        _say('SMOKE mic ok at ${t()} s: ${File(path).lengthSync()} bytes, $heard levels, $loud above -90 dBFS');
      } catch (e) {
        _say('SMOKE FAIL mic: $e');
      }
      await mic.dispose();
    }
    if (!nightDone && t() >= nightAt) {
      nightDone = true;
      try {
        final r = await startRecorderService(dir);
        _say(r is ServiceRequestFailure ? 'SMOKE FAIL night: ${r.error}' : 'SMOKE night ok at ${t()} s');
      } catch (e) {
        _say('SMOKE FAIL night: $e');
      }
    }
    if (t() >= endAt) {
      timer.cancel();
      await keeper.release();
      _say('SMOKE session service released; recorder running=${await FlutterForegroundTask.isRunningService}');
      FlutterForegroundTask.sendDataToTask(stopCommand);
      await Future<void>.delayed(const Duration(seconds: 5));
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
      await sound.stop(seconds: 1);
      _say('SMOKE done');
    }
  });
}
