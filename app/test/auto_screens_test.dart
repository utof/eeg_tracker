// "When I put the headband on" (DECISIONS 600-609): the page at the owner's phone width (393 dp) with real fonts, at
// 100 % and 130 % text, with no layout overflow (build/screens/auto_*.png for a human look); what this phone allows, in
// words; and the flows on a fake app folder: the defaults, a change saved, other cannot start by itself, the offer.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/auto/bedtime.dart';
import 'package:eeg_tracker/auto/channel.dart';
import 'package:eeg_tracker/auto/log.dart';
import 'package:eeg_tracker/auto/store.dart';
import 'package:eeg_tracker/ui/auto_start_screen.dart';
import 'package:eeg_tracker/ui/auto_start_view.dart';
import 'package:eeg_tracker/ui/hands_free_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

const WatchStatus _xiaomiUnpaired = WatchStatus({
  'sdkInt': 34,
  'companion': true,
  'presence': true,
  'paired': false,
  'batteryExempt': false,
  'notifications': true,
  'xiaomi': 'OS1.0.6.0',
});

const WatchStatus _paired = WatchStatus({
  'sdkInt': 34,
  'companion': true,
  'presence': true,
  'paired': true,
  'observing': true,
  'name': 'BB Black',
  'batteryExempt': true,
  'notifications': true,
});

Future<void> _shoot(WidgetTester tester, Widget w, String name, double scale, {double height = 873}) async {
  tester.view.physicalSize = Size(1080, height * 1080 / 393);
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: nightTheme(),
        home: RepaintBoundary(key: key, child: w),
      ),
    ),
  );
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

void _no(WearKind k, AutoChoice c) {}

void main() {
  setUpAll(loadFonts);

  final stats = {
    WearKind.night: KindStats(WearKind.night)
      ..asked = 6
      ..yes = 5
      ..no = 1
      ..automatic = 0,
    WearKind.work: KindStats(WearKind.work),
    WearKind.other: KindStats(WearKind.other)
      ..asked = 2
      ..relabelled = 1
      ..no = 1,
  };

  final pages = <String, Widget Function()>{
    'defaults_unpaired': () => const AutoStartView(model: AutoStartModel(status: _xiaomiUnpaired), onChoice: _no),
    'paired_with_offer': () => AutoStartView(
      model: AutoStartModel(
        settings: const AutoSettings().withChoice(WearKind.night, AutoChoice.ask).withChime(true),
        usual: const UsualNight(bedMin: 23 * 60 + 40, wakeMin: 7 * 60 + 30, fromNights: 9),
        status: _paired,
        stats: stats,
        offers: const {WearKind.night},
      ),
      onChoice: _no,
    ),
  };

  for (final scale in [1.0, 1.3]) {
    for (final e in pages.entries) {
      testWidgets('auto ${e.key} at ${(scale * 100).round()} % text, first screen and full length', (tester) async {
        await _shoot(tester, e.value(), 'auto_${e.key}', scale);
        await _shoot(tester, e.value(), 'auto_${e.key}_full', scale, height: scale == 1.0 ? 2600 : 3600);
      });
    }
  }

  group('what this phone allows, in words', () {
    test('a Xiaomi, not paired, no battery exemption: says so, and how to fix it', () {
      final lines = [for (final (l, _) in watchLines(_xiaomiUnpaired)) l];
      expect(lines.join('\n'), contains('Not paired yet'));
      expect(lines.join('\n'), contains('checks only when you open it'));
      expect(lines.join('\n'), contains('Autostart'));
      expect(lines.join('\n'), contains('not known yet'));
    });

    test('paired and watched: the good news, in green', () {
      final (line, color) = watchLines(_paired).first;
      expect(line, startsWith('Paired with BB Black: Android watches for the headband'));
      expect(color, Night.live);
    });

    test('Android 11 and lower: no presence events; a refused background start is reported first', () {
      final old = watchLines(const WatchStatus({'sdkInt': 30, 'companion': true, 'presence': false}));
      expect(old.map((e) => e.$1).join('\n'), contains('This Android (30) cannot tell the app when the headband is near.'));
      final refused = watchLines(
        WatchStatus({'sdkInt': 34, 'companion': true, 'presence': true, 'refused_at': DateTime(2026, 11, 20, 23, 10).millisecondsSinceEpoch}),
      );
      expect(refused.first.$1, 'Android refused a check in the background at 23:10.');
    });

    test('notifications off: the first line', () {
      expect(watchLines(const WatchStatus({'sdkInt': 34, 'notifications': false})).first.$2, Night.problem);
    });

    test('the Settings entry\'s line', () {
      expect(autoSummary(const AutoSettings()), 'Night: Ask me · Work: Ask me · Other: Ask me');
      var off = const AutoSettings();
      for (final k in WearKind.values) {
        off = off.withChoice(k, AutoChoice.nothing);
      }
      expect(autoSummary(off), 'Do nothing (the app does not check).');
    });

    test('results per kind', () {
      expect(statsLine(KindStats(WearKind.work)), 'Work: nothing yet.');
      expect(statsLine(stats[WearKind.night]!), 'Night: asked 6 times; 5 of 6 answered: right');
    });
  });

  group('the page on a fake app folder', () {
    late Directory tmp;
    late String rec;
    final armed = <List<Object?>>[];
    setUp(() {
      armed.clear();
      // the phone's side answers at once (an unanswered channel would leave the page's reload pending)
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('eeg_tracker/auto'),
        (call) async {
          if (call.method == 'armBedtime') armed.add((call.arguments as Map)['at'] as List<Object?>);
          return null;
        },
      );
      tmp = Directory.systemTemp.createTempSync('autoscreen');
      rec = '${tmp.path}/recordings';
      Directory(rec).createSync();
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('eeg_tracker/auto'),
        null,
      );
      tmp.deleteSync(recursive: true);
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: nightTheme(), home: AutoStartScreen(recordings: rec, watch: () async => _xiaomiUnpaired)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('three kinds on "Ask me"; a change is saved; other offers no automatic start', (tester) async {
      await open(tester);
      expect(find.text('Ask me'), findsNWidgets(3));
      expect(find.text('Automatic'), findsNWidgets(2), reason: 'night and work only');
      await tester.tap(find.text('Automatic').first);
      await tester.pumpAndSettle();
      expect(AutoStore(autoDirFor(rec)).settings().choice(WearKind.night), AutoChoice.start);
      await tester.tap(find.text('Do nothing').last);
      await tester.pumpAndSettle();
      expect(AutoStore(autoDirFor(rec)).settings().choice(WearKind.other), AutoChoice.nothing);
      expect(armed.last, isNotEmpty, reason: 'every change arms the bedtime checks again');
      for (final k in WearKind.values) {
        await tester.tap(find.text('Do nothing').at(k.index));
        await tester.pumpAndSettle();
      }
      expect(armed.last, isEmpty, reason: 'all three "Do nothing": no checks at all');
      expect(find.text('21:00-07:00', findRichText: true), findsNothing);
      expect(find.textContaining('until 3 nights are recorded'), findsOneWidget);
    });

    testWidgets('the chime switch for automatic work sessions starts off and is saved', (tester) async {
      await open(tester);
      expect(find.text('Off: hints are silent.'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(AutoStore(autoDirFor(rec)).settings().workChime, isTrue);
    });

    testWidgets('the offer after 10 yes: taking it switches the night to automatic and the card goes', (tester) async {
      AutoLog(autoDirFor(rec)).add(DateTime(2026, 11, 20, 23), 'offer', {'kind': 'night', 'yes_in_a_row': 10});
      await open(tester);
      expect(find.textContaining('You said yes 10 times in a row'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Start automatically'));
      await tester.pumpAndSettle();
      expect(AutoStore(autoDirFor(rec)).settings().choice(WearKind.night), AutoChoice.start);
      expect(find.textContaining('You said yes 10 times in a row'), findsNothing);
    });
  });

  testWidgets('the Settings entry opens with its line', (tester) async {
    var opened = 0;
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1080 / 393;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: SettingsView(
          model: const SettingsViewModel(),
          onToggle: (_) {},
          onCalibrate: () {},
          onInfo: () {},
          autoStart: autoSummary(const AutoSettings()),
          onAutoStart: () => opened++,
        ),
      ),
    );
    expect(find.text('Night: Ask me · Work: Ask me · Other: Ask me'), findsOneWidget);
    await tester.tap(find.text('When I put the headband on'));
    expect(opened, 1);
  });
}
