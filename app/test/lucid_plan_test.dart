// The lucid cues' honest self-test (DECISIONS 305-306): the hidden schedule of cue and silent nights, the frozen plan
// and the results that open per 12 nights, "tested" apart from "seen together".
import 'package:eeg_tracker/lucid/plan.dart';
import 'package:flutter_test/flutter_test.dart';

const _salt = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

LucidNight _night(
  int index, {
  String? lucid = 'no',
  String? heard = 'no',
  int recall = 1,
  int cues = 4,
  int aroused = 0,
  int signals = 0,
  bool practised = true,
}) => LucidNight(
  index: index,
  cueMoments: cues,
  arousedMoments: aroused,
  signalsInDreamSleep: signals,
  practised: practised,
  answers: lucid == null ? null : LucidAnswers(lucid: lucid, heard: heard!, recall: recall),
);

void main() {
  test('the schedule: blocks of 4 nights, 2 with cues and 2 silent, the same for the same secret', () {
    final s = LucidSealed.draw(_salt);
    expect(s.arms.length, LucidTest.maxNights);
    for (var b = 0; b < s.arms.length; b += 4) {
      expect(s.arms.sublist(b, b + 4).where((a) => a == NightArm.cue).length, 2);
    }
    expect(LucidSealed.draw(_salt).toJson(), s.toJson());
    expect(s.consistent, isTrue);
    expect(LucidSealed.fromJson(s.toJson())!.arms, s.arms);
    expect(LucidSealed.fromJson({'salt': _salt, 'allocation': 'CSXC'}), isNull);
  });

  test('after the planned nights every night has cues', () {
    final s = LucidSealed.draw(_salt);
    expect(s.armOf(LucidTest.maxNights), NightArm.cue);
    expect(s.armOf(1000), NightArm.cue);
    expect(s.armOf(-1), NightArm.cue);
  });

  test('the plan freezes the schedule by its hash', () {
    final s = LucidSealed.draw(_salt);
    final p = LucidPlan(frozen: DateTime(2026, 11, 19, 21), scheduleSha256: s.sha);
    expect(p.toJson()['scheduleSha256'], s.sha);
    expect(LucidPlan.fromJson(p.toJson())!.sha, p.sha);
    expect(p.toJson()['primary'], contains('lucid'));
  });

  test('sealed until 12 nights; then whole sets of 12 only', () {
    final s = LucidSealed.draw(_salt);
    final p = LucidPlan(frozen: DateTime(2026, 11, 19), scheduleSha256: s.sha);
    final eleven = [for (var i = 0; i < 11; i++) _night(i)];
    expect(lucidResults(plan: p, planSha: p.sha, sealed: s, nights: eleven), isNull);
    final fourteen = [for (var i = 0; i < 14; i++) _night(i)];
    final r = lucidResults(plan: p, planSha: p.sha, sealed: s, nights: fourteen)!;
    expect(r.shown.length, 12);
    expect(r.hidden, 2);
    expect(r.planOk, isTrue);
  });

  test('the tested answer: lucid mornings after cue nights against silent nights, shuffled inside blocks', () {
    final s = LucidSealed.draw(_salt);
    final p = LucidPlan(frozen: DateTime(2026, 11, 19), scheduleSha256: s.sha);
    final nights = [for (var i = 0; i < 12; i++) _night(i, lucid: s.arms[i] == NightArm.cue ? 'yes' : 'no')];
    final r = lucidResults(plan: p, planSha: p.sha, sealed: s, nights: nights)!;
    expect(r.lucid!.diff, 1.0);
    expect(r.lucid!.orders, 216); // 6 layouts in each of 3 blocks
    expect(r.lucid!.p, closeTo(2 / 216, 1e-12));
    expect(r.cueNights, 6);
    expect(r.silentNights, 6);
    expect(r.verdict, LucidVerdict.likely);
  });

  test('unanswered mornings are left out of the test and counted', () {
    final s = LucidSealed.draw(_salt);
    final p = LucidPlan(frozen: DateTime(2026, 11, 19), scheduleSha256: s.sha);
    final nights = [for (var i = 0; i < 12; i++) _night(i, lucid: i < 3 ? null : 'no')];
    final r = lucidResults(plan: p, planSha: p.sha, sealed: s, nights: nights)!;
    expect(r.unanswered, 3);
    expect(r.lucid!.live + r.lucid!.replay, 9);
    expect(r.verdict, LucidVerdict.notClear);
  });

  test('arousals per cue moment are compared too: the silent nights give the spontaneous rate', () {
    final s = LucidSealed.draw(_salt);
    final p = LucidPlan(frozen: DateTime(2026, 11, 19), scheduleSha256: s.sha);
    final nights = [for (var i = 0; i < 12; i++) _night(i, cues: 10, aroused: s.arms[i] == NightArm.cue ? 3 : 1)];
    final r = lucidResults(plan: p, planSha: p.sha, sealed: s, nights: nights)!;
    expect(r.arousalShare, (0.3, 0.1));
  });

  test('a changed schedule shows: the plan no longer matches', () {
    final s = LucidSealed.draw(_salt);
    final p = LucidPlan(frozen: DateTime(2026, 11, 19), scheduleSha256: s.sha);
    final flipped = LucidSealed(_salt, [for (final a in s.arms) a == NightArm.cue ? NightArm.silent : NightArm.cue]);
    final r = lucidResults(plan: p, planSha: p.sha, sealed: flipped, nights: [for (var i = 0; i < 12; i++) _night(i)])!;
    expect(r.planOk, isFalse);
  });

  test('seen together, not tested: lucid mornings by whether a cue was heard', () {
    final s = LucidSealed.draw(_salt);
    final p = LucidPlan(frozen: DateTime(2026, 11, 19), scheduleSha256: s.sha);
    final nights = [for (var i = 0; i < 12; i++) _night(i, lucid: i < 4 ? 'yes' : 'no', heard: i < 6 ? 'dream' : 'no')];
    final r = lucidResults(plan: p, planSha: p.sha, sealed: s, nights: nights)!;
    expect(r.lucidWhenHeard, (4, 6));
    expect(r.lucidWhenNotHeard, (0, 6));
  });

  test('the answers: lucid yes counts, not sure does not; heard in a dream or woke counts as heard', () {
    expect(const LucidAnswers(lucid: 'yes', heard: 'no', recall: 2).lucidValue, 1);
    expect(const LucidAnswers(lucid: 'unsure', heard: 'no', recall: 2).lucidValue, 0);
    expect(const LucidAnswers(lucid: 'no', heard: 'woke', recall: 0).heardValue, 1);
    expect(const LucidAnswers(lucid: 'no', heard: 'unsure', recall: 0).heardValue, 0);
    expect(LucidAnswers.fromJson({'lucid': 'maybe', 'heard': 'no', 'recall': 1}), isNull);
    expect(
      LucidAnswers.fromJson(const LucidAnswers(lucid: 'yes', heard: 'dream', recall: 3, signal: 'yes').toJson())!
          .signal,
      'yes',
    );
  });
}
