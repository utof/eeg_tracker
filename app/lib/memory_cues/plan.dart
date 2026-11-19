// The memory cues' honest self-test (DECISIONS 503-505). Two things are hidden and drawn by the phone:
// - which nights have sound: shuffled blocks of 4 nights, 2 with sound and 2 silent (the lucid cues' draw), for 36
//   nights; after them every night has sound. A silent night does everything the same (the model, the rule, the cue
//   moments in the night's markers), only no sound plays.
// - which half's sound plays (or would play): a fair coin each night from the same secret, so you cannot tell in the
//   morning which half was cued.
// The plan (what is measured, the analysis) and the schedule's SHA-256 are frozen before the first night. Results only
// per 12 finished nights, never per night:
// - tested: on nights with sound, how much less the half whose sound played drifted overnight than the other half
//   (morning distance minus evening distance), with a randomisation test over the app's own coins (every way the coin
//   could have fallen on those nights); one verdict, only for this number;
// - tested, no verdict: hearing a sound and the other half's drift, sound nights against silent nights (the block
//   shuffle); seen together, not tested: the same halves on silent nights (what chance alone gives), stirs after cue
//   moments.
// Pure: numbers in, words out; store.dart keeps the files.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../training/check.dart' show Arm, allocate, canonicalJson, sha256Hex;
import '../training/reveal.dart' show PermutationResult, permutationTest;

export '../training/check.dart' show newSalt;

/// Planning values (DECISIONS 503-504).
abstract final class MemoryTest {
  static const int blockSize = 4, soundPerBlock = 2;
  static const int revealEvery = 12, maxNights = 36;

  /// The verdict needs at least this many sound nights with both tests: with fewer, even the clearest result cannot
  /// reach p < 0.05 by the coins alone (6 nights: the smallest p is 2 in 64).
  static const int minSoundNights = 6;
}

enum MemoryArm { sound, silent }

/// The hidden part: the secret, the schedule of sound and silent nights, and each night's half.
class MemorySealed {
  const MemorySealed(this.salt, this.arms, this.sounds);

  factory MemorySealed.draw(String salt) => MemorySealed(
    salt,
    [
      for (final a in allocate(
        salt,
        MemoryTest.maxNights ~/ MemoryTest.blockSize,
        size: MemoryTest.blockSize,
        live: MemoryTest.soundPerBlock,
      ))
        a == Arm.live ? MemoryArm.sound : MemoryArm.silent,
    ],
    [for (var i = 0; i < MemoryTest.maxNights; i++) coin(salt, i)],
  );

  final String salt;
  final List<MemoryArm> arms;

  /// Per night, the half (sound 0 or 1) whose sound plays, or would on a silent night.
  final List<int> sounds;

  /// Night [index]'s coin: the first byte of SHA-256("salt:sound:index"), under 128 is sound 0.
  static int coin(String salt, int index) =>
      sha256.convert(utf8.encode('$salt:sound:$index')).bytes.first < 128 ? 0 : 1;

  /// Night [index] (from 0): its arm; nights after the planned ones all have sound.
  MemoryArm armOf(int index) => index >= 0 && index < arms.length ? arms[index] : MemoryArm.sound;

  /// Night [index]'s half, also after the planned nights.
  int soundOf(int index) => index >= 0 && index < sounds.length ? sounds[index] : coin(salt, index);

  Map<String, Object?> toJson() => {
    'salt': salt,
    'allocation': arms.map((a) => a == MemoryArm.sound ? 'C' : 'S').join(),
    'sounds': sounds.join(),
  };
  String get sha => sha256Hex(canonicalJson(toJson()));

  /// True when the schedule and the halves are the ones the secret gives.
  bool get consistent => canonicalJson(MemorySealed.draw(salt).toJson()) == canonicalJson(toJson());

  static MemorySealed? fromJson(Object? j) {
    if (j is! Map || j['salt'] is! String) return null;
    final a = j['allocation'], s = j['sounds'];
    if (a is! String || !RegExp(r'^[CS]+$').hasMatch(a)) return null;
    if (s is! String || !RegExp(r'^[01]+$').hasMatch(s)) return null;
    return MemorySealed(
      j['salt'] as String,
      [for (final c in a.split('')) c == 'C' ? MemoryArm.sound : MemoryArm.silent],
      [for (final c in s.split('')) int.parse(c)],
    );
  }
}

/// The frozen plan, saved with its hash before the first night.
class MemoryPlan {
  const MemoryPlan({required this.frozen, required this.scheduleSha256});
  final DateTime frozen;
  final String scheduleSha256;

  Map<String, Object?> toJson() => {
    'version': 1,
    'frozen': frozen.toIso8601String(),
    'design':
        'an evening task (objects at places on a board, half learned with sound 0, half with sound 1), a night with '
        'memory cues on, a morning test; each night with sound or silent (the same rule, the same cue moments, no '
        'sound), shuffled blocks of ${MemoryTest.blockSize} nights (${MemoryTest.soundPerBlock} with sound) drawn for '
        '${MemoryTest.maxNights}, after them every night has sound; each night a fair coin picks the half whose sound '
        'plays (or would)',
    'blockSize': MemoryTest.blockSize,
    'soundPerBlock': MemoryTest.soundPerBlock,
    'maxNights': MemoryTest.maxNights,
    'revealEvery': MemoryTest.revealEvery,
    'measure':
        'drift of a half = its mean distance from the places (board widths; an object not placed counts as half the '
        'diagonal) in the morning test minus in the evening test',
    'primary': 'on nights with sound: the other half\'s drift minus the drift of the half whose sound played',
    'secondary': [
      'heard a sound in the night (yes, or it woke me): sound nights minus silent nights',
      'the drift of the half whose sound did not play: sound nights minus silent nights (does the sound cost the '
          'rest?)',
      'cue moments followed by an arousal within 30 s (movement, the drift-off detector saying awake, or an awake '
          'epoch): the silent nights give the rate without sound',
    ],
    'seenTogether': ['the same two halves on silent nights (no sound played: what chance alone gives)'],
    'exclusions': 'a night without both tests is reported but left out of the tests',
    'analysis':
        'primary: mean over sound nights, two-sided randomisation test over every way the coins of those nights could '
        'have fallen (50 000 seeded draws above 200 000 ways); secondary: difference of the means, sound minus silent, '
        'two-sided permutation test shuffling the labels inside each block; a verdict only for the primary measure, '
        'from ${MemoryTest.minSoundNights} sound nights with both tests',
    'honesty':
        'every night is reported; the schedule, the coins and the primary measure do not change; results only per whole '
        'set of ${MemoryTest.revealEvery} finished nights; a null result is shown as clearly as a positive one',
    'scheduleSha256': scheduleSha256,
  };

  String get sha => sha256Hex(canonicalJson(toJson()));

  static MemoryPlan? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final frozen = DateTime.tryParse('${j['frozen']}'), s = j['scheduleSha256'];
    if (frozen == null || s is! String || s.length != 64) return null;
    return MemoryPlan(frozen: frozen, scheduleSha256: s);
  }
}

/// One finished night of the test as the results read it: its cue moments, the two halves' mean distances in the
/// evening and morning tests (sound 0, sound 1; morning null when it was not done) and the morning's "heard a sound?"
/// (no / yes / woke / unsure).
class MemoryNight {
  const MemoryNight({
    required this.index,
    required this.cueMoments,
    required this.arousedMoments,
    required this.evening,
    this.morning,
    this.heard,
  });
  final int index, cueMoments, arousedMoments;
  final List<double> evening;
  final List<double>? morning;
  final String? heard;

  bool get tested => morning != null;

  /// Morning minus evening distance of sound [s]'s half.
  double drift(int s) => morning![s] - evening[s];

  int get heardValue => heard == 'yes' || heard == 'woke' ? 1 : 0;
}

enum MemoryVerdict { likely, notClear, tooFew }

/// Mean drifts of the half whose sound played (or would) and of the other half; null without a tested night.
typedef HalfDrifts = ({double? played, double? other, int nights});

class MemoryResults {
  const MemoryResults({
    required this.shown,
    required this.hidden,
    required this.planOk,
    required this.arms,
    required this.primary,
    required this.soundNights,
    required this.silentNights,
    required this.heard,
    required this.otherHalf,
    required this.arousalShare,
    required this.heardShare,
    required this.cueMoments,
    required this.unanswered,
  });

  /// The nights revealed (whole sets of 12), oldest first, with their arms; [hidden]: finished nights after them.
  final List<MemoryNight> shown;
  final int hidden;
  final List<MemoryArm> arms;

  /// The plan's hash, the schedule's hash and the schedule drawn again from the secret all agree.
  final bool planOk;

  /// Tested: on sound nights, the other half's drift minus the played half's (positive: the sound helped).
  final PermutationResult? primary;

  /// The halves per kind of night.
  final HalfDrifts soundNights, silentNights;

  /// Tested, no verdict: heard a sound, and the other half's drift, sound nights minus silent nights.
  final PermutationResult? heard, otherHalf;

  /// Cue moments followed by an arousal, as a share: (sound nights, silent nights); null without cue moments.
  final (double?, double?) arousalShare;

  /// Mornings with a sound heard (yes, or it woke me), as a share of the answered mornings: (sound, silent nights).
  final (double?, double?) heardShare;

  /// Mean cue moments a night: (sound nights, silent nights).
  final (double?, double?) cueMoments;

  /// Shown nights without both tests.
  final int unanswered;

  int get soundNightCount => arms.where((a) => a == MemoryArm.sound).length;

  MemoryVerdict get verdict {
    final p = primary;
    if (p == null || p.live < MemoryTest.minSoundNights) return MemoryVerdict.tooFew;
    return p.p < 0.05 ? MemoryVerdict.likely : MemoryVerdict.notClear;
  }
}

/// The results, or null while fewer than [MemoryTest.revealEvery] nights of the test are finished (sealed).
/// [nights]: the finished nights (morning test done, or its time over); [planSha]: the hash saved with the plan.
MemoryResults? memoryResults({
  required MemoryPlan plan,
  required String planSha,
  required MemorySealed sealed,
  required List<MemoryNight> nights,
}) {
  final inTest = [
    for (final n in nights)
      if (n.index >= 0 && n.index < MemoryTest.maxNights) n,
  ]..sort((a, b) => a.index.compareTo(b.index));
  final sets = inTest.length ~/ MemoryTest.revealEvery;
  if (sets == 0) return null;
  final shown = inTest.take(sets * MemoryTest.revealEvery).toList();
  final arms = [for (final n in shown) sealed.armOf(n.index)];
  final planOk = plan.sha == planSha && sealed.sha == plan.scheduleSha256 && sealed.consistent;
  final tested = [
    for (var j = 0; j < shown.length; j++)
      if (shown[j].tested) j,
  ];

  // primary: on each tested sound night, the played half against the other, the night as its own block of two
  final soundTested = [
    for (final j in tested)
      if (arms[j] == MemoryArm.sound) j,
  ];
  final values = <double>[], live = <bool>[], blocks = <int>[];
  for (final j in soundTested) {
    final n = shown[j], p = sealed.soundOf(n.index);
    values
      ..add(-n.drift(p))
      ..add(-n.drift(1 - p));
    live
      ..add(true)
      ..add(false);
    blocks
      ..add(n.index)
      ..add(n.index);
  }
  final primary = soundTested.isEmpty ? null : permutationTest(values, live, blocks);

  HalfDrifts halves(MemoryArm a) {
    final which = [
      for (final j in tested)
        if (arms[j] == a) j,
    ];
    if (which.isEmpty) return (played: null, other: null, nights: 0);
    double mean(double Function(MemoryNight n, int p) f) =>
        which.fold(0.0, (s, j) => s + f(shown[j], sealed.soundOf(shown[j].index))) / which.length;
    return (played: mean((n, p) => n.drift(p)), other: mean((n, p) => n.drift(1 - p)), nights: which.length);
  }

  PermutationResult? acrossNights(double Function(MemoryNight n) value, List<int> which) => which.isEmpty
      ? null
      : permutationTest([for (final j in which) value(shown[j])], [for (final j in which) arms[j] == MemoryArm.sound], [
          for (final j in which) shown[j].index ~/ MemoryTest.blockSize,
        ]);

  (double?, double?) perKind(double? Function(List<MemoryNight> ns) f) => (
    f([
      for (var j = 0; j < shown.length; j++)
        if (arms[j] == MemoryArm.sound) shown[j],
    ]),
    f([
      for (var j = 0; j < shown.length; j++)
        if (arms[j] == MemoryArm.silent) shown[j],
    ]),
  );

  final withHeard = [
    for (final j in tested)
      if (shown[j].heard != null) j,
  ];
  return MemoryResults(
    shown: shown,
    hidden: inTest.length - shown.length,
    planOk: planOk,
    arms: arms,
    primary: primary,
    soundNights: halves(MemoryArm.sound),
    silentNights: halves(MemoryArm.silent),
    heard: acrossNights((n) => n.heardValue.toDouble(), withHeard),
    otherHalf: acrossNights((n) => n.drift(1 - sealed.soundOf(n.index)), tested),
    arousalShare: perKind((ns) {
      final moments = ns.fold(0, (a, n) => a + n.cueMoments);
      return moments == 0 ? null : ns.fold(0, (a, n) => a + n.arousedMoments) / moments;
    }),
    cueMoments: perKind((ns) => ns.isEmpty ? null : ns.fold(0, (a, n) => a + n.cueMoments) / ns.length),
    heardShare: perKind((ns) {
      final answered = [
        for (final n in ns)
          if (n.tested && n.heard != null) n,
      ];
      return answered.isEmpty ? null : answered.fold(0, (a, n) => a + n.heardValue) / answered.length;
    }),
    unanswered: shown.length - tested.length,
  );
}
