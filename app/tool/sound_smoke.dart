// The emulator smoke test's sound check (app/README.md, "Emulator smoke test"): an entry point of its own that starts
// every sound engine on the device in turn, without a headband (in the app, meditation, alpha-theta and the check-in
// only make sound after the headband is found), and writes one `SMOKE` line per engine to logcat and the screen.
// It is never part of the app: build it with `-t tool/sound_smoke.dart` as a debug APK for the emulator.
import 'dart:async';

import 'package:eeg_tracker/dream/store.dart' show PromptKind;
import 'package:eeg_tracker/feedback/mapping.dart';
import 'package:eeg_tracker/sound/alpha_theta_sound.dart';
import 'package:eeg_tracker/sound/check_in_sound.dart';
import 'package:eeg_tracker/sound/dream_sound.dart';
import 'package:eeg_tracker/sound/soloud_sound.dart';
import 'package:eeg_tracker/sound/soloud_state_sound.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:flutter/material.dart';

final ValueNotifier<List<String>> _lines = ValueNotifier(const []);

void _say(String line) {
  debugPrint(line);
  _lines.value = [..._lines.value, line];
}

Future<void> _wait(double s) => Future<void>.delayed(Duration(milliseconds: (s * 1000).round()));

Future<void> _step(String name, Future<void> Function() run) async {
  final t = Stopwatch()..start();
  try {
    await run().timeout(const Duration(seconds: 60));
    _say('SMOKE ok $name (${(t.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)');
  } catch (e) {
    _say('SMOKE FAIL $name: $e');
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
  _say('SMOKE start');
  for (final mode in ['training', 'relax']) {
    await _step('meditation ($mode)', () async {
      final s = SoloudSound(mode: mode);
      await s.start();
      s.bed(on: true);
      s.glide(Targets.layers(0.8, 0.2, bellsAllowed: true, neutral: false));
      await _wait(2);
      s.bell();
      s.cue();
      await _wait(2);
      _say('  info ${s.info()}');
      await s.stop();
    });
  }
  await _step('alpha-theta', () async {
    final s = SoloudAlphaThetaSound();
    await s.start();
    s.bed(on: true);
    for (final level in [0.2, 0.5, 0.8]) {
      s.play((level: level, rough: 0.1, reward: level > 0.5 ? 'chime' : null, gated: false));
      await _wait(1);
    }
    s.cue();
    s.wake();
    await _wait(1);
    _say('  info ${s.info()}');
    await s.stop();
  });
  await _step('check-in tones', () async {
    final s = SoloudCheckInSound();
    await s.start();
    s.close();
    await _wait(1.5);
    s.open();
    await _wait(1.5);
    s.end();
    await _wait(1.5);
    await s.stop();
  });
  await _step('dream catcher (made-in-app prompts)', () async {
    final s = SoloudDreamSound();
    await s.start();
    await s.prompt(PromptKind.theme, null);
    await s.prompt(PromptKind.question, null);
    s.wake();
    await _wait(1);
    await s.stop();
    await s.close();
  });
  for (final beat in [Beat.none, Beat.binaural, Beat.isochronic]) {
    await _step('sound for states (relax, ${beat.name})', () async {
      final s = SoloudStateSound();
      await s.start(SoundPlan.of(SoundState.relax, beat: beat, minutes: 15), fadeInS: 0.5);
      await _wait(3);
      await s.stop(seconds: 0.5);
    });
  }
  _say('SMOKE done');
}
