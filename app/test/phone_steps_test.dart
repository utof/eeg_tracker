// The phone's step counter in the night's log (DECISIONS 800-809): the minute rule of the lines, the switch's file and
// its page. The recorder end to end is in night_recorder_test.dart.
import 'dart:io';

import 'package:eeg_tracker/recorder/phone_steps.dart';
import 'package:eeg_tracker/ui/phone_steps_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

class _Steps implements StepProbe {
  _Steps(this.state);
  final String state;
  int? value;
  bool broken = false;
  int stops = 0;

  @override
  Future<String> start() async => state;

  @override
  Future<int?> read() async {
    if (broken) throw StateError('no sensor service');
    return value;
  }

  @override
  Future<void> stop() async => stops++;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('phone_steps_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('StepLog', () {
    test('one line in a clock minute, the next one at the first check of the next minute', () async {
      var now = DateTime(2026, 11, 20, 8, 59, 55);
      final probe = _Steps('on')..value = 1000;
      final lines = <String>[];
      final steps = StepLog(probe, () => now);
      await steps.setup(lines.add);
      expect(lines, ['phone step counter: on']);
      await steps.tick(lines.add); // 08:59:55
      now = DateTime(2026, 11, 20, 8, 59, 59);
      probe.value = 1010;
      await steps.tick(lines.add); // same minute: nothing
      now = DateTime(2026, 11, 20, 9, 0, 5);
      await steps.tick(lines.add);
      now = DateTime(2026, 11, 20, 9, 0, 15);
      probe.value = 1020;
      await steps.tick(lines.add); // same minute again
      expect(lines, ['phone step counter: on', 'phone steps 1000', 'phone steps 1010']);
    });

    test('no sensor event yet: nothing, and the minute is tried again at the next check', () async {
      var now = DateTime(2026, 11, 20, 8, 0, 5);
      final probe = _Steps('on');
      final lines = <String>[];
      final steps = StepLog(probe, () => now);
      await steps.setup(lines.add);
      await steps.tick(lines.add);
      now = DateTime(2026, 11, 20, 8, 0, 15);
      probe.value = 42;
      await steps.tick(lines.add);
      expect(lines, ['phone step counter: on', 'phone steps 42']);
    });

    test('a refused permission, no sensor or the switch off: said once, never read', () async {
      for (final state in ['no permission', 'no sensor', 'off']) {
        final probe = _Steps(state)..value = 5;
        final lines = <String>[];
        final steps = StepLog(probe, () => DateTime(2026, 11, 20, 8));
        await steps.setup(lines.add);
        await steps.tick(lines.add);
        expect(lines, ['phone step counter: $state']);
      }
    });

    test('a broken probe costs the lines only; a new run starts the minute count again', () async {
      final now = DateTime(2026, 11, 20, 8);
      final probe = _Steps('on')
        ..value = 7
        ..broken = true;
      final lines = <String>[];
      final steps = StepLog(probe, () => now);
      await steps.setup(lines.add);
      await steps.tick(lines.add);
      expect(lines, ['phone step counter: on']);
      probe.broken = false;
      await steps.tick(lines.add);
      await steps.setup(lines.add); // the next run's file
      await steps.tick(lines.add); // same clock minute, new file: a line again
      expect(lines, ['phone step counter: on', 'phone steps 7', 'phone step counter: on', 'phone steps 7']);
      await steps.stop();
      expect(probe.stops, 1);
    });
  });

  group('StepSettings', () {
    test('off when missing or damaged, on after setOn, and off again', () {
      final s = StepSettings(Directory('${tmp.path}/steps'));
      expect(s.on, isFalse);
      s.setOn(true, DateTime(2026, 11, 20));
      expect(StepSettings(Directory('${tmp.path}/steps')).on, isTrue);
      expect(File('${tmp.path}/steps/settings.json').readAsStringSync(), contains('"on":true'));
      File('${tmp.path}/steps/settings.json').writeAsStringSync('{broken');
      expect(s.on, isFalse);
      s.setOn(false, DateTime(2026, 11, 20));
      expect(s.on, isFalse);
    });

    test('the folder sits beside the recordings folder', () {
      expect(stepsDirFor('/data/files/recordings').path, '/data/files/steps');
    });
  });

  group('PhoneStepsSwitch', () {
    Future<StepSettings> pump(WidgetTester tester, {required PermissionStatus answer, List<String>? opened}) async {
      final settings = StepSettings(Directory('${tmp.path}/steps'));
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PhoneStepsSwitch(
                settings: settings,
                ask: () async => answer,
                openSettings: () async => opened?.add('app settings'),
                now: () => DateTime(2026, 11, 20, 9),
              ),
            ),
          ),
        ),
      );
      return settings;
    }

    testWidgets('off at first; switching on asks the permission and saves the switch', (tester) async {
      final settings = await pump(tester, answer: PermissionStatus.granted);
      expect(find.text('Count steps with the phone while recording'), findsOneWidget);
      expect(find.textContaining('trouser pocket'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(settings.on, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(settings.on, isFalse);
    });

    testWidgets('a refused permission leaves it off and says so', (tester) async {
      final settings = await pump(tester, answer: PermissionStatus.denied);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(settings.on, isFalse);
      expect(find.textContaining('Still off'), findsOneWidget);
      expect(find.text("Open the app's settings"), findsNothing);
    });

    testWidgets('a permission the phone will not ask again offers the app\'s settings', (tester) async {
      final opened = <String>[];
      await pump(tester, answer: PermissionStatus.permanentlyDenied, opened: opened);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text("Open the app's settings"));
      await tester.pump();
      expect(opened, ['app settings']);
    });

    testWidgets('a switch saved before shows on', (tester) async {
      StepSettings(Directory('${tmp.path}/steps')).setOn(true, DateTime(2026, 11, 20));
      await pump(tester, answer: PermissionStatus.granted);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });
  });
}
