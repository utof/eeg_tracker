// The replay check's pure parts: the schedule (deterministic from its salt, balanced in every block, unbiased
// over many salts), the frozen plan and its hashes, the reveal locked until 12 sessions, the permutation test
// and the binomial tail on numbers worked out by hand, the replayer's live gates and the donor rule.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/feedback/session.dart';
import 'package:eeg_tracker/training/check.dart';
import 'package:eeg_tracker/training/check_store.dart';
import 'package:eeg_tracker/training/control.dart';
import 'package:eeg_tracker/training/replay.dart';
import 'package:eeg_tracker/training/reveal.dart';
import 'package:flutter_test/flutter_test.dart';

CheckRecord rec(
  int i,
  Arm arm, {
  double? outcome,
  double? silent,
  double ex = 0.1,
  String guess = 'unsure',
  int control = 3,
}) => CheckRecord(
      index: i,
      stem: 's$i',
      start: DateTime(2026, 12, 1).add(Duration(days: i)),
      arm: arm,
      runS: 600,
      outcome: outcome,
      silent: silent,
      excludedShare: ex,
      asleepS: 0,
      ratings: CheckRatings(calm: 3, guess: guess, confidence: 50, control: control, random: 3),
    );

void main() {
  test('sha256 and canonical JSON: known vector, key order does not matter', () {
    expect(sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(
      canonicalJson({
        'b': 1,
        'a': [
          2,
          {'d': 3, 'c': 4},
        ],
      }),
      '{"a":[2,{"c":4,"d":3}],"b":1}',
    );
  });

  test('schedule: the same salt gives the same arms; every block of 4 has 2 live and 2 replay', () {
    final a = allocate('00ff', 9), b = allocate('00ff', 9), c = allocate('00fe', 9);
    expect(armsText(a), armsText(b));
    expect(armsText(a), isNot(armsText(c)));
    expect(a.length, 36);
    for (var blk = 0; blk < 9; blk++) {
      expect(a.sublist(blk * 4, blk * 4 + 4).where((x) => x == Arm.live).length, 2, reason: 'block $blk');
    }
    expect(blockLayouts(4, 2).length, 6);
    expect(blockLayouts(4, 3).length, 4);
    final three = allocate('x', 5, live: 3);
    for (var blk = 0; blk < 5; blk++) {
      expect(three.sublist(blk * 4, blk * 4 + 4).where((x) => x == Arm.live).length, 3);
    }
  });

  test('schedule: over 3000 salts each of the 6 block layouts comes up about equally often', () {
    final counts = <String, int>{};
    for (var i = 0; i < 3000; i++) {
      final first = armsText(allocate('salt$i', 1));
      counts[first] = (counts[first] ?? 0) + 1;
    }
    expect(counts.length, 6);
    for (final v in counts.values) {
      expect(v, inInclusiveRange(400, 600), reason: '500 expected, binomial SD about 20');
    }
  });

  test('salt: 64 hex characters from the generator; the sealed file proves its schedule', () {
    final salt = newSalt(math.Random(4));
    expect(salt, matches(RegExp(r'^[0-9a-f]{64}$')));
    final s = Sealed.draw(salt);
    expect(s.arms.length, CheckRule.maxSessions);
    expect(s.consistent, isTrue);
    final swapped = Sealed(salt, [s.arms[1], s.arms[0], ...s.arms.skip(2)]);
    if (s.arms[0] != s.arms[1]) {
      expect(swapped.consistent, isFalse);
      expect(swapped.sha, isNot(s.sha));
    }
    expect(Sealed.fromJson(jsonDecode(jsonEncode(s.toJson())))!.sha, s.sha);
  });

  test('plan: its hash covers every rule; any change shows', () {
    final p = CheckPlan(kind: SessionKind.meditation, frozen: DateTime(2026, 11, 18, 22), allocationSha256: 'a' * 64);
    expect(p.sha, hasLength(64));
    expect(CheckPlan.fromJson(jsonDecode(jsonEncode(p.toJson())))!.sha, p.sha);
    final other = CheckPlan(kind: SessionKind.alphaTheta, frozen: p.frozen, allocationSha256: p.allocationSha256);
    expect(other.sha, isNot(p.sha));
    expect(p.toJson()['primary'], contains('alpha'));
    expect(other.toJson()['primary'], contains('theta/alpha'));
    expect(
      CheckPlan.fromJson({'version': 1, 'kind': 'meditation', 'frozen': 'x', 'allocationSha256': 'a' * 64}),
      isNull,
    );
  });

  test('slots: donor phase until 4 live sessions exist, then the schedule, never the arm in words', () {
    final sealed = Sealed.draw('fixed');
    List<DonorCandidate> cands(int n) => [
      for (var i = 0; i < n; i++) (stem: 'd$i', start: DateTime(2026, 11, 1 + i), runS: 600.0, rate: 3.0),
    ];
    final donor = nextSlot(
      kind: SessionKind.meditation,
      sealed: null,
      records: const [],
      candidates: cands(2),
      neededS: 600,
    );
    expect(donor.phase, SlotPhase.donor);
    expect(donor.arm, Arm.live);
    expect(donor.status, contains('Live session 3 of 4'));
    final first = nextSlot(
      kind: SessionKind.meditation,
      sealed: sealed,
      records: const [],
      candidates: cands(5),
      neededS: 600,
    );
    expect(first.phase, SlotPhase.randomised);
    expect(first.index, 0);
    expect(first.arm, sealed.arms[0]);
    expect(first.donors.isEmpty, first.arm == Arm.live);
    expect(first.status, isNot(contains('replay')));
    expect(first.status, isNot(contains(' live')));
    final done = nextSlot(
      kind: SessionKind.meditation,
      sealed: sealed,
      records: [for (var i = 0; i < 36; i++) rec(i, sealed.arms[i])],
      candidates: cands(5),
      neededS: 600,
    );
    expect(done.phase, SlotPhase.finished);
  });

  test('store: the plan is frozen before the first randomised session and never redrawn', () {
    final dir = Directory.systemTemp.createTempSync('check');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = CheckStore(dir, SessionKind.meditation);
    List<DonorCandidate> cands(int n) => [
      for (var i = 0; i < n; i++) (stem: 'd$i', start: DateTime(2026, 11, 1 + i), runS: 300.0, rate: 3.0),
    ];
    expect(prepareSlot(store, cands(3), 600, DateTime(2026, 11, 20)).phase, SlotPhase.donor);
    expect(store.plan, isNull, reason: 'nothing frozen in the donor phase');
    final slot = prepareSlot(store, cands(4), 600, DateTime(2026, 11, 21));
    expect(slot.phase, SlotPhase.randomised);
    final plan = store.plan!, sealed = store.sealed!;
    expect(plan.sha, plan.plan.sha);
    expect(plan.plan.allocationSha256, sealed.sha);
    expect(slot.arm, sealed.arms[0]);
    if (slot.arm == Arm.replay) expect(slot.donors.length, 2, reason: '300 s donors spliced to cover 600 s');
    prepareSlot(store, cands(6), 600, DateTime(2026, 11, 22));
    expect(store.sealed!.salt, sealed.salt, reason: 'frozen once');
    store.add(rec(0, slot.arm));
    store.rate(0, const CheckRatings(calm: 4, guess: 'live', confidence: 70, control: 4, random: 2));
    expect(store.records.single.ratings!.guess, 'live');
    expect(File('${store.dir.path}/events.jsonl').readAsLinesSync().first, contains('plan frozen'));
    // a replayed session is never a donor
    final replayed = Arm.replay;
    store.add(rec(0, replayed));
    final next = prepareSlot(
      store,
      [...cands(4), (stem: 's0', start: DateTime(2026, 12, 9), runS: 600, rate: 3)],
      600,
      DateTime(2026, 11, 23),
    );
    expect(next.donors, isNot(contains('s0')));
  });

  test('reveal: locked until 12 sessions, then only whole sets; a schedule edit shows', () {
    final dir = Directory.systemTemp.createTempSync('check');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = CheckStore(dir, SessionKind.meditation)..freeze(DateTime(2026, 11, 18));
    final arms = store.sealed!.arms;
    expect(store.reveal(), isNull);
    for (var i = 0; i < 11; i++) {
      store.add(rec(i, arms[i], outcome: arms[i] == Arm.live ? 0.2 : 0.0));
    }
    expect(store.reveal(), isNull, reason: '11 sessions: still locked');
    expect(store.untilReveal, 1);
    store.add(rec(11, arms[11], outcome: arms[11] == Arm.live ? 0.2 : 0.0));
    store.add(rec(12, arms[12], outcome: 0.1));
    final r = store.reveal()!;
    expect(r.shown.length, 12);
    expect(r.hidden, 1, reason: 'session 13 stays sealed');
    expect(r.planOk, isTrue);
    expect(r.primary!.diff, closeTo(0.2, 1e-12));
    expect(r.primary!.orders, 216);
    expect(r.primary!.p, closeTo(2 / 216, 1e-12), reason: 'only the true order and its mirror are as extreme');
    expect(r.note.join(' '), contains('differed'));
    // someone edits the sealed schedule: the reveal says the hashes no longer agree
    final f = File('${store.dir.path}/sealed.json');
    final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    final text = j['allocation']! as String;
    j['allocation'] = text.substring(4, 8) + text.substring(0, 4) + text.substring(8);
    f.writeAsStringSync(jsonEncode(j));
    if (j['allocation'] != text) expect(store.reveal()!.planOk, isFalse);
  });

  test('permutation test: hand-checked small cases, exact and sampled agree', () {
    // one block of 4, live = the two largest: 1 of 6 orders as large, 2 of 6 as extreme both ways
    final r = permutationTest([1, 2, 3, 4], [false, false, true, true], [0, 0, 0, 0])!;
    expect(r.diff, 2);
    expect(r.orders, 6);
    expect(r.p, closeTo(2 / 6, 1e-12));
    // no difference at all: p = 1
    expect(permutationTest([1, 1, 1, 1], [true, false, true, false], [0, 0, 0, 0])!.p, 1);
    // only one kind: no test
    expect(permutationTest([1, 2], [true, true], [0, 0]), isNull);
    // synthetic sessions: live 0.15 higher, noise SD 0.1, 24 sessions in 6 blocks
    final g = gaussian(9), arms = allocate('synthetic', 6);
    final vals = [for (final a in arms) (a == Arm.live ? 0.15 : 0.0) + 0.1 * g()];
    final live = [for (final a in arms) a == Arm.live], blocks = [for (var i = 0; i < 24; i++) i ~/ 4];
    final exact = permutationTest(vals, live, blocks)!;
    final sampled = permutationTest(vals, live, blocks, maxExact: 10, draws: 20000, seed: 3)!;
    expect(exact.exact, isTrue);
    expect(exact.orders, 46656);
    expect(sampled.exact, isFalse);
    expect(sampled.p, closeTo(exact.p, 0.01));
    expect(exact.p, lessThan(0.05), reason: 'a 1.5 SD effect over 24 sessions is found');
    // and with no effect, p is not small
    final g0 = gaussian(10), noEffect = [for (final _ in arms) 0.1 * g0()];
    expect(permutationTest(noEffect, live, blocks)!.p, greaterThan(0.05));
  });

  test('binomial tail: exact values', () {
    expect(binomialTail(0, 10), 1);
    expect(binomialTail(10, 10), closeTo(1 / 1024, 1e-15));
    expect(binomialTail(9, 10), closeTo(11 / 1024, 1e-15));
    expect(binomialTail(6, 12), closeTo(2510 / 4096, 1e-12), reason: '1 - (1+12+66+220+495+792) / 4096');
    expect(binomialTail(13, 12), 0);
  });

  test('reveal: guesses right more than chance are called partly unblinded; excluded sessions are counted', () {
    final sealed = Sealed.draw('guess');
    final plan = CheckPlan(kind: SessionKind.alphaTheta, frozen: DateTime(2026, 11, 18), allocationSha256: sealed.sha);
    final records = [
      for (var i = 0; i < 12; i++)
        rec(i, sealed.arms[i], outcome: 0.05 * (i % 3), guess: sealed.arms[i].name, ex: i == 5 ? 0.5 : 0.1),
    ];
    final r = reveal(plan: plan, planSha: plan.sha, sealed: sealed, records: records)!;
    expect(r.right, 12);
    expect(r.judged, 12);
    expect(r.guessP, closeTo(1 / 4096, 1e-12));
    expect(r.excluded, 1);
    expect(r.primary!.live + r.primary!.replay, 11);
    expect(r.note.join(' '), contains('partly unblinded'));
    expect(r.note.join(' '), contains('theta-to-alpha'));
  });

  test('plans frozen from now on (version 2) name the silent minutes as a secondary measure; version 1 stays valid', () {
    final p = CheckPlan(kind: SessionKind.meditation, frozen: DateTime(2026, 11, 19), allocationSha256: 'b' * 64);
    expect(p.version, 2);
    final secondary = (p.toJson()['secondary']! as List).cast<String>();
    expect(secondary.last, startsWith('the silent minutes after the sound'));
    final old = CheckPlan(kind: SessionKind.meditation, frozen: p.frozen, allocationSha256: p.allocationSha256, version: 1);
    expect((old.toJson()['secondary']! as List).any((e) => '$e'.contains('silent')), isFalse);
    // a version-1 plan as written before this change: the same text, so its saved hash still agrees
    final back = CheckPlan.fromJson(jsonDecode(jsonEncode(old.toJson())))!;
    expect(back.version, 1);
    expect(back.sha, old.sha);
    expect(CheckPlan.fromJson(jsonDecode(jsonEncode(p.toJson())))!.sha, p.sha);
    final at = CheckPlan(kind: SessionKind.alphaTheta, frozen: p.frozen, allocationSha256: p.allocationSha256);
    expect((at.toJson()['secondary']! as List).any((e) => '$e'.contains('silent')), isFalse, reason: 'none in alpha-theta');
  });

  test('reveal: the silent minutes, live against replay, with the same within-block test, when the plan named them', () {
    final sealed = Sealed.draw('silent');
    final plan = CheckPlan(kind: SessionKind.meditation, frozen: DateTime(2026, 11, 19), allocationSha256: sealed.sha);
    final records = [
      for (var i = 0; i < 12; i++)
        rec(i, sealed.arms[i], outcome: 0.1, silent: i == 4 ? null : (sealed.arms[i] == Arm.live ? 0.3 : 0.1)),
    ];
    final r = reveal(plan: plan, planSha: plan.sha, sealed: sealed, records: records)!;
    expect(r.silent!.diff, closeTo(0.2, 1e-12));
    expect(r.silent!.live + r.silent!.replay, 11, reason: 'a session without the silent minutes is left out');
    expect(r.silent!.p, lessThan(0.05));
    expect(r.note.join(' '), contains('silent minutes'));
    final v1 = CheckPlan(kind: SessionKind.meditation, frozen: plan.frozen, allocationSha256: sealed.sha, version: 1);
    expect(reveal(plan: v1, planSha: v1.sha, sealed: sealed, records: records)!.silent, isNull,
        reason: 'not in a plan frozen before: never tested after the fact');
  });

  test('records and ratings: JSON round trip; bad answers refused', () {
    final withSilent = rec(4, Arm.live, outcome: 0.12, silent: 0.08);
    expect(CheckRecord.fromJson(jsonDecode(jsonEncode(withSilent.toJson())))!.toJson(), withSilent.toJson());
    expect(rec(4, Arm.live, outcome: 0.12).toJson(), isNot(contains('silent')), reason: 'older records unchanged');
    expect(CheckRecord.fromJson(jsonDecode(jsonEncode(withSilent.withRatings(withSilent.ratings!).toJson())))!.silent, 0.08);
    final r = rec(3, Arm.replay, outcome: 0.12);
    expect(CheckRecord.fromJson(jsonDecode(jsonEncode(r.toJson())))!.toJson(), r.toJson());
    expect(CheckRatings.fromJson({'calm': 6, 'guess': 'live', 'confidence': 50, 'control': 3, 'random': 3}), isNull);
    expect(CheckRatings.fromJson({'calm': 3, 'guess': 'maybe', 'confidence': 50, 'control': 3, 'random': 3}), isNull);
    expect(CheckRecord.fromJson({'index': -1}), isNull);
  });

  test('replayer: the donor stream plays while the live gates still act, rewards wait as live ones would', () {
    final donor = [
      for (var i = 0; i < 100; i++)
        (level: i / 100, rough: 0.0, reward: i == 20 || i == 50 || i == 95 ? 'bell' : null, gated: false),
    ];
    final rp = Replayer([donor], cleanSteps: cleanStepsFor(SessionKind.meditation));
    const live = (level: 0.35, rough: 0.6, reward: null, gated: false);
    final out = <Control>[];
    for (var i = 0; i < 120; i++) {
      out.add(rp.next(live, gated: i >= 40 && i < 48)); // a blink-like gate 4.0-4.8 s
    }
    expect(out[10].level, closeTo(0.10, 1e-12), reason: 'donor bed');
    expect(out[10].rough, 0.6, reason: 'jaw roughness is always live');
    expect(out[45].level, 0.35, reason: 'gated: the live neutral bed');
    expect(out[45].gated, isTrue);
    expect(out[50].reward, isNull, reason: 'the donor bell 0.2 s after the gate is dropped (a live bell needs 4 s)');
    expect(out[20].reward, 'bell', reason: 'no gate before: the donor bell sounds');
    expect(out[95].reward, 'bell', reason: '4.8 s after the gate');
    expect(out.where((c) => c.reward != null).length, 2);
    expect(out[105].level, closeTo(0.05, 1e-12), reason: 'the stream loops when the session outlasts it');
  });

  test('control stream from a real session log, and a refused kind', () {
    final s = Session(), demo = DemoSignal(2);
    while (s.n < 250 * 150) {
      demo.eyes = demo.t < 30 ? 'open' : 'closed';
      s.push(demo.next(250));
    }
    final saved = jsonDecode(jsonEncode(s.log.toJson())) as Map<String, Object?>;
    final c = controlStream(saved, SessionKind.meditation);
    final runSteps = s.log.lines.where((l) => l['type'] == 'step' && l['s'] == null).length;
    expect(c.length, runSteps);
    expect(c.where((x) => x.reward == 'bell').length, s.rung);
    expect(rewardsPerMinute(c), greaterThan(0));
    expect(() => controlStream(saved, SessionKind.alphaTheta), throwsFormatException);
  });

  test('donors: closest reward rate, least used, spliced to the length', () {
    final cands = <DonorCandidate>[
      (stem: 'a', start: DateTime(2026, 11, 1), runS: 600, rate: 3.0),
      (stem: 'b', start: DateTime(2026, 11, 2), runS: 600, rate: 3.1),
      (stem: 'c', start: DateTime(2026, 11, 3), runS: 600, rate: 6.0),
      (stem: 'd', start: DateTime(2026, 11, 4), runS: 300, rate: 2.9),
      (stem: 'e', start: DateTime(2026, 11, 5), runS: 30, rate: 3.0),
    ];
    expect(pickDonors(cands, 600, const {}), ['d', 'b']);
    expect(pickDonors(cands, 600, const {'d': 1}), ['b']);
    expect(pickDonors(cands, 300, const {'b': 2, 'd': 1}), ['a']);
    expect(pickDonors(cands, 3000, const {}).toSet(), {'a', 'b', 'c', 'd'});
    expect(pickDonors(const [], 600, const {}), isEmpty);
  });
}
