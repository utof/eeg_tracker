// "What happened" (DECISIONS 1101-1104): one best guess per 30 seconds of a finished recording, each with how sure it
// is, from the kept detectors' pass, the sleep report's stages and the walking pass. Made-up passes; no signal files.
import 'package:eeg_tracker/activity/happened.dart';
import 'package:eeg_tracker/archive/seen.dart';
import 'package:eeg_tracker/walking/detector.dart' show StretchKind;
import 'package:eeg_tracker/walking/pass.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime t0 = DateTime(2026, 11, 26, 13, 0);

/// A pass of [n] quiet, eyes-open, alert epochs from [t0], changed by [edit].
RecordingSeen pass(int n, [void Function(List<String> q, List<String> eyes, List<String> level, List<int> jaw, List<int> move)? edit]) {
  final q = List.filled(n, 'g'), eyes = List.filled(n, 'o'), level = List.filled(n, 'a');
  final jaw = List.filled(n, 0), move = List.filled(n, 0);
  edit?.call(q, eyes, level, jaw, move);
  return RecordingSeen(startMs: t0.millisecondsSinceEpoch, quality: q.join(), eyes: eyes.join(), level: level.join(), jaw: jaw, move: move);
}

DateTime at(int epoch) => t0.add(Duration(seconds: 30 * epoch));

List<String> words(List<Mark> marks) => [
  for (final m in marks) '${m.what.word} ${m.start.difference(t0).inSeconds ~/ 30}-${m.end.difference(t0).inSeconds ~/ 30} ${m.sure.word}',
];

void main() {
  test('a quiet recording with open eyes: nothing is marked', () {
    expect(happenedMarks(seen: pass(40), from: t0, to: at(40)), isEmpty);
  });

  test('eyes closed and still for 3 minutes or more is "Eyes closed, resting", strong; a shorter stretch is not', () {
    final seen = pass(60, (q, eyes, level, jaw, move) {
      for (var i = 4; i < 12; i++) {
        eyes[i] = 'c'; // 4 minutes
      }
      for (var i = 20; i < 25; i++) {
        eyes[i] = 'c'; // 2.5 minutes: too short
      }
    });
    expect(words(happenedMarks(seen: seen, from: t0, to: at(60))), ['Eyes closed, resting 4-12 strong']);
  });

  test('one odd epoch inside is bridged; movement or jaw muscle in an epoch is not resting', () {
    final seen = pass(40, (q, eyes, level, jaw, move) {
      for (var i = 2; i < 12; i++) {
        eyes[i] = 'c';
      }
      eyes[6] = 'o'; // one odd epoch: bridged
      for (var i = 20; i < 32; i++) {
        eyes[i] = 'c';
      }
      move[24] = 1; // a movement second: bridged as the one odd epoch
      jaw[28] = 2;
      jaw[29] = 2; // talking: two epochs break the rest in two
    });
    expect(words(happenedMarks(seen: seen, from: t0, to: at(40))), [
      'Eyes closed, resting 2-12 strong',
      'Eyes closed, resting 20-28 strong',
      'Talking or chewing 28-30 weak',
    ]);
  });

  test('one state per moment, the first that applies: no signal, asleep, walking, moving, talking, resting, drowsy', () {
    final seen = pass(80, (q, eyes, level, jaw, move) {
      q[0] = 'm'; // no signal wins over everything
      eyes[0] = 'c';
      for (var i = 10; i < 20; i++) {
        eyes[i] = 'c'; // asleep by the report: not "resting"
        jaw[i] = 3; // and not talking
      }
      for (var i = 30; i < 34; i++) {
        move[i] = 5; // moving, inside a walk: walking wins
      }
      for (var i = 40; i < 44; i++) {
        move[i] = 4;
        jaw[i] = 3; // moving wins over talking
      }
      for (var i = 50; i < 54; i++) {
        jaw[i] = 2;
        level[i] = 'd'; // talking wins over drowsy
      }
      for (var i = 60; i < 66; i++) {
        level[i] = i < 64 ? 'd' : 'g';
      }
    });
    final stages = (start: at(10), stages: '2222233RRR');
    final walk = WalkResult(
      recording: 'r',
      start: t0,
      channels: const ['O1'],
      sampleRate: 250,
      windows: 0,
      walkingMin: 4,
      headbandSteps: 400,
      minutes: const [],
      walks: [
        WalkSummary(
          start: at(28),
          end: at(36),
          walkingMin: 4,
          stoppedMin: 0,
          steps: 400,
          pace: 104,
          stretches: [
            WalkStretch(kind: StretchKind.walking, start: at(28), end: at(34), steps: 300, pace: 104, confidence: 'sure'),
            WalkStretch(kind: StretchKind.running, start: at(34), end: at(36), steps: 100, pace: 160, confidence: 'unsure'),
          ],
        ),
      ],
    );
    expect(words(happenedMarks(seen: seen, stages: stages, walk: walk, from: t0, to: at(80))), [
      'No signal 0-1 near certain',
      'Nap 10-20 good',
      'Walking 28-34 good',
      'Running 34-36 some',
      'Moving 40-44 good',
      'Talking or chewing 50-54 weak',
      'Drowsy 60-66 some',
    ]);
  });

  test('a long sleep, or one at night, is "Asleep"; awake inside it is not marked asleep', () {
    final night = DateTime(2026, 11, 26, 0, 30);
    final stages = (start: night, stages: '${'2' * 20}WWWW${'3' * 20}');
    final marks = happenedMarks(stages: stages, from: night, to: night.add(const Duration(minutes: 22)));
    expect([for (final m in marks) m.what], [What.asleep, What.asleep]);
    expect(marks.first.end, night.add(const Duration(minutes: 10)));
    expect(marks.last.start, night.add(const Duration(minutes: 12)));
    expect(marks.first.sure, Sure.good);
  });

  test('no pass (another electrode layout, or the raw signal left the phone): asleep and walking are still marked', () {
    final walk = WalkResult(
      recording: 'r',
      start: t0,
      channels: const ['Fp1'],
      sampleRate: 250,
      windows: 0,
      walkingMin: 3,
      headbandSteps: 300,
      minutes: const [],
      walks: [
        WalkSummary(
          start: at(4),
          end: at(10),
          walkingMin: 3,
          stoppedMin: 0,
          steps: 300,
          pace: 100,
          stretches: [WalkStretch(kind: StretchKind.walking, start: at(4), end: at(10), steps: 300, pace: 100, confidence: 'likely')],
        ),
      ],
    );
    expect(words(happenedMarks(walk: walk, from: t0, to: at(20))), ['Walking 4-10 good']);
  });

  test('marks never overlap, stay inside the recording and each says where it comes from', () {
    final seen = pass(30, (q, eyes, level, jaw, move) {
      for (var i = 0; i < 30; i++) {
        eyes[i] = 'c';
      }
      move[10] = 3;
      move[12] = 3; // epoch 11 between them is one still epoch: too short to be a rest, and another state is not bridged
    });
    final marks = happenedMarks(seen: seen, from: t0, to: at(28));
    for (var i = 1; i < marks.length; i++) {
      expect(marks[i].start.isBefore(marks[i - 1].end), isFalse);
    }
    expect(marks.last.end, at(28));
    expect(marks.every((m) => m.source.isNotEmpty), isTrue);
    expect(words(marks), [
      'Eyes closed, resting 0-10 strong',
      'Moving 10-11 good',
      'Moving 12-13 good',
      'Eyes closed, resting 13-28 strong',
    ]);
  });

  test('the numbers behind a mark, from the pass', () {
    final seen = pass(20, (q, eyes, level, jaw, move) {
      for (var i = 2; i < 10; i++) {
        eyes[i] = 'c';
      }
      eyes[5] = 'o';
      q[6] = 'd';
      move[7] = 2;
    });
    final m = happenedMarks(seen: seen, from: t0, to: at(20)).single;
    final n = markNumbers(m, seen);
    expect(n['eyes_closed_share'], closeTo(7 / 8, 1e-9));
    expect(n['good_signal_share'], closeTo(7 / 8, 1e-9));
    expect(n['movement_s_per_min'], closeTo(2 / 4, 1e-9));
    expect(n['jaw_bursts_per_min'], 0);
    expect(n['back_alpha'], isNull, reason: 'this pass kept no alpha');
  });
}
