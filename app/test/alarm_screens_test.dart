// The smart alarm on the screens (lib/ui/alarm_view.dart, DECISIONS 233-238): the lines in words, the setup sheet,
// the "Waking up" section worked out from the alarm's files and the night's full scoring, and renders of every state
// at 100 and 130 % text and at the owner's 393 dp width to build/screens/alarm_*.png (no overflow allowed).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/alarm/record.dart';
import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/detectors/drift_off.dart' show DriftState;
import 'package:eeg_tracker/recorder/status.dart' show AlarmStatus;
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/ui/alarm_view.dart';
import 'package:eeg_tracker/ui/lights_off_view.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

int _ms(int h, int m, [int day = 25]) => DateTime(2026, 11, day, h, m).millisecondsSinceEpoch;

/// A night from 23:30 to 07:40: light sleep, deep sleep 06:20-06:50, then light and dream sleep.
SleepReport _report() {
  final start = DateTime(2026, 11, 24, 23, 30);
  final stages = <String>[];
  for (var t = start; t.isBefore(DateTime(2026, 11, 25, 7, 40)); t = t.add(const Duration(seconds: 30))) {
    final m = t.hour * 60 + t.minute;
    stages.add(
      t.day == 24 && m < 23 * 60 + 45
          ? 'W'
          : (m >= 6 * 60 + 20 && m < 6 * 60 + 50)
          ? 'N3'
          : (m >= 7 * 60 + 5 && m < 7 * 60 + 20)
          ? 'R'
          : 'N2',
    );
  }
  return SleepReport(
    jsonDecode(
          jsonEncode(
            buildReport(
              nightOf: '2026-11-24',
              built: DateTime(2026, 11, 25, 7, 45),
              scoringSeconds: 90,
              start: start,
              lengthSeconds: 30.0 * stages.length,
              inputs: const {'2026-11-24-233000.f32': 1000},
              model: 'test',
              stages: stages,
            ),
          ),
        )
        as Map<String, dynamic>,
  );
}

AlarmNight _night({String why = 'light', String stage = 'N2', int ringH = 7, int ringM = 2, String by = 'smart'}) {
  final plan = AlarmPlan(endMs: _ms(7, 30), windowMin: 30);
  final ring = _ms(ringH, ringM);
  return AlarmNight(
    plan: plan,
    record: {
      'plan': plan.toJson(),
      'phase': why == 'window end' ? 'ended' : 'woke',
      'wake': {'at_ms': ring, 'why': why, 'stage': why == 'window end' ? null : stage, 'behind': 4},
      'off': null,
    },
    rings: [
      (endMs: plan.endMs, event: 'set', atMs: _ms(23, 20, 24), by: null, windowMin: 30),
      (endMs: plan.endMs, event: 'ring', atMs: ring, by: by, windowMin: null),
      (endMs: plan.endMs, event: 'awake', atMs: ring + 95000, by: null, windowMin: null),
    ],
  );
}

NightViewModel _between(String line, String action) => NightViewModel(
  title: 'Ready',
  sentence: 'Last night is saved. Put the headband on to start a new one.',
  tone: Tone.calm,
  running: false,
  alarmLine: line,
  alarmAction: action,
);

NightViewModel _recording(String? alarmLine, {String? action = 'Alarm off'}) => NightViewModel(
  title: 'Recording',
  sentence: 'All is well. You can put the phone down.',
  tone: Tone.live,
  running: true,
  minutes: 412.5,
  dataAgeSeconds: 1,
  battery: 64,
  rssi: -66,
  contactOhms: const {'O1': 4.2e5, 'O2': 6.1e5, 'T3': 1.8e6, 'T4': 3.4e6},
  lightsOffLine: lightsOffLine(lightsOffMs: _ms(23, 42, 24), drift: DriftState.asleep, onsetMs: _ms(23, 51, 24)),
  lightsOffTapped: true,
  alarmLine: alarmLine,
  alarmAction: action,
);

final _evening = DateTime(2026, 11, 24, 23, 10);
const _scoring = AlarmStatus(endMs: 0, windowMin: 30, phase: 'scoring', stage: 'N2');

Map<String, Widget> _states() {
  final end = _ms(7, 30);
  AlarmStatus st(String phase, {String? stage, int? wakeMs, String? why, String? note}) =>
      AlarmStatus(endMs: end, windowMin: 30, phase: phase, stage: stage, wakeMs: wakeMs, why: why, note: note);
  Widget night(NightViewModel m) =>
      NightView(model: m, onStart: () {}, onStop: () {}, onFix: (_) {}, onLightsOff: () {}, onAlarm: () {}, onAwake: () {});
  return {
    'setup_off': night(_between(alarmSetupLine(const AlarmSetup(), _evening), 'Set alarm')),
    'setup_on': night(_between(alarmSetupLine(const AlarmSetup(on: true), _evening), 'Change')),
    'recording_waiting': night(_recording(alarmNightLine(st('waiting'), nowMs: _ms(2, 10)))),
    'recording_scoring': night(_recording(alarmNightLine(st('scoring', stage: 'N3'), nowMs: _ms(6, 40)))),
    'recording_woke': night(_recording(alarmNightLine(st('woke', wakeMs: _ms(7, 6), why: 'light'), nowMs: _ms(7, 8)), action: null)),
    'ringing': WakeFace(reason: 'Light sleep, 28 min before 07:30.', onAwake: () {}),
    'sheet': Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Material(color: Night.surfaceHigh, child: AlarmSheet(setup: const AlarmSetup(on: true), onInfo: () {})),
      ),
    ),
    'waking_up': Scaffold(
      appBar: AppBar(title: const Text('Night of Tue 24 Nov')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          WakingUpSection(content: wakingUp(_night(), _report()), onInfo: () {}),
          WakingUpSection(content: wakingUp(_night(why: 'window end', ringH: 7, ringM: 30, by: 'window end'), _report())),
        ],
      ),
    ),
  };
}

void main() {
  setUpAll(loadFonts);

  group('the lines', () {
    test('before Start: off, or when and from when', () {
      expect(alarmSetupLine(const AlarmSetup(), _evening), 'Smart alarm off.');
      expect(
        alarmSetupLine(const AlarmSetup(on: true), _evening),
        'Wakes you by 07:30 tomorrow, from 07:00 at a light moment.',
      );
      expect(
        alarmSetupLine(const AlarmSetup(on: true, hour: 9, minute: 5, windowMin: 45), DateTime(2026, 11, 25, 2)),
        'Wakes you by 09:05 today, from 08:20 at a light moment.',
      );
    });

    test('during the night: what the alarm is doing, in words', () {
      final end = _ms(7, 30);
      String? line(String phase, {String? stage, int? wakeMs, String? why, String? note, int now = 0}) => alarmNightLine(
        AlarmStatus(endMs: end, windowMin: 30, phase: phase, stage: stage, wakeMs: wakeMs, why: why, note: note),
        nowMs: now == 0 ? _ms(2, 0) : now,
      );
      expect(line('waiting'), 'Alarm 07:00-07:30. The sleep model starts at 06:00.');
      expect(line('scoring'), 'Alarm 07:00-07:30. The sleep model is starting (5 minutes).');
      expect(line('scoring', stage: 'N3'), 'Alarm 07:00-07:30. Watching your sleep: deep sleep 2 min ago.');
      expect(line('woke', wakeMs: _ms(7, 6), why: 'dream'), 'Woke you at 07:06, in dream sleep.');
      expect(line('ended'), 'Alarm 07:00-07:30. No light moment came, so it rang at 07:30.');
      expect(line('off', note: 'The sleep model was switched off (x).'), 'Alarm 07:00-07:30. The sleep model is off; it rings at 07:30.');
      expect(line('off', note: 'Turned off.'), 'Smart alarm turned off for tonight.');
      expect(alarmNightLine(null, nowMs: 0), isNull);
      expect(_scoring.phase, 'scoring');
    });
  });

  group('the setup', () {
    test('is kept between nights, and bad files give the default (off)', () {
      final dir = Directory.systemTemp.createTempSync('alarm_setup');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AlarmSetupStore(File('${dir.path}/alarm/setup.json'));
      expect(store.read().on, isFalse);
      store.write(const AlarmSetup(on: true, hour: 6, minute: 45, windowMin: 20));
      final back = store.read();
      expect((back.on, back.hour, back.minute, back.windowMin), (true, 6, 45, 20));
      File('${dir.path}/alarm/setup.json').writeAsStringSync('{"on": true, "hour": 99, "windowMin": 7}');
      final bad = store.read();
      expect((bad.on, bad.hour, bad.windowMin), (true, 7, AlarmRule.defaultWindowMin));
      expect(const AlarmSetup().planAt(_evening), isNull);
    });

    testWidgets('the sheet: time, window, Set alarm', (tester) async {
      AlarmSetup? got;
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => got = await showModalBottomSheet<AlarmSetup>(
                    context: c,
                    isScrollControlled: true,
                    builder: (_) => AlarmSheet(setup: const AlarmSetup(), pickTime: (_, _) async => const TimeOfDay(hour: 6, minute: 50)),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('07:30'), findsOneWidget);
      await tester.tap(find.text('07:30'));
      await tester.pumpAndSettle();
      expect(find.text('06:50'), findsOneWidget);
      await tester.tap(find.text('20 min'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Between 06:30 and 06:50'), findsOneWidget);
      await tester.tap(find.text('Set alarm'));
      await tester.pumpAndSettle();
      expect((got!.on, got!.hour, got!.minute, got!.windowMin), (true, 6, 50, 20));
    });
  });

  group('Waking up', () {
    test('a light-sleep wake: when, why, the full-night scoring, I\'m awake', () {
      final w = wakingUp(_night(), _report());
      expect(w.lead, 'Smart alarm 07:00-07:30.');
      expect(w.rows, [('Woke you', '07:02'), ('Why', 'light sleep'), ('Full-night scoring', 'light sleep'), ('I\'m awake', 'after 95 s')]);
      expect(w.sentences, [
        'That was 28 min before 07:30, read by the live sleep model 2 minutes behind.',
        'The full-night scoring agrees: not deep sleep.',
      ]);
      expect(w.muted.last, contains('neither is checked against a sleep lab'));
    });

    test('a wake the full-night scoring calls deep sleep is said plainly', () {
      final w = wakingUp(_night(ringH: 6, ringM: 30), _report());
      expect(w.rows[2], ('Full-night scoring', 'deep sleep'));
      expect(w.sentences.last, 'The full-night scoring calls that minute deep sleep: the live reading was wrong this time.');
    });

    test('the window\'s end; the app gone; turned off; a re-ring', () {
      final end = wakingUp(_night(why: 'window end', ringH: 7, ringM: 30, by: 'window end'), _report());
      expect(end.rows[1], ('Why', 'the window\'s end'));
      expect(end.sentences.first, 'No light moment came inside the window, so it rang at its end.');
      final p = AlarmPlan(endMs: _ms(7, 30), windowMin: 30);
      final gone = wakingUp(
        AlarmNight(plan: p, rings: [(endMs: p.endMs, event: 'ring', atMs: p.endMs, by: 'window end', windowMin: null)]),
        _report(),
      );
      expect(gone.sentences.first, startsWith('The sleep model did not run (the app was not recording then)'));
      final off = wakingUp(
        AlarmNight(plan: p, rings: [(endMs: p.endMs, event: 'cancel', atMs: _ms(5, 2), by: null, windowMin: null)]),
        _report(),
      );
      expect((off.rows.single, off.sentences.single), (('Turned off', '05:02'), 'It did not ring.'));
      final again = wakingUp(_night(by: 'backup'), _report());
      expect(again.muted.first, 'The app was stopped while it rang; the phone\'s alarm rang again.');
    });

    test('the store finds the night\'s alarm by its window\'s end, from the ringer\'s lines or the model\'s file', () {
      final dir = Directory.systemTemp.createTempSync('alarm_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AlarmStore(dir);
      final p = AlarmPlan(endMs: _ms(7, 30), windowMin: 30);
      File('${dir.path}/rings.jsonl').writeAsStringSync(
        '${jsonEncode({'endMs': p.endMs, 'event': 'set', 'atMs': _ms(23, 20, 24), 'windowMin': 30})}\n'
        'damaged\n'
        '${jsonEncode({'endMs': p.endMs, 'event': 'ring', 'atMs': _ms(7, 6), 'by': 'smart'})}\n'
        '${jsonEncode({'endMs': _ms(7, 30, 26), 'event': 'set', 'atMs': _ms(23, 0, 25), 'windowMin': 20})}\n',
      );
      final r = _report();
      final a = store.forNight(r.dataStart, r.dataEnd)!;
      expect((a.plan.endMs, a.plan.windowMin, a.ring!.by, a.record), (p.endMs, 30, 'smart', null));
      store.write(p.endMs, {'plan': p.toJson(), 'wake': {'at_ms': _ms(7, 6), 'why': 'dream'}});
      expect(store.forNight(r.dataStart, r.dataEnd)!.why, AlarmWhy.dream);
      expect(store.forNight(DateTime(2026, 11, 20), DateTime(2026, 11, 21)), isNull);
    });
  });

  final states = _states();
  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1210, 2695); // 440 x 980 dp
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        await _shot(tester, e.value, scale, 2.75, 'build/screens/alarm_${e.key}${scale == 1.0 ? '' : '_text130'}.png');
      });
    }
  }
  // The owner's 11T is narrower (393 dp): the bar with two lines and two buttons must still fit at 130 % text.
  for (final name in ['setup_on', 'recording_scoring', 'ringing', 'sheet', 'waking_up']) {
    testWidgets('$name at 393 dp and 130 % text', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      await _shot(tester, states[name]!, 1.3, 1080 / 393, 'build/screens/alarm_${name}_393dp_text130.png');
    });
  }
}

Future<void> _shot(WidgetTester tester, Widget child, double scale, double ratio, String path) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: nightTheme(),
        home: RepaintBoundary(key: key, child: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: ratio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}
