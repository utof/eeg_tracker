// "Which sound works for me": a fair test of two sounds for one state (ROADMAP row 18, DECISIONS rows 434-438). The
// app draws the days in shuffled blocks of 4 (the self-experiments' own draw, every weekday with both sounds),
// freezes the plan before day 1, sets each day's sound when that day comes, and at the end tests the difference with
// the self-experiments' randomisation test, labelled "tested". Made-up sessions: days without the headband, another
// state played on a plan day, sessions from before the plan (no tag), two sessions on one day, a stop.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/experiments/analysis.dart' show Orders, Verdict;
import 'package:eeg_tracker/experiments/experiment.dart' show ExpPhase, drawDays;
import 'package:eeg_tracker/sleep/drift.dart' show DriftResult, LightsOffFrom;
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/readout.dart' show ReadSummary;
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/states/trial.dart';
import 'package:eeg_tracker/states/trial_store.dart';
import 'package:eeg_tracker/states/weeks.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:flutter_test/flutter_test.dart';

const pinkNone = SoundPick(Bed.pink, Beat.none), pinkPulsed = SoundPick(Bed.pink, Beat.pulsed);

/// Made at 09:00 on Thu 19 Nov 2026: day 1 is Fri 20 Nov.
final made = DateTime(2026, 11, 19, 9);

DateTime onDay(String key, {int hour = 23}) => dayNoon(key).add(Duration(hours: hour - 12));

/// A fall-asleep session at 23:00 of [day] that played [pick], asleep after [onsetMin] (null: sound only).
SoundSession bedtime(String day, SoundPick pick, double? onsetMin, {TrialTag? tag, SoundState state = SoundState.asleep, int hour = 23}) =>
    SoundSession(
      start: onDay(day, hour: hour),
      plan: SoundPlan.of(state, bed: pick.bed, beat: pick.beat),
      headband: onsetMin == null ? HeadbandUse.soundOnly : HeadbandUse.used,
      soundStartS: 64,
      baselineS: onsetMin == null ? 0 : 60,
      endS: 1800,
      end: onsetMin == null ? SoundEnd.time : SoundEnd.asleep,
      drift: onsetMin == null ? const {} : {'baselineS': 70, 'onsetS': (onsetMin * 60).round()},
      summary: state == SoundState.relax && onsetMin != null ? ReadSummary(0, 200, onsetMin, 1, null) : null,
      trial: tag,
    );

void main() {
  late Directory dir;
  late TrialStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sound-trials');
    store = TrialStore(trialsDirFor(dir));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  TrialState start({SoundState state = SoundState.asleep, SoundPick a = pinkPulsed, SoundPick b = pinkNone, int weeks = 4, int? minutes}) =>
      store.create(state: state, a: a, b: b, minutes: minutes ?? presets[state]!.defaultMinutes, weeks: weeks, now: made, random: math.Random(7));

  group('the plan', () {
    test('frozen before day 1: the secret and the order first, then the plan with both hashes', () {
      final s = start();
      final folder = Directory('${trialsDirFor(dir).path}/${s.plan.id}');
      expect(folder.listSync().map((f) => f.uri.pathSegments.last).toSet(), {'sealed.json', 'plan.json', 'progress.json', 'events.jsonl'});
      expect(s.plan.start, '2026-11-20', reason: 'day 1 is tomorrow');
      expect(s.plan.days, 28);
      expect(s.plan.unlocks, '2026-12-19', reason: 'the day after the last number can come in');
      expect(s.planOk, isTrue);
      final sealed = jsonDecode(File('${folder.path}/sealed.json').readAsStringSync()) as Map;
      final order = [for (final c in (sealed['allocation'] as String).split('')) c == '1'];
      expect(order, drawDays(sealed['salt'] as String, 28), reason: "the self-experiments' draw: blocks of 4, both sounds on every weekday");
      for (var b = 0; b < 7; b++) {
        expect(order.sublist(b * 4, b * 4 + 4).where((x) => x).length, 2);
      }
      final plan = jsonDecode(File('${folder.path}/plan.json').readAsStringSync()) as Map;
      expect(plan['sha256'], s.plan.sha);
      expect((plan['plan'] as Map)['allocationSha256'], hasLength(64));
      expect((plan['plan'] as Map)['sounds'], {
        'a': {'bed': 'pink', 'beat': 'pulsed', 'line': 'Pink noise, pulsed noise 10 to 3 Hz'},
        'b': {'bed': 'pink', 'beat': 'none', 'line': 'Pink noise, no beat'},
      });
      expect(File('${folder.path}/events.jsonl').readAsStringSync(), contains('plan frozen'));
    });

    test('an edited plan or order is noticed', () {
      final s = start();
      final f = File('${trialsDirFor(dir).path}/${s.plan.id}/plan.json');
      final j = jsonDecode(f.readAsStringSync()) as Map;
      (j['plan'] as Map)['minutes'] = 15;
      f.writeAsStringSync(jsonEncode(j));
      expect(store.load(s.plan.id, made)!.planOk, isFalse);
    });

    test('one test per state at a time; two different sounds; a sound that plays', () {
      start();
      expect(() => start(), throwsStateError);
      expect(start(state: SoundState.relax, a: const SoundPick(Bed.ocean, Beat.none), b: const SoundPick(Bed.rain, Beat.none)).plan.state, SoundState.relax);
      expect(() => start(state: SoundState.focus, a: pinkNone, b: pinkNone), throwsArgumentError);
      expect(() => start(state: SoundState.focus, a: const SoundPick(Bed.none, Beat.none)), throwsArgumentError);
      expect(() => start(state: SoundState.wake, weeks: 3), throwsArgumentError);
      expect(() => start(state: SoundState.wake, minutes: 30), throwsArgumentError, reason: 'wake up offers 5 or 10 minutes');
      expect(store.active(SoundState.asleep, made), isNotNull);
      expect(store.active(SoundState.pause, made), isNull);
    });

    test("each day's sound only when that day has come; the days ahead never leave the sealed file", () {
      final s0 = start();
      expect(s0.phase, ExpPhase.waiting);
      expect(s0.todaySound, isNull);
      expect(s0.tagFor(SoundState.asleep), isNull);
      final order = s0.orderForResults(early: true)!;
      final day5 = store.load(s0.plan.id, onDay('2026-11-24', hour: 22))!;
      expect(day5.phase, ExpPhase.running);
      expect(day5.todayIndex, 4);
      expect(day5.todaySound, order[4] ? pinkPulsed : pinkNone);
      expect(day5.pastDays.length, 4);
      expect(day5.orderForResults(), isNull, reason: 'sealed while it runs');
      final tag = day5.tagFor(SoundState.asleep)!;
      expect((tag.plan, tag.day, tag.sound), (s0.plan.id, '2026-11-24', order[4] ? 'a' : 'b'));
      expect(day5.tagFor(SoundState.relax), isNull, reason: 'another state is free');
      // 02:00 still belongs to the evening before (a day runs 04:00 to 04:00)
      expect(store.load(s0.plan.id, DateTime(2026, 11, 25, 2))!.todayIndex, 4);
      final after = store.load(s0.plan.id, onDay('2026-12-18', hour: 9))!;
      expect(after.phase, ExpPhase.lastNumber);
      expect(after.todaySound, isNull);
      expect(store.load(s0.plan.id, onDay('2026-12-19', hour: 9))!.phase, ExpPhase.finished);
      expect(store.active(SoundState.asleep, onDay('2026-12-19', hour: 9)), isNull, reason: 'the slot is free again');
    });

    test('Stop keeps the days that are over, opens the answer marked as stopped and frees the slot', () {
      final s = start();
      final at = onDay('2026-11-30', hour: 10);
      store.stop(s.plan.id, at);
      final back = store.load(s.plan.id, at)!;
      expect(back.phase, ExpPhase.stopped);
      expect(back.assignedDays, 10);
      expect(back.open, isTrue);
      expect(back.tagFor(SoundState.asleep), isNull);
      expect(store.active(SoundState.asleep, at), isNull);
      expect(File('${trialsDirFor(dir).path}/${s.plan.id}/events.jsonl').readAsStringSync(), contains('stopped'));
    });
  });

  group('the answer', () {
    /// One bedtime session on every day of the plan, played as drawn; [onset] gives each day's minutes.
    List<SoundSession> nights(TrialState s, double? Function(int i, bool a) onset) {
      final order = s.orderForResults(early: true)!;
      return [
        for (var i = 0; i < s.plan.days; i++)
          bedtime(
            addDays(s.plan.start, i),
            order[i] ? s.plan.a : s.plan.b,
            onset(i, order[i]),
            tag: TrialTag(s.plan.id, addDays(s.plan.start, i), order[i] ? 'a' : 'b'),
          ),
      ];
    }

    TrialState finished(TrialState s) => store.load(s.plan.id, onDay(s.plan.unlocks, hour: 9))!;

    test('a clear difference: "likely real for you", the same p as the self-experiments\' test on those days', () {
      final s = start();
      double minutes(int i, bool a) => (a ? 12 : 24) + (i * 7 % 5) - 2.0;
      final r = trialResults(finished(s), nights(s, minutes));
      expect(r.tested, isNotNull);
      expect(r.verdict, Verdict.likelyReal);
      final order = s.orderForResults(early: true)!;
      final o = Orders.of(order, [for (var i = 0; i < 28; i++) minutes(i, order[i])]);
      expect(r.tested!.diff, closeTo(o.diff(), 1e-9));
      expect(r.tested!.diff, lessThan(-9));
      expect(r.tested!.high!, lessThan(0));
      expect(r.tested!.p, o.p());
      expect(r.tested!.exact, isTrue);
      expect(r.withNumber, 28);
      expect(trialSentence(r), startsWith('With “Pink noise, pulsed noise 10 to 3 Hz” your time to fall asleep was '));
      expect(trialSentence(r), contains(' min shorter than with “Pink noise, no beat” (range −'));
      expect(trialSentence(r), endsWith('min): likely real for you.'));
    });

    test('no difference over enough days: "little or no effect" once the range is inside 5 minutes', () {
      final s = start(weeks: 8);
      final r = trialResults(finished(s), nights(s, (i, a) => 15 + (i % 2 == 0 ? 0.5 : -0.5)));
      expect(r.verdict, Verdict.littleOrNone);
      expect(r.tested!.exact, isFalse, reason: '8 weeks: sampled orders');
      expect(trialNote(r), contains('does not change it much for you'));
    });

    test('days without the headband, another state, sessions with no tag and a second session are left out', () {
      final s = start();
      final order = s.orderForResults(early: true)!;
      final list = nights(s, (i, a) => i < 6 ? null : (a ? 10.0 : 20.0)); // the first 6 days: sound only
      final day7 = addDays(s.plan.start, 6), day8 = addDays(s.plan.start, 7);
      // a relax session earlier on day 7 (the state switched that evening): not a fall-asleep number
      list.add(bedtime(day7, const SoundPick(Bed.ocean, Beat.none), 1.5, state: SoundState.relax, hour: 20));
      // day 8: an untagged session (as from an older app) and a second tagged one after the first
      list.add(bedtime(day8, order[7] ? s.plan.b : s.plan.a, 40, hour: 21));
      list.add(bedtime(day8, order[7] ? s.plan.a : s.plan.b, 41, tag: TrialTag(s.plan.id, day8, order[7] ? 'a' : 'b'), hour: 23).copyWithStart(onDay(day8, hour: 23).add(const Duration(minutes: 50))));
      final r = trialResults(finished(s), list);
      expect(r.withNumber, 22);
      expect(r.tested!.diff, closeTo(-10, 1e-9), reason: 'only the first tagged session of each day, the fall-asleep ones');
      expect(r.tested!.nDo + r.tested!.nDont, 22);
    });

    test('a tag of another plan, or a session whose sound is not the day\'s, does not count', () {
      final s = start();
      final day1 = s.plan.start, order = s.orderForResults(early: true)!;
      final wrongPlan = bedtime(day1, order[0] ? s.plan.a : s.plan.b, 9, tag: TrialTag('2020-01-01-000000', day1, order[0] ? 'a' : 'b'));
      final wrongSound = bedtime(day1, order[0] ? s.plan.b : s.plan.a, 9, tag: TrialTag(s.plan.id, day1, order[0] ? 'a' : 'b'));
      expect(trialResults(finished(s), [wrongPlan, wrongSound]).withNumber, 0);
    });

    test('too few: under 5 days of a sound with a number', () {
      final s = start();
      final r = trialResults(finished(s), nights(s, (i, a) => a && i > 7 ? null : 15.0));
      expect(r.verdict, Verdict.tooFew);
      expect(trialSentence(r), startsWith('Too few days to say:'));
      expect(trialSentence(r), contains('it takes 5 of each'));
    });

    test('stopped early: only the days that were over are counted', () {
      final s = start();
      final at = onDay(addDays(s.plan.start, 14), hour: 10);
      store.stop(s.plan.id, at);
      final r = trialResults(store.load(s.plan.id, at)!, nights(s, (i, a) => a ? 10.0 : 20.0));
      expect(r.days, 14);
      expect(r.withNumber, 14);
    });

    test('relax: compared as a ratio, said as a percentage', () {
      const ocean = SoundPick(Bed.ocean, Beat.none), rain = SoundPick(Bed.rain, Beat.none);
      final s = start(state: SoundState.relax, a: ocean, b: rain);
      final order = s.orderForResults(early: true)!;
      final list = [
        for (var i = 0; i < 28; i++)
          bedtime(addDays(s.plan.start, i), order[i] ? ocean : rain, order[i] ? 1.32 : 1.1, state: SoundState.relax, hour: 18,
              tag: TrialTag(s.plan.id, addDays(s.plan.start, i), order[i] ? 'a' : 'b')),
      ];
      final r = trialResults(finished(s), list);
      expect(r.tested!.diff, closeTo(math.log(1.2), 1e-9));
      expect(trialSentence(r), contains('your alpha against the quiet minute was 20 % higher than with “Rain, no beat”'));
    });

    test('the night\'s report counts for a tagged session whose detector missed sleep', () {
      final s = start();
      final day1 = s.plan.start, order = s.orderForResults(early: true)!;
      final pick = order[0] ? s.plan.a : s.plan.b;
      final missed = SoundSession(
        start: onDay(day1),
        plan: SoundPlan.of(SoundState.asleep, bed: pick.bed, beat: pick.beat),
        headband: HeadbandUse.used,
        soundStartS: 64,
        baselineS: 60,
        endS: 1800,
        end: SoundEnd.time,
        drift: const {'baselineS': 70},
        trial: TrialTag(s.plan.id, day1, order[0] ? 'a' : 'b'),
      );
      final night = DriftResult(lightsOff: onDay(day1), from: LightsOffFrom.sound, agree: null, counted: false, modelOnsetMin: 33);
      expect(trialResults(finished(s), [missed], nights: [night]).withNumber, 1);
    });
  });
}

extension on SoundSession {
  SoundSession copyWithStart(DateTime start) => SoundSession.fromJson({...toJson(), 'start': start.toIso8601String()})!;
}
