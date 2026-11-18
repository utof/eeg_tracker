// Lights off and "Falling asleep" in words (lib/ui/lights_off_view.dart): the line above the night screen's buttons,
// the minutes, the agreement and the check, the bar's buttons and the question before a second Lights off.
import 'package:eeg_tracker/detectors/drift_off.dart' show DriftState;
import 'package:eeg_tracker/sleep/drift.dart';
import 'package:eeg_tracker/ui/lights_off_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t2342 = DateTime(2026, 11, 18, 23, 42).millisecondsSinceEpoch;
  final t2351 = DateTime(2026, 11, 18, 23, 51, 30).millisecondsSinceEpoch;

  test('the line above Lights off follows the detector', () {
    expect(lightsOffLine(lightsOffMs: null, drift: DriftState.awake, onsetMs: null),
        'Tap Lights off as you close your eyes to sleep.');
    expect(lightsOffLine(lightsOffMs: null, drift: DriftState.asleep, onsetMs: t2351),
        'Asleep since 23:51 by the detector, counted from the start.');
    expect(lightsOffLine(lightsOffMs: t2342, drift: DriftState.baseline, onsetMs: null),
        'Lights off 23:42. Learning your eyes-closed alpha (a minute).');
    expect(lightsOffLine(lightsOffMs: t2342, drift: DriftState.drowsy, onsetMs: null), 'Lights off 23:42. Drowsy, by the detector.');
    expect(lightsOffLine(lightsOffMs: t2342, drift: DriftState.asleep, onsetMs: t2351),
        'Lights off 23:42. Asleep since 23:51, by the detector.');
    expect(lightsOffLine(lightsOffMs: t2342, drift: null, onsetMs: null),
        'Lights off 23:42. The morning report works out when you fell asleep.',
        reason: 'the detector is off (after a restart, or it stopped)');
    expect(lightsOffLine(lightsOffMs: t2342, drift: null, onsetMs: null, recording: false), 'Lights off 23:42.',
        reason: 'still finding the headband: the detector starts with the first data');
  });

  test('minutes after lights off in half minutes', () {
    expect(afterText(17), '17 min');
    expect(afterText(17.5), '17½ min');
    expect(afterText(0.5), '½ min');
    expect(afterText(0), '0 min');
    expect(afterText(74.5), '1 h 15 min');
  });

  DriftResult result({double? on, double? model, LightsOffFrom from = LightsOffFrom.button}) {
    final diff = on != null && model != null ? on - model : null;
    final agree = on == null && model == null ? null : diff != null && diff.abs() <= 5;
    return DriftResult(
      lightsOff: DateTime(2026, 11, 18, 23, 42),
      from: from,
      onsetMin: on,
      modelOnsetMin: model,
      diffMin: diff,
      agree: agree,
      counted: from != LightsOffFrom.nightStart && agree != null,
    );
  }

  test('agreement in words', () {
    expect(agreeSentence(result(on: 17.5, model: 18)), 'They agree: half a minute apart, within 5 minutes.');
    expect(agreeSentence(result(on: 18, model: 18)), 'They agree to the half minute.');
    expect(agreeSentence(result(on: 13, model: 18)), 'They agree: 5 min apart, within 5 minutes.');
    expect(agreeSentence(result(on: 25.5, model: 18)), 'They are 7½ min apart, more than 5 minutes, so they disagree.');
    expect(agreeSentence(result(model: 18)), 'The detector did not see you fall asleep; the sleep model did.');
    expect(agreeSentence(result(on: 18)), 'The sleep model found no sleep after lights off; the detector did.');
    expect(agreeSentence(result()), 'Neither found you falling asleep after lights off.');
    expect(sourceSentence(result(on: 1, model: 1)), isNull);
    expect(sourceSentence(result(from: LightsOffFrom.nightStart)), contains('not tapped'));
  });

  test('the check in words', () {
    expect(checkSentence(const DriftCheck(0, 0)), startsWith('The check: no night with Lights off yet.'));
    expect(checkSentence(const DriftCheck(1, 1)), startsWith('The check so far: 1 of 1 night agrees within 5 minutes.'));
    expect(checkSentence(const DriftCheck(2, 3)), startsWith('The check so far: 2 of 3 nights agree'));
    expect(checkSentence(const DriftCheck(4, 5)), endsWith('so the detector can be trusted.'));
    expect(checkSentence(const DriftCheck(3, 5)), endsWith('it needs 4 to be trusted.'));
  });

  Widget app(Widget child) => MaterialApp(theme: nightTheme(), home: Scaffold(body: child));

  testWidgets('the bar: Lights off filled until tapped, then quiet; both call back', (tester) async {
    var lights = 0, stops = 0;
    await tester.pumpWidget(app(NightActions(
      line: 'Tap Lights off as you close your eyes to sleep.',
      tapped: false,
      busy: false,
      onLightsOff: () => lights++,
      onStop: () => stops++,
    )));
    expect(find.widgetWithText(FilledButton, 'Lights off'), findsOneWidget);
    await tester.tap(find.text('Lights off'));
    await tester.tap(find.text('Stop'));
    expect((lights, stops), (1, 1));
    await tester.pumpWidget(app(NightActions(line: null, tapped: true, busy: false, onLightsOff: () => lights++, onStop: () {})));
    expect(find.byType(FilledButton), findsNothing, reason: 'no filled button once lights off was given');
    await tester.tap(find.text('Lights off again'));
    expect(lights, 2);
  });

  testWidgets('a second Lights off asks first', (tester) async {
    bool? answer;
    await tester.pumpWidget(app(Builder(
      builder: (context) => TextButton(
        onPressed: () async => answer = await confirmLightsOffAgain(context, DateTime(2026, 11, 18, 23, 42)),
        child: const Text('again'),
      ),
    )));
    await tester.tap(find.text('again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('instead of 23:42'), findsOneWidget);
    await tester.tap(find.text('Keep 23:42'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    await tester.tap(find.text('again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lights off now'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });
}
