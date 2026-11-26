// The guesses file and the question "Meditating or resting?" (DECISIONS 1105-1106, 1113): every mark of "What
// happened" with the numbers behind it in `files/activity/<recording>.guesses.json`, and one estimate a day for eyes
// closed and still for 3 minutes or more by day, outside anything you marked yourself. Made-up passes in a made-up
// app folder.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/activity/guesses.dart';
import 'package:eeg_tracker/activity/happened.dart';
import 'package:eeg_tracker/archive/seen.dart';
import 'package:eeg_tracker/archive/tags.dart';
import 'package:eeg_tracker/auto/bedtime.dart';
import 'package:eeg_tracker/confirm/questions.dart';
import 'package:eeg_tracker/confirm/sources.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_labels/shared_labels.dart';

const UsualNight usual = UsualNight(bedMin: 23 * 60, wakeMin: 7 * 60);

RecordingSeen pass(DateTime start, int n, List<(int, int)> closed) {
  final eyes = List.filled(n, 'o');
  for (final (a, b) in closed) {
    for (var i = a; i < b; i++) {
      eyes[i] = 'c';
    }
  }
  return RecordingSeen(
    startMs: start.millisecondsSinceEpoch,
    quality: 'g' * n,
    eyes: eyes.join(),
    level: 'a' * n,
    jaw: List.filled(n, 0),
    move: List.filled(n, 0),
    alpha: [for (final e in eyes) e == 'c' ? 2.5 : 1.0],
  );
}

void main() {
  late Directory files;
  setUp(() => files = Directory.systemTemp.createTempSync('guesses'));
  tearDown(() => files.deleteSync(recursive: true));

  final day = DateTime(2026, 11, 26, 13, 0);
  DateTime at(DateTime t0, int epoch) => t0.add(Duration(seconds: 30 * epoch));

  void keep(String id, DateTime t0, RecordingSeen seen, {DateTime? made}) {
    final marks = happenedMarks(seen: seen, from: t0, to: seen.epochStart(seen.epochs));
    writeGuesses(files, id, marks, seen: seen, usual: usual, key: 'k', made: made ?? day.add(const Duration(hours: 2)));
  }

  test('the file: every mark with its times, how sure, and the numbers behind it', () {
    keep('2026-11-26-130000', day, pass(day, 40, [(4, 12)]));
    final f = guessesFileFor(files, '2026-11-26-130000');
    final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    expect((j['version'], j['recording'], j['key']), (1, '2026-11-26-130000', 'k'));
    final m = (j['marks']! as List).single as Map<String, Object?>;
    expect((m['what'], m['sure']), ('eyes_closed_resting', 'strong'));
    expect((m['start'], m['end']), ('2026-11-26T13:02:00+03:00', '2026-11-26T13:06:00+03:00'));
    expect((m['eyes_closed_share'], m['good_signal_share'], m['back_alpha']), (1, 1, 2.5));
    expect((m['jaw_bursts_per_min'], m['movement_s_per_min']), (0, 0));
    expect((m['minutes_from_bedtime'], m['in_bedtime_window']), (-598, false), reason: '13:02 is 9 h 58 before 23:00');
    expect(guessesKeyOf(f), 'k');
    final back = readGuesses(f)!;
    expect((back.recording, back.marks.single.what, back.marks.single.length), ('2026-11-26-130000', What.resting, const Duration(minutes: 4)));
    expect(back.numbers.single['eyes_closed_share'], 1);
    expect(files.listSync(recursive: true).whereType<File>().where((x) => x.path.endsWith('.tmp')), isEmpty);
  });

  group('"Meditating or resting?"', () {
    List<Estimate> found({DateTime? now}) => restEstimates(files, usual: usual, now: now ?? day.add(const Duration(hours: 3)));

    test('eyes closed and still for 3 minutes or more by day: one estimate, the detector\'s own label', () {
      keep('2026-11-26-130000', day, pass(day, 40, [(4, 12)]));
      final e = found().single;
      expect((e.detector, e.label, e.recording), (restDetector, Labels.eyesClosed, '2026-11-26-130000'));
      expect((e.start, e.end), (at(day, 4), at(day, 12)));
      expect(e.confidence, 1);
      expect(isChoice(e), isTrue);
    });

    test('at most one a day (04:00 to 04:00): the longest, over every recording of that day', () {
      keep('2026-11-26-130000', day, pass(day, 80, [(4, 12), (30, 50)]));
      final evening = DateTime(2026, 11, 26, 18, 0);
      keep('2026-11-26-180000', evening, pass(evening, 40, [(0, 14)]));
      final next = DateTime(2026, 11, 27, 10, 0);
      keep('2026-11-27-100000', next, pass(next, 40, [(0, 8)]));
      final got = found(now: next.add(const Duration(hours: 1)));
      expect([for (final e in got) (e.start, e.length.inMinutes)], [(at(day, 30), 10), (next, 4)]);
    });

    test('a question already asked that day stands: a longer stretch found later adds no second one', () {
      keep('2026-11-26-130000', day, pass(day, 40, [(4, 12)]));
      final q = ConfirmQuestions(files, clock: () => day.add(const Duration(hours: 1)));
      expect(q.gather(collect: (d) => restEstimates(d, usual: usual, now: day.add(const Duration(hours: 1)))), 1);
      final evening = DateTime(2026, 11, 26, 18, 0);
      keep('2026-11-26-180000', evening, pass(evening, 40, [(0, 30)]));
      expect(q.gather(collect: (d) => restEstimates(d, usual: usual, now: evening.add(const Duration(hours: 1)))), 0);
      expect(q.store.read().estimates.values.single.start, at(day, 4));
    });

    test('not in your usual night', () {
      final night = DateTime(2026, 11, 26, 23, 30);
      keep('2026-11-26-233000', night, pass(night, 40, [(4, 20)]), made: night.add(const Duration(hours: 1)));
      final early = DateTime(2026, 11, 26, 6, 0);
      keep('2026-11-26-060000', early, pass(early, 40, [(4, 20)]));
      expect(found(now: night.add(const Duration(hours: 2))), isEmpty);
    });

    test('not inside what you marked yourself (meditation, a sound, sleep, a nap, a check-in), nor where you tagged', () {
      keep('2026-11-26-130000', day, pass(day, 120, [(4, 12), (30, 40), (60, 70), (90, 100)]));
      final spans = Directory('${files.path}/spans')..createSync();
      Span span(int n, String kind, int a, int b) =>
          Span(id: '2026-11-26-130000-$n', kind: kind, start: at(day, a), end: at(day, b), source: 'owner_button');
      spansFileOf(spans, '2026-11-26-130000').writeAsStringSync(
        [
          for (final s in [span(1, 'meditate', 0, 14), span(2, 'sleep', 35, 45), span(3, 'work', 55, 75)])
            jsonEncode(s.toLine(day)),
        ].join('\n'),
      );
      TagStore(files).saveTags('2026-11-26-130000', [ManualTag(start: at(day, 88), end: at(day, 102), label: 'rest')]);
      // left: the stretch inside the work session (work is not an answer to "meditating or resting?")
      expect([for (final e in found()) e.start], [at(day, 60)]);
    });

    test('the question: a choice card on the card and in the notification, never drawn blind', () async {
      keep('2026-11-26-130000', day, pass(day, 40, [(4, 12)]));
      final now = day.add(const Duration(minutes: 40));
      final q = ConfirmQuestions(files, clock: () => now);
      q.gather(collect: (d) => restEstimates(d, usual: usual, now: now));
      final card = q.pending().single;
      expect(card.kind, CardKind.choice);
      expect(card.text, '13:02-13:06. Your eyes were closed and you were still. Meditating or resting?');
      expect(card.chips, [Labels.meditating, Labels.resting]);
      q.answer(card.id, Answer.said, card: card.kind, said: Labels.resting);
      expect(q.pending(), isEmpty);
      final label = File('${files.path}/confirm/labels.tsv').readAsLinesSync().last.split('\t');
      expect(label, containsAll(['resting', 'owner_app_prompt', '1']));
    });
  });

  test('collectEstimates takes them in', () {
    final t0 = DateTime.now().subtract(const Duration(hours: 2));
    final noon = DateTime(t0.year, t0.month, t0.day, 13);
    keep('x', noon, pass(noon, 40, [(4, 12)]), made: noon.add(const Duration(hours: 1)));
    final got = collectEstimates(files, now: noon.add(const Duration(hours: 2)));
    expect([for (final e in got) e.detector], [restDetector]);
  });
}
