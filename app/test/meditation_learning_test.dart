// The meditation learning verdict (ROADMAP row 21; docs/evidence/meditation-feedback.md): the robust trend
// against SciPy, the silent block at the end of a session, and the verdict's rules and words at 8 and 12 sessions.
// Every number below is made up; nothing here was measured on a person.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/feedback/session.dart';
import 'package:eeg_tracker/meditation/learning.dart';
import 'package:eeg_tracker/meditation/silent_block.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/meditation/trend.dart';
import 'package:eeg_tracker/training/control.dart';
import 'package:flutter_test/flutter_test.dart';

/// A calibrated core on the demo signal (30 s eyes open, then closed until calibration ends).
Session calibrated(DemoSignal demo) {
  final s = Session();
  while (s.phase != 'run') {
    demo.eyes = demo.t < 30 ? 'open' : 'closed';
    s.push(demo.next(25));
  }
  return s;
}

/// The silent block's meter after [seconds] of the demo with eyes closed.
SilentMeter silentFor(Session s, DemoSignal demo, double seconds, {DriftState? drift}) {
  final m = SilentMeter();
  while (m.seconds < seconds - 1e-9) {
    for (final r in s.push(demo.next(25))) {
      m.add(r, s.baseline, drift: drift);
    }
  }
  return m;
}

/// A made-up meditation summary on day [day] whose silent block has [alpha] (log10 against the silent minute);
/// [withBlock] false: stopped before the silent block.
MeditationSummary session(
  int day, {
  double? alpha,
  bool withBlock = true,
  double muscle = 0.02,
  double drowsy = 0.01,
  double? outcome,
  bool bluetooth = false,
  bool inCheck = false,
  SessionKind kind = SessionKind.meditation,
}) => MeditationSummary(
  kind: kind,
  start: DateTime(2026, 11, 1).add(Duration(days: day, hours: 21)),
  lengthMin: 10,
  runS: 600,
  complete: true,
  settledS: 300,
  longestSettledS: 40,
  bells: 12,
  restless: {Restless.jaw: 1, Restless.blinks: 3, Restless.movement: 0},
  drifting: 0,
  drowsyS: 0,
  calm: const [0.5],
  iafHz: 10,
  note: '',
  logFile: '',
  outcome: outcome,
  check: inCheck ? const {'phase': 'randomised', 'index': 0} : null,
  bluetoothSound: bluetooth,
  silent: !withBlock
      ? null
      : SilentBlock(plannedS: 120, seconds: 120, countedS: 100, alpha: alpha, muscleShare: muscle, drowsyShare: drowsy),
);

void main() {
  group('trend: Theil-Sen with its 90 % range', () {
    final fixture = jsonDecode(File('test/fixtures/learning_trend.json').readAsStringSync()) as Map<String, Object?>;
    final cases = (fixture['cases']! as List).cast<Map<String, Object?>>();

    test('the fixture is SciPy\'s, at 90 %', () {
      expect(fixture['level'], 0.9);
      expect(cases, hasLength(8));
    });

    for (final c in cases) {
      test('the same slope and range as scipy.stats.theilslopes: ${c['name']}', () {
        List<double> d(String k) => [for (final v in c[k]! as List) (v as num).toDouble()];
        final t = theilSen(d('x'), d('y'))!;
        expect(t.n, d('y').length);
        expect(t.slope, closeTo((c['slope']! as num).toDouble(), 1e-12));
        expect(t.low, closeTo((c['low']! as num).toDouble(), 1e-12));
        expect(t.high, closeTo((c['high']! as num).toDouble(), 1e-12));
      });
    }

    test('fewer than 2 distinct x values give no trend; lengths must agree', () {
      expect(theilSen([1], [0.2]), isNull);
      expect(theilSen([1, 1, 1], [0.1, 0.2, 0.3]), isNull);
      expect(() => theilSen([1, 2], [0.1]), throwsArgumentError);
    });

    test('rounding of the range\'s ranks is numpy\'s: half to even', () {
      expect(roundHalfEven(2.5), 2);
      expect(roundHalfEven(3.5), 4);
      expect(roundHalfEven(-0.5), 0);
      expect(roundHalfEven(2.4999), 2);
      expect(roundHalfEven(2.5001), 3);
    });
  });

  group('the silent block', () {
    test('its number is alpha in the silent minutes against the calibration\'s silent eyes-closed minute', () {
      final plain = DemoSignal(5)..wanders = false;
      final s1 = calibrated(plain), same = silentFor(s1, plain, 120).block(120);
      final louder = DemoSignal(5)..wanders = false;
      final s2 = calibrated(louder);
      louder.alphaGain = 2; // twice the amplitude: 4x the power, +0.6 in log10
      final more = silentFor(s2, louder, 120).block(120);
      expect(same.seconds, closeTo(120, 0.05));
      expect(same.alpha, isNotNull);
      expect(same.alpha!.abs(), lessThan(0.15), reason: 'the same alpha as the calibration minute');
      expect(more.alpha! - same.alpha!, closeTo(0.6, 0.15));
      // the demo clenches 3 s every 45 s: jaw time shows as the muscle share, and is never counted
      expect(same.muscleShare, inInclusiveRange(0.04, 0.2));
      expect(same.countedS, lessThan(120 * (1 - same.muscleShare) + 0.05));
      expect(same.drowsyShare, 0);
    });

    test('drowsy or asleep time is its own share; asleep steps are not counted; under 60 s counted: no number', () {
      final demo = DemoSignal(5);
      final s = calibrated(demo);
      final asleep = silentFor(s, demo, 120, drift: DriftState.asleep).block(120);
      expect(asleep.drowsyShare, 1);
      expect(asleep.countedS, 0);
      expect(asleep.alpha, isNull);
      final short = silentFor(s, demo, 50).block(120);
      expect(short.seconds, closeTo(50, 0.05));
      expect(short.alpha, isNull, reason: 'under $silentMinCountedS s of awake clean signal');
    });

    test('the summary keeps it; damaged numbers are refused; older files read as before', () {
      final m = session(1, alpha: 0.12, muscle: 0.05, drowsy: 0.1);
      final back = MeditationSummary.fromJson(jsonDecode(jsonEncode(m.toJson())))!;
      expect(back.toJson(), m.toJson());
      expect(back.silent!.alpha, 0.12);
      expect(back.bluetoothSound, isFalse);
      Map<String, Object?> j() => jsonDecode(jsonEncode(m.toJson())) as Map<String, Object?>;
      expect(MeditationSummary.fromJson(j()..remove('silent'))!.silent, isNull);
      expect(MeditationSummary.fromJson(j()..['silent'] = {'alpha': 'x'})!.silent, isNull);
      expect(MeditationSummary.fromJson(j()..['silent'] = {...m.silent!.toJson(), 'muscleShare': 2})!.silent, isNull);
      expect(MeditationSummary.fromJson(j()..['bluetoothSound'] = true)!.bluetoothSound, isTrue);
      expect(
        session(2, withBlock: false).toJson(),
        isNot(contains('silent')),
        reason: 'a session without the block writes nothing new',
      );
    });
  });

  group('the learning verdict', () {
    List<MeditationSummary> rising(int n, {double step = 0.01}) => [
      for (var k = 0; k < n; k++) session(k, alpha: step * k),
    ];

    test('before 8 sessions with a silent block: not enough sessions yet, never a verdict', () {
      for (final n in [0, 1, 7]) {
        final v = learningVerdict(rising(n));
        expect(v.verdict, Verdict.notYet);
        expect(v.silent, isNull);
        expect(
          v.lines.first,
          'Not enough sessions yet: $n of 8 with the silent minutes at the end. The first '
          'verdict comes after 8, a second at 12.',
        );
      }
      // sessions stopped before the silent block, or with too little clean signal in it, do not count
      final mixed = [...rising(7), session(20, withBlock: false), session(21, muscle: 0.5)];
      expect(learningVerdict(mixed).have, 7);
      expect(learningVerdict(mixed).verdict, Verdict.notYet);
    });

    test('8 sessions going up: the trend per session with its 90 % range, seen together, not tested', () {
      final v = learningVerdict(rising(8));
      expect(v.verdict, Verdict.up);
      expect((v.from, v.to, v.nextAt), (1, 8, 12));
      expect(v.silent!.slope, closeTo(0.01, 1e-12));
      expect(
        v.lines.first,
        'Going up: alpha in the silent minutes rose about +2.3 % a session over your first 8 '
        'sessions (90 % range +2.3 to +2.3 %).',
      );
      expect(
        v.lines.last,
        'Seen together, not tested: practice itself, sleep, the time of day or how the headband '
        'sits can move this too. Checked again at 12 sessions.',
      );
    });

    test('a rise with muscle or drowsy time rising alongside is not called learning', () {
      final v = learningVerdict([for (var k = 0; k < 8; k++) session(k, alpha: 0.01 * k, muscle: 0.02 * k)]);
      expect(v.verdict, Verdict.upAlongside);
      expect(v.alongside, ['jaw or neck muscle']);
      expect(v.lines.first, contains('but jaw or neck muscle rose with it, so it is not counted as learning'));
      final both = learningVerdict([
        for (var k = 0; k < 8; k++) session(k, alpha: 0.01 * k, muscle: 0.02 * k, drowsy: 0.03 * k),
      ]);
      expect(both.alongside, ['jaw or neck muscle', 'drowsiness']);
      // a share that wobbles without a clear rise does not block the verdict
      final wobble = learningVerdict([
        for (var k = 0; k < 8; k++) session(k, alpha: 0.01 * k, muscle: k.isEven ? 0.0 : 0.04),
      ]);
      expect(wobble.verdict, Verdict.up);
    });

    test('flat and going down say so plainly', () {
      final flat = learningVerdict([for (var k = 0; k < 8; k++) session(k, alpha: k.isEven ? 0.1 : -0.1)]);
      expect(flat.verdict, Verdict.flat);
      expect(flat.silent!.low, lessThanOrEqualTo(0));
      expect(flat.silent!.high, greaterThanOrEqualTo(0));
      expect(flat.lines.first, startsWith('No clear trend: alpha in the silent minutes changed about'));
      expect(flat.lines.first, contains('16-57 % of people'));
      final down = learningVerdict([for (var k = 0; k < 8; k++) session(k, alpha: -0.02 * k)]);
      expect(down.verdict, Verdict.down);
      expect(down.lines.first, startsWith('Going down: alpha in the silent minutes fell about −4.5 % a session'));
    });

    test('checked again at 12, then every 12 on the latest 12 sessions; oldest first whatever the order given', () {
      final at12 = learningVerdict(rising(13).reversed.toList());
      expect((at12.from, at12.to, at12.have, at12.nextAt), (1, 12, 13, 24));
      expect(at12.silent!.n, 12);
      expect(at12.lines.first, contains('over your first 12 sessions'));
      final at24 = learningVerdict([
        for (var k = 0; k < 25; k++) session(k, alpha: k < 12 ? 0.02 * k : 0.24 + (k.isEven ? 0.05 : -0.05)),
      ]);
      expect((at24.from, at24.to, at24.nextAt), (13, 24, 36));
      expect(at24.verdict, Verdict.flat, reason: 'a plateau after the first 12 shows as flat');
      expect(at24.lines.first, contains('over sessions 13-24'));
    });

    test('alpha-theta sessions are not counted; with the sound on is a second, plain line', () {
      final sessions = [
        for (var k = 0; k < 8; k++) session(k, alpha: 0.01 * k, outcome: 0.05 + 0.004 * k),
        session(30, alpha: 0.5, kind: SessionKind.alphaTheta),
      ];
      final v = learningVerdict(sessions);
      expect(v.have, 8);
      expect(v.withSound!.slope, closeTo(0.004, 1e-12));
      expect(v.lines, contains('With the sound on: about +0.9 % a session (90 % range +0.9 to +0.9 %).'));
    });

    test('Bluetooth sessions and replay-check sessions are counted and named', () {
      final v = learningVerdict([
        for (var k = 0; k < 8; k++) session(k, alpha: 0.01 * k, bluetooth: k < 3, inCheck: k >= 4),
      ]);
      expect(
        v.lines,
        contains('3 of these 8 sessions played over Bluetooth, where the sound comes about 0.25-0.5 s late.'),
      );
      expect(v.lines, contains('4 of these 8 sessions were in the replay check, so some had replayed sound.'));
    });

    test('the replay check makes the silent minutes a test: live against replay, with its p', () {
      final v = learningVerdict(rising(8), tested: (diff: 0.05, p: 0.03, sessions: 12, first: 1, last: 12));
      expect(
        v.lines,
        contains(
          'Tested by the replay check (sessions 1-12): alpha in the silent minutes was +12 % after live '
          'sound against replayed sound (p = 0.03).',
        ),
      );
      final none = learningVerdict(rising(8), tested: (diff: 0.004, p: 0.62, sessions: 12, first: 1, last: 12));
      expect(none.lines.where((l) => l.startsWith('Tested')).single, contains('no clear difference'));
      expect(
        learningVerdict(rising(3), tested: (diff: 0.05, p: 0.03, sessions: 12, first: 1, last: 12)).lines,
        contains(startsWith('Tested by the replay check')),
        reason: 'the test stands on its own sessions',
      );
    });
  });
}
