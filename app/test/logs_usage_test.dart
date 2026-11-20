// How the app is used (DECISIONS 713-714): what the screen's watchers write from widget tests (the page on top, taps
// by control and words, a switch's row, tabs, scrolls, drags, never typed text) and the summary the Usage page shows
// (time per screen, features, most tapped, not opened, scrolling, hints and breaks, auto-start's guesses, smoothness,
// start-up, storage).
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/logs/activity.dart';
import 'package:eeg_tracker/logs/files.dart';
import 'package:eeg_tracker/logs/log.dart';
import 'package:eeg_tracker/logs/usage.dart';
import 'package:eeg_tracker/logs/usage_report.dart';
import 'package:eeg_tracker/logs/usage_watch.dart';
import 'package:eeg_tracker/ui/home_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter_test/flutter_test.dart';

class FooScreen extends StatelessWidget {
  const FooScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Foo')),
    body: ListView(children: [for (var i = 0; i < 60; i++) ListTile(title: Text('Row $i'))]),
  );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool _on = false;
  final TextEditingController _typed = TextEditingController(text: 'my secret note');

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        FilledButton(
          key: const ValueKey('start-night'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FooScreen())),
          child: const Text('Start night 3'),
        ),
        Row(
          children: [
            const Text('Share on Wi-Fi'),
            Switch(value: _on, onChanged: (v) => setState(() => _on = v)),
          ],
        ),
        SizedBox(width: 300, child: TextField(controller: _typed)),
        IconButton(onPressed: () {}, tooltip: 'Settings', icon: const Icon(Icons.settings)),
        const SizedBox(height: 120, width: 300, child: ColoredBox(color: Colors.black)),
      ],
    ),
  );
}

void main() {
  late Directory tmp;
  late Logs logs;

  List<Map<String, Object?>> usage() {
    final f = logFiles(tmp, kind: LogKind.usage);
    return [
      for (final file in f)
        for (final l in file.readAsLinesSync()) jsonDecode(l) as Map<String, Object?>,
    ];
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('logs_usage');
    Activity.reset();
    Usage.reset();
    logs = Logs.start(engine: 'screen', recordingsDir: () async => null, catchErrors: false, capturePrint: false)..attach(tmp);
  });
  tearDown(() async {
    await Logs.reset();
    Activity.reset();
    Usage.reset();
    tmp.deleteSync(recursive: true);
  });

  Widget app() => MaterialApp(
    navigatorObservers: [UsageNavigatorObserver(rename: (n) => n == 'Home' ? 'tab:${Usage.homeTab}' : n)],
    builder: (context, child) => UsageGestures(child: child!),
    home: const _Home(),
  );

  group('the screen\'s watchers', () {
    testWidgets('the page on top by its widget\'s name; a tap by its control, words (digits as #) and key', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.tap(find.text('Start night 3'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      final ev = usage();
      final views = [for (final e in ev) if (e['ev'] == 'view') e['screen']];
      expect(views, ['tab:Night', 'FooScreen', 'tab:Night']);
      final tap = ev.firstWhere((e) => e['ev'] == 'tap');
      expect(tap, containsPair('control', 'FilledButton'));
      expect(tap, containsPair('label', 'Start night #'));
      expect(tap, containsPair('id', 'start-night'));
      expect(tap, containsPair('screen', 'tab:Night'));
      expect(logs.screen, 'tab:Night');
    });

    testWidgets('a bare switch is named by its row; an icon button by its tooltip; typed text is never read', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.tap(find.byType(IconButton));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final taps = [for (final e in usage()) if (e['ev'] == 'tap') e];
      expect(taps[0], containsPair('control', 'Switch'));
      expect(taps[0], containsPair('label', 'Share on Wi-Fi'));
      expect(taps[1], containsPair('label', 'Settings'));
      expect(jsonEncode(usage()), isNot(contains('secret')));
    });

    testWidgets('a scroll by finger: its direction, distance and how far down the page; a drag that scrolled nothing', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.tap(find.text('Start night 3'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.dragFrom(tester.getCenter(find.byType(ColoredBox).last), const Offset(-200, 0));
      await tester.pumpAndSettle();
      final ev = usage();
      final scroll = ev.firstWhere((e) => e['ev'] == 'scroll');
      expect(scroll, containsPair('screen', 'FooScreen'));
      expect(scroll, containsPair('dir', 'down'));
      expect(scroll['px'], greaterThan(400));
      expect(scroll['reach'], greaterThan(0));
      expect(ev.where((e) => e['ev'] == 'drag' && e['screen'] == 'FooScreen'), isEmpty, reason: 'a scroll is not also a drag');
      final drag = ev.lastWhere((e) => e['ev'] == 'drag');
      expect(drag, containsPair('dir', 'left'));
      expect(drag, containsPair('screen', 'tab:Night'));
    });

    testWidgets('the bottom bar\'s tabs name the home page', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [UsageNavigatorObserver(rename: (n) => n == 'HomeTabs' ? 'tab:${Usage.homeTab}' : n)],
          builder: (context, child) => UsageGestures(child: child!),
          home: HomeTabs(page: (context, tab) => Center(child: Text(tab.title))),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Signal'));
      await tester.pump();
      await tester.tap(find.text('More'));
      await tester.pump();
      final views = [for (final e in usage()) if (e['ev'] == 'view') e['screen']];
      expect(views, ['tab:Night', 'tab:Signal', 'tab:More']);
    });

    testWidgets('a feature\'s start and its length go into the usage log', (tester) async {
      var now = DateTime(2026, 11, 20, 10);
      Activity.clock = () => now;
      Usage.followActivity();
      Activity.begin('signal');
      now = now.add(const Duration(minutes: 3));
      Activity.end('signal');
      final f = [for (final e in usage()) if (e['ev'] == 'feature') e];
      expect(f.first, allOf(containsPair('name', 'signal'), containsPair('on', true)));
      expect(f.last, allOf(containsPair('on', false), containsPair('s', 180)));
    });

    test('frame timings per screen: frames, slow, janky, the worst', () {
      final lines = <Map<String, Object?>>[];
      var screen = 'tab:Signal';
      final w = FrameWatch(screen: () => screen, write: lines.add);
      FrameTiming frame(int buildMs, int rasterMs) => FrameTiming(
        vsyncStart: 0,
        buildStart: 0,
        buildFinish: buildMs * 1000,
        rasterStart: buildMs * 1000,
        rasterFinish: (buildMs + rasterMs) * 1000,
        rasterFinishWallTime: (buildMs + rasterMs) * 1000,
      );
      w.add([frame(5, 6), frame(20, 4), frame(4, 40)]);
      screen = 'MeditationScreen';
      w.add([frame(3, 3)]);
      w.flush();
      expect(lines.first, allOf(containsPair('screen', 'tab:Signal'), containsPair('n', 3), containsPair('slow', 2)));
      expect(lines.first, allOf(containsPair('janky', 1), containsPair('worst_ms', 40)));
      expect(lines.last, allOf(containsPair('screen', 'MeditationScreen'), containsPair('n', 1), containsPair('slow', 0)));
    });

    test('a control\'s words: one line, at most 40 characters, digits as #', () {
      expect(usageLabel('Night of 18 Nov\n  · 2 file sets'), 'Night of ## Nov · # file sets');
      expect(usageLabel('x' * 50), hasLength(40));
    });
  });

  group('the summary', () {
    final day = DateTime(2026, 11, 20, 8);
    String at(int min) => day.add(Duration(minutes: min)).toIso8601String();
    final ev = <Map<String, Object?>>[
      {'t': at(0), 'ev': 'app', 'state': 'front'},
      {'t': at(0), 'ev': 'view', 'screen': 'tab:Night'},
      {'t': at(2), 'ev': 'tap', 'screen': 'tab:Night', 'control': 'FilledButton', 'label': 'Start night'},
      {'t': at(3), 'ev': 'view', 'screen': 'tab:Signal'},
      {'t': at(3), 'ev': 'feature', 'name': 'signal', 'on': true},
      {'t': at(13), 'ev': 'feature', 'name': 'signal', 'on': false, 's': 600},
      {'t': at(13), 'ev': 'view', 'screen': 'MeditationScreen'},
      {'t': at(14), 'ev': 'scroll', 'screen': 'MeditationScreen', 'axis': 'v', 'dir': 'down', 'px': 900, 'ms': 300, 'reach': 0.9},
      {'t': at(15), 'ev': 'tap', 'screen': 'MeditationScreen', 'control': 'FilledButton', 'label': 'Start'},
      {'t': at(15), 'ev': 'tap', 'screen': 'tab:Night', 'control': 'FilledButton', 'label': 'Start night'},
      {'t': at(20), 'ev': 'app', 'state': 'back'},
      // the work session's break hints: one followed by a break, one ignored
      {'t': at(60), 'ev': 'hint', 'kind': 'work-break', 'step': 'shown'},
      {'t': at(62), 'ev': 'hint', 'kind': 'work-break', 'step': 'answered', 'answer': 'onBreak', 'after_s': 120},
      {'t': at(62), 'ev': 'hint', 'kind': 'work-break', 'step': 'break'},
      {'t': at(120), 'ev': 'hint', 'kind': 'work-break', 'step': 'shown'},
      {'t': at(150), 'ev': 'hint', 'kind': 'work-break', 'step': 'ignored', 'after_s': 1800},
      // the app killed in front: its stretch ends after 3 hours, not at the next day's event
      {'t': at(200), 'ev': 'app', 'state': 'front'},
      {'t': at(200), 'ev': 'view', 'screen': 'tab:Trends'},
      {'t': at(16), 'ev': 'drag', 'screen': 'MeditationScreen', 'dir': 'left', 'px': 300, 'ms': 200},
    ];
    final metrics = <Map<String, Object?>>[
      {'t': at(5), 'kind': 'frames', 'screen': 'tab:Signal', 'n': 600, 'slow': 90, 'janky': 60, 'worst_ms': 120},
      {'t': at(14), 'kind': 'frames', 'screen': 'MeditationScreen', 'n': 300, 'slow': 0, 'janky': 0, 'worst_ms': 12},
      {'t': at(0), 'kind': 'startup', 'main_ms': 400, 'process_ms': 1200},
      {'t': at(200), 'kind': 'startup', 'main_ms': 300, 'process_ms': 900},
      {'t': day.subtract(const Duration(days: 2)).toIso8601String(), 'kind': 'storage', 'cats': {'recordings': 100e6, 'logs': 1e6}},
      {'t': at(0), 'kind': 'storage', 'cats': {'recordings': 300e6, 'logs': 3e6}},
    ];
    final auto = <Map<String, Object?>>[
      {'at': at(30), 'event': 'answer', 'kind': 'night', 'answer': 'yes'},
      {'at': at(31), 'event': 'answer', 'kind': 'work', 'answer': 'night'},
      {'at': at(32), 'event': 'answer', 'kind': 'night', 'answer': 'none'},
      {'at': at(33), 'event': 'answer', 'kind': 'other', 'answer': 'work'},
    ];
    final s = usageSummary(ev, metrics, since: DateTime(2026, 11, 20), now: day.add(const Duration(days: 1)), auto: auto);

    test('time in the app and on each screen: back ends a stretch, 3 hours of silence ends one', () {
      expect(s.opens, 2);
      expect(s.inApp, const Duration(minutes: 20 + 180));
      expect(s.screens.first, (screen: 'tab:Trends', time: const Duration(hours: 3), visits: 1));
      final signal = s.screens.firstWhere((x) => x.screen == 'tab:Signal');
      expect(signal.time, const Duration(minutes: 10));
    });

    test('features with their time, most tapped, not opened, scrolling', () {
      expect(s.features.single, (feature: 'signal', times: 1, total: const Duration(minutes: 10)));
      expect(s.taps.first, (screen: 'tab:Night', control: 'Start night', taps: 2));
      expect(s.notOpened, contains('NapScreen'));
      expect(s.notOpened, isNot(contains('MeditationScreen')));
      expect(s.notOpened, isNot(contains('tab:Signal')));
      expect(s.scrolls.single, (screen: 'MeditationScreen', scrolls: 1, px: 900, reach: 0.9));
      expect(s.drags, 1);
    });

    test('hints: shown, answered, ignored, a break after one of two; auto-start right 1 of 2', () {
      final h = s.hints.single;
      expect((h.kind, h.shown, h.ignored), ('work-break', 2, 1));
      expect(h.answers, {'onBreak': 1});
      expect(h.medianAfter, const Duration(minutes: 2));
      expect((s.breakHints, s.breaksAfter), (2, 1));
      expect((s.autoGuesses, s.autoRight), (2, 1));
    });

    test('smoothness worst first, start-up times, storage with its growth a day', () {
      expect(s.smooth.first.screen, 'tab:Signal');
      expect(s.smooth.first.janky, 60);
      expect(s.startups, [1200, 900]);
      final rec = s.storage.first;
      expect(rec.category, 'recordings');
      expect(rec.bytes, 300000000);
      expect(rec.perDay, closeTo(100e6, 1e6), reason: '200 MB more in 2 days');
    });

    test('a screen\'s words: the known ones, any other split from its widget name', () {
      expect(screenLabel('tab:Signal'), 'Signal tab');
      expect(screenLabel('SleepReportScreen'), 'Sleep report');
      expect(screenLabel('ReplayResultsScreen'), 'Replay results');
      expect(screenLabel('dialog'), 'Dialog');
    });

    test('every screen the "not opened" list knows is a page of the app (its widget is in lib/ui)', () {
      final source = [
        for (final f in Directory('lib/ui').listSync())
          if (f is File && f.path.endsWith('.dart')) f.readAsStringSync(),
      ].join('\n');
      for (final k in knownScreens.keys) {
        if (k.startsWith('tab:')) {
          expect(HomeTab.values.map((t) => t.label), contains(k.substring(4)));
        } else {
          expect(source, contains('class $k extends'), reason: k);
        }
      }
    });
  });
}
