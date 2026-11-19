// Sound for states over weeks (ROADMAP row 18, DECISIONS rows 430-433): each session's number for its state (fall
// asleep: minutes to sleep onset; relax: alpha against the quiet minute; break: slow waves, i.e. drowsiness; focus and
// wake up: your answer, marked weak), and the comparison of the sounds you used per state, "not enough yet" until 14
// sessions with a number. Made-up sessions: without the headband, a state switched in the same evening, old files
// without the newer fields, the night's report filling in what the session did not see.
import 'dart:convert';

import 'package:eeg_tracker/sleep/drift.dart' show DriftResult, LightsOffFrom;
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/readout.dart' show ReadSummary;
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/states/weeks.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime(2026, 11, 20, 23);

/// A finished session with the headband unless [headband] says otherwise.
SoundSession sess(
  DateTime start,
  SoundState state, {
  Bed? bed,
  Beat beat = Beat.none,
  int? minutes,
  String headband = HeadbandUse.used,
  String end = SoundEnd.time,
  Map<String, Object?> drift = const {},
  ReadSummary? summary,
  int? rating,
  TrialTag? trial,
}) {
  final used = headband == HeadbandUse.used;
  return SoundSession(
    start: start,
    plan: SoundPlan.of(state, bed: bed, beat: beat, minutes: minutes),
    headband: headband,
    soundStartS: used ? 64 : 0,
    baselineS: used ? 60 : 0,
    endS: 900,
    end: end,
    drift: drift,
    summary: summary,
    rating: rating,
    trial: trial,
  );
}

DriftResult night(DateTime lightsOff, {double? onset, double? model, LightsOffFrom from = LightsOffFrom.sound}) =>
    DriftResult(lightsOff: lightsOff, from: from, agree: null, counted: false, onsetMin: onset, modelOnsetMin: model);

ReadSummary sum({double alpha = 1, double slow = 1, int clean = 240}) => ReadSummary(0, clean, alpha, slow, null);

void main() {
  group("a session's number", () {
    test('fall asleep: minutes from lights off to the detector\'s onset, counted up to 45', () {
      final n = sessionNumber(sess(t0, SoundState.asleep, end: SoundEnd.asleep, drift: const {'baselineS': 75, 'onsetS': 1080, 'asleepAtS': 1259}))!;
      expect((n.value, n.from), (18.0, NumberFrom.detector));
      expect(sessionNumber(sess(t0, SoundState.asleep, end: SoundEnd.cap, drift: const {'onsetS': 2900}))!.value, 45);
    });

    test('fall asleep: still awake when the sound stopped at its 45-minute cap counts as 45', () {
      final n = sessionNumber(sess(t0, SoundState.asleep, minutes: 45, end: SoundEnd.cap, drift: const {'baselineS': 75, 'onsetS': null}))!;
      expect((n.value, n.from), (45.0, NumberFrom.notAsleep));
      expect(
        sessionNumber(sess(t0, SoundState.asleep, minutes: 15, drift: const {'baselineS': 75})),
        isNull,
        reason: 'the timer ended it at 15 min and no night followed: when you fell asleep is not known',
      );
      expect(sessionNumber(sess(t0, SoundState.asleep, end: SoundEnd.stopped, drift: const {'baselineS': 75})), isNull);
      expect(sessionNumber(sess(t0, SoundState.asleep, end: SoundEnd.cap)), isNull, reason: 'the detector never had its baseline');
    });

    test("fall asleep: the night's report fills in when the session itself did not see sleep", () {
      final s = sess(t0, SoundState.asleep, minutes: 15, drift: const {'baselineS': 75});
      final near = t0.add(const Duration(seconds: 40));
      var n = sessionNumber(s, nights: [night(near, onset: 21.5, model: 19)])!;
      expect((n.value, n.from), (21.5, NumberFrom.nightDetector));
      n = sessionNumber(s, nights: [night(near, model: 19)])!;
      expect((n.value, n.from), (19.0, NumberFrom.sleepModel));
      expect(sessionNumber(s, nights: [night(near, onset: 70)])!.value, 45, reason: 'counted up to 45 like every session');
      expect(sessionNumber(s, nights: [night(t0.add(const Duration(minutes: 20)), onset: 12)]), isNull, reason: 'another lights off');
      expect(sessionNumber(s, nights: [night(near)]), isNull, reason: 'neither found sleep in that night');
      final own = sess(t0, SoundState.asleep, end: SoundEnd.asleep, drift: const {'baselineS': 75, 'onsetS': 600});
      expect(sessionNumber(own, nights: [night(near, onset: 21)])!.from, NumberFrom.detector, reason: "the session's own detector first");
    });

    test('fall asleep while the night recorded (sound only): the night\'s lights off, if it was tapped at about that time', () {
      final s = sess(t0, SoundState.asleep, headband: HeadbandUse.nightRecording);
      expect(sessionNumber(s), isNull);
      final tapped = night(t0.subtract(const Duration(minutes: 3)), onset: 14, from: LightsOffFrom.button);
      expect(sessionNumber(s, nights: [tapped])!.value, 14);
    });

    test('without the headband nothing is measured', () {
      for (final h in [HeadbandUse.soundOnly, HeadbandUse.notFound, HeadbandUse.lost]) {
        expect(sessionNumber(sess(t0, SoundState.relax, headband: h, summary: sum(alpha: 1.3))), isNull, reason: h);
        expect(sessionNumber(sess(t0, SoundState.pause, headband: h, summary: sum(slow: 1.3))), isNull, reason: h);
        expect(sessionNumber(sess(t0, SoundState.asleep, headband: h, end: SoundEnd.cap, drift: const {'baselineS': 75})), isNull);
      }
    });

    test('relax: alpha against the quiet minute; break: slow waves (drowsiness); a minute of clean signal at least', () {
      final r = sessionNumber(sess(t0, SoundState.relax, summary: sum(alpha: 1.25, slow: 0.9)))!;
      expect((r.value, r.from), (1.25, NumberFrom.readout));
      expect(sessionNumber(sess(t0, SoundState.pause, summary: sum(alpha: 1.25, slow: 0.9)))!.value, 0.9);
      expect(sessionNumber(sess(t0, SoundState.relax, summary: sum(alpha: 1.25, clean: 59))), isNull);
      expect(sessionNumber(sess(t0, SoundState.relax)), isNull, reason: 'no comparison: a short quiet minute');
      expect(sessionNumber(sess(t0, SoundState.relax, summary: sum(alpha: double.nan))), isNull);
      expect(sessionNumber(sess(t0, SoundState.relax, summary: sum(alpha: 1.2), end: SoundEnd.stopped))!.value, 1.2);
    });

    test('focus and wake up: your answer, with or without the headband; not answered: none', () {
      expect(sessionNumber(sess(t0, SoundState.focus, rating: 4))!.value, 4);
      final w = sessionNumber(sess(t0, SoundState.wake, headband: HeadbandUse.soundOnly, rating: 2))!;
      expect((w.value, w.from), (2.0, NumberFrom.rating));
      expect(sessionNumber(sess(t0, SoundState.focus)), isNull);
      expect(stateMeasures[SoundState.focus]!.weak, isTrue);
      expect(stateMeasures[SoundState.wake]!.weak, isTrue);
      expect(stateMeasures[SoundState.asleep]!.weak, isFalse);
    });

    test('a session the phone cut short (still "running") or that failed has no number', () {
      expect(sessionNumber(sess(t0, SoundState.focus, rating: 4, end: SoundEnd.running)), isNull);
      expect(sessionNumber(sess(t0, SoundState.relax, summary: sum(alpha: 1.2), end: SoundEnd.failed)), isNull);
    });
  });

  group('the comparison over weeks', () {
    test('one row per sound of the chosen state; the other states stay out, also from the same evening', () {
      final list = [
        sess(t0, SoundState.relax, summary: sum(alpha: 1.4)),
        // the state switched: relax first, then fall asleep the same evening
        sess(t0.add(const Duration(minutes: 20)), SoundState.asleep, end: SoundEnd.asleep, drift: const {'baselineS': 70, 'onsetS': 900}),
        sess(t0.add(const Duration(days: 1)), SoundState.asleep, beat: Beat.pulsed, end: SoundEnd.asleep, drift: const {'baselineS': 70, 'onsetS': 1500}),
        sess(t0.add(const Duration(days: 2)), SoundState.asleep, headband: HeadbandUse.soundOnly),
      ];
      final c = compareSounds(SoundState.asleep, list);
      expect(c.rows.map((r) => r.line), ['Pink noise, no beat', 'Pink noise, pulsed noise 10 to 3 Hz']);
      expect(c.rows.first.played, 2, reason: 'the session without the headband was played, it just has no number');
      expect(c.rows.first.values, [15.0]);
      expect(c.played, 3);
      expect(c.counted, 2);
      final relax = compareSounds(SoundState.relax, list);
      expect(relax.rows.single.line, 'Ocean, no beat');
      expect(relax.rows.single.values, [1.4]);
    });

    test('"not enough yet" until 14 sessions with a number; then the median and the middle half', () {
      final list = [
        for (var i = 1; i <= 13; i++)
          sess(t0.add(Duration(days: i)), SoundState.asleep, end: SoundEnd.asleep, drift: {'baselineS': 70, 'onsetS': i * 60}),
      ];
      var row = compareSounds(SoundState.asleep, list).rows.single;
      expect(row.enough, isFalse);
      expect((row.median, row.low, row.high), (null, null, null));
      list.add(sess(t0.add(const Duration(days: 14)), SoundState.asleep, end: SoundEnd.asleep, drift: const {'baselineS': 70, 'onsetS': 840}));
      row = compareSounds(SoundState.asleep, list).rows.single;
      expect(row.enough, isTrue);
      expect(WeeksRule.minSessions, 14);
      expect(row.median, 7.5);
      expect(row.low, closeTo(4.25, 1e-9));
      expect(row.high, closeTo(10.75, 1e-9));
    });

    test('rows: the most used sound first, sessions newest last do not matter; a tie by name', () {
      final list = [
        sess(t0, SoundState.relax, bed: Bed.rain, summary: sum()),
        sess(t0.add(const Duration(days: 1)), SoundState.relax, summary: sum()),
        sess(t0.add(const Duration(days: 2)), SoundState.relax, summary: sum()),
        sess(t0.add(const Duration(days: 3)), SoundState.relax, bed: Bed.brown, summary: sum()),
      ];
      expect(compareSounds(SoundState.relax, list).rows.map((r) => r.line), ['Ocean, no beat', 'Brown noise, no beat', 'Rain, no beat']);
    });

    test('old files without the newer fields still count', () {
      final j = sess(t0, SoundState.relax, summary: sum(alpha: 1.3)).toJson()
        ..remove('trial')
        ..['drift'] = null;
      final back = SoundSession.fromJson(jsonDecode(jsonEncode(j)))!;
      expect(compareSounds(SoundState.relax, [back]).rows.single.values, [1.3]);
    });

    test('the words: a value, the middle half, and "not enough yet" with the count', () {
      final m = stateMeasures[SoundState.asleep]!;
      expect(m.show(18.4), '18 min');
      expect(stateMeasures[SoundState.relax]!.show(1.123), '+12 %');
      expect(stateMeasures[SoundState.pause]!.show(0.9), '−10 %');
      expect(stateMeasures[SoundState.focus]!.show(3.5), '3.5 of 5');
      final few = compareSounds(SoundState.asleep, [
        sess(t0, SoundState.asleep, end: SoundEnd.asleep, drift: const {'baselineS': 70, 'onsetS': 600}),
        sess(t0.add(const Duration(days: 1)), SoundState.asleep, headband: HeadbandUse.soundOnly),
      ]).rows.single;
      expect(rowDetail(m, few), '2 sessions, 1 with a number: not enough yet (1 of 14)');
      final many = compareSounds(SoundState.asleep, [
        for (var i = 1; i <= 14; i++)
          sess(t0.add(Duration(days: i)), SoundState.asleep, end: SoundEnd.asleep, drift: {'baselineS': 70, 'onsetS': i * 60}),
      ]).rows.single;
      expect(rowDetail(m, many), 'Half of 14 sessions between 4 and 11 min');
      expect(rowValue(m, many), '8 min');
      expect(rowValue(m, few), 'not enough yet');
    });
  });
}
