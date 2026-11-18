// Sound for states: the state presets, the sound plan (beat path, carrier rules, loudness shares) and when the sound
// fades and stops (DECISIONS rows 88 and 130-131). Pure, no audio.
import 'dart:math' as math;

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/timers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('presets', () {
    test('five states with the evidence note\'s beat paths, lengths and fades', () {
      expect(presets.keys, SoundState.values);
      final asleep = presets[SoundState.asleep]!;
      expect((asleep.fromHz, asleep.toHz, asleep.rampMin), (10, 3, 30));
      expect((asleep.fadeInS, asleep.fadeOutS), (45, Drift.soundFadeS), reason: 'sleep fades out over 2.5 min (row 88)');
      expect(asleep.minutes.last * 60, Drift.soundCapS, reason: 'never longer than the 45-minute cap');
      expect(presets[SoundState.relax]!.fromHz, 10);
      expect(presets[SoundState.relax]!.toHz, 10);
      expect(presets[SoundState.focus]!.fromHz, 16);
      expect((presets[SoundState.pause]!.fromHz, presets[SoundState.pause]!.toHz, presets[SoundState.pause]!.rampMin), (10, 8, 5));
      expect((presets[SoundState.wake]!.fromHz, presets[SoundState.wake]!.toHz), (10, 18));
      for (final p in presets.values) {
        expect(p.minutes, contains(p.defaultMinutes), reason: p.name);
        expect(p.bed, isNot(Bed.none), reason: 'a calm bed is the default (ROADMAP row 17)');
        expect(p.why, isNotEmpty);
        expect(p.expect, isNotEmpty);
        expect(p.fadeInS, greaterThan(0));
        expect(p.fadeOutS, greaterThan(0));
      }
      expect(presets.values.where((p) => p.eyesClosed).map((p) => p.state), {SoundState.asleep, SoundState.relax, SoundState.pause});
    });

    test('the plan starts with no beat: beats are optional extras', () {
      for (final s in SoundState.values) {
        final plan = SoundPlan.of(s);
        expect(plan.beat, Beat.none, reason: s.name);
        expect(plan.bed, presets[s]!.bed);
        expect(plan.minutes, presets[s]!.defaultMinutes);
      }
    });
  });

  group('beat path', () {
    test('slides exponentially from the start rate to the end rate, then holds', () {
      final p = SoundPlan.of(SoundState.asleep, beat: Beat.pulsed, minutes: 45);
      expect(p.rampS, 30 * 60, reason: 'the preset ramp when the session is longer');
      expect(p.rateAt(0), 10);
      expect(p.rateAt(p.rampS / 2), closeTo(math.sqrt(30), 1e-9), reason: 'geometric mean of 10 and 3');
      expect(p.rateAt(p.rampS), closeTo(3, 1e-9));
      expect(p.rateAt(p.rampS + 600), closeTo(3, 1e-9));
      expect(p.rateAt(-5), 10);
      final short = SoundPlan.of(SoundState.asleep, beat: Beat.pulsed, minutes: 15);
      expect(short.rampS, 15 * 60, reason: 'a shorter session reaches the end rate at its end');
      final relax = SoundPlan.of(SoundState.relax, beat: Beat.isochronic);
      expect([relax.rateAt(0), relax.rateAt(300), relax.rateAt(9999)], [10, 10, 10]);
    });

    test('no beat has no rate; depths are stored per kind and the trough stays within -6 to -20 dB', () {
      expect(SoundPlan.of(SoundState.relax).rateAt(10), isNull);
      expect(SoundPlan.of(SoundState.relax, beat: Beat.binaural).depth, 0);
      for (final b in [Beat.pulsed, Beat.isochronic]) {
        final d = SoundPlan.of(SoundState.relax, beat: b).depth;
        expect(d, beatDepth[b]);
        final troughDb = 20 * _log10(1 - d);
        expect(troughDb, inInclusiveRange(-20, -6), reason: b.name);
      }
    });
  });

  group('carrier', () {
    test('no tone between 220 and 280 Hz: it would fold into the brain-wave bands at 250 samples a second', () {
      expect(Tone.folded(240), closeTo(10, 1e-9));
      expect(Tone.folded(200), closeTo(50, 1e-9));
      expect(Tone.folded(400), closeTo(100, 1e-9));
      for (final c in Tone.carriers) {
        expect(c < 220 || c > 280, isTrue, reason: '$c');
        for (final beat in [for (final p in presets.values) ...[p.fromHz, p.toHz]]) {
          expect(Tone.folded(c - beat / 2), greaterThan(30), reason: '$c - $beat/2');
          expect(Tone.folded(c + beat / 2), greaterThan(30), reason: '$c + $beat/2');
        }
      }
      expect(Tone.carriers, contains(Tone.carrierHz));
      expect(() => SoundPlan.of(SoundState.relax, beat: Beat.isochronic, carrierHz: 240), throwsArgumentError);
      expect(() => SoundPlan.of(SoundState.relax, beat: Beat.isochronic, carrierHz: 250), throwsArgumentError);
      expect(SoundPlan.of(SoundState.relax, beat: Beat.isochronic, carrierHz: 300).carrierHz, 300);
    });
  });

  group('loudness shares', () {
    test('the beat sits 6 dB above the bed, alone it takes it all; no beat is the bed alone at the same total', () {
      final both = SoundPlan.of(SoundState.relax, beat: Beat.pulsed);
      expect(both.beatShare + both.bedShare, closeTo(1, 1e-12));
      expect(10 * _log10(both.beatShare / both.bedShare), closeTo(6.02, 0.01));
      final bedOnly = SoundPlan.of(SoundState.relax);
      expect((bedOnly.bedShare, bedOnly.beatShare), (1, 0));
      final beatOnly = SoundPlan.of(SoundState.relax, beat: Beat.isochronic, bed: Bed.none);
      expect((beatOnly.bedShare, beatOnly.beatShare), (0, 1));
      expect(() => SoundPlan.of(SoundState.relax, bed: Bed.none), throwsArgumentError, reason: 'nothing to play');
    });
  });

  group('plan file', () {
    test('round-trips through JSON; damaged plans are refused', () {
      final p = SoundPlan.of(SoundState.asleep, bed: Bed.rain, beat: Beat.binaural, minutes: 15);
      final back = SoundPlan.fromJson(p.toJson());
      expect(back, isNotNull);
      expect(back!.toJson(), p.toJson());
      expect(p.toJson()['state'], 'asleep');
      expect(p.toJson()['beat'], 'binaural');
      expect(SoundPlan.fromJson({...p.toJson(), 'state': 'flying'}), isNull);
      expect(SoundPlan.fromJson({...p.toJson(), 'minutes': -3}), isNull);
      expect(SoundPlan.fromJson({...p.toJson(), 'carrierHz': 240}), isNull);
      expect(SoundPlan.fromJson('nope'), isNull);
    });

    test('a plain line for the screen and the log', () {
      expect(SoundPlan.of(SoundState.asleep).line, 'Pink noise, no beat');
      expect(SoundPlan.of(SoundState.asleep, beat: Beat.pulsed).line, 'Pink noise, pulsed noise 10 → 3 Hz');
      expect(SoundPlan.of(SoundState.relax, beat: Beat.isochronic, bed: Bed.none).line, 'Isochronic tones 10 Hz');
    });
  });

  group('when the sound stops', () {
    test('timer: fades out over the state\'s fade and is silent at the chosen length', () {
      final relax = SoundPlan.of(SoundState.relax); // 10 min, 20 s out
      final t = soundStop(relax, soundStartS: 70);
      expect((t.fadeFromS, t.offAtS, t.why), (70 + 600 - 20, 70 + 600, StopWhy.time));
    });

    test('fall asleep: 2.5 minutes of fade once probably asleep, silent 45 minutes after lights off at the latest', () {
      final p = SoundPlan.of(SoundState.asleep, minutes: 45);
      final none = soundStop(p, soundStartS: 75);
      expect((none.fadeFromS, none.offAtS, none.why), (Drift.soundCapS - 150, Drift.soundCapS, StopWhy.cap));
      final asleep = soundStop(p, soundStartS: 75, asleepAtS: 1019);
      expect((asleep.fadeFromS, asleep.offAtS, asleep.why), (1020, 1170, StopWhy.asleep));
      final shorter = soundStop(SoundPlan.of(SoundState.asleep, minutes: 15), soundStartS: 0);
      expect((shorter.fadeFromS, shorter.offAtS, shorter.why), (900 - 150, 900, StopWhy.time));
      final late = soundStop(p, soundStartS: 75, asleepAtS: 2600);
      expect((late.fadeFromS, late.offAtS, late.why), (Drift.soundCapS - 150, Drift.soundCapS, StopWhy.cap));
    });

    test('agrees with the drift-off detector\'s own sound timers (driftTimers)', () {
      for (final asleepAt in [null, 400, 1019, 2300, 2549, 2550, 2700]) {
        final d = DriftOff(0)..asleepAt = asleepAt;
        final ref = driftTimers(d, const [], 0.5);
        final mine = soundStop(SoundPlan.of(SoundState.asleep, minutes: 45), soundStartS: 0, asleepAtS: asleepAt);
        expect((mine.fadeFromS, mine.offAtS), (ref.soundFadeFrom, ref.soundOffAt), reason: 'asleep at $asleepAt');
      }
    });

    test('only fall asleep stops for sleep; other states keep their timer', () {
      final t = soundStop(SoundPlan.of(SoundState.relax), soundStartS: 0, asleepAtS: 200);
      expect(t.why, StopWhy.time);
      expect(t.offAtS, 600);
    });
  });
}

double _log10(double x) => math.log(x) / math.ln10;
