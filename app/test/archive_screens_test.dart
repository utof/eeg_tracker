// The Archive's pages (DECISIONS 700-709): the list, a recording with its timeline, the raw signal, rendered at a phone's
// size with real fonts (build/screens/archive_*.png for a human look; no overflow, also at 130 % text), and what the
// owner can do on them: the passes filling the list, a tag added from a band, the normal removal with the laptop's copy,
// and the Danger zone's two confirmations.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eeg_tracker/archive/bands.dart';
import 'package:eeg_tracker/archive/delete.dart';
import 'package:eeg_tracker/archive/detail.dart';
import 'package:eeg_tracker/archive/items.dart';
import 'package:eeg_tracker/archive/page.dart';
import 'package:eeg_tracker/archive/raw_remover.dart' show OnLaptop;
import 'package:eeg_tracker/archive/seen.dart';
import 'package:eeg_tracker/archive/tags.dart';
import 'package:eeg_tracker/ui/archive_screen.dart';
import 'package:eeg_tracker/ui/archive_view.dart';
import 'package:eeg_tracker/ui/home_tabs.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/raw_signal_screen.dart';
import 'package:eeg_tracker/ui/recording_screen.dart';
import 'package:eeg_tracker/ui/recording_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final _now = DateTime(2026, 11, 19, 9, 30);
DateTime _t(int d, int h, int m) => DateTime(2026, 11, 18 + d, h, m);

RawSet _set(DateTime start, DateTime end, {String writer = 'night', String? auto, int mb = 30, List<String>? names}) => RawSet(
  folder: writer == 'board' ? 'recordings-diy' : 'recordings',
  stem:
      '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}-'
      '${start.hour.toString().padLeft(2, '0')}${start.minute.toString().padLeft(2, '0')}00',
  start: start,
  end: end,
  bytes: mb * 1000000,
  rawBytes: mb * 1000000,
  samplesBytes: mb * 1000000,
  writer: writer,
  auto: auto,
  files: const [],
  names: names ?? const ['O1', 'O2', 'T3', 'T4'],
  rate: 250,
  device: writer == 'board' ? 'DIY board' : 'BrainBit',
);

final ArchiveItem _night = ArchiveItem(
  id: '2026-11-18-231200',
  kind: ArchiveKind.night,
  start: _t(0, 23, 12),
  end: _t(1, 7, 40),
  started: byHand(ArchiveKind.night),
  sets: [_set(_t(0, 23, 12), _t(1, 3, 2), mb: 220), _set(_t(1, 3, 40), _t(1, 7, 40), mb: 190)],
  report: ReportFile(
    path: 'nights/2026-11-18.report.json',
    nightOf: '2026-11-18',
    start: _t(0, 23, 12),
    end: _t(1, 7, 40),
    scored: true,
    asleepMin: 372,
    inputs: const [],
    bytes: 40000,
  ),
  tags: TagsFile(id: '2026-11-18-231200', tags: [ManualTag(start: _t(1, 6, 50), end: _t(1, 7, 40), label: 'rest', made: _now)]),
  tagsBytes: 200,
);

final ArchiveItem _work = ArchiveItem(
  id: '2026-11-19-090000',
  kind: ArchiveKind.work,
  start: _t(1, 9, 0),
  end: _t(1, 9, 25),
  started: const Started(StartedHow.watcher, 'By itself: the headband watcher'),
  sessions: [
    SessionFile(kind: ArchiveKind.work, path: 'work-sessions/2026-11-19-090000.work.json', start: _t(1, 9, 0), end: _t(1, 9, 25), bytes: 34000),
  ],
);

final ArchiveItem _board = ArchiveItem(
  id: '2026-11-17-210000',
  kind: ArchiveKind.board,
  start: _t(-1, 21, 0),
  end: _t(-1, 21, 10),
  started: byHand(ArchiveKind.board),
  sets: [_set(_t(-1, 21, 0), _t(-1, 21, 10), writer: 'board', mb: 22, names: [for (var c = 1; c <= 8; c++) 'Ch$c'])],
  laptop: OnLaptop.yes,
);

final ArchiveItem _removed = ArchiveItem(
  id: '2026-11-17-020000',
  kind: ArchiveKind.night,
  start: _t(-1, 2, 0),
  end: _t(-1, 8, 30),
  started: const Started(StartedHow.watcherYes, 'The headband watcher asked; you said Yes'),
  sets: [
    RawSet(
      folder: 'recordings',
      stem: '2026-11-17-020000',
      start: _t(-1, 2, 0),
      end: _t(-1, 8, 30),
      bytes: 9000,
      rawBytes: 0,
      writer: 'night',
      files: const [],
      removed: true,
      removedOnLaptop: true,
    ),
  ],
);

ArchivePage _page({List<String> toSee = const []}) => ArchivePage(
  ArchiveList([_work, _night, _board, _removed]),
  found: {
    _night.id: {'eyes': 14, 'drowsy': 6, 'talking': 9, 'moving': 22, 'nosignal': 38},
  },
  why: {_board.id: 'The activity tags need O1 O2 T3 T4; this recording (DIY board: Ch1 Ch2 Ch3 Ch4 Ch5 Ch6 Ch7 Ch8) has no O1, O2, T3, T4.'},
  toSee: toSee,
);

/// A made-up pass over the night: eyes closed at lights off, drowsy, talking before sleep, moves through the night, a
/// gap where the headband was away.
RecordingSeen _seen() {
  final n = _night.length.inSeconds ~/ 30;
  final r = math.Random(3);
  String lane(String Function(int i) f) => [for (var i = 0; i < n; i++) f(i)].join();
  return RecordingSeen(
    startMs: _night.start.millisecondsSinceEpoch,
    quality: lane((i) => i >= 460 && i < 536 ? 'm' : (r.nextDouble() < 0.1 ? 'd' : 'g')),
    eyes: lane((i) => i >= 8 && i < 30 ? 'c' : 'o'),
    level: lane((i) => i >= 30 && i < 44 ? 'd' : (i < 6 ? '-' : 'a')),
    jaw: [for (var i = 0; i < n; i++) i < 8 || (i > 900 && i < 905) ? 3 : 0],
    move: [for (var i = 0; i < n; i++) r.nextDouble() < 0.03 ? 4 : 0],
  );
}

TimelineInput _input() => TimelineInput(
  seen: _seen(),
  stages: (start: _night.start, stages: '${'W' * 50}${'12223333222RRR2' * 60}${'W' * 120}'),
  sessions: [SessionFile(kind: ArchiveKind.dream, path: 'dream-catcher/x.dream.json', start: _t(0, 23, 12), end: _t(0, 23, 30), bytes: 1)],
  tags: _night.manualTags,
);

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

Widget _app(Widget home) => MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: home);

void main() {
  setUpAll(loadFonts);

  group('words', () {
    test('where a recording is, and the length', () {
      expect(whereText(_night), '410\u00a0MB · only on this phone');
      expect(whereText(_board), '22\u00a0MB on the phone · checked copy on the laptop');
      expect(whereText(_removed), 'Raw recording on the laptop; 9\u00a0KB of results here');
      expect(lengthText(const Duration(seconds: 40)), 'under a minute');
      expect(lengthText(_night.length), '8 h 28');
      expect(dayTitle('2026-11-19', _now), 'Today');
      expect(dayTitle('2026-11-18', _now), 'Yesterday');
      expect(dayTitle('2026-11-16', _now), 'Mon 16 Nov');
    });
  });

  for (final scale in [1.0, 1.3]) {
    final s = (scale * 100).round();
    testWidgets('archive_list at $s % text', (tester) async {
      await _shoot(tester, ArchiveView(model: ArchiveViewModel(page: _page(toSee: [_work.id]), passing: true), now: _now), 'archive_list_$s', scale: scale, height: 1500);
      expect(find.text('Tags: sleep · rest'), findsOneWidget);
      expect(find.textContaining('Found: asleep 6 h 12'), findsOneWidget);
      expect(find.text('Night · You: Start night'), findsNWidgets(1));
      expect(find.text('Work session · By itself: the headband watcher'), findsOneWidget);
      expect(find.textContaining('Finding activity in 1 more recording'), findsOneWidget);
    });

    testWidgets('archive_recording at $s % text', (tester) async {
      final tl = timelineOf(_night, _input());
      await _shoot(
        tester,
        RecordingView(model: RecordingViewModel(item: _night, timeline: tl), onDanger: () {}, onAddTag: () {}, onSignal: () {}),
        'archive_recording_$s',
        scale: scale,
        height: 2900,
      );
      expect(find.text('Danger zone'), findsOneWidget);
      expect(find.text('Remove from this phone'), findsNothing); // only on this phone: no normal removal
      for (final l in ['Sleep', 'Eyes closed', 'Drowsy', 'Talking', 'Moving', 'Signal', 'Work', 'Meeting', 'Sessions', 'Your tags']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
    });
  }

  testWidgets('archive_list_empty and the filter by a kind', (tester) async {
    await _shoot(tester, ArchiveView(model: const ArchiveViewModel(page: ArchivePage(ArchiveList([]))), now: _now), 'archive_empty');
    expect(find.textContaining('Nothing recorded on this phone yet'), findsOneWidget);
    await _shoot(
      tester,
      ArchiveView(model: ArchiveViewModel(page: _page(), filter: KindGroup.work), now: _now),
      'archive_filtered',
    );
    expect(find.text('Work session · By itself: the headband watcher'), findsOneWidget);
    expect(find.text('Night · You: Start night'), findsNothing);
    expect(find.textContaining('Showing work only'), findsOneWidget);
  });

  testWidgets('archive_signal: every channel at a moment', (tester) async {
    final r = math.Random(1);
    final values = Float32List(4 * 250 * 12);
    for (var k = 0; k < values.length; k++) {
      values[k] = (math.sin(k / 4 / 250 * 2 * math.pi * 10) * 20 + (r.nextDouble() - 0.5) * 8);
    }
    Future<RawWindow> read(List<String> p, DateTime at, int s) async =>
        RawWindow(names: const ['O1', 'O2', 'T3', 'T4'], rate: 250, start: at, values: values, lead: 500);
    await _shoot(tester, RawSignalScreen(paths: const ['x.f32'], at: _t(1, 3, 12), read: read), 'archive_signal');
    await tester.pump();
    expect(find.text('Signal at 03:12:00'), findsOneWidget);
    expect(find.text('10 s later'), findsOneWidget);
  });

  group('on the pages', () {
    late Directory files;
    setUp(() => files = Directory.systemTemp.createTempSync('archive_screens'));
    tearDown(() => files.deleteSync(recursive: true));

    testWidgets('the list fills as each pass ends; it waits while a night records', (tester) async {
      final seen = <String>[];
      await tester.pumpWidget(
        _app(
          ArchiveScreen(
            filesPath: files.path,
            now: () => _now,
            load: (_) async => _page(toSee: [_work.id]),
            busy: () async => const ArchiveBusy(),
            see: (f, id, p) async {
              seen.add(id);
              return (seen: _seen(), why: null);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(seen, [_work.id]);
      expect(find.textContaining('Found: eyes closed'), findsWidgets);
      await tester.pumpWidget(
        _app(
          ArchiveScreen(
            key: const ValueKey('night'),
            filesPath: files.path,
            now: () => _now,
            load: (_) async => _page(toSee: [_work.id]),
            busy: () async => const ArchiveBusy(nightRecording: true),
            see: (f, id, p) async => throw StateError('no pass while a night records'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Finding activity waits while a night or a session records'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // the retry timer goes with the page
    });

    Widget recording(ArchiveItem item, List<(DeleteMode, String)> deleted) => _app(
      RecordingScreen(
        item: item,
        filesPath: files.path,
        all: [item],
        detail: (f, i, s) async => RecordingDetail(input: _input(), rawPaths: const [], passKept: true),
        busy: () async => const ArchiveBusy(),
        delete: (f, i, m, all, b) async {
          deleted.add((m, i.id));
          return const DeleteOutcome(freedBytes: 1000000, refused: []);
        },
      ),
    );

    testWidgets('the Danger zone asks twice, says it is the only copy, and offers Everything', (tester) async {
      tester.view.physicalSize = const Size(1210, 2695);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final deleted = <(DeleteMode, String)>[];
      await tester.pumpWidget(recording(_night, deleted));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Delete…'), 300);
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This is the only copy'), findsOneWidget);
      expect(find.textContaining('The raw recording only'), findsOneWidget);
      await tester.tap(find.textContaining('Everything ('));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for good?'), findsOneWidget);
      expect(find.textContaining('No other copy exists'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);
      // again, through to the end
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(deleted, [(DeleteMode.rawOnly, _night.id)]);
    });

    testWidgets('with the laptop\'s checked copy: Remove from this phone, one confirmation', (tester) async {
      tester.view.physicalSize = const Size(1210, 2695);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final deleted = <(DeleteMode, String)>[];
      await tester.pumpWidget(recording(_board, deleted));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Remove from this phone'), 300);
      await tester.tap(find.text('Remove from this phone'));
      await tester.pumpAndSettle();
      expect(find.textContaining('It stays on your laptop'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(deleted, [(DeleteMode.rawOnLaptop, _board.id)]);
    });

    testWidgets('a tag from a band: the asleep stretch, tagged sleep', (tester) async {
      tester.view.physicalSize = const Size(1210, 2695);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(recording(_night, []));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Asleep'), 300);
      await tester.tap(find.text('Asleep'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(find.textContaining("The sleep report's stages"), findsOneWidget);
      await tester.tap(find.text('Tag this span'));
      await tester.pumpAndSettle();
      expect(find.text('Tag a span'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final tags = TagStore(files).tags(_night.id);
      expect([for (final t in tags) t.label], ['sleep']);
    });

    testWidgets('More leads with the archive', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _app(
          NightView(
            tab: HomeTab.more,
            model: const NightViewModel(title: 'Ready', sentence: '', tone: Tone.calm, running: false),
            onStart: () {},
            onStop: () {},
            onFix: (_) {},
            onArchive: () => opened++,
          ),
        ),
      );
      await tester.tap(find.text('Open the archive'));
      expect(opened, 1);
    });
  });
}
