// Renders the "Unusual for you" section in its states on the Trends page and its line in the night screen's
// Morning section at the owner's Xiaomi 11T size (393 dp wide) with real fonts, writes build/screens/unusual_*.png
// for a human look, and fails on any layout overflow (also at 130 % text). Then the controls and the page's wiring
// on a fake app folder: the switch, a cause, "feeling ill" and Resume.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/morning_section.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/trends_screen.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:eeg_tracker/ui/unusual_view.dart';
import 'package:eeg_tracker/unusual/card.dart';
import 'package:eeg_tracker/unusual/detector.dart';
import 'package:eeg_tracker/unusual/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

const _start = '2026-10-01';
String _day(int k) => addDays(_start, k);
double _wobble(int k) => 420.0 + 10 * ((k % 3) - 1);
Map<String, double> _series(int n, double? Function(int k) f) => {
  for (var k = 0; k < n; k++)
    if (f(k) != null) _day(k): f(k)!,
};

UnusualCard _card(Map<String, Map<String, double>> s, int today, {Map<String, Set<String>> causes = const {}, List<Ill> ill = const []}) {
  final v = judgeDays(s, _start, _day(today), ill: ill);
  return unusualCard(v, s, _day(today), causes: causes, pausedUntil: pauseEnd(ill, _day(today)));
}

final Map<String, UnusualCard?> _states = {
  'off': offCard,
  'learning': _card({'asleep': _series(13, _wobble)}, 12),
  'quiet': _card({'asleep': _series(80, (k) => (k == 22 || k == 23 || k == 50 || k == 51) ? 300 : _wobble(k))}, 79),
  'alert': _card({'asleep': _series(60, (k) => k >= 58 ? 300 : _wobble(k))}, 59),
  'alert_many': _card(
    {
      'asleep': _series(60, (k) => k == 58 ? null : (k == 57 || k == 59 ? 330 : _wobble(k))),
      'kss': _series(60, (k) => k >= 58 ? 7 : 4),
      'mood': _series(60, (k) => k >= 58 ? 2 : (k % 4 == 0 ? 3 : 4)),
      'tension': _series(60, (k) => k >= 58 ? 4 : 2),
      'reaction': _series(60, (k) => k >= 58 ? 340 : 280.0 + k % 3),
    },
    59,
    causes: {
      _day(59): {'late night', 'stress'},
    },
  ),
  'back': _card({'asleep': _series(80, (k) => (k == 70 || k == 71) ? 300 : _wobble(k))}, 72),
  'paused': _card(
    {'asleep': _series(62, (k) => (k == 58 || k == 59) ? 300 : _wobble(k))},
    61,
    ill: [Ill(start: _day(59), tapped: _day(59))],
  ),
  'error': null,
};

/// The day each state is shown on (the page's "Today" matches the card).
const Map<String, int> _today = {'learning': 12, 'quiet': 79, 'back': 72, 'paused': 61};

Widget _page(String state, UnusualCard? card) => TrendsView(
  model: buildTrends((nights: const [], mornings: const [], sessions: const []), dayNoon(_day(_today[state] ?? 59))),
  onInfo: () {},
  unusual: UnusualSection(
    card: card,
    error: 'FileSystemException: Cannot open file',
    onSwitch: (_) {},
    onInfo: () {},
    onCauses: (_) {},
    onResume: () {},
  ),
);

Future<void> _shoot(WidgetTester tester, Widget w, String name, {double scale = 1, double height = 873}) async {
  tester.view.physicalSize = Size(1080, height * 1080 / 393); // the owner's Xiaomi 11T: 393 x 873 dp
  tester.view.devicePixelRatio = 1080 / 393;
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
    final image = await boundary.toImage(pixelRatio: height > 873 ? 1.6 : 1080 / 393);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  test('the rendered states are the ones named', () {
    expect({for (final e in _states.entries) e.key: e.value?.kind}, {
      'off': CardKind.off,
      'learning': CardKind.learning,
      'quiet': CardKind.quiet,
      'alert': CardKind.alert,
      'alert_many': CardKind.alert,
      'back': CardKind.back,
      'paused': CardKind.paused,
      'error': null,
    });
    expect(_states['alert_many']!.lines.length, 4);
  });

  for (final scale in [1.0, 1.3]) {
    for (final e in _states.entries) {
      testWidgets('unusual ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        final name = 'unusual_${e.key}${scale == 1.0 ? '' : '_text130'}';
        await _shoot(tester, _page(e.key, e.value), name, scale: scale);
        await _shoot(tester, _page(e.key, e.value), '${name}_whole', scale: scale, height: 2000);
      });
    }
    testWidgets('the main screen line at ${(scale * 100).round()} % text', (tester) async {
      final line = _states['alert_many']!.mainLine!;
      final w = Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            MorningSection(doneAt: '09:12', onCheckIn: () {}, onTrends: () {}, unusual: line),
          ],
        ),
      );
      await _shoot(tester, w, 'unusual_main_line${scale == 1.0 ? '' : '_text130'}', scale: scale);
      expect(find.text(line), findsOneWidget);
    });
  }

  group('the controls', () {
    Future<void> pump(WidgetTester tester, Widget w) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: Scaffold(body: ListView(children: [w]))));
    }

    testWidgets('a chip adds or takes back a cause; the switch says off', (tester) async {
      Set<String>? causes;
      bool? on;
      await pump(
        tester,
        UnusualSection(card: _states['alert_many'], onCauses: (c) => causes = c, onSwitch: (v) => on = v),
      );
      await tester.tap(find.widgetWithText(FilterChip, 'Alcohol'));
      expect(causes, {'late night', 'stress', 'alcohol'});
      await tester.tap(find.widgetWithText(FilterChip, 'Stress'));
      expect(causes, {'late night'});
      await tester.tap(find.byType(Switch));
      expect(on, isFalse);
    });

    testWidgets('a pause has Resume now; with no card the switch cannot be used', (tester) async {
      var resumed = false;
      await pump(tester, UnusualSection(card: _states['paused'], onResume: () => resumed = true));
      await tester.tap(find.text('Resume now'));
      expect(resumed, isTrue);
      await pump(tester, UnusualSection(card: null, error: 'broken', onSwitch: (_) {}));
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.text('It could not be worked out: broken.'), findsOneWidget);
    });
  });

  group('the Trends page on a fake app folder', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('unusual_screens'));
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('it learns at first; the switch turns it off and back on, saved in files/unusual', (tester) async {
      final rec = '${tmp.path}/files/recordings';
      Directory(rec).createSync(recursive: true);
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: TrendsScreen(recordingsDir: rec)));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.textContaining('Learning your usual: 0 of 28 days.'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byType(Switch));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.textContaining('Off. When on'), findsOneWidget);
      final settings = jsonDecode(File('${tmp.path}/files/unusual/settings.json').readAsStringSync()) as Map;
      expect(settings['on'], isFalse);
      expect(UnusualStore(unusualDirFor(rec)).on, isFalse);
      expect(unusualToday(rec, DateTime.now()).kind, CardKind.off);
    });
  });
}
