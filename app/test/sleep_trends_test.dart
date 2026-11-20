// The sleep numbers on Trends (DECISIONS rows 650-659): stage minutes, wake-ups, time to fall asleep, sleep
// efficiency and sleep regularity from the phone's sleep reports, and the morning "How did you sleep?" tap. Made-up
// reports only: nights with and without Lights off, someone else's night, a noisy night, an older report.
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/experiments/experiment.dart' show outcomeById;
import 'package:eeg_tracker/morning/controller.dart' show MorningAnswers;
import 'package:eeg_tracker/morning/result.dart' show MorningMarker;
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/trends/usual.dart';
import 'package:eeg_tracker/ui/trends_screen.dart' show readTrendInputs;
import 'package:eeg_tracker/ui/trends_view.dart' show arrowWords, missingMeasures;
import 'package:flutter_test/flutter_test.dart';

/// A scored night: one period from [onset] to [wake] with the minutes of each stage; [lightsOff] and [source] give
/// its `drift_off`; [noisy] is the share of the time asleep read through noise; [answer] the "Was this you?" answer.
Map<String, Object?> night(
  DateTime onset,
  DateTime wake, {
  double light = 240,
  double deep = 80,
  double dream = 100,
  int wakeUps = 1,
  DateTime? start,
  DateTime? lightsOff,
  String source = 'button',
  double? fell = 12,
  double noisy = 0,
  String? answer,
  bool extras = true,
}) {
  final asleep = light + deep + dream;
  final first = start ?? onset.subtract(const Duration(minutes: 20));
  return {
    'night_of': dayKey(onset.subtract(const Duration(hours: 8))),
    'scored': true,
    'data_start': isoLocal(first),
    'data_end': isoLocal(wake.add(const Duration(minutes: 5))),
    'total': {'asleep_min': asleep, 'recorded_min': asleep + 40, 'missing_min': 0, 'stray_sleep_min': 0},
    'periods': [
      {
        'start': isoLocal(onset),
        'end': isoLocal(wake),
        'asleep_min': asleep,
        'light_min': light,
        'deep_min': deep,
        'dream_min': dream,
        'awake_min': 20,
        'wake_ups': wakeUps,
        'missing_min': 0,
      },
    ],
    if (lightsOff != null || source == 'night start')
      'drift_off': {
        'version': 1,
        'lights_off': isoLocal(lightsOff ?? first),
        'source': source,
        'onset': null,
        'model_onset': null,
        'onset_min': null,
        'model_onset_min': fell,
        'diff_min': null,
        'agree': null,
        'counted': source != 'night start',
      },
    if (extras)
      'extras': {
        'version': 2,
        'quality': '',
        'night': _tally(asleep, noisy),
        'asleep': {..._tally(asleep, noisy), 'jaw_per_hour': 5.0, 'moves_per_hour': 0.0},
        'hours': const <Object?>[],
      },
    if (answer != null) 'wearer': {'answer': answer, 'at': isoLocal(wake)},
  };
}

Map<String, Object?> _tally(double min, double noisy) => {
  'min': min,
  'good_min': min * (1 - noisy),
  'degraded_min': min * noisy / 2,
  'missing_min': min * noisy / 2,
  'jaw_bursts': 0,
  'one_sided_bursts': 0,
  'movement_bursts': 0,
  'moves': 0,
};

TrendInputs inputs(List<Map<String, Object?>> nights, {List<MorningRecord> mornings = const []}) =>
    (nights: [for (final n in nights) SleepReport(n)], mornings: mornings, sessions: const []);

final now = DateTime(2026, 11, 18, 15);

TrendRow rowOf(TrendsModel m, String id) => m.rows.singleWhere((r) => r.spec.id == id);

TrendRow row(List<Map<String, Object?>> nights, String id) => rowOf(buildTrends(inputs(nights), now), id);

/// An ordinary night ending on the morning of [day] (November 2026) at [wakeMin] minutes after 07:00, fell asleep
/// [onsetMin] minutes after 23:00 the evening before.
Map<String, Object?> nightOn(int day, {int onsetMin = 0, int wakeMin = 0, double deep = 80}) => night(
  DateTime(2026, 11, day - 1, 23).add(Duration(minutes: onsetMin)),
  DateTime(2026, 11, day, 7).add(Duration(minutes: wakeMin)),
  deep: deep,
);

MorningRecord checkIn(DateTime start, {Map<String, Object?>? ratings}) => MorningRecord.fromJson({
  'version': 'morning-v1',
  'start': isoLocal(start),
  'back': {'alpha_ec_uv2': 31.3, 'ec_rise': 2.56, 'iaf_hz': 9.6, 'clean_share': 0.97},
  'ratings': ratings ?? {'kss': 4, 'mood': 4, 'tension': 2},
})!;

void main() {
  group('stage minutes, wake-ups and falling asleep', () {
    test('light, deep and dream minutes and wake-ups of the night before, as numbers of their own', () {
      final n = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), light: 250, deep: 70, dream: 95, wakeUps: 2);
      final m = buildTrends(inputs([n]), now);
      expect(rowOf(m, 'light').value, 250);
      expect(rowOf(m, 'deep').value, 70);
      expect(rowOf(m, 'dream').value, 95);
      expect(rowOf(m, 'wakeups').value, 2);
      expect(rowOf(m, 'deep').spec.format(70), '1 h 10 min');
      expect(rowOf(m, 'wakeups').spec.format(2), '2 wake-ups');
      expect(rowOf(m, 'wakeups').spec.format(1), '1 wake-up');
      expect(rowOf(m, 'deep').day, '2026-11-18');
      for (final id in ['light', 'deep', 'dream', 'wakeups', 'efficiency', 'regularity']) {
        expect(rowOf(m, id).spec.group, TrendGroup.sleep, reason: id);
      }
    });

    test('two sleeps that end the same day are added up; the first Lights off gives the falling-asleep time', () {
      final a = night(DateTime(2026, 11, 18, 0, 30), DateTime(2026, 11, 18, 4, 30), light: 60, deep: 30, dream: 20, wakeUps: 1,
          lightsOff: DateTime(2026, 11, 18, 0, 10), fell: 14);
      final b = night(DateTime(2026, 11, 18, 5), DateTime(2026, 11, 18, 9), light: 150, deep: 60, dream: 60, wakeUps: 2,
          lightsOff: DateTime(2026, 11, 18, 4, 50), fell: 30);
      final m = buildTrends(inputs([b, a]), now);
      expect(rowOf(m, 'light').value, 210);
      expect(rowOf(m, 'deep').value, 90);
      expect(rowOf(m, 'dream').value, 80);
      expect(rowOf(m, 'wakeups').value, 3);
      expect(rowOf(m, 'fall_asleep').value, 14);
    });

    test('falling asleep needs a Lights off: a night counted from its start has none', () {
      final tapped = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), lightsOff: DateTime(2026, 11, 17, 22, 45), fell: 17);
      final none = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), source: 'night start', fell: 5);
      final older = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7)); // no drift_off at all
      expect(row([tapped], 'fall_asleep').value, 17);
      expect(row([none], 'fall_asleep').hasData, isFalse);
      expect(row([older], 'fall_asleep').hasData, isFalse);
      // the model found no sleep after Lights off
      expect(row([night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), lightsOff: DateTime(2026, 11, 17, 22, 45), fell: null)], 'fall_asleep').hasData,
          isFalse);
    });

    test('someone else\'s night and a night mostly read through noise are left out of these rows (not of "Asleep")', () {
      final other = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), answer: 'someone else');
      final noisy = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), noisy: 0.6);
      final fine = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), noisy: 0.5);
      for (final id in ['light', 'deep', 'dream', 'wakeups', 'efficiency']) {
        expect(row([other], id).hasData, isFalse, reason: 'someone else, $id');
        expect(row([noisy], id).hasData, isFalse, reason: 'noisy, $id');
        expect(row([fine], id).hasData, isTrue, reason: 'half noisy is the limit, $id');
      }
      expect(row([noisy], 'asleep').value, 420); // the length is the report's own number, as before
      // the noisy night does not add into a good night's day
      final good = night(DateTime(2026, 11, 18, 3), DateTime(2026, 11, 18, 9), light: 100, deep: 50, dream: 50);
      expect(row([noisy, good], 'deep').value, 50);
    });

    test('a night with no sleep period or an older report without extras', () {
      final empty = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7))..['periods'] = <Object?>[];
      expect(row([empty], 'deep').hasData, isFalse);
      final older = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), extras: false);
      expect(row([older], 'deep').value, 80); // its noise cannot be told: it counts, as in the export
    });

    test('arrows: deep and dream minutes, wake-ups and falling asleep may get one; light sleep never', () {
      final scales = {for (final s in measureSpecs) s.id: s.scale};
      expect(scales['light'], Scale.noArrows);
      expect(scales['deep']!.arrows, isTrue);
      expect(scales['dream']!.arrows, isTrue);
      expect(scales['wakeups']!.arrows, isTrue);
      expect(scales['fall_asleep']!.arrows, isTrue);
      expect(scales['efficiency']!.arrows, isTrue);
      expect(scales['regularity']!.arrows, isTrue);
      // 20 nights of deep sleep near 80 min: 40 min less is beyond the spread and the 15 minutes that matter
      final days = {for (var k = 0; k < 20; k++) addDays('2026-11-17', k - 20): 80.0 + (k.isEven ? 4 : -4)};
      final u = usualOf(days, '2026-11-17', scales['deep']!);
      expect(u.arrow(40), Arrow.down);
      expect(u.arrow(70), Arrow.none);
      final r = TrendRow(spec: measureSpecs.singleWhere((s) => s.id == 'deep'), usual: u, line: const [], day: '2026-11-17', value: 40, arrow: Arrow.down);
      expect(arrowWords(r), startsWith('Less than usual'));
    });

    test('the rows say where they come from, and the sleep model rows that it is not checked against a lab test', () {
      for (final id in ['light', 'deep', 'dream', 'wakeups', 'fall_asleep', 'efficiency', 'regularity']) {
        final note = measureSpecs.singleWhere((s) => s.id == id).note!;
        expect(note, contains('not yet checked against a lab test on this headband'), reason: id);
        expect(note, endsWith('Seen together, not tested.'), reason: id);
      }
      final eff = measureSpecs.singleWhere((s) => s.id == 'efficiency').note!;
      expect(eff, contains('Lights off'));
      expect(eff, contains('recording started'));
      expect(measureSpecs.where((s) => s.label.toLowerCase().contains('score')), isEmpty); // no single sleep score
    });

    test('"Nothing yet for" does not name the number that needs a Lights off tap', () {
      final m = buildTrends(inputs([night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7))]), now);
      expect(missingMeasures(m), isNot(contains('falling asleep')));
    });
  });

  group('sleep efficiency', () {
    test('asleep over the time from Lights off to the last wake-up', () {
      // Lights off 22:30, asleep 400 min (6 h 40), last wake-up 07:00 -> 510 min in bed
      final n = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7),
          light: 240, deep: 70, dream: 90, start: DateTime(2026, 11, 17, 22, 30), lightsOff: DateTime(2026, 11, 17, 22, 30));
      expect(row([n], 'efficiency').value, closeTo(400 / 510 * 100, 1e-9));
      expect(row([n], 'efficiency').spec.format(78.4), '78 %');
    });

    test('with no Lights off it counts from when the recording started', () {
      // recording from 22:00: 540 min to the 07:00 wake-up
      final n = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7),
          light: 240, deep: 70, dream: 90, start: DateTime(2026, 11, 17, 22));
      expect(row([n], 'efficiency').value, closeTo(400 / 540 * 100, 1e-9));
      final startNight = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7),
          light: 240, deep: 70, dream: 90, start: DateTime(2026, 11, 17, 22), source: 'night start');
      expect(row([startNight], 'efficiency').value, closeTo(400 / 540 * 100, 1e-9));
    });

    test('a late Lights off tap cannot make it over 100 %, and a very short stay gives none', () {
      final late = night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7),
          light: 300, deep: 80, dream: 100, start: DateTime(2026, 11, 17, 22, 30), lightsOff: DateTime(2026, 11, 18, 0, 30));
      expect(row([late], 'efficiency').value, lessThanOrEqualTo(100));
      expect(row([late], 'efficiency').value, closeTo(480 / 480 * 100, 1e-9)); // counted from the first sleep
      final short = night(DateTime(2026, 11, 18, 6), DateTime(2026, 11, 18, 6, 20), light: 15, deep: 0, dream: 0,
          start: DateTime(2026, 11, 18, 5, 55));
      expect(row([short], 'efficiency').hasData, isFalse);
    });

    test('two sleeps in a day: all the time asleep over all the time in bed', () {
      final a = night(DateTime(2026, 11, 18, 0, 30), DateTime(2026, 11, 18, 4, 30), light: 100, deep: 40, dream: 30,
          start: DateTime(2026, 11, 18, 0, 0), lightsOff: DateTime(2026, 11, 18, 0, 0));
      final b = night(DateTime(2026, 11, 18, 5), DateTime(2026, 11, 18, 8), light: 100, deep: 20, dream: 20,
          start: DateTime(2026, 11, 18, 4, 30), lightsOff: DateTime(2026, 11, 18, 4, 30));
      // 170 + 140 min asleep over 270 + 210 min in bed
      expect(row([a, b], 'efficiency').value, closeTo(310 / 480 * 100, 1e-9));
    });
  });

  group('sleep regularity', () {
    test('the same times every night: no spread', () {
      final m = buildTrends(inputs([for (var d = 12; d <= 18; d++) nightOn(d)]), now);
      expect(rowOf(m, 'regularity').value, closeTo(0, 1e-6));
      expect(rowOf(m, 'regularity').spec.format(34.4), '±34 min');
    });

    test('needs 5 nights in the last 7; it shows only for a day that has a night', () {
      expect(row([for (var d = 14; d <= 18; d++) nightOn(d)], 'regularity').hasData, isTrue);
      expect(row([for (var d = 15; d <= 18; d++) nightOn(d)], 'regularity').hasData, isFalse);
      // 7 days with 4 nights, the earliest too long ago
      expect(row([nightOn(10), nightOn(11), for (var d = 15; d <= 18; d++) nightOn(d)], 'regularity').hasData, isFalse);
    });

    test('the spread is that of bedtimes and of wake-up times, averaged, each as a circular standard deviation', () {
      // onsets 23:00 +/- 20 min alternating, wake-ups 07:00 +/- 40 min alternating
      final nights = [
        for (var d = 12; d <= 18; d++) nightOn(d, onsetMin: d.isEven ? 20 : -20, wakeMin: d.isEven ? 40 : -40),
      ];
      final r = row(nights, 'regularity');
      double sd(List<double> minutes) {
        final c = minutes.map((v) => math.cos(v * math.pi / 720)).reduce((a, b) => a + b) / minutes.length;
        final s = minutes.map((v) => math.sin(v * math.pi / 720)).reduce((a, b) => a + b) / minutes.length;
        return math.sqrt(-2 * math.log(math.sqrt(c * c + s * s))) * 720 / math.pi;
      }
      final onsets = [for (var d = 12; d <= 18; d++) 23 * 60.0 + (d.isEven ? 20 : -20)];
      final wakes = [for (var d = 12; d <= 18; d++) 7 * 60.0 + (d.isEven ? 40 : -40)];
      expect(r.value, closeTo((sd(onsets) + sd(wakes)) / 2, 1e-6));
      expect(r.value, closeTo(30, 4)); // about the plain spread of 20 and 40 minutes
    });

    test('a bedtime either side of midnight is a few minutes apart, not a day', () {
      final nights = [
        for (var d = 12; d <= 18; d++) night(DateTime(2026, 11, d - 1, 23, 50).add(Duration(minutes: d.isEven ? 0 : 20)), DateTime(2026, 11, d, 7)),
      ];
      expect(row(nights, 'regularity').value, lessThan(15));
    });

    test('left-out nights (someone else, noisy) do not count as nights', () {
      final nights = [
        for (var d = 14; d <= 18; d++) nightOn(d),
        night(DateTime(2026, 11, 12, 23), DateTime(2026, 11, 13, 7), answer: 'someone else'),
        night(DateTime(2026, 11, 13, 23), DateTime(2026, 11, 14, 7), noisy: 0.9),
      ];
      expect(row(nights, 'regularity').value, closeTo(0, 1e-6)); // five good nights, the odd ones not in it
      final four = [for (var d = 15; d <= 18; d++) nightOn(d), night(DateTime(2026, 11, 13, 23), DateTime(2026, 11, 14, 7), noisy: 0.9)];
      expect(row(four, 'regularity').hasData, isFalse);
    });
  });

  group('How did you sleep? in the check-in', () {
    test('the check-in keeps the tap and the trends show it as a day number', () {
      final rec = checkIn(DateTime(2026, 11, 18, 9), ratings: {'kss': 4, 'mood': 4, 'tension': 2, 'sleep': 2});
      expect(rec.slept, 2);
      final m = buildTrends(inputs(const [], mornings: [rec]), now);
      final r = rowOf(m, 'slept');
      expect(r.value, 2);
      expect(r.spec.group, TrendGroup.morning);
      expect(r.spec.format(2), '2 of 5');
      expect(r.spec.label, 'How you slept');
      expect(missingMeasures(m), isNot(contains('how you slept')));
    });

    test('left out when not tapped, or not in 1-5; the first check-in of the day with it counts', () {
      expect(checkIn(DateTime(2026, 11, 18, 9)).slept, isNull);
      expect(checkIn(DateTime(2026, 11, 18, 9), ratings: {'kss': 4, 'mood': 4, 'tension': 2, 'sleep': 6}).slept, isNull);
      expect(checkIn(DateTime(2026, 11, 18, 9), ratings: {'kss': 4, 'mood': 4, 'tension': 2, 'sleep': 3.5}).slept, isNull);
      final m = buildTrends(
        inputs(const [], mornings: [
          checkIn(DateTime(2026, 11, 18, 9)),
          checkIn(DateTime(2026, 11, 18, 11), ratings: {'kss': 4, 'mood': 4, 'tension': 2, 'sleep': 5}),
        ]),
        now,
      );
      expect(rowOf(m, 'slept').value, 5);
    });

    test('a night marked someone else is not read here: the check-in keeps its own rating', () {
      final m = buildTrends(
        inputs([night(DateTime(2026, 11, 17, 23), DateTime(2026, 11, 18, 7), answer: 'someone else')],
            mornings: [checkIn(DateTime(2026, 11, 18, 9), ratings: {'kss': 4, 'mood': 4, 'tension': 2, 'sleep': 4})]),
        now,
      );
      expect(rowOf(m, 'slept').value, 4);
      expect(rowOf(m, 'deep').hasData, isFalse);
    });

    test('the answers carry it into the ratings and the marker only when it was tapped', () {
      const base = (kss: 4, mood: 3, tension: 2, cups: 0, drinks: 0, today: false);
      MorningAnswers answers({int? sleep}) => MorningAnswers(
        kss: base.kss, mood: base.mood, tension: base.tension, cups: base.cups, drinks: base.drinks,
        caffeineToday: base.today, sleep: sleep,
      );
      expect(answers().ratings, {'kss': 4, 'mood': 3, 'tension': 2});
      expect(answers(sleep: 3).ratings, {'kss': 4, 'mood': 3, 'tension': 2, 'sleep': 3});
      expect(MorningMarker.ratings(answers().ratings), 'morning:ratings {"kss":4,"mood":3,"tension":2}');
      expect(MorningMarker.ratings(answers(sleep: 3).ratings), 'morning:ratings {"kss":4,"mood":3,"tension":2,"sleep":3}');
    });

    test('it is offered as a self-experiment outcome, judged by the next morning', () {
      final o = outcomeById('slept')!;
      expect(o.label, 'How you slept');
      expect(o.more, 'better');
      expect(o.less, 'worse');
      expect(o.matters, 1);
      expect(outcomeById('deep'), isNull); // stage minutes stay out (DECISIONS 202)
      expect(outcomeById('efficiency'), isNull);
    });
  });

  test('the page reads the nights from files and leaves out the ones marked someone else', () {
    final root = Directory.systemTemp.createTempSync('sleeptrends');
    addTearDown(() => root.deleteSync(recursive: true));
    final rec = Directory('${root.path}/files/recordings')..createSync(recursive: true);
    final dir = nightsDirFor(rec.path);
    final store = NightReportStore(dir);
    store.write(nightOn(18));
    store.write(night(DateTime(2026, 11, 16, 23), DateTime(2026, 11, 17, 7), answer: 'someone else'));
    final i = readTrendInputs(rec.path);
    expect(i.nights, hasLength(1));
    final m = buildTrends(i, now);
    expect(rowOf(m, 'deep').line.where((v) => v != null), hasLength(1));
  });
}
