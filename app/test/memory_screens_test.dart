// Renders the Memory cues page, the evening task and the morning test in their states at the owner's phone width
// (393 dp), with real fonts, writes PNGs to build/screens/memory_*.png for a human look (the first viewport and the
// whole column), fails on any layout overflow (also at 130 % text), checks what is due from the files, and drives the
// evening task and the morning test end to end with a fake bell. The sessions and nights below are made up for the
// pictures; nothing here was measured.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/cues/night_cues.dart' show CueMoment;
import 'package:eeg_tracker/lucid/bell.dart';
import 'package:eeg_tracker/memory_cues/plan.dart';
import 'package:eeg_tracker/memory_cues/sounds.dart' show memorySoundFiles;
import 'package:eeg_tracker/memory_cues/store.dart';
import 'package:eeg_tracker/memory_cues/task.dart';
import 'package:eeg_tracker/ui/hands_free_view.dart';
import 'package:eeg_tracker/ui/memory_cues_screen.dart';
import 'package:eeg_tracker/ui/memory_cues_view.dart';
import 'package:eeg_tracker/ui/memory_task_view.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final int _start = DateTime(2026, 11, 26, 0, 40).millisecondsSinceEpoch;

/// A finished session: the evening test a little off each place, made up.
MemorySession _session({int seed = 11, DateTime? done}) {
  final at = done ?? DateTime(2026, 11, 25, 23, 52);
  final s = drawSession(math.Random(seed), at.subtract(const Duration(minutes: 13)), boardDp: 345);
  final r = math.Random(seed + 1);
  return s.copyWith(
    evening: {
      for (final i in s.items)
        i.object: (x: i.x + (r.nextDouble() - 0.5) * 0.12, y: i.y + (r.nextDouble() - 0.5) * 0.12),
    },
    eveningEnd: at.subtract(const Duration(minutes: 2)),
    levels: [0.0126, 0.02],
    completed: at,
  );
}

final MemorySession _s = _session();

/// The morning test: a little further off, a few far off.
final Map<String, BoardPoint> _morningTaps = () {
  final r = math.Random(5);
  return {
    for (final (j, i) in _s.items.indexed)
      i.object: j % 9 == 0
          ? (x: 0.1 + r.nextDouble() * 0.8, y: 0.1 + r.nextDouble() * 1.05)
          : (x: i.x + (r.nextDouble() - 0.5) * 0.2, y: i.y + (r.nextDouble() - 0.5) * 0.2),
  };
}();

final MemoryNightRecord _record = MemoryNightRecord(
  startMs: _start,
  index: 4,
  session: _s.id,
  cuesFromMs: _start + 30 * 60000,
  phase: 'done',
  cues: [
    for (var k = 0; k < 46; k++)
      CueMoment(
        atMs: _start + (60 + k ~/ 10 * 25) * 60000 + k * 10000,
        step: -3,
        period: 1 + k ~/ 10,
        confidence: 0.81,
        aroused: k == 23,
      ),
  ],
);

final _nights = [
  (answered: true, lucid: false),
  (answered: true, lucid: false),
  (answered: false, lucid: false),
  (answered: true, lucid: false),
  (answered: true, lucid: false),
];

MemoryResults _results() {
  final sealed = MemorySealed.draw('7' * 64);
  final plan = MemoryPlan(frozen: DateTime(2026, 11, 10), scheduleSha256: sealed.sha);
  return memoryResults(
    plan: plan,
    planSha: plan.sha,
    sealed: sealed,
    nights: [
      for (var i = 0; i < 13; i++)
        MemoryNight(
          index: i,
          cueMoments: 40 + i,
          arousedMoments: i % 3,
          evening: const [0.12, 0.12],
          morning: i == 5 ? null : [0.15 + (i % 4) * 0.004, 0.16 - (i % 3) * 0.004],
          heard: i == 5 ? null : (i % 4 == 0 ? 'yes' : 'no'),
        ),
    ],
  )!;
}

final Map<String, MemoryViewModel> states = {
  'off': const MemoryViewModel(on: false, due: MemoryDue.turnOn),
  'waiting': MemoryViewModel(on: true, due: MemoryDue.waiting, lucidOn: true, nights: _nights, nextIndex: 5),
  'evening': MemoryViewModel(
    on: true,
    due: MemoryDue.evening,
    nights: _nights,
    nextIndex: 5,
    levels: _s.levels,
    last: MemoryLastNight(
      record: _record,
      session: _s,
      morning: MemoryMorning(session: _s.id, made: DateTime(2026, 11, 26, 8, 14), taps: _morningTaps, heard: 'no'),
    ),
  ),
  'ready': MemoryViewModel(
    on: true,
    due: MemoryDue.ready,
    readyAt: DateTime(2026, 11, 26, 23, 41),
    nights: _nights,
    nextIndex: 5,
    levels: _s.levels,
  ),
  'morning': MemoryViewModel(
    on: true,
    due: MemoryDue.morning,
    nights: _nights.sublist(0, 4),
    nextIndex: 5,
    levels: _s.levels,
    last: MemoryLastNight(record: _record, session: _s),
  ),
  'results': MemoryViewModel(
    on: true,
    due: MemoryDue.evening,
    nights: [for (var i = 0; i < 13; i++) (answered: i != 5, lucid: false)],
    nextIndex: 13,
    results: _results(),
    levels: _s.levels,
    last: MemoryLastNight(
      record: MemoryNightRecord(
        startMs: _start,
        index: 12,
        session: 'gone',
        cuesFromMs: _start + 30 * 60000,
        phase: 'off',
        off: 'The sleep model stopped (it failed or was too slow), so no more cues tonight.',
      ),
      expired: true,
    ),
  ),
};

final MemoryItem _first = _s.itemOf(_s.studyOrder.first);

final Map<String, TaskViewModel> faces = {
  'task_intro': TaskViewModel(morning: false, phase: TaskPhase.intro, session: _s),
  'task_study': TaskViewModel(
    morning: false,
    phase: TaskPhase.study,
    session: _s,
    object: _first.object,
    done: _s.studyOrder.take(6).toSet(),
  ),
  'task_learn': TaskViewModel(
    morning: false,
    phase: TaskPhase.learn,
    session: _s,
    object: _first.object,
    done: _s.studyOrder.take(9).toSet(),
    round: 2,
  ),
  'task_learn_answer': TaskViewModel(
    morning: false,
    phase: TaskPhase.learn,
    session: _s,
    object: _first.object,
    tap: (x: _first.x + 0.2, y: _first.y + 0.1),
    showPlace: true,
    close: false,
    done: _s.studyOrder.take(9).toSet(),
    round: 2,
  ),
  'task_test': TaskViewModel(
    morning: false,
    phase: TaskPhase.test,
    session: _s,
    object: _first.object,
    done: _s.studyOrder.skip(3).take(20).toSet(),
  ),
  'task_loudness': TaskViewModel(
    morning: false,
    phase: TaskPhase.loudness,
    session: _s,
    loudnessSound: 1,
    loudnessStep: 4,
  ),
  'task_done': TaskViewModel(morning: false, phase: TaskPhase.done, session: _s),
  'morning_intro': TaskViewModel(morning: true, phase: TaskPhase.intro, session: _s),
  'morning_heard': TaskViewModel(morning: true, phase: TaskPhase.heard, session: _s),
  'morning_result': TaskViewModel(
    morning: true,
    phase: TaskPhase.result,
    session: _s,
    morningTaps: _morningTaps,
    numbers: (
      closeEvening: closeCount(_s, _s.evening),
      closeMorning: closeCount(_s, _morningTaps),
      distEvening: meanError(_s, _s.evening),
      distMorning: meanError(_s, _morningTaps),
    ),
  ),
};

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Widget _app(Widget child, double scale, GlobalKey key) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: nightTheme(),
      home: RepaintBoundary(key: key, child: child),
    ),
  ),
);

MemoryView _view(MemoryViewModel m) =>
    MemoryView(model: m, onTurnOn: () {}, onTurnOff: () {}, onEvening: () {}, onMorning: () {}, onInfo: () {});

TaskView _face(TaskViewModel m) => TaskView(
  model: m,
  onStart: () {},
  onTap: (_) {},
  onHeardSound: () {},
  onStop: () {},
  onHeardAnswer: (_) {},
  onSave: () {},
  onDone: () {},
);

class _Bell implements CueBell {
  final List<(String, double)> played = [];
  @override
  Future<bool> play(File cue, double gain) async {
    played.add((cue.path.split('/').last, gain));
    return true;
  }

  @override
  Future<({int volume, int max})?> mediaVolume() async => (volume: 8, max: 15);
}

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    final suffix = scale == 1.0 ? '' : '_text130';
    for (final e in states.entries) {
      for (final full in [false, true]) {
        testWidgets('memory ${e.key}${full ? ' (whole column)' : ''} at ${(scale * 100).round()} % text', (
          tester,
        ) async {
          tester.view.physicalSize = Size(1080, full ? 2.75 * 5200 : 2400);
          tester.view.devicePixelRatio = 2.75;
          addTearDown(tester.view.reset);
          final key = GlobalKey();
          await tester.pumpWidget(_app(_view(e.value), scale, key));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          await _shot(tester, key, 'memory_${e.key}${full ? '_full' : ''}$suffix');
        });
      }
    }
    for (final e in faces.entries) {
      testWidgets('memory ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = Size(1080, e.key == 'morning_result' ? 2.75 * 1500 : 2400);
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(_app(_face(e.value), scale, key));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        await _shot(tester, key, 'memory_${e.key}$suffix');
      });
    }

    testWidgets('night screen with its Memory cues section at ${(scale * 100).round()} % text', (tester) async {
      tester.view.physicalSize = const Size(1080, 2.75 * 2800);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final view = NightView(
        model: const NightViewModel(
          title: 'Ready',
          sentence: 'Put the headband on, then Start night.',
          tone: Tone.calm,
          running: false,
          memoryLine: 'On: learn the board before Start night.',
        ),
        onStart: () {},
        onStop: () {},
        onFix: (_) {},
        onMeditate: () {},
        onDream: () {},
        onNap: () {},
        onLucid: () {},
        onMemory: () {},
        onSound: () {},
      );
      await tester.pumpWidget(_app(view, scale, key));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.text('Memory cues'), findsWidgets);
      await _shot(tester, key, 'night_memory$suffix');
    });

    testWidgets('settings with its Memory cues row at ${(scale * 100).round()} % text', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      var opened = false;
      await tester.pumpWidget(
        _app(
          SettingsView(
            model: const SettingsViewModel(on: false, nightRunning: false),
            onToggle: (_) {},
            onCalibrate: () {},
            onInfo: () {},
            studyOn: false,
            onStudy: () {},
            memoryOn: false,
            onMemory: () => opened = true,
          ),
          scale,
          key,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('the assistant\'s proposal; evidence weak'), findsOneWidget);
      await _shot(tester, key, 'settings_memory$suffix');
      await tester.tap(find.text('Memory cues'));
      expect(opened, isTrue);
    });
  }

  group('what is due, from the files', () {
    late Directory dir;
    late MemoryStore store;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('memory_due');
      store = MemoryStore(Directory('${dir.path}/memory_cues'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    MemoryViewModel model(DateTime now, {bool running = false, bool lucidOn = false, int? runningStart}) =>
        memoryModel(store: store, now: now, nightRunning: running, lucidOn: lucidOn, runningStartMs: runningStart);

    test('never used: turn on, and no night-screen line; on: learn tonight; lucid cues on: waiting', () {
      expect(model(DateTime(2026, 11, 25, 21)).due, MemoryDue.turnOn);
      expect(memoryNightLine('${dir.path}/recordings'), isNull);
      store.setOn(true, DateTime(2026, 11, 25, 21));
      expect(model(DateTime(2026, 11, 25, 21)).due, MemoryDue.evening);
      expect(
        memoryNightLine('${dir.path}/recordings', now: DateTime(2026, 11, 25, 21)),
        'On: learn the board before Sleep.',
      );
      expect(model(DateTime(2026, 11, 25, 21), lucidOn: true).due, MemoryDue.waiting);
    });

    test('a finished session makes the next 3 hours ready; a night that uses it ends that', () {
      store.setOn(true, DateTime(2026, 11, 25, 21));
      final s = _session(done: DateTime(2026, 11, 25, 23, 52));
      store.saveSession(s);
      final m = model(DateTime(2026, 11, 26, 0, 30));
      expect((m.due, m.readyAt), (MemoryDue.ready, s.completed));
      expect(m.levels, s.levels);
      expect(model(DateTime(2026, 11, 26, 3)).due, MemoryDue.evening);
      expect(model(DateTime(2026, 11, 26, 0, 41), running: true, runningStart: _start).due, MemoryDue.night);
    });

    /// The first night of the test.
    final first = MemoryNightRecord(startMs: _start, index: 0, session: _s.id, cuesFromMs: _start + 30 * 60000);

    test('the morning after a night in the test: the test is due, even if switched off since; then the evening', () {
      store.setOn(true, DateTime(2026, 11, 25, 21));
      store.saveSession(_s);
      store.saveNight(first);
      final morning = DateTime(2026, 11, 26, 8, 30);
      expect(model(morning).due, MemoryDue.morning);
      expect(model(morning, running: true, runningStart: _start).due, isNot(MemoryDue.morning));
      expect(
        memoryNightLine('${dir.path}/recordings', now: morning),
        'This morning\'s test is waiting: about 2 minutes.',
      );
      store.setOn(false, DateTime(2026, 11, 26, 8));
      expect(model(morning).due, MemoryDue.morning);
      store.saveMorning(first.stamp, MemoryMorning(session: _s.id, made: morning, taps: _morningTaps, heard: 'no'));
      final m = model(morning);
      expect(m.due, MemoryDue.turnOn);
      expect(m.nights, [(answered: true, lucid: false)]);
      expect(m.last!.morning, isNotNull);
    });

    test('the morning test runs out after 30 hours or when a new evening task begins; the night stays in the test', () {
      store.setOn(true, DateTime(2026, 11, 25, 21));
      store.saveSession(_s);
      store.saveNight(first);
      expect(model(DateTime(2026, 11, 27, 6, 41)).due, MemoryDue.evening);
      expect(model(DateTime(2026, 11, 27, 6, 41)).last!.expired, isTrue);
      store.saveSession(drawSession(math.Random(3), DateTime(2026, 11, 26, 21)));
      final m = model(DateTime(2026, 11, 26, 21, 5));
      expect(m.due, MemoryDue.evening);
      expect(m.nights, [(answered: false, lucid: false)]);
    });
  });

  group('the task, end to end', () {
    late Directory dir;
    late MemoryStore store;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('memory_task');
      store = MemoryStore(Directory('${dir.path}/memory_cues'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> tapBoard(WidgetTester tester, BoardPoint p) async {
      final board = find.byType(MemoryBoard);
      final box = tester.getRect(board);
      await tester.tapAt(box.topLeft + Offset(p.x * box.width, p.y * box.width));
    }

    testWidgets('the evening: look, learn, test, two loudness taps; a complete session, the sounds at their halves', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final bell = _Bell();
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: MemoryTaskScreen(store: store, bell: bell, random: math.Random(4)),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pump();
      // the first look: every object once, each with its own half's sound
      for (var i = 0; i < TaskRule.objects; i++) {
        await tester.pump(const Duration(milliseconds: TaskRule.studyMs + TaskRule.studyGapMs));
      }
      await tester.pump();
      final session = store.sessions().single;
      expect(bell.played, hasLength(TaskRule.objects));
      for (final (j, o) in session.studyOrder.indexed) {
        expect(bell.played[j].$1, memorySoundFiles[session.itemOf(o).sound]);
      }
      expect(find.text('Where was it? Tap its place.'), findsOneWidget);
      // learning: put every object exactly in its place (one round)
      for (var i = 0; i < TaskRule.objects; i++) {
        final icon = tester.widget<Icon>(find.byKey(const ValueKey('memory-tray')));
        final item = session.items.firstWhere((it) => it.object == icon.semanticLabel);
        await tapBoard(tester, (x: item.x, y: item.y));
        await tester.pump(const Duration(milliseconds: 1900));
      }
      // the test: every object a little off
      for (var i = 0; i < TaskRule.objects; i++) {
        final icon = tester.widget<Icon>(find.byKey(const ValueKey('memory-tray')));
        final item = session.items.firstWhere((it) => it.object == icon.semanticLabel);
        await tapBoard(tester, (x: item.x + 0.05, y: item.y));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.text('I hear it'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9)); // a few steps of the bell
      await tester.tap(find.text('I hear it'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('I hear it'));
      await tester.pumpAndSettle();
      expect(find.text('Ready for tonight'), findsOneWidget);
      final done = store.sessions().single;
      expect(done.isComplete, isTrue);
      expect(done.learn, hasLength(TaskRule.objects));
      expect(done.evening, hasLength(TaskRule.objects));
      expect(meanError(done, done.evening), closeTo(0.05, 1e-3));
      expect(done.levels![1], lessThan(done.levels![0]), reason: 'the knock\'s ramp starts 12 dB under the bell\'s');
      expect(done.mediaVolume, 8);
      expect(store.freshSession(DateTime.now().add(const Duration(minutes: 20)).millisecondsSinceEpoch)!.id, done.id);
    });

    testWidgets('the morning: the test with no sound, the question, then the numbers and the drift map', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      store.saveSession(_s);
      store.saveNight(_record);
      final bell = _Bell();
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: MemoryTaskScreen(store: store, bell: bell, morningOf: _record, session: _s, random: math.Random(2)),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pump();
      for (var i = 0; i < TaskRule.objects; i++) {
        final icon = tester.widget<Icon>(find.byKey(const ValueKey('memory-tray')));
        final item = _s.items.firstWhere((it) => it.object == icon.semanticLabel);
        await tapBoard(tester, (x: item.x, y: item.y > 0.6 ? item.y - 0.1 : item.y + 0.1));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(bell.played, isEmpty, reason: 'no sound in the tests');
      expect(find.text('Answer the question'), findsOneWidget);
      await tester.tap(find.text('No'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Saved'), findsOneWidget);
      final m = store.morning(_record.stamp)!;
      expect(m.heard, 'no');
      expect(meanError(_s, m.taps), closeTo(0.1, 1e-3));
    });
  });
}
