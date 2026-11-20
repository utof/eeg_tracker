// Renders the morning check-in, the trends page and the night screen's Morning section in their states at a
// phone's size with real fonts, writes build/screens/morning_*.png and trends_*.png for a human look, and fails on
// any layout overflow (also at 130 % text). The days are made up (fixed patterns), not recordings.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/morning/controller.dart';
import 'package:eeg_tracker/morning/live.dart';
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/recorder/contact.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/morning_screen.dart' show outcomeFor;
import 'package:eeg_tracker/ui/morning_section.dart';
import 'package:eeg_tracker/ui/form_parts.dart' show ChoiceQuestion;
import 'package:eeg_tracker/ui/morning_view.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final _now = DateTime(2026, 11, 18, 15, 10);

/// [jaw]: the night extras' jaw muscle bursts an hour asleep (report version 2); null: an older report without them.
SleepReport _night(DateTime start, double hours, {double? jaw}) {
  final end = start.add(Duration(minutes: (hours * 60).round()));
  final asleep = hours * 60 - 20;
  Map<String, Object?> tally(int bursts) => {
    'min': asleep,
    'good_min': asleep,
    'degraded_min': 0,
    'missing_min': 0,
    'jaw_bursts': bursts,
    'one_sided_bursts': 0,
    'movement_bursts': 0,
    'moves': 0,
  };
  return SleepReport({
    if (jaw != null)
      'extras': {
        'version': 1,
        'quality': '',
        'night': tally((jaw * asleep / 60).round()),
        'asleep': {...tally((jaw * asleep / 60).round()), 'jaw_per_hour': jaw, 'moves_per_hour': 12.0},
        'hours': const <Object?>[],
      },
    'night_of': '${start.year}-${start.month}-${start.day}',
    'scored': true,
    'data_start': isoLocal(start),
    'data_end': isoLocal(end),
    'total': {'asleep_min': asleep, 'recorded_min': hours * 60, 'missing_min': 0, 'stray_sleep_min': 0},
    'periods': [
      {
        'start': isoLocal(start.add(const Duration(minutes: 15))),
        'end': isoLocal(end),
        'asleep_min': asleep,
        'light_min': asleep / 2,
        'deep_min': asleep / 4,
        'dream_min': asleep / 4,
        'awake_min': 5,
        'wake_ups': 0,
        'missing_min': 0,
      },
    ],
  });
}

MorningRecord _morning(DateTime start, {required int kss, double iaf = 9.6, double alpha = 31, double? reaction}) =>
    MorningRecord.fromJson({
      'version': 'morning-v1',
      'start': isoLocal(start),
      'back': {'alpha_ec_uv2': alpha, 'ec_rise': alpha / 12.2, 'iaf_hz': iaf, 'clean_share': 0.97},
      'ratings': {'kss': kss, 'mood': 4, 'tension': 2},
      'habits': {'caffeine_cups': 2, 'caffeine_late': false, 'caffeine_today': false, 'alcohol_drinks': kss > 6 ? 2 : 0},
      'reaction': reaction == null ? null : {'median_ms': reaction},
    })!;

MeditationSummary _session(DateTime start, double runS, double settledS) => MeditationSummary(
  start: start,
  lengthMin: runS / 60,
  runS: runS,
  complete: true,
  settledS: settledS,
  longestSettledS: settledS / 3,
  bells: 4,
  restless: const {},
  drifting: 0,
  drowsyS: 0,
  calm: const [],
  iafHz: 9.7,
  note: '',
  logFile: 'x.session.json',
);

/// The owner's state today: the night of 06:51-14:36, one check-in, one meditation.
final TrendInputs _first = (
  nights: [_night(DateTime(2026, 11, 18, 6, 51), 7.75, jaw: 22.8)],
  mornings: [_morning(DateTime(2026, 11, 18, 14, 48), kss: 8, iaf: 9.62, alpha: 31.3)],
  sessions: [_session(DateTime(2026, 11, 18, 15, 0), 600, 270)],
);

/// Days of made-up data ending today: regular-ish nights, mornings, some meditations; today a short night.
TrendInputs _days(int n) {
  final r = math.Random(5), j = math.Random(7);
  return (
    nights: [
      for (var d = n; d >= 0; d--)
        _night(
          DateTime(2026, 11, 18 - d, 0, 20 + r.nextInt(50)),
          d == 0 ? 4.6 : 6.8 + r.nextDouble() * 1.2,
          // the jaw count from the night extras on (older reports have none); today a tense night
          jaw: d > 40 ? null : (d == 0 ? 34.6 : ((18 + j.nextDouble() * 8) * 10).round() / 10),
        ),
    ],
    mornings: [
      for (var d = n; d >= 0; d--)
        if (d % 9 != 4)
          _morning(
            DateTime(2026, 11, 18 - d, 8, 30),
            kss: d == 0 ? 7 : 3 + r.nextInt(3),
            iaf: 9.5 + r.nextDouble() * 0.3,
            alpha: 26 + r.nextDouble() * 10,
            reaction: d == 0 ? 361 : 290 + r.nextDouble() * 30,
          ),
    ],
    sessions: [
      for (var d = n; d >= 0; d--)
        if (d % 3 == 0) _session(DateTime(2026, 11, 18 - d, 19), 600, 200 + r.nextDouble() * 200),
    ],
  );
}

final _month = buildTrends(_days(30), DateTime(2026, 11, 18, 13));

List<ContactLine> _contact({bool noisy = false}) => [
  (channel: 'O1', contact: Contact.good, grade: Grade.good, word: 'good', spread: 14),
  (channel: 'O2', contact: Contact.good, grade: noisy ? Grade.bad : Grade.good, word: noisy ? 'noisy' : 'good', spread: noisy ? 74 : 17),
  (channel: 'T3', contact: Contact.fair, grade: Grade.fair, word: 'fair', spread: 38),
  (channel: 'T4', contact: Contact.none, grade: Grade.bad, word: 'not touching', spread: 0),
];

MorningOutcome _outcome(TrendInputs inputs) => outcomeFor(inputs.mornings.last, inputs);

void _no() {}

/// A page with every action wired, so buttons render as the owner sees them.
Widget _v(MorningViewModel m) => MorningView(
  model: m,
  onCheckContact: _no,
  onRecheck: _no,
  onBegin: _no,
  onStop: _no,
  onDone: _no,
  onTrends: _no,
  onInfo: _no,
  onSave: (_) {},
);

final Map<String, Widget> _states = {
  'morning_intro': _v(const MorningViewModel(stage: MorningStage.intro)),
  'morning_intro_done': _v(const MorningViewModel(stage: MorningStage.intro, doneTodayAt: '09:12')),
  'morning_intro_night': _v(const MorningViewModel(stage: MorningStage.intro, nightRunning: true)),
  'morning_failed': _v(
    const MorningViewModel(
      stage: MorningStage.failed,
      message: 'Headband not found. Is it switched on, charged, and free (no night recording)?',
    ),
  ),
  'morning_connecting': _v(const MorningViewModel(stage: MorningStage.connecting, message: 'Found BrainBit. Connecting.')),
  'morning_contact': _v(MorningViewModel(stage: MorningStage.contact, contact: _contact())),
  'morning_contact_noisy': _v(
    MorningViewModel(stage: MorningStage.contact, contact: _contact(noisy: true), rechecking: true),
  ),
  'morning_closed': _v(const MorningViewModel(stage: MorningStage.closed, secondsLeft: 87)),
  'morning_closed_nosignal': _v(const MorningViewModel(stage: MorningStage.closed, secondsLeft: 61, noSignal: true)),
  'morning_open': _v(const MorningViewModel(stage: MorningStage.open, secondsLeft: 104)),
  'morning_questions': _v(const MorningViewModel(stage: MorningStage.questions)),
  'morning_result_first': _v(MorningViewModel(stage: MorningStage.result, outcome: _outcome(_first))),
  'morning_result_month': _v(MorningViewModel(stage: MorningStage.result, outcome: _outcome(_days(30)))),
  'trends_empty': TrendsView(model: buildTrends((nights: const [], mornings: const [], sessions: const []), _now)),
  'trends_first': TrendsView(model: buildTrends(_first, _now)),
  'trends_month': TrendsView(model: _month),
  'trends_forecast': TrendsView(model: buildTrends(_days(75), DateTime(2026, 11, 18, 13))),
  'night_morning': NightView(
    model: const NightViewModel(title: 'Ready', sentence: 'Last night is saved.', tone: Tone.calm, running: false),
    onStart: () {},
    onStop: () {},
    onFix: (_) {},
    morning: MorningSection(doneAt: null, onCheckIn: () {}, onTrends: () {}),
  ),
};

Future<void> _shoot(WidgetTester tester, Widget w, String name, {double scale = 1, double height = 980}) async {
  tester.view.physicalSize = Size(1210, height * 2.75); // about a Xiaomi 12T: 440 x 980 dp
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: w)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: height > 980 ? 2.0 : 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  test('the made-up month shows usual, arrows and a hidden forecast', () {
    final asleep = _month.rows.singleWhere((r) => r.spec.id == 'asleep');
    expect(asleep.usual.arrowsReady, isTrue);
    expect(asleep.arrow.name, 'down');
    expect(_month.forecast.shown, isFalse);
  });

  for (final scale in [1.0, 1.3]) {
    for (final e in _states.entries) {
      testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
        await _shoot(tester, e.value, '${e.key}${scale == 1.0 ? '' : '_text130'}', scale: scale);
      });
    }
  }

  for (final name in ['trends_first', 'trends_month', 'trends_forecast', 'morning_questions', 'morning_result_month']) {
    testWidgets('$name, the whole page for a look', (tester) async {
      await _shoot(tester, _states[name]!, '${name}_full', height: 3200);
    });
  }

  testWidgets('the questions: Save waits for every answer and says so', (tester) async {
    MorningAnswers? saved;
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: MorningView(model: const MorningViewModel(stage: MorningStage.questions), onSave: (a) => saved = a),
      ),
    );
    expect(find.text('Answer each question'), findsOneWidget);
    Future<void> pick<T extends Object>(String question, String label) async {
      await tester.scrollUntilVisible(find.text(question), 150);
      await tester.pump();
      final q = find.ancestor(of: find.text(question), matching: find.byType(ChoiceQuestion<T>));
      await tester.tap(find.descendant(of: q, matching: find.text(label)));
      await tester.pump();
    }

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pump();
    await pick<int>('Mood', '3');
    await pick<int>('Tension', '2');
    await pick<int>('Cups of coffee, strong tea or energy drinks', '2');
    await pick<int>('Drinks of alcohol (a beer, a glass of wine or a shot each)', '0');
    expect(find.text('Answer each question'), findsOneWidget); // the late cup and this morning still open
    await pick<bool>('Any in the 8 hours before you went to sleep?', 'No');
    await pick<bool>('Any caffeine before this check-in?', 'No');
    expect(find.text('Save without the reaction test'), findsOneWidget);
    await tester.tap(find.text('Save without the reaction test'));
    expect(saved, isNotNull);
    expect(saved!.cups, 2);
    expect(saved!.caffeineLate, isFalse);
    expect(saved!.reaction, isNull);
    expect(saved!.sleep, isNull); // "How did you sleep?" is optional: Save did not wait for it
  });

  testWidgets('the questions: one tap on "How did you sleep?" is kept, and Save still waits only for the others', (tester) async {
    MorningAnswers? saved;
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: MorningView(model: const MorningViewModel(stage: MorningStage.questions), onSave: (a) => saved = a),
      ),
    );
    Future<void> pick<T extends Object>(String question, String label) async {
      await tester.scrollUntilVisible(find.text(question), 150);
      await tester.pump();
      final q = find.ancestor(of: find.text(question), matching: find.byType(ChoiceQuestion<T>));
      await tester.tap(find.descendant(of: q, matching: find.text(label)));
      await tester.pump();
    }

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pump();
    await pick<int>('Mood', '3');
    await pick<int>('Tension', '2');
    await pick<int>('How did you sleep? (optional)', '4');
    expect(find.text('1 very badly'), findsOneWidget);
    expect(find.text('5 very well'), findsOneWidget);
    expect(find.text('Answer each question'), findsOneWidget); // the tap alone does not finish the questions
    await pick<int>('Cups of coffee, strong tea or energy drinks', '0');
    await pick<int>('Drinks of alcohol (a beer, a glass of wine or a shot each)', '0');
    await pick<bool>('Any caffeine before this check-in?', 'No');
    await tester.tap(find.text('Save without the reaction test'));
    expect(saved!.sleep, 4);
  });
}
