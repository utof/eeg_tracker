// Renders the "Try these" page in its states at the owner's phone width (393 dp) with real fonts, writes
// build/screens/try_*.png for a human look, and fails on any layout overflow (also at 130 % text). Then the flows on a
// fake app folder: Done re-signs to the next stop, a note is saved and logged, Skip and Not done yet, what the app saw
// ticks itself, and a stop whose screen is the main screen goes back to it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/try_these/cards.dart';
import 'package:eeg_tracker/try_these/progress.dart';
import 'package:eeg_tracker/try_these/seen.dart';
import 'package:eeg_tracker/ui/morning_section.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/parts.dart' show SectionHeading;
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/try_these_screen.dart';
import 'package:eeg_tracker/ui/try_these_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final DateTime _t = DateTime(2026, 11, 21, 8, 40);

Map<String, CardProgress> _some() => {
  'night': CardProgress(state: TryState.done, at: _t.subtract(const Duration(days: 1))),
  'sleep-time': CardProgress(
    state: TryState.done,
    at: _t.subtract(const Duration(days: 1)),
    byApp: true,
    seen: 'Scored on this phone in 6 min: the night of Thu 19 Nov.',
  ),
  'sleep-extras': CardProgress(state: TryState.skipped, at: _t),
  'check-in': CardProgress(
    state: TryState.done,
    at: _t,
    note: 'The tones were fine. O1 said "noisy" until I parted the hair; alpha speed 9.4 Hz.',
  ),
  'nap': const CardProgress(note: 'Not yet: no free afternoon this week.'),
};

void _no() {}

Widget _page(Map<String, CardProgress> p, {String? expanded, bool finished = false, bool first = true}) {
  final page = buildTryPage(tryCards, p);
  return TryTheseView(
    page: page,
    expanded: first ? page.next?.id : expanded,
    showFinished: finished,
    onToggle: (_) {},
    onOpen: (_) {},
    onDone: (_) {},
    onSkip: (_) {},
    onReopen: (_) {},
    onNote: (_, _) {},
    onShowFinished: _no,
  );
}

/// The page's states; [reveal] is the open stop's title, scrolled to the top of the first screen as after a tap.
final Map<String, ({Widget Function() w, String? reveal})> pages = {
  'new': (w: () => _page(const {}), reveal: null),
  'progress': (w: () => _page(_some()), reveal: null),
  'proposal_open': (w: () => _page(_some(), expanded: 'sharp', first: false), reveal: 'Sharp hours'),
  'weak_open': (w: () => _page(_some(), expanded: 'lucid', first: false), reveal: 'Lucid dream cues'),
  'finished_open': (
    w: () => _page(_some(), expanded: 'check-in', finished: true, first: false),
    reveal: 'Morning check-in and Trends',
  ),
  'seen_open': (
    w: () => _page(_some(), expanded: 'sleep-time', finished: true, first: false),
    reveal: 'How long the phone takes to score a night',
  ),
  'all_done': (
    w: () => _page({for (final c in tryCards) c.id: CardProgress(state: TryState.done, at: _t)}),
    reveal: null,
  ),
};

/// The night screen between nights, with the section (it reads nothing without a phone: its first line).
Widget _night() => NightView(
  model: const NightViewModel(
    title: 'Ready',
    sentence: 'Put the headband on and switch it on, then start the night.',
    tone: Tone.calm,
    running: false,
  ),
  onStart: _no,
  onStop: _no,
  onFix: (_) {},
  morning: const MorningSection(doneAt: null, onCheckIn: _no, onTrends: _no),
);

/// Pushes [w] over a stub page (as the app opens it, so the app bar has its Back arrow), checks for overflow and
/// writes build/screens/[name].png at the owner's first screen (873 dp), scrolled to [reveal] when given; with [full],
/// as tall as the whole page (and it fails if anything is left below the capture). [push] false: [w] is the home page,
/// shot at [height] dp.
Future<void> _shoot(
  WidgetTester tester,
  Widget w,
  String name,
  double scale, {
  double height = 873,
  bool full = false,
  String? reveal,
  bool push = true,
}) async {
  void size(double dp) {
    tester.view.physicalSize = Size(1080, dp * 1080 / 393); // the owner's Xiaomi 11T: 393 dp wide
    tester.view.devicePixelRatio = 1080 / 393;
  }

  size(height);
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view)
          .copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(
        navigatorKey: nav,
        debugShowCheckedModeBanner: false,
        theme: nightTheme(),
        home: push ? const Scaffold() : RepaintBoundary(key: key, child: w),
      ),
    ),
  );
  if (push) {
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => RepaintBoundary(key: key, child: w),
        ),
      ),
    );
  }
  await tester.pumpAndSettle();
  ScrollPosition page() => tester
      .state<ScrollableState>(
        find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)).first,
      )
      .position;
  if (full) {
    size(height + page().maxScrollExtent + 24);
    await tester.pumpAndSettle();
    expect(page().maxScrollExtent, 0, reason: '$name: the capture must hold the whole page');
  } else if (reveal != null) {
    await tester.ensureVisible(find.text(reveal));
    await tester.pumpAndSettle();
  }
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
      testWidgets('try ${e.key} at $pct % text, first screen and full length', (tester) async {
        await _shoot(tester, e.value.w(), 'try_${e.key}', scale, reveal: e.value.reveal);
        await _shoot(tester, e.value.w(), 'try_${e.key}_full', scale, full: true);
      });
    }
    testWidgets('the section\'s line once read, nothing done and 3 done, at $pct % text', (tester) async {
      Widget section(Map<String, CardProgress> p) => Scaffold(
        body: ListView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          children: [
            const SectionHeading('Try these'),
            TryEntryView(line: entryLine(buildTryPage(tryCards, p)), onOpen: _no),
          ],
        ),
      );
      await _shoot(tester, section(const {}), 'try_night_line_new', scale, height: 400, push: false);
      expect(
        find.text(
          '0 of ${tryCards.length} tried. Next: A night with Lights off, a few seconds tonight, 2 minutes in '
          'the morning.',
        ),
        findsOneWidget,
      );
      await _shoot(tester, section(_some()), 'try_night_line_progress', scale, height: 400, push: false);
      expect(find.textContaining('3 of ${tryCards.length} tried. Next: Export data to the laptop'), findsOneWidget);
    });
    testWidgets('the night screen\'s section at $pct % text', (tester) async {
      await _shoot(tester, _night(), 'try_night_section', scale, height: 1500, push: false);
      expect(find.text('Try these'), findsNWidgets(2), reason: 'the heading and the button');
      expect(find.text(entryLine(null)), findsOneWidget);
    });
  }

  testWidgets('weak evidence is said in words beside the cards graded weak, and in the open stop', (tester) async {
    tester.view.physicalSize = const Size(1080, 12000);
    tester.view.devicePixelRatio = 1080 / 393;
    addTearDown(tester.view.reset);
    final weak = tryCards.where((c) => c.weakEvidence).length;
    Widget view(String? open) {
      final page = buildTryPage(tryCards, const {});
      return MaterialApp(
        theme: nightTheme(),
        home: TryTheseView(
          page: page,
          expanded: open,
          showFinished: false,
          onToggle: (_) {},
          onOpen: (_) {},
          onDone: (_) {},
          onSkip: (_) {},
          onReopen: (_) {},
          onNote: (_, _) {},
          onShowFinished: _no,
        ),
      );
    }

    await tester.pumpWidget(view(null));
    expect(find.text('The evidence is weak.'), findsNWidgets(weak));
    expect(find.textContaining('The i on its screen says why'), findsNothing);
    expect(find.text('The assistant\'s idea.'), findsNWidgets(tryCards.where((c) => c.proposal).length));
    await tester.pumpWidget(view('lucid'));
    expect(find.text('The evidence is weak.'), findsNWidgets(weak - 1), reason: 'the open stop says it in its body');
    expect(find.text('The evidence is weak: it may do nothing for you. The i on its screen says why.'), findsOneWidget);
    await tester.pumpWidget(view('sharp'));
    expect(find.textContaining('may do nothing for you'), findsNothing);
  });

  testWidgets('a finished tour leads to Export data, where the notes go', (tester) async {
    final opened = <String>[];
    final page = buildTryPage(tryCards, {for (final c in tryCards) c.id: CardProgress(state: TryState.done, at: _t)});
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: TryTheseView(
          page: page,
          expanded: null,
          showFinished: false,
          onToggle: (_) {},
          onOpen: (c) => opened.add(c.id),
          onDone: (_) {},
          onSkip: (_) {},
          onReopen: (_) {},
          onNote: (_, _) {},
          onShowFinished: _no,
        ),
      ),
    );
    await tester.tap(find.text('Open Export data'));
    expect(opened, ['export']);
  });

  test('a finished stop says when, and who ticked it', () {
    expect(finishedLine(CardProgress(state: TryState.done, at: _t)), 'Done Sat 21 Nov.');
    expect(finishedLine(CardProgress(state: TryState.done, at: _t, byApp: true)), 'Seen by the app Sat 21 Nov.');
    expect(finishedLine(CardProgress(state: TryState.skipped, at: _t)), 'Skipped Sat 21 Nov.');
  });

  group('the flows on a fake app folder', () {
    late Directory tmp;
    late String rec;
    late TryStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('try-ui');
      rec = '${tmp.path}/files/recordings';
      Directory(rec).createSync(recursive: true);
      store = TryStore(tryDirFor(rec));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<Map<String, String>> seenHere(String files, Set<String> ids) async => seenByApp(Directory(files), ids);

    Future<void> openPage(WidgetTester tester, {List<String>? popped}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    await Navigator.of(c).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TryTheseScreen(recordingsDir: rec, now: () => _t, seen: seenHere),
                      ),
                    );
                    popped?.add('back');
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the first stop is open; Done saves it and the next stop opens', (tester) async {
      await openPage(tester);
      expect(find.text('0 of ${tryCards.length} tried'), findsOneWidget);
      expect(find.text(tryCards.first.what), findsOneWidget);
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(store.load()['night']!.state, TryState.done);
      expect(find.text(tryCards[1].what), findsOneWidget, reason: 'the page re-signs to the next stop');
      expect(find.text(tryCards.first.what), findsNothing);
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 3000));
      await tester.pumpAndSettle();
      expect(find.text('1 of ${tryCards.length} tried'), findsOneWidget);
    });

    testWidgets('a note typed on the open stop goes with Done into the file and the log', (tester) async {
      await openPage(tester);
      await tester.enterText(find.byType(TextField), 'Lights off said learning; numbers 12 and 9 min.');
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(store.load()['night']!.note, 'Lights off said learning; numbers 12 and 9 min.');
      final log = File('${store.dir.path}/events.jsonl').readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
      expect(
        log.single,
        allOf(containsPair('event', 'done'), containsPair('note', 'Lights off said learning; numbers 12 and 9 min.')),
      );
    });

    testWidgets('a note alone is saved a moment after typing, and kept when the page closes', (tester) async {
      await openPage(tester);
      await tester.enterText(find.byType(TextField), 'tonight');
      await tester.pump(const Duration(seconds: 1));
      expect(store.load()['night']!.note, 'tonight');
      expect(store.load()['night']!.state, TryState.open);
      await tester.enterText(find.byType(TextField), 'tonight, after the film');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(store.load()['night']!.note, 'tonight, after the film');
    });

    testWidgets('Skip folds a stop into Done and skipped; Not done yet brings it back', (tester) async {
      await openPage(tester);
      await tester.ensureVisible(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(store.load()['night']!.state, TryState.skipped);
      await tester.dragUntilVisible(
        find.text('Show 1 stop'),
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show 1 stop'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text(tryCards.first.title),
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(tryCards.first.title));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('Not done yet'),
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not done yet'));
      await tester.pumpAndSettle();
      expect(store.load()['night']!.state, TryState.open);
    });

    testWidgets('what the app saw ticks itself when the page opens', (tester) async {
      File('${tmp.path}/files/mornings/2026-11-21-071500.morning.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      await openPage(tester);
      expect(store.load()['check-in']!.byApp, isTrue);
      expect(find.text('1 of ${tryCards.length} tried'), findsOneWidget);
    });

    testWidgets('a stop on the main screen goes back to it', (tester) async {
      final popped = <String>[];
      await openPage(tester, popped: popped);
      await tester.ensureVisible(find.text('Back to the main screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back to the main screen'));
      await tester.pumpAndSettle();
      expect(popped, ['back']);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
