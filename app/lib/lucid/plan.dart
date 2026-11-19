// The lucid cues' honest self-test (DECISIONS 305-306). Some nights the cues are silent on purpose and you are not
// told which: everything else is the same (the model, the rule, the cue moments in the night's markers), only no
// sound plays. In the morning three questions. Results only per 12 nights, never per night: lucid mornings after cue
// nights against silent nights, with the replay check's permutation test (training/reveal.dart), "tested", apart
// from what is only "seen together".
//
// - The schedule comes from a random secret made on the phone (the replay check's draw, training/check.dart):
//   shuffled blocks of 4 nights, 2 with cues and 2 silent, drawn for 36 nights; after them every night has cues.
// - The plan (what is measured, the analysis) and the schedule's SHA-256 are frozen before the first night, so the
//   schedule cannot change afterwards without the hash showing it.
// Pure: numbers in, words out; store.dart keeps the files.
import '../training/check.dart' show Arm, allocate, canonicalJson, sha256Hex;
import '../training/reveal.dart' show PermutationResult, permutationTest;

export '../training/check.dart' show newSalt;

/// Planning values (DECISIONS 305).
abstract final class LucidTest {
  static const int blockSize = 4, cuePerBlock = 2;
  static const int revealEvery = 12, plannedNights = 24, maxNights = 36;

  /// The test needs at least this many answered nights of each kind.
  static const int minEach = 3;
}

enum NightArm { cue, silent }

/// The hidden part: the secret and the schedule it gives. Read by the night recorder; shown only with the results.
class LucidSealed {
  const LucidSealed(this.salt, this.arms);

  factory LucidSealed.draw(String salt) => LucidSealed(salt, [
    for (final a in allocate(
      salt,
      LucidTest.maxNights ~/ LucidTest.blockSize,
      size: LucidTest.blockSize,
      live: LucidTest.cuePerBlock,
    ))
      a == Arm.live ? NightArm.cue : NightArm.silent,
  ]);

  final String salt;
  final List<NightArm> arms;

  /// Night [index] (from 0): its arm; nights after the planned ones all have cues.
  NightArm armOf(int index) => index >= 0 && index < arms.length ? arms[index] : NightArm.cue;

  static String text(List<NightArm> arms) => arms.map((a) => a == NightArm.cue ? 'C' : 'S').join();

  Map<String, Object?> toJson() => {'salt': salt, 'allocation': text(arms)};
  String get sha => sha256Hex(canonicalJson(toJson()));

  /// True when the schedule is the one the secret gives.
  bool get consistent => text(LucidSealed.draw(salt).arms.take(arms.length).toList()) == text(arms);

  static LucidSealed? fromJson(Object? j) {
    if (j is! Map || j['salt'] is! String) return null;
    final a = j['allocation'];
    if (a is! String || !RegExp(r'^[CS]+$').hasMatch(a)) return null;
    return LucidSealed(j['salt'] as String, [for (final c in a.split('')) c == 'C' ? NightArm.cue : NightArm.silent]);
  }
}

/// The frozen plan, saved with its hash before the first night.
class LucidPlan {
  const LucidPlan({required this.frozen, required this.scheduleSha256});
  final DateTime frozen;
  final String scheduleSha256;

  Map<String, Object?> toJson() => {
    'version': 1,
    'frozen': frozen.toIso8601String(),
    'design':
        'whole nights with lucid cues on, each with cues or silent (the same rule, the same cue moments, no sound); '
        'shuffled blocks of ${LucidTest.blockSize} nights (${LucidTest.cuePerBlock} with cues), drawn for '
        '${LucidTest.maxNights}; after them every night has cues',
    'blockSize': LucidTest.blockSize,
    'cuePerBlock': LucidTest.cuePerBlock,
    'plannedNights': LucidTest.plannedNights,
    'maxNights': LucidTest.maxNights,
    'revealEvery': LucidTest.revealEvery,
    'primary':
        'share of mornings answering yes to "were you lucid (you knew you were dreaming) in a dream?"; cue '
        'nights minus silent nights',
    'secondary': [
      'heard a cue (in a dream, or it woke you)',
      'cue moments followed by an arousal within 30 s (movement, the drift-off detector saying awake, or an awake '
          'epoch): the silent nights give the rate without sound',
      'dream signals (left-right-left-right, or a double clench) found in dream sleep',
      'dream recall (0-3)',
    ],
    'seenTogether': [
      'lucid mornings when a cue was heard against when not',
      'dream signals found against lucid mornings',
      'nights with the evening practice against without',
    ],
    'exclusions': 'a night without a morning answer is reported but left out of the tests',
    'analysis':
        'difference of the means, cue minus silent; two-sided permutation test shuffling the labels inside each block '
        '(every order); a verdict only for the primary measure',
    'honesty':
        'every night is reported; the schedule and the primary measure do not change; results only per whole set of '
        '${LucidTest.revealEvery} nights; a null result is shown as clearly as a positive one',
    'scheduleSha256': scheduleSha256,
  };

  String get sha => sha256Hex(canonicalJson(toJson()));

  static LucidPlan? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final frozen = DateTime.tryParse('${j['frozen']}'), s = j['scheduleSha256'];
    if (frozen == null || s is! String || s.length != 64) return null;
    return LucidPlan(frozen: frozen, scheduleSha256: s);
  }
}

/// The morning's answers. [lucid]: yes / no / unsure; [heard]: no / dream (heard in a dream) / woke (it woke me) /
/// unsure; [recall]: 0 nothing, 1 a feeling or a fragment, 2 one dream, 3 more than one; [signal]: yes / no, asked
/// only after a lucid yes.
class LucidAnswers {
  const LucidAnswers({required this.lucid, required this.heard, required this.recall, this.signal});
  final String lucid, heard;
  final int recall;
  final String? signal;

  static const lucidWords = ['yes', 'no', 'unsure'];
  static const heardWords = ['no', 'dream', 'woke', 'unsure'];

  int get lucidValue => lucid == 'yes' ? 1 : 0;
  int get heardValue => heard == 'dream' || heard == 'woke' ? 1 : 0;

  Map<String, Object?> toJson() => {'lucid': lucid, 'heard': heard, 'recall': recall, 'signal': signal};

  static LucidAnswers? fromJson(Object? j) {
    if (j is! Map) return null;
    final l = j['lucid'], h = j['heard'], r = j['recall'], s = j['signal'];
    if (!lucidWords.contains(l) || !heardWords.contains(h) || r is! int || r < 0 || r > 3) return null;
    if (s != null && s != 'yes' && s != 'no') return null;
    return LucidAnswers(lucid: l as String, heard: h as String, recall: r, signal: s as String?);
  }
}

/// One night of the test as the results read it (from the night's record, its morning answers and its signals).
class LucidNight {
  const LucidNight({
    required this.index,
    required this.cueMoments,
    required this.arousedMoments,
    required this.signalsInDreamSleep,
    required this.practised,
    this.answers,
  });
  final int index, cueMoments, arousedMoments, signalsInDreamSleep;
  final bool practised;
  final LucidAnswers? answers;
}

enum LucidVerdict { likely, notClear, tooFew }

class LucidResults {
  const LucidResults({
    required this.shown,
    required this.hidden,
    required this.planOk,
    required this.arms,
    required this.lucid,
    required this.heard,
    required this.signals,
    required this.recall,
    required this.arousalShare,
    required this.unanswered,
    required this.lucidWhenHeard,
    required this.lucidWhenNotHeard,
    required this.signalNightsLucid,
    required this.practisedLucid,
    required this.unpractisedLucid,
  });

  /// The nights revealed (whole sets of 12), oldest first, with their arms; [hidden]: nights after them, still sealed.
  final List<LucidNight> shown;
  final int hidden;
  final List<NightArm> arms;

  /// The plan's hash, the schedule's hash and the schedule drawn again from the secret all agree.
  final bool planOk;

  /// Tested (the schedule's own randomness): the primary measure, then the secondary ones (no verdict).
  final PermutationResult? lucid, heard, signals, recall;

  /// Cue moments followed by an arousal, as a share: (cue nights, silent nights); null without cue moments.
  final (double?, double?) arousalShare;
  final int unanswered;

  /// Seen together, not tested: (lucid mornings, answered mornings).
  final (int, int) lucidWhenHeard, lucidWhenNotHeard, signalNightsLucid, practisedLucid, unpractisedLucid;

  int get cueNights => arms.where((a) => a == NightArm.cue).length;
  int get silentNights => arms.length - cueNights;

  LucidVerdict get verdict {
    final p = lucid;
    if (p == null || p.live < LucidTest.minEach || p.replay < LucidTest.minEach) return LucidVerdict.tooFew;
    return p.p < 0.05 ? LucidVerdict.likely : LucidVerdict.notClear;
  }
}

/// The results, or null while fewer than [LucidTest.revealEvery] nights of the test exist (sealed). [planSha]: the
/// hash saved with the plan.
LucidResults? lucidResults({
  required LucidPlan plan,
  required String planSha,
  required LucidSealed sealed,
  required List<LucidNight> nights,
}) {
  final inTest = [
    for (final n in nights)
      if (n.index >= 0 && n.index < LucidTest.maxNights) n,
  ]..sort((a, b) => a.index.compareTo(b.index));
  final sets = inTest.length ~/ LucidTest.revealEvery;
  if (sets == 0) return null;
  final shown = inTest.take(sets * LucidTest.revealEvery).toList();
  final arms = [for (final n in shown) sealed.armOf(n.index)];
  final planOk = plan.sha == planSha && sealed.sha == plan.scheduleSha256 && sealed.consistent;
  final answered = [
    for (var j = 0; j < shown.length; j++)
      if (shown[j].answers != null) j,
  ];
  PermutationResult? test(double Function(LucidNight n) value, List<int> which) => which.isEmpty
      ? null
      : permutationTest([for (final j in which) value(shown[j])], [for (final j in which) arms[j] == NightArm.cue], [
          for (final j in which) shown[j].index ~/ LucidTest.blockSize,
        ]);
  final all = [for (var j = 0; j < shown.length; j++) j];
  double? share(NightArm a) {
    var moments = 0, aroused = 0;
    for (var j = 0; j < shown.length; j++) {
      if (arms[j] != a) continue;
      moments += shown[j].cueMoments;
      aroused += shown[j].arousedMoments;
    }
    return moments == 0 ? null : aroused / moments;
  }

  (int, int) count(bool Function(LucidNight n) where) {
    var yes = 0, n = 0;
    for (final j in answered) {
      final night = shown[j];
      if (!where(night)) continue;
      n++;
      yes += night.answers!.lucidValue;
    }
    return (yes, n);
  }

  return LucidResults(
    shown: shown,
    hidden: inTest.length - shown.length,
    planOk: planOk,
    arms: arms,
    lucid: test((n) => n.answers!.lucidValue.toDouble(), answered),
    heard: test((n) => n.answers!.heardValue.toDouble(), answered),
    signals: test((n) => n.signalsInDreamSleep > 0 ? 1 : 0, all),
    recall: test((n) => n.answers!.recall.toDouble(), answered),
    arousalShare: (share(NightArm.cue), share(NightArm.silent)),
    unanswered: shown.length - answered.length,
    lucidWhenHeard: count((n) => n.answers!.heardValue == 1),
    lucidWhenNotHeard: count((n) => n.answers!.heardValue == 0),
    signalNightsLucid: count((n) => n.signalsInDreamSleep > 0),
    practisedLucid: count((n) => n.practised),
    unpractisedLucid: count((n) => !n.practised),
  );
}
