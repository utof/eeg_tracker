// The memory cues' honest self-test (DECISIONS 503-505): a hidden schedule of sound and silent nights in blocks of 4,
// a hidden choice of which half's sound plays each night, a plan frozen with the schedule's hash, and results only per
// 12 finished nights: the tested number (on sound nights, the half whose sound played against the other half, by the
// app's own coin) apart from what is only seen together.
import 'package:eeg_tracker/memory_cues/plan.dart';
import 'package:eeg_tracker/training/check.dart' show sha256Hex, canonicalJson;
import 'package:flutter_test/flutter_test.dart';

String salt(int k) => k.toRadixString(16).padLeft(64, '0');

/// A finished night: [drift] (morning minus evening distance) of the half whose sound plays (or would) and of the
/// other half.
MemoryNight night(MemorySealed s, int index, {required double played, required double other, String heard = 'no'}) {
  final p = s.soundOf(index);
  final evening = [0.2, 0.2], morning = [0.2, 0.2];
  morning[p] = 0.2 + played;
  morning[1 - p] = 0.2 + other;
  return MemoryNight(index: index, cueMoments: 40, arousedMoments: 2, evening: evening, morning: morning, heard: heard);
}

void main() {
  test('blocks of 4 nights, 2 with sound; a fair coin picks the half each night; the same secret, the same draw', () {
    final s = MemorySealed.draw(salt(1));
    expect(s.arms, hasLength(MemoryTest.maxNights));
    for (var b = 0; b < MemoryTest.maxNights; b += 4) {
      expect(s.arms.sublist(b, b + 4).where((a) => a == MemoryArm.sound), hasLength(2));
    }
    expect(s.sounds, hasLength(MemoryTest.maxNights));
    expect(s.sounds.toSet(), {0, 1});
    expect(MemorySealed.draw(salt(1)).toJson(), s.toJson());
    expect(MemorySealed.draw(salt(2)).toJson(), isNot(s.toJson()));
    // over many secrets, each half is picked about half the time
    var zeros = 0;
    for (var k = 0; k < 100; k++) {
      zeros += MemorySealed.draw(salt(k)).sounds.where((v) => v == 0).length;
    }
    expect(zeros / (100 * MemoryTest.maxNights), closeTo(0.5, 0.03));
  });

  test('after the planned nights every night has sound; the schedule survives JSON and its check', () {
    final s = MemorySealed.draw(salt(3));
    expect(s.armOf(MemoryTest.maxNights + 5), MemoryArm.sound);
    expect(s.soundOf(MemoryTest.maxNights + 5), anyOf(0, 1));
    final back = MemorySealed.fromJson(s.toJson())!;
    expect(back.toJson(), s.toJson());
    expect(back.consistent, isTrue);
    final j = s.toJson()..['sounds'] = '1${(s.toJson()['sounds']! as String).substring(1)}';
    final changed = MemorySealed.fromJson(j)!;
    expect(changed.consistent, s.sounds.first == 1);
    expect(MemorySealed.fromJson({'salt': 'x', 'allocation': 'CQ', 'sounds': '01'}), isNull);
  });

  test('the plan holds the schedule\'s hash; its own hash is over its canonical JSON', () {
    final s = MemorySealed.draw(salt(4));
    final p = MemoryPlan(frozen: DateTime(2026, 11, 24, 22), scheduleSha256: s.sha);
    expect(p.sha, sha256Hex(canonicalJson(p.toJson())));
    expect(p.toJson()['primary'], contains('half'));
    expect(MemoryPlan.fromJson(p.toJson())!.sha, p.sha);
  });

  group('results', () {
    final sealed = MemorySealed.draw(salt(5));
    final plan = MemoryPlan(frozen: DateTime(2026, 11, 24, 22), scheduleSha256: sealed.sha);

    MemoryResults? results(List<MemoryNight> nights) =>
        memoryResults(plan: plan, planSha: plan.sha, sealed: sealed, nights: nights);

    test('sealed until 12 nights are finished', () {
      expect(results([for (var i = 0; i < 11; i++) night(sealed, i, played: 0.05, other: 0.05)]), isNull);
      expect(results([for (var i = 0; i < 12; i++) night(sealed, i, played: 0.05, other: 0.05)]), isNotNull);
    });

    test('a clear benefit on every sound night: the played half drifted less; "likely real for you"', () {
      final nights = [
        for (var i = 0; i < 24; i++)
          sealed.armOf(i) == MemoryArm.sound
              ? night(sealed, i, played: 0.01 + 0.001 * i, other: 0.08 + 0.001 * i)
              : night(sealed, i, played: 0.05, other: 0.05 + (i.isEven ? 0.01 : -0.01)),
      ];
      final r = results(nights)!;
      expect(r.shown, hasLength(24));
      expect(r.planOk, isTrue);
      expect(r.primary!.diff, closeTo(0.07, 1e-9), reason: 'the other half drifted 0.07 more');
      expect(r.primary!.live, 12);
      expect(r.verdict, MemoryVerdict.likely);
      final soundIdx = [
        for (var i = 0; i < 24; i++)
          if (sealed.armOf(i) == MemoryArm.sound) i,
      ];
      final meanIdx = soundIdx.reduce((a, b) => a + b) / soundIdx.length;
      expect(r.soundNights.played, closeTo(0.01 + 0.001 * meanIdx, 1e-9));
      expect(r.soundNights.other, closeTo(0.08 + 0.001 * meanIdx, 1e-9));
      expect(r.silentNights.played, closeTo(0.05, 1e-9));
    });

    test('the sign of the coin, not the size, is what the test shuffles: no difference, "not clear yet"', () {
      var n = 0;
      final nights = [
        for (var i = 0; i < 12; i++)
          night(
            sealed,
            i,
            played: 0.05 + ((sealed.armOf(i) == MemoryArm.sound ? n++ : 0).isEven ? 0.02 : -0.02),
            other: 0.05,
          ),
      ];
      final r = results(nights)!;
      expect(r.verdict, MemoryVerdict.notClear);
      expect(r.primary!.p, greaterThan(0.05));
    });

    test('too few sound nights with both tests: "too few"; a night without its morning test is left out', () {
      final nights = [
        for (var i = 0; i < 12; i++)
          if (sealed.armOf(i) == MemoryArm.sound && i > 4)
            MemoryNight(index: i, cueMoments: 0, arousedMoments: 0, evening: const [0.2, 0.2])
          else
            night(sealed, i, played: 0.0, other: 0.1),
      ];
      final r = results(nights)!;
      expect(r.unanswered, greaterThan(0));
      expect(r.verdict, MemoryVerdict.tooFew);
    });

    test('a changed schedule shows: the plan check fails', () {
      final other = MemorySealed.draw(salt(6));
      final r = memoryResults(
        plan: plan,
        planSha: plan.sha,
        sealed: other,
        nights: [for (var i = 0; i < 12; i++) night(other, i, played: 0.0, other: 0.0)],
      )!;
      expect(r.planOk, isFalse);
    });

    test('heard a sound and the stirs after cue moments, per kind of night', () {
      final nights = [
        for (var i = 0; i < 12; i++)
          night(sealed, i, played: 0, other: 0, heard: sealed.armOf(i) == MemoryArm.sound ? 'yes' : 'no'),
      ];
      final r = results(nights)!;
      expect(r.heard!.diff, closeTo(1.0, 1e-9));
      expect(r.heardShare, (1.0, 0.0));
      expect(r.arousalShare.$1, closeTo(2 / 40, 1e-9));
      expect(r.arousalShare.$2, closeTo(2 / 40, 1e-9));
    });
  });
}
