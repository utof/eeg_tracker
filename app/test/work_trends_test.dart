// The work session's day numbers on the Trends page and as self-experiment outcomes (DECISIONS rows 480-489), worked
// out from made-up session files: an old file, partial days, a session over 04:00, someone else's session, a noisy
// session.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/experiments/analysis.dart';
import 'package:eeg_tracker/experiments/experiment.dart';
import 'package:eeg_tracker/study/arm.dart' show readOwnDayNumbers;
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/trends/usual.dart';
import 'package:eeg_tracker/ui/theme.dart' show nightTheme;
import 'package:eeg_tracker/ui/trends_view.dart' show TrendsView, missingMeasures;
import 'package:eeg_tracker/work/days.dart';
import 'package:eeg_tracker/work/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const TrendInputs _none = (nights: [], mornings: [], sessions: []);
const String _a = 'alert', _g = 'getting_drowsy', _d = 'drowsy', _u = 'unknown';

/// A session file as the phone writes it: one epoch per 30 s from [start], with [levels] one per epoch. [closed]:
/// epoch numbers read as closed eyes. [withTime]: false writes the first version's file (no epoch time: `t` held
/// the theta number).
Map<String, Object?> session(
  DateTime start,
  List<String> levels, {
  Set<int> closed = const {},
  bool withTime = true,
  List<Map<String, Object?>> hints = const [],
  List<Map<String, Object?>> breaks = const [],
  List<Map<String, Object?>> ratings = const [],
  Map<String, Object?>? wearer,
}) => {
  'version': 1,
  'kind': 'work_session',
  'start': start.toIso8601String(),
  'end': start.add(Duration(seconds: 30 * levels.length)).toIso8601String(),
  'ended': 'stopped',
  'hints': hints,
  'breaks': breaks,
  'ratings': ratings,
  'wearer': ?wearer,
  'epochs': [
    for (final (i, l) in levels.indexed)
      {
        't': withTime ? start.add(Duration(seconds: 30 * i)).toIso8601String() : -0.4,
        's': 30 * i,
        'eyes_closed': closed.contains(i),
        'level': l,
      },
  ],
};

List<String> run(int n, String level) => List.filled(n, level);

Map<String, Object?> hint(DateTime at, {bool taken = false}) => {
  'at': at.toIso8601String(),
  'reason': 'stretch',
  'active_min': 60.0,
  'threshold_min': 60.0,
  'level': 'alert',
  'taken': taken,
};

Map<String, Object?> brk(DateTime start, int minutes) => {
  'start': start.toIso8601String(),
  'end': start.add(Duration(minutes: minutes)).toIso8601String(),
  'source': 'tapped',
};

Map<String, Object?> tap(DateTime at, int v) => {'at': at.toIso8601String(), 'value': v, 'hint': null};

void main() {
  final nine = DateTime(2026, 11, 18, 9);
  final now = DateTime(2026, 11, 30, 15);

  // 8 and 12 on alternate days: a usual of 10 with a spread of 3
  Map<String, Map<String, double>> steady(double last) => {
    'workdrowsy': {
      for (var d = 1; d <= 29; d++) '2026-11-${d.toString().padLeft(2, '0')}': d.isEven ? 12.0 : 8.0,
      '2026-11-30': last,
    },
  };

  group('the day numbers', () {
    test('one session: usable time, the drowsy share, hints, breaks and the mean tap', () {
      // 8 unknown (baseline) + 60 alert + 20 getting drowsy + 12 drowsy + 30 alert = 130 epochs (65 min); the
      // 8-minute break at 50:00 takes epochs 100-115, the 2-minute pause at 58:00 takes 116-119
      final s = session(
        nine,
        [...run(8, _u), ...run(60, _a), ...run(20, _g), ...run(12, _d), ...run(30, _a)],
        hints: [hint(nine.add(const Duration(minutes: 40)), taken: true), hint(nine.add(const Duration(minutes: 47)))],
        breaks: [brk(nine.add(const Duration(minutes: 50)), 8), brk(nine.add(const Duration(minutes: 58)), 2)],
        ratings: [tap(nine.add(const Duration(minutes: 40)), 4), tap(nine.add(const Duration(minutes: 47)), 2)],
      );
      final n = workDayNumbers([s]);
      expect(n['worktime']!['2026-11-18'], closeTo(51, 1e-9), reason: '102 usable epochs: not the 8 unknown, not the breaks');
      expect(n['workdrowsy']!['2026-11-18'], closeTo(32 / 102 * 100, 1e-9));
      expect(n['workhints'], {'2026-11-18': 2.0});
      expect(n['workfollowed'], {'2026-11-18': 1.0});
      expect(n['workbreaks'], {'2026-11-18': 1.0}, reason: 'the 2-minute pause does not count: under 5 minutes');
      expect(n['worksharp'], {'2026-11-18': 3.0});
    });

    test('noisy and eyes-closed half minutes are left out of the time and of the share', () {
      // 50 alert, 20 closed (read alert but not scored), 10 getting drowsy, 20 unknown
      final levels = [...run(50, _a), ...run(20, _a), ...run(10, _g), ...run(20, _u)];
      final n = workDayNumbers([
        session(nine, levels, closed: {for (var i = 50; i < 70; i++) i}),
      ]);
      expect(n['worktime']!['2026-11-18'], closeTo(30, 1e-9), reason: '60 usable epochs');
      expect(n['workdrowsy']!['2026-11-18'], closeTo(10 / 60 * 100, 1e-9));
    });

    test('under 30 minutes of usable time a day has no number at all, taps and hints included', () {
      final short = session(
        nine,
        [...run(10, _u), ...run(59, _a)],
        hints: [hint(nine.add(const Duration(minutes: 20)))],
        ratings: [tap(nine.add(const Duration(minutes: 20)), 5)],
      );
      expect(workDayNumbers([short]).values.every((d) => d.isEmpty), isTrue);
      final enough = session(nine, [...run(10, _u), ...run(60, _a)]);
      expect(workDayNumbers([enough])['worktime'], {'2026-11-18': 30.0});
    });

    test('a session of noisy time only gives nothing', () {
      expect(workDayNumbers([session(nine, run(240, _u))]).values.every((d) => d.isEmpty), isTrue);
    });

    test("someone else's session is left out, as their nights are", () {
      final mine = session(nine, run(80, _a));
      final other = session(DateTime(2026, 11, 18, 14), run(80, _d), wearer: {'answer': 'someone else', 'at': 'x'});
      final n = workDayNumbers([mine, other]);
      expect(n['worktime'], {'2026-11-18': 40.0});
      expect(n['workdrowsy'], {'2026-11-18': 0.0});
      final said = session(DateTime(2026, 11, 18, 14), run(80, _d), wearer: {'answer': 'me', 'at': 'x'});
      expect(workDayNumbers([mine, said])['worktime'], {'2026-11-18': 80.0});
    });

    test('time inside a break is not work time', () {
      final s = session(
        nine,
        run(120, _a), // an hour
        breaks: [brk(nine.add(const Duration(minutes: 20)), 10)],
      );
      expect(workDayNumbers([s])['worktime'], {'2026-11-18': 50.0});
    });

    test('minutes until the first drowsy stretch: 8 of 12 half minutes up, in worked minutes', () {
      // 70 alert, then 12 half minutes with drowsy on 8 of them (the 8th is epoch 70 + 8 + 2 gaps = index 79)
      final levels = [
        ...run(70, _a),
        _g, _g, _a, _g, _g, _a, _g, _g, _g, _g, _a, _a, //
        ...run(30, _a),
      ];
      final n = workDayNumbers([session(nine, levels)]);
      // up epochs at 70,71,73,74,76,77,78,79: the 8th is index 79, so 80 epochs (40 min) worked up to and with it
      expect(n['workfirst'], {'2026-11-18': 40.0});
    });

    test('a day without a drowsy stretch has no "until" number, and an alert-only day shares 0 %', () {
      final n = workDayNumbers([session(nine, run(100, _a))]);
      expect(n['workfirst'], isEmpty);
      expect(n['workdrowsy'], {'2026-11-18': 0.0});
    });

    test('the stretch counts the worked minutes of the day before it, across sessions; breaks and unknown do not', () {
      final first = session(nine, [...run(20, _u), ...run(40, _a)]); // 20 usable minutes
      final levels = [...run(30, _a), ...run(12, _d)]; // 8 of 12 reached at the 8th drowsy epoch
      final second = session(DateTime(2026, 11, 18, 13), levels);
      expect(workDayNumbers([second, first])['workfirst'], {'2026-11-18': 20 + 19.0});
    });

    test('a session over 04:00 is split: each half goes to its own day, each needs its 30 minutes', () {
      final start = DateTime(2026, 11, 19, 1, 30); // 01:30-05:30; 04:00 is epoch 300
      final both = session(start, run(480, _a));
      final n = workDayNumbers([both]);
      expect(n['worktime'], {'2026-11-18': 150.0, '2026-11-19': 90.0});
      final short = session(DateTime(2026, 11, 19, 2), run(360, _a)); // 02:00-05:00
      expect(workDayNumbers([short])['worktime'], {'2026-11-18': 120.0, '2026-11-19': 60.0});
      final tiny = session(DateTime(2026, 11, 19, 3, 40), run(110, _a)); // 03:40-04:35
      expect(workDayNumbers([tiny])['worktime'], {'2026-11-19': 35.0}, reason: '20 minutes before 04:00 is too little');
    });

    test('the first file version (no time on the epochs: `t` held the theta number) is placed by its seconds', () {
      final old = session(DateTime(2026, 11, 19, 3, 0), run(240, _a), withTime: false); // 03:00-05:00
      final n = workDayNumbers([old]);
      expect(n['worktime'], {'2026-11-18': 60.0, '2026-11-19': 60.0});
    });

    test('a damaged or foreign entry is skipped, a half-written epoch too', () {
      final ok = session(nine, run(80, _a));
      final epochs = (ok['epochs']! as List).cast<Map<String, Object?>>();
      final bent = {
        ...ok,
        'epochs': [...epochs, 'junk', {'level': 5}, {'t': 'not a time', 's': null, 'level': 'alert'}],
        'hints': [3, {'at': 'x'}],
        'ratings': [{'at': nine.toIso8601String(), 'value': 9}],
      };
      final n = workDayNumbers([bent, 'text', null, {'kind': 'other'}, {'kind': 'work_session', 'start': 'x'}]);
      expect(n['worktime'], {'2026-11-18': 40.0});
      expect(n['workhints'], {'2026-11-18': 0.0});
      expect(n['worksharp'], isEmpty, reason: 'a tap outside 1-5 is not a tap');
    });

    test('several sessions in a day add up; hints and taps belong to the day of their own time', () {
      final one = session(nine, run(80, _a), ratings: [tap(nine.add(const Duration(minutes: 30)), 5)]);
      final two = session(DateTime(2026, 11, 18, 15), run(80, _g), ratings: [tap(DateTime(2026, 11, 18, 15, 30), 2)]);
      final n = workDayNumbers([one, two]);
      expect(n['worktime'], {'2026-11-18': 80.0});
      expect(n['workdrowsy'], {'2026-11-18': 50.0});
      expect(n['worksharp'], {'2026-11-18': 3.5});
    });
  });

  group('from the folder', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('work-trends'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('readWorkDayNumbers and readOwnDayNumbers read files/work-sessions/ beside recordings/', () {
      final recordings = '${tmp.path}/files/recordings';
      Directory(recordings).createSync(recursive: true);
      final store = WorkStore(workDirFor(recordings));
      store.save(session(nine, run(80, _g)));
      File('${store.dir.path}/broken.work.json').writeAsStringSync('{');
      File('${store.dir.path}/note.txt').writeAsStringSync('hello');
      expect(readWorkDayNumbers(recordings)['workdrowsy'], {'2026-11-18': 100.0});
      expect(readOwnDayNumbers(recordings)['workdrowsy'], {'2026-11-18': 100.0});
      expect(readWorkDayNumbers('${tmp.path}/nothing/recordings')['worktime'], isEmpty);
    });
  });

  group('on the trends', () {
    test('the numbers join Trends, each said to be seen together, not tested', () {
      final m = buildTrends(_none, now, extra: steady(60));
      final ids = {for (final r in m.rows) r.spec.id: r};
      for (final id in ['worktime', 'workdrowsy', 'workfirst', 'workhints', 'workfollowed', 'workbreaks', 'worksharp']) {
        final r = ids[id]!;
        expect(r.spec.group, TrendGroup.work, reason: id);
        expect(r.spec.note, contains('Seen together, not tested.'), reason: id);
      }
      final r = ids['workdrowsy']!;
      expect(r.spec.label, 'Work time drowsy');
      expect(r.spec.format(32.4), '32 %');
      expect(r.value, 60);
      expect(r.yesterday, 8);
      expect(r.usual.median, 10);
      expect(r.arrow, Arrow.up);
      expect(r.spec.up, 'drowsier than usual');
      expect(ids['worksharp']!.spec.format(3.46), '3.5 of 5');
      expect(ids['worksharp']!.spec.scale, Scale.meanRating);
      expect(ids['workfirst']!.spec.format(95), '1 h 35 min');
      expect(ids['workbreaks']!.spec.scale, Scale.noArrows);
      expect(ids['workhints']!.spec.format(1), '1 hint');
      expect(ids['workhints']!.spec.format(7), '7 hints');
    });

    test('an arrow needs 14 days, like every number', () {
      final few = {
        'workdrowsy': {for (var d = 20; d <= 29; d++) '2026-11-$d': 10.0, '2026-11-30': 60.0},
      };
      expect(buildTrends(_none, now, extra: few).rows.singleWhere((r) => r.spec.id == 'workdrowsy').arrow, Arrow.none);
    });

    test('never used: the work numbers are not listed as missing', () {
      final m = buildTrends(_none, now);
      expect(missingMeasures(m), isNot(contains('work time drowsy')));
      expect(missingMeasures(m).where((s) => s.startsWith('work') || s.contains('sharpness at work')), isEmpty);
      expect(missingMeasures(m), contains('sleepiness'));
    });
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('the page shows the work numbers in words at ${(scale * 100).round()} % text', (tester) async {
      tester.view.physicalSize = const Size(1210, 14000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final extra = {
        ...steady(60),
        'worktime': {'2026-11-30': 215.0},
        'workfirst': {'2026-11-30': 95.0},
        'workhints': {'2026-11-30': 2.0},
        'worksharp': {'2026-11-29': 3.5, '2026-11-30': 2.5},
      };
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(theme: nightTheme(), home: TrendsView(model: buildTrends(_none, now, extra: extra))),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Work time drowsy'), findsWidgets);
      expect(find.text('60\u00a0%'), findsOneWidget);
      expect(find.textContaining('Drowsier than usual (normal range'), findsOneWidget);
      expect(find.text('Work with a signal'), findsWidgets);
      expect(find.text('3\u00a0h\u00a035\u00a0min'), findsOneWidget);
      expect(find.text('Sharpness at work'), findsWidgets);
      expect(find.textContaining('Seen together, not tested.'), findsWidgets);
      expect(find.textContaining('Nothing yet for'), findsOneWidget);
      expect(find.textContaining('work'), findsWidgets);
    });
  }

  group('as self-experiment outcomes', () {
    test('the share of work time drowsy and the work sharpness are offered, judged by the next day like every outcome', () {
      final o = outcomeById('workdrowsy')!;
      expect(o.noun, 'share of work time drowsy');
      expect(o.matters, 10);
      expect(o.relative, isFalse);
      expect(sizeWords(o, 7.6), '8\u00a0percentage\u00a0points higher');
      expect(rangeWords(o, -5, 12), '−5 to +12\u00a0percentage\u00a0points');
      final s = outcomeById('worksharp')!;
      expect(s.noun, 'sharpness at work');
      expect(s.matters, 0.5);
      expect(sizeWords(s, -0.64), '0.6\u00a0points lower');
      for (final id in ['worktime', 'workfirst', 'workhints', 'workfollowed', 'workbreaks']) {
        expect(outcomeById(id), isNull, reason: '$id is not offered');
      }
    });
  });

  test('the file is read as the phone writes it (a JSON round trip)', () {
    final text = jsonEncode(session(nine, run(80, _g)));
    expect(workDayNumbers([jsonDecode(text)])['workdrowsy'], {'2026-11-18': 100.0});
  });
}
