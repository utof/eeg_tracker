// The three record pages under More (DECISIONS 712-716) on a made-up app folder: the App log (levels, parts of the
// app, a line opened, Copy, Share, Delete), How I use the app (its switch writes the settings file, the sections),
// Battery (what costs the most with its sentence, the headband); each rendered at 100 % and 130 % text into
// build/screens/ for a human look, failing on any overflow. And the More tab's links open them.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/headband/battery_estimate.dart';
import 'package:eeg_tracker/logs/files.dart';
import 'package:eeg_tracker/logs/settings.dart';
import 'package:eeg_tracker/ui/battery_screen.dart';
import 'package:eeg_tracker/ui/logs_screen.dart';
import 'package:eeg_tracker/ui/records_parts.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/usage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

void _write(File f, List<Map<String, Object?>> lines) {
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(lines.map((l) => '${jsonEncode(l)}\n').join(), mode: FileMode.append);
}

/// A day of the app on a made-up phone, ending at [now].
Directory makeFolder(Directory tmp, DateTime now) {
  final files = Directory('${tmp.path}/files');
  final logs = Directory('${files.path}/logs');
  Directory('${files.path}/recordings').createSync(recursive: true);
  String at(Duration ago) => logTime(now.subtract(ago));
  final day = logDay(now);
  _write(File('${logs.path}/app-$day-screen.jsonl'), [
    {'t': at(const Duration(hours: 5)), 'level': 'info', 'sub': 'app', 'msg': 'first frame 412 ms after main()'},
    {'t': at(const Duration(hours: 4)), 'level': 'info', 'sub': 'scoring', 'msg': 'scored 2026-11-19 in 98 s', 'data': {'ms': 98000}},
    {'t': at(const Duration(hours: 3)), 'level': 'info', 'sub': 'sessions', 'msg': 'session held: Meditation'},
    {
      't': at(const Duration(hours: 2)),
      'level': 'error',
      'sub': 'app',
      'msg': 'Flutter error in rendering library',
      'error': 'A RenderFlex overflowed by 12 pixels on the right.',
      'stack': '#0 RenderFlex.performLayout\n#1 RenderObject.layout',
      'screen': 'MeditationScreen',
      'on': ['app-open', 'session:Meditation'],
    },
    {'t': at(const Duration(hours: 1)), 'level': 'info', 'sub': 'packing', 'msg': 'packed 2 recordings, 0 failed, 0 left'},
  ]);
  _write(File('${logs.path}/app-$day-recorder.jsonl'), [
    {'t': at(const Duration(hours: 9)), 'level': 'info', 'sub': 'recorder', 'msg': 'connected BB Black', 'data': {'rssi': -68, 'battery': 92}},
    {'t': at(const Duration(hours: 8)), 'level': 'warn', 'sub': 'recorder', 'msg': 'headband link dropped: out of range'},
    {
      't': at(const Duration(hours: 8)),
      'level': 'info',
      'sub': 'recorder',
      'msg': 'headband back after a drop (out of range)',
      'data': {'reconnect_ms': 19000},
    },
    {'t': at(const Duration(hours: 7)), 'level': 'info', 'sub': 'share', 'msg': 'sharing on Wi-Fi: the laptop copied 12 files, 84.0 MB'},
  ]);
  _write(File('${logs.path}/usage-$day-screen.jsonl'), [
    {'t': at(const Duration(hours: 3)), 'ev': 'app', 'state': 'front'},
    {'t': at(const Duration(hours: 3)), 'ev': 'view', 'screen': 'tab:Night'},
    {'t': at(const Duration(minutes: 178)), 'ev': 'tap', 'screen': 'tab:Night', 'control': 'FilledButton', 'label': 'Start night'},
    {'t': at(const Duration(minutes: 175)), 'ev': 'view', 'screen': 'tab:Signal'},
    {'t': at(const Duration(minutes: 175)), 'ev': 'feature', 'name': 'signal', 'on': true},
    {'t': at(const Duration(minutes: 160)), 'ev': 'scroll', 'screen': 'tab:Signal', 'axis': 'v', 'dir': 'down', 'px': 800, 'ms': 400, 'reach': 1.0},
    {'t': at(const Duration(minutes: 155)), 'ev': 'feature', 'name': 'signal', 'on': false, 's': 1200},
    {'t': at(const Duration(minutes: 155)), 'ev': 'view', 'screen': 'MeditationScreen'},
    {'t': at(const Duration(minutes: 150)), 'ev': 'hint', 'kind': 'work-break', 'step': 'shown'},
    {'t': at(const Duration(minutes: 148)), 'ev': 'hint', 'kind': 'work-break', 'step': 'answered', 'answer': 'snooze', 'after_s': 120},
    {'t': at(const Duration(minutes: 120)), 'ev': 'app', 'state': 'back'},
  ]);
  // the app open on a page (screen on) and the Signal tab; a night with its headband link
  final power = <Map<String, Object?>>[];
  void drain(Duration from, Duration span, double rate, List<String> on, {bool screen = false, int cpuPerMin = 0}) {
    for (var t = Duration.zero; t <= span; t += const Duration(minutes: 1)) {
      final h = t.inMilliseconds / 3600000;
      power.add({
        't': at(from - t),
        'kind': 'power',
        'pct': ((4000 - rate * h) / 50).round(),
        'uah': ((4000 - rate * h) * 1000).round(),
        'plug': 'no',
        'screen': screen,
        'cpu': t.inMinutes * cpuPerMin,
        'on': on,
      });
    }
  }

  drain(const Duration(hours: 10), const Duration(hours: 6), 45, ['night', 'headband']);
  final night = [...power];
  power.clear();
  drain(const Duration(hours: 3), const Duration(minutes: 30), 160, ['app-open'], screen: true, cpuPerMin: 3000);
  drain(const Duration(minutes: 149), const Duration(minutes: 30), 230, ['app-open', 'signal'], screen: true, cpuPerMin: 21000);
  _write(File('${logs.path}/metrics-$day-recorder.jsonl'), night);
  _write(File('${logs.path}/metrics-$day-screen.jsonl'), [
    ...power,
    {'t': at(const Duration(minutes: 160)), 'kind': 'frames', 'screen': 'tab:Signal', 'n': 3600, 'slow': 400, 'janky': 250, 'worst_ms': 140},
    {'t': at(const Duration(minutes: 150)), 'kind': 'frames', 'screen': 'MeditationScreen', 'n': 1800, 'slow': 3, 'janky': 0, 'worst_ms': 19},
    {'t': at(const Duration(hours: 3)), 'kind': 'startup', 'main_ms': 420, 'process_ms': 1310},
    {'t': at(const Duration(hours: 3)), 'kind': 'storage', 'cats': {'recordings': 812e6, 'nights': 4.2e6, 'logs': 2.1e6}},
    {'t': at(const Duration(hours: 9)), 'kind': 'contact', 'source': 'night', 'ohms': {'O1': 140000, 'O2': 180000, 'T3': 260000, 'T4': 210000}},
    {'t': at(const Duration(hours: 3)), 'kind': 'contact', 'source': 'signal', 'ohms': {'O1': 120000, 'O2': null, 'T3': 300000, 'T4': 250000}},
  ]);
  final stem = now.subtract(const Duration(hours: 10));
  File('${files.path}/recordings/run.log').writeAsStringSync([
    for (var m = 0; m <= 360; m += 10)
      '${logTime(stem.add(Duration(minutes: m))).substring(0, 23)} samples ${m * 15000} (+2500) battery ${m == 0 ? 100 : 95 - m ~/ 12}%',
  ].join('\n'));
  return files;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 60 && find.text('Reading…').evaluate().isNotEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump();
}

Future<void> _shoot(WidgetTester tester, Widget w, String name, double scale) async {
  tester.view.physicalSize = const Size(1080, 2400 * 2);
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: w)),
    ),
  );
  await _settle(tester);
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
  late Directory tmp;
  late Directory files;
  late String rec;
  final now = DateTime.now();
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('logs_screens');
    files = makeFolder(tmp, now);
    rec = '${files.path}/recordings';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  for (final scale in [1.0, 1.3]) {
    testWidgets('the App log at ${(scale * 100).round()} % text', (tester) async {
      await _shoot(tester, LogsScreen(recordingsDir: rec), 'records_log', scale);
      expect(find.textContaining('9 lines in 7 days: 1 error, 1 warning'), findsOneWidget);
    });
    testWidgets('How I use the app at ${(scale * 100).round()} % text', (tester) async {
      await _shoot(tester, UsageScreen(recordingsDir: rec), 'records_usage', scale);
      expect(find.text('Record how I use the app'), findsOneWidget);
    });
    testWidgets('Battery at ${(scale * 100).round()} % text', (tester) async {
      await _shoot(tester, BatteryScreen(recordingsDir: rec), 'records_battery', scale);
      expect(find.text('What costs the most'), findsOneWidget);
    });
  }

  testWidgets('the App log: Errors shows the error alone, a part of the app filters, a tap opens its facts', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: LogsScreen(recordingsDir: rec)));
    await _settle(tester);
    expect(find.text('connected BB Black'), findsOneWidget);
    await tester.tap(find.text('Errors'));
    await tester.pump();
    expect(find.text('connected BB Black'), findsNothing);
    expect(find.textContaining('Flutter error in rendering library'), findsOneWidget);
    await tester.tap(find.textContaining('Flutter error in rendering library'));
    await tester.pump();
    expect(find.textContaining('on MeditationScreen'), findsOneWidget);
    expect(find.textContaining('RenderFlex.performLayout'), findsOneWidget);
    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.tap(find.text('recorder 3'));
    await tester.pump();
    expect(find.text('scored 2026-11-19 in 98 s'), findsNothing);
    expect(find.text('connected BB Black'), findsOneWidget);
  });

  testWidgets('Copy puts the lines shown on the clipboard; Share sends the log files; Delete empties it', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    List<File>? shared;
    await tester.pumpWidget(
      MaterialApp(theme: nightTheme(), home: LogsScreen(recordingsDir: rec, share: (f) async => shared = f)),
    );
    await _settle(tester);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, contains('warn recorder [recorder] headband link dropped: out of range'));
    await tester.tap(find.text('Share the log'));
    await tester.pump();
    expect(shared!.map((f) => f.uri.pathSegments.last).toSet(), {'app-${logDay(now)}-screen.jsonl', 'app-${logDay(now)}-recorder.jsonl'});
    await tester.tap(find.text('Delete the app log'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(logFiles(Directory('${files.path}/logs'), kind: LogKind.app), isEmpty);
    expect(logFiles(Directory('${files.path}/logs'), kind: LogKind.usage), isNotEmpty);
  });

  testWidgets('How I use the app: the switch writes the settings file; the sections say what was seen', (tester) async {
    tester.view.physicalSize = const Size(1080, 9000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: UsageScreen(recordingsDir: rec)));
    await _settle(tester);
    expect(find.text('Signal tab'), findsWidgets);
    expect(find.text('Start night'), findsOneWidget);
    expect(find.text('stutters'), findsOneWidget);
    expect(find.textContaining('Nap coach'), findsOneWidget, reason: 'not opened');
    expect(find.text('Break hints (work)'), findsOneWidget);
    expect(find.text('1.3 s'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(LogSettings.load(Directory('${files.path}/logs')).usage, isFalse);
  });

  testWidgets('Battery: the Signal tab\'s sentence, the night, the headband\'s drain and its link', (tester) async {
    tester.view.physicalSize = const Size(1080, 9000);
    addTearDown(tester.view.reset);
    // the headband card's estimate (the one battery rule, DECISIONS 946): the page shows the same number
    BandBatteryStore.forRecordings(rec).save(BandBatteryTrack()..note(62, DateTime(2026, 11, 20, 9), streaming: false));
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: BatteryScreen(recordingsDir: rec)));
    await _settle(tester);
    expect(find.text('about 62 %'), findsOneWidget);
    expect(find.textContaining('about 5.6 h of streaming left at 11 % an hour'), findsOneWidget);
    expect(find.text('230 mAh/h'), findsWidgets);
    expect(find.textContaining('It adds about 70 mAh an hour to what runs with it.'), findsOneWidget);
    expect(find.textContaining('Mostly the screen being on.'), findsOneWidget);
    expect(find.textContaining('worth optimising'), findsOneWidget);
    expect(find.text('Headband link, Night recording'), findsWidgets);
    expect(find.textContaining('% an hour'), findsWidgets);
    expect(find.textContaining('back after 19 s (median)'), findsOneWidget);
    expect(find.text('Contact over the day'), findsOneWidget);
    await tester.tap(find.text('Delete the battery samples'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await _settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(logFiles(Directory('${files.path}/logs'), kind: LogKind.metrics), isEmpty);
    expect(logFiles(Directory('${files.path}/logs'), kind: LogKind.app), isNotEmpty);
  });

  testWidgets('the More tab\'s links open the three pages', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: const Scaffold(body: RecordsLinks())));
    await tester.tap(find.byKey(const ValueKey('records-battery')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BatteryScreen), findsOneWidget);
  });
}
