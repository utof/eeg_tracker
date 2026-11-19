// Renders the sharp-hours page and the one-tap question in their states at the owner's phone width (393 dp) with
// real fonts, writes build/screens/sharp_*.png for a human look, and fails on any layout overflow (also at 130 %
// text). Then the flows on a fake app folder with a fake phone: switch on, change the count, rate, delete.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/alphatheta/rules.dart' show ReactionTest;
import 'package:eeg_tracker/sharp/hours.dart';
import 'package:eeg_tracker/sharp/page.dart';
import 'package:eeg_tracker/sharp/prompts.dart';
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sharp/store.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/sharp_hours_screen.dart';
import 'package:eeg_tracker/ui/sharp_chart.dart';
import 'package:eeg_tracker/ui/sharp_hours_view.dart';
import 'package:eeg_tracker/ui/sharp_rating_screen.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;
import 'sharp_prompts_test.dart' show FakeSharpPhone;

final DateTime _now = DateTime(2026, 11, 28, 16, 20);

/// A recorded night ending at [wake] after 7.5 hours (made up).
SleepReport _night(DateTime wake) {
  final start = wake.subtract(const Duration(minutes: 450));
  return SleepReport({
    'night_of': dayKey(start),
    'scored': true,
    'data_start': isoLocal(start),
    'data_end': isoLocal(wake),
    'total': {'asleep_min': 420.0, 'recorded_min': 450.0, 'missing_min': 0, 'stray_sleep_min': 0},
    'periods': [
      {
        'start': isoLocal(start),
        'end': isoLocal(wake),
        'asleep_min': 420.0,
        'light_min': 300.0,
        'deep_min': 60.0,
        'dream_min': 60.0,
        'awake_min': 30.0,
        'wake_ups': 1,
        'missing_min': 0,
      },
    ],
  });
}

/// [days] days up to [last] of made-up answers to the schedule's own moments (a fifth missed), sharper before noon
/// and slower in the evening when [peak]; a reaction test after about half of them.
({List<SharpRating> r, List<SharpReaction> t, List<SleepReport> n}) _data(int days, DateTime last, {bool peak = false, int seed = 3}) {
  final g = math.Random(seed);
  final r = <SharpRating>[], t = <SharpReaction>[], n = <SleepReport>[];
  for (var d = days - 1; d >= 0; d--) {
    final day = addDays(dayKey(last), -d);
    final noon = dayNoon(day);
    n.add(_night(DateTime(noon.year, noon.month, noon.day, 7, 10 + g.nextInt(40))));
    for (final p in promptsForDay(day, _on())) {
      final at = p.at.add(Duration(minutes: 1 + g.nextInt(6)));
      if (at.isAfter(last) || g.nextDouble() < 0.2) continue;
      final h = at.hour + at.minute / 60;
      final base = 3 + (peak && h < 12 ? 1 : 0) + (peak && h > 19 ? -1 : 0);
      final v = (base + (g.nextDouble() + g.nextDouble() - 1) * 1.6).round().clamp(1, 5);
      r.add(SharpRating(at: at, sharp: v, prompt: p.at, shown: p.at, testAsked: p.test));
      if (p.test || g.nextDouble() < 0.2) {
        final ms = (peak && h < 12 ? 280 : 315) + g.nextInt(30);
        t.add(SharpReaction(at: at.add(const Duration(minutes: 2)), ratingAt: at, timesMs: List.filled(9, ms)));
      }
    }
  }
  return (r: r, t: t, n: n);
}

SharpSettings _on({DateTime? changed}) => SharpSettings(
  on: true,
  perDay: 4,
  fromMin: 9 * 60 + 30,
  untilMin: 22 * 60 + 30,
  seed: 'render',
  firstOn: DateTime(2026, 11, 1),
  changed: changed ?? DateTime(2026, 11, 1),
);

/// Every prompt of the last 7 days as arrived (or only [share] of them), shown unless a recording was running.
List<PromptEvent> _arrived(SharpSettings s, {double share = 1}) {
  final out = <PromptEvent>[];
  var k = 0;
  for (var d = 1; d <= 7; d++) {
    for (final p in promptsForDay(addDays(dayKey(_now), -d), s)) {
      k++;
      if (share < 1 && k.isEven) continue;
      out.add(PromptEvent(planned: p.at, at: p.at, event: k % 9 == 0 ? PromptEventKind.skipped : PromptEventKind.shown));
    }
  }
  return out;
}

SharpPageModel _model({
  SharpSettings? saved,
  int days = 0,
  bool peak = false,
  double share = 1,
  bool notifications = true,
}) {
  final d = days == 0 ? (r: <SharpRating>[], t: <SharpReaction>[], n: <SleepReport>[]) : _data(days, _now, peak: peak);
  return buildSharpPage(
    saved: saved,
    ratings: d.r,
    reactions: d.t,
    events: saved == null ? const [] : _arrived(saved, share: share),
    reports: d.n,
    now: _now,
    seed: 'render',
    notificationsOn: notifications,
    xiaomi: true,
  );
}

void _no() {}

/// The page as on the phone: every control live (a render with no callbacks would draw them all disabled).
Widget _page(SharpPageModel m, [SharpAxis axis = SharpAxis.clock]) => SharpHoursView(
  model: m,
  axis: axis,
  onAxis: (_) {},
  onToggle: (_) {},
  onWindow: _no,
  onPerDay: (_) {},
  onRate: _no,
  onInfo: _no,
  onNotifications: _no,
  onPhoneSettings: (_) {},
  onSound: _no,
  onDelete: _no,
);

final _launch = SharpLaunch(planned: DateTime(2026, 11, 28, 14, 2), shown: DateTime(2026, 11, 28, 14, 3), test: true);
final _rated = SharpRating(at: DateTime(2026, 11, 28, 14, 5), sharp: 4, prompt: DateTime(2026, 11, 28, 14, 2));

/// The page's states: each shot as the first screen and at full length, at 100 and 130 % text.
final Map<String, Widget Function()> pages = {
  'page_new': () => _page(_model()),
  'page_collecting': () => _page(_model(saved: _on(), days: 9)),
  'page_held_back': () => _page(_model(saved: _on(), days: 5, share: 0.5, notifications: false)),
  'page_open_clock': () => _page(_model(saved: _on(), days: 30, peak: true)),
  'page_open_since_waking': () => _page(_model(saved: _on(), days: 30, peak: true), SharpAxis.sinceWake),
  'page_open_pressure': () => _page(_model(saved: _on(), days: 30), SharpAxis.pressure),
  'trends_section': () => TrendsView(
    model: buildTrends((nights: const [], mornings: const [], sessions: const []), _now, extra: {
      'sharp': {dayKey(_now): 3.4},
    }),
    onSharp: _no,
    onExperiments: _no,
    sharpLine: 'On. Collecting: 23 of about 60 ratings, day 9 of 21.',
  ),
};

/// The question's steps: one screen each.
final Map<String, Widget Function()> questions = {
  'question_ask': () => SharpQuestionView(stage: QuestionStage.ask, launch: _launch, onRate: (_) {}),
  'question_ask_page': () => SharpQuestionView(stage: QuestionStage.ask, onRate: (_) {}),
  'question_saved': () => SharpQuestionView(stage: QuestionStage.saved, saved: _rated, canTest: true, onTest: _no, onDone: _no),
  'question_test': () => SharpQuestionView(stage: QuestionStage.test, saved: _rated, launch: _launch, testSeed: 1, onDone: _no),
  'question_tested': () => SharpQuestionView(
    stage: QuestionStage.test,
    saved: _rated,
    launch: _launch,
    tested: true,
    onDone: _no,
    finished: ReactionTest()
      ..times.addAll(const [298, 312, 305, 341, 287, 330, 296, 318, 309, 352, 301, 294, 325])
      ..falseStarts = 1,
  ),
};

/// Pushes [w] over a stub page (as the app opens it, so the app bar has its Back arrow), checks for overflow and
/// writes build/screens/[name].png; [height] in dp (873 = the owner's first screen; more = the whole page).
Future<void> _shoot(WidgetTester tester, Widget w, String name, double scale, {double height = 873}) async {
  tester.view.physicalSize = Size(1080, height * 1080 / 393); // the owner's Xiaomi 11T: 393 dp wide
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(navigatorKey: nav, debugShowCheckedModeBanner: false, theme: nightTheme(), home: const Scaffold()),
    ),
  );
  unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => RepaintBoundary(key: key, child: w))));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1080 / 393);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name${scale == 1.0 ? '' : '_text130'}.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    final pct = (scale * 100).round();
    for (final e in pages.entries) {
      testWidgets('sharp ${e.key} at $pct % text, first screen and full length', (tester) async {
        await _shoot(tester, e.value(), 'sharp_${e.key}', scale);
        await _shoot(tester, e.value(), 'sharp_${e.key}_full', scale, height: scale == 1.0 ? 2700 : 3500);
      });
    }
    for (final e in questions.entries) {
      testWidgets('sharp ${e.key} at $pct % text', (tester) async {
        await _shoot(tester, e.value(), 'sharp_${e.key}', scale);
      });
    }
  }

  group('the words', () {
    test('status, delivery and the collecting sentence', () {
      expect(sharpStatus(_model()), 'Off. Nothing is asked until you switch it on.');
      expect(sharpStatus(_model(saved: _on())), 'On: 4 a day at random moments, 09:30 to 22:30.');
      final collecting = _model(saved: _on(), days: 9);
      expect(collecting.gate.open, isFalse);
      expect(ratingWords(collecting, SharpAxis.clock), startsWith('Dots only for now'));
      expect(reachWords(collecting), startsWith('Last 7 days: 28 of 28 questions arrived'));
      expect(reachWords(_model(saved: _on(), share: 0.5)), startsWith('Only 14 of 28 questions reached you'));
    });

    test('after 30 days with a morning peak the clock names it; the reaction tests too', () {
      final m = _model(saved: _on(), days: 30, peak: true);
      expect(m.gate.open, isTrue);
      expect(ratingWords(m, SharpAxis.clock), startsWith('Sharpest 09:30 to 12:00'), reason: 'both morning blocks, from the window\'s start');
      expect(reactionWords(m, SharpAxis.clock), startsWith('Quickest 10:00 to 12:00'));
      expect(axisNote(SharpAxis.sinceWake, 2), contains('2 answers have no recorded wake-up'));
    });

    test('the clock\'s columns follow the waking window, past midnight in order', () {
      expect(chartBlocksOf(SharpAxis.clock, 570, 1350), [4, 5, 6, 7, 8, 9, 10, 11]);
      expect(chartBlocksOf(SharpAxis.clock, 15 * 60, 3 * 60), [7, 8, 9, 10, 11, 0, 1]);
    });
  });

  group('the flows on a fake app folder', () {
    late Directory tmp;
    late String rec;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sharp-ui');
      rec = '${tmp.path}/files/recordings';
      Directory(rec).createSync(recursive: true);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('switch on: settings saved with a new secret, the moments handed to the phone; 6 a day re-arms', (tester) async {
      final phone = FakeSharpPhone();
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: SharpHoursScreen(recordingsDir: rec, phone: phone, now: () => _now)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('Off. Nothing is asked until you switch it on.'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      final store = SharpStore(sharpDirFor(rec));
      final s = store.settings()!;
      expect(s.on, isTrue);
      expect(s.perDay, 4);
      expect(s.seed, hasLength(32));
      expect(s.firstOn, _now);
      expect(phone.armed.last, isNotEmpty);
      expect(phone.armed.last.first.at.isAfter(_now), isTrue);
      await tester.tap(find.text('6'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(store.settings()!.perDay, 6);
      expect(phone.armed.last.length, greaterThan(phone.armed.first.length));
      final events = File('${store.dir.path}/events.jsonl').readAsLinesSync();
      expect(events, hasLength(2));
    });

    testWidgets('a question from a notification: one tap saves it with its prompt, then the suggested test', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: SharpRatingScreen(recordingsDir: rec, launch: _launch, now: () => _now)));
      await tester.tap(find.text('Sharp'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      final r = SharpStore(sharpDirFor(rec)).ratings().single;
      expect(r.sharp, 4);
      expect(r.prompt, _launch.planned);
      expect(r.shown, _launch.shown);
      expect(r.testAsked, isTrue);
      expect(find.text('Now the 1-minute reaction test'), findsOneWidget);
    });

    testWidgets('rated from the page: no prompt; the test is offered, not started', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: SharpRatingScreen(recordingsDir: rec, now: () => _now)));
      await tester.tap(find.text('Foggy'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      final r = SharpStore(sharpDirFor(rec)).ratings().single;
      expect(r.sharp, 1);
      expect(r.prompted, isFalse);
      expect(find.text('Saved: 1, Foggy.'), findsOneWidget);
      expect(find.text('1-minute reaction test'), findsOneWidget);
    });

    testWidgets('delete asks once, then removes every file and stops the questions', (tester) async {
      final phone = FakeSharpPhone();
      final store = SharpStore(sharpDirFor(rec))
        ..saveSettings(_on())
        ..addRating(SharpRating(at: _now, sharp: 3));
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: SharpHoursScreen(recordingsDir: rec, phone: phone, now: () => _now)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Delete my sharp-hours data'), 300);
      await tester.tap(find.text('Delete my sharp-hours data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(store.dir.existsSync(), isFalse);
      expect(phone.armed.last, isEmpty);
    });
  });
}

/// The clock's columns for a window, with no answers.
List<int> chartBlocksOf(SharpAxis axis, int from, int until) => chartBlocks(axis, const [], fromMin: from, untilMin: until);

/// For a look at the made-up month's blocks.
SharpPageModel debugModel() => _model(saved: _on(), days: 30, peak: true);
