// The work session's drowsiness level (DECISIONS 440-442): a baseline from the first scored minutes, each 30 s epoch's
// eyes-open alpha, theta and slow eye movement against it, the median of the last 5 minutes, and the level in words.
import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/work/drowsiness.dart';
import 'package:flutter_test/flutter_test.dart';

/// [n] seconds of the same input.
void feed(WorkDrowsiness d, int n, {double alpha = 10, double theta = 6, double sem = 20, int blinkEvery = 0, int moveEvery = 0, bool muscle = false, bool movement = false, bool backClean = true}) {
  for (var i = 0; i < n; i++) {
    d.second(WorkInput(
      alpha: alpha,
      theta: theta,
      sem: sem,
      backClean: backClean,
      sideClean: true,
      blinks: blinkEvery > 0 && (i % ep) % blinkEvery == 0 ? 1 : 0,
      eyeMoves: moveEvery > 0 && (i % ep) % moveEvery == 0 ? 1 : 0,
      muscle: muscle,
      movement: movement,
    ));
  }
}

const int ep = 30;

void main() {
  // 2 epochs of settling, then 6 for the baseline: calibrated after 8 epochs (4 minutes)
  const cal = WorkRule.settleEpochs + WorkRule.baselineEpochs;

  test('nothing before the baseline; after a minute of settling, the median of the next 3 scored minutes', () {
    final d = WorkDrowsiness();
    feed(d, 2 * ep, alpha: 40, theta: 30, sem: 90, blinkEvery: 3, moveEvery: 3); // settling in: left out
    feed(d, 5 * ep, alpha: 10, theta: 6, sem: 20, blinkEvery: 10, moveEvery: 7);
    expect(d.calibrated, isFalse);
    expect(d.level, DrowsyLevel.unknown);
    expect(d.baselineLeft, 1);
    feed(d, ep, alpha: 10, theta: 6, sem: 20, blinkEvery: 10, moveEvery: 7);
    expect(d.calibrated, isTrue);
    expect(d.baseline!.alpha, closeTo(10, 1e-9));
    expect(d.baseline!.events, closeTo(8, 1e-9), reason: '3 blinks and 5 eye movements a half minute');
    expect(d.baseline!.theta, closeTo(6, 1e-9));
    expect(d.baseline!.sem, closeTo(20, 1e-9));
    expect(d.calibratedAtS, cal * ep);
  });

  test('steady at the baseline reads alert once 6 of the last 10 epochs are scored', () {
    final d = WorkDrowsiness();
    feed(d, cal * ep, blinkEvery: 10, moveEvery: 7);
    feed(d, 5 * ep, blinkEvery: 10, moveEvery: 7);
    expect(d.level, DrowsyLevel.unknown, reason: 'only 5 scored epochs after the baseline');
    feed(d, ep, blinkEvery: 10, moveEvery: 7);
    expect(d.window, closeTo(0, 1e-9));
    expect(d.level, DrowsyLevel.alert);
  });

  test('alpha doubled and still eyes for 5 minutes read drowsy; one odd minute does not', () {
    final d = WorkDrowsiness();
    feed(d, (cal + 6) * ep, blinkEvery: 10, moveEvery: 7);
    expect(d.level, DrowsyLevel.alert);
    // alpha x2 (a = 1) and one eye event in 30 s instead of 8 (still = log2(9/2) = 2.17): index 1.58
    feed(d, 2 * ep, alpha: 20, blinkEvery: 30);
    expect(d.epochs.last.a, closeTo(1, 1e-9));
    expect(d.epochs.last.still, closeTo(2.1699250014423126, 1e-9));
    expect(d.epochs.last.index, closeTo(1.5849625007211563, 1e-9));
    expect(d.level, DrowsyLevel.alert, reason: 'a median of 10 epochs: two high ones change nothing');
    feed(d, 4 * ep, alpha: 20, blinkEvery: 30);
    expect(d.level, DrowsyLevel.drowsy);
  });

  test('alpha up alone counts half; still eyes with alpha down never raise the level (focus, not drowsiness)', () {
    final d = WorkDrowsiness();
    feed(d, (cal + 6) * ep, blinkEvery: 10, moveEvery: 7);
    feed(d, 10 * ep, alpha: 10, blinkEvery: 30); // still eyes, alpha unchanged: (0 + 2.17) / 2, but a < 0? no: a = 0
    expect(d.epochs.last.index, closeTo(1.0849625007211563, 1e-9));
    feed(d, 10 * ep, alpha: 7, blinkEvery: 30); // alpha down: capped
    expect(d.epochs.last.index, WorkRule.stillAloneCap);
    expect(d.level, DrowsyLevel.alert);
    feed(d, 10 * ep, alpha: 20, blinkEvery: 10, moveEvery: 7); // alpha x2, eyes as usual: index 0.5
    expect(d.epochs.last.index, closeTo(0.5, 1e-9));
    expect(d.level, DrowsyLevel.gettingDrowsy);
  });

  test('getting drowsy comes down only 0.1 under the line', () {
    final d = WorkDrowsiness();
    feed(d, (cal + 6) * ep, blinkEvery: 10, moveEvery: 7);
    feed(d, 10 * ep, alpha: 10 * 1.5157165665103982, blinkEvery: 10, moveEvery: 7); // a = 0.6, still 0: 0.3? no:
    expect(d.epochs.last.index, closeTo(0.3, 1e-9));
    expect(d.level, DrowsyLevel.alert);
    feed(d, 10 * ep, alpha: 10 * 2.2973967099940698, blinkEvery: 10, moveEvery: 7); // a = 1.2: index 0.6
    expect(d.window, closeTo(0.6, 1e-9));
    expect(d.level, DrowsyLevel.gettingDrowsy);
    feed(d, 10 * ep, alpha: 10 * 1.8660659830736148, blinkEvery: 10, moveEvery: 7); // a = 0.9: index 0.45
    expect(d.level, DrowsyLevel.gettingDrowsy, reason: 'within the hysteresis');
    feed(d, 10 * ep, blinkEvery: 10, moveEvery: 7);
    expect(d.level, DrowsyLevel.alert);
  });

  test('muscle, movement and blink seconds are left out of alpha; an epoch with under 10 clean seconds is not scored', () {
    final d = WorkDrowsiness();
    feed(d, (cal + 6) * ep, blinkEvery: 10, moveEvery: 7);
    // high alpha only while chewing: left out, the epoch reads the clean seconds
    for (var i = 0; i < ep; i++) {
      final chew = i < 15;
      d.second(WorkInput(alpha: chew ? 80 : 10, theta: 6, sem: 20, backClean: true, sideClean: true, muscle: chew, blinks: i % 10 == 0 ? 1 : 0, eyeMoves: i % 7 == 0 ? 1 : 0));
    }
    expect(d.epochs.last.a, closeTo(0, 1e-9));
    expect(d.epochs.last.muscleS, 15);
    // 25 seconds of movement: under 10 clean seconds, and too few seconds to count eye events
    for (var i = 0; i < ep; i++) {
      d.second(WorkInput(alpha: 50, theta: 30, sem: 90, backClean: true, sideClean: true, movement: i < 25));
    }
    expect(d.epochs.last.index, isNull);
    expect(d.epochs.last.cleanS, 5);
    expect(d.epochs.last.events, isNull);
  });

  test('eye events count per 30 seconds without holes or movement', () {
    final d = WorkDrowsiness();
    for (var i = 0; i < ep; i++) {
      d.second(WorkInput(alpha: 10, theta: 6, sem: 20, backClean: true, sideClean: true, gap: i < 10, blinks: i >= 10 && i % 5 == 0 ? 1 : 0));
    }
    expect(d.epochs.last.events, closeTo(4 * 30 / 20, 1e-9));
  });

  test('a mostly noisy 5 minutes reads not sure instead of a level', () {
    final d = WorkDrowsiness();
    feed(d, (cal + 6) * ep, blinkEvery: 10, moveEvery: 7);
    feed(d, 5 * ep, backClean: false, blinkEvery: 10, moveEvery: 7);
    expect(d.level, DrowsyLevel.unknown);
    expect(d.noisy, isTrue);
  });

  test('eyes closed (alpha far up, no blinks, at most one eye movement) is not drowsiness; 2 minutes of it says so', () {
    final d = WorkDrowsiness();
    feed(d, (cal + 6) * ep, blinkEvery: 10, moveEvery: 7);
    feed(d, 4 * ep, alpha: 60, theta: 8, sem: 10);
    expect(d.epochs.last.eyesClosed, isTrue);
    expect(d.epochs.last.index, isNull);
    expect(d.eyesClosed, isTrue);
    expect(d.level, DrowsyLevel.alert, reason: 'the open-eyed epochs before still decide');
    // the same alpha with blinks is open eyes with a lot of alpha: scored
    feed(d, ep, alpha: 60, theta: 8, sem: 10, blinkEvery: 10, moveEvery: 7);
    expect(d.epochs.last.eyesClosed, isFalse);
    expect(d.epochs.last.index, isNotNull);
  });

  test('with the eyes-closed minute, half its alpha marks closed eyes, also during the baseline', () {
    final d = WorkDrowsiness(closedAlpha: 40);
    feed(d, 3 * ep, alpha: 25, theta: 6, sem: 20);
    expect(d.epochs.last.eyesClosed, isTrue);
    feed(d, 6 * ep, blinkEvery: 10, moveEvery: 7);
    expect(d.calibrated, isTrue);
    expect(d.baseline!.alpha, closeTo(10, 1e-9), reason: 'the closed-eyes epoch stayed out of the baseline');
  });

  test('after the baseline, the eyes-closed line is the geometric middle of open and closed alpha, at least 2x', () {
    // the owner's check-in: eyes closed gave 2.5x the eyes-open alpha; 3x alone would never see his closed eyes
    final d = WorkDrowsiness(closedAlpha: 25);
    feed(d, cal * ep, blinkEvery: 10, moveEvery: 7);
    feed(d, ep, alpha: 22, theta: 6, sem: 20);
    expect(d.epochs.last.eyesClosed, isTrue, reason: 'line max(2 x 10, sqrt(10 x 25)) = 20');
    final plain = WorkDrowsiness();
    feed(plain, cal * ep, blinkEvery: 10, moveEvery: 7);
    feed(plain, ep, alpha: 22, theta: 6, sem: 20);
    expect(plain.epochs.last.eyesClosed, isFalse, reason: 'without the minute the line is 3x');
    final strong = WorkDrowsiness(closedAlpha: 160);
    feed(strong, cal * ep, blinkEvery: 10, moveEvery: 7);
    feed(strong, ep, alpha: 35, theta: 6, sem: 20);
    expect(strong.epochs.last.eyesClosed, isFalse, reason: 'sqrt(10 x 160) = 40');
  });

  test('the input of one detector second: back alpha and theta of the usable channels, T3-T4 slow power', () {
    final s = Second(3)
      ..alpha[0] = 10
      ..alpha[1] = 30
      ..theta[0] = 4
      ..theta[1] = 8
      ..sem = 12
      ..blinks = 1;
    var x = workInputOf(s, eyeMoves: 2);
    expect(x.alpha, 20);
    expect(x.theta, 6);
    expect(x.sem, 12);
    expect(x.backClean, isTrue);
    expect(x.sideClean, isTrue);
    expect(x.blinks, 1);
    expect(x.eyeMoves, 2);
    s.flat[1] = true;
    s.railed[3] = true;
    x = workInputOf(s);
    expect(x.alpha, 10);
    expect(x.theta, 4);
    expect(x.sideClean, isFalse);
  });

  test('each epoch goes out as JSON with the numbers a later re-analysis needs; the baseline reads back', () {
    final d = WorkDrowsiness();
    feed(d, (cal + 6) * ep, blinkEvery: 10, moveEvery: 7);
    final j = d.epochs.last.toJson();
    expect(j.keys, containsAll(['s', 'clean_s', 'alpha', 'theta', 'sem', 'events', 'blinks', 'eye_moves', 'muscle_s', 'movement_s', 'eyes_closed', 'a', 'still', 'index', 'window', 'level']));
    expect(j['level'], 'alert');
    expect(j['blinks'], 3);
    final b = WorkBaseline.fromJson(d.baseline!.toJson())!;
    expect(b.alpha, d.baseline!.alpha);
    expect(b.events, d.baseline!.events);
    expect(levelOf('getting_drowsy'), DrowsyLevel.gettingDrowsy);
  });
}
