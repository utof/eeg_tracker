// The replay check (ROADMAP row 23, wish 12; DECISIONS rows 100-103): does the live link to your brain matter,
// or would a replay of your own earlier session do as well? Pure: the plan, the hidden schedule, the records
// and the reveal; check_store.dart keeps them on disk.
//
// - Off by default. While on, every session of a kind (meditation, alpha-theta) first collects live sessions
//   until 4 can be replayed; then each session is live or a replay, drawn in shuffled blocks of 4 (2 live,
//   2 replay).
// - The schedule comes from a random secret (the salt) made on the phone; before the first randomised session
//   the plan (what is measured, how many sessions, the exclusions, the analysis) and the SHA-256 of the
//   schedule are frozen and saved, so the schedule cannot change afterwards without the hash showing it.
// - Nothing on the screen tells live from replay. After each session: how calm you feel, your guess, how in
//   control and how random the sound felt.
// - Results only per 12 sessions (3 whole blocks), never per session: live minus replay of the primary
//   measure with a permutation test that shuffles the labels inside each block, and how often you guessed
//   right.
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'control.dart';
import 'replay.dart';

export 'replay.dart' show DonorCandidate, pickDonors;

enum Arm { live, replay }

/// Planning values (DECISIONS row 100).
abstract final class CheckRule {
  static const int blockSize = 4, livePerBlock = 2;

  /// Live sessions that must exist (as donors) before the first randomised one.
  static const int donorsFirst = 4;

  /// Planned randomised sessions (the research: 24-36); the schedule is drawn for [maxSessions].
  static const int plannedSessions = 24, maxSessions = 36;

  /// Results are shown per this many sessions (3 blocks: 216 orders, so the smallest possible p is about 0.005).
  static const int revealEvery = 12;
}

/// The exact reminder shown before every session while the check is on (the research report's words).
const String checkReminder =
    'Replay check is on. This session\'s sound may follow your brain live or replay one of your earlier '
    'sessions. Practise as usual; afterwards you\'ll be asked to guess.';

String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// JSON with object keys sorted at every level, no spaces: the text that is hashed.
String canonicalJson(Object? v) => jsonEncode(_sorted(v));

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = [for (final k in v.keys) '$k']..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final e in v) _sorted(e)];
  return v;
}

/// Positions of the live sessions in a block: every way to choose [live] of [size], in a fixed order.
List<List<int>> blockLayouts(int size, int live) {
  final out = <List<int>>[];
  void pick(int from, List<int> chosen) {
    if (chosen.length == live) {
      out.add([...chosen]);
      return;
    }
    for (var i = from; i < size; i++) {
      pick(i + 1, [...chosen, i]);
    }
  }

  pick(0, []);
  return out;
}

/// The schedule for [blocks] blocks, drawn from [salt] alone: block b uses the bytes of SHA-256("salt:b"),
/// the first byte under the largest multiple of the layout count (no modulo bias) picks its layout. The same
/// salt always gives the same schedule, and every block holds exactly [live] live sessions.
List<Arm> allocate(String salt, int blocks, {int size = CheckRule.blockSize, int live = CheckRule.livePerBlock}) {
  final layouts = blockLayouts(size, live), m = layouts.length, limit = 256 - 256 % m;
  final out = <Arm>[];
  for (var b = 0; b < blocks; b++) {
    var pickIndex = -1;
    for (var round = 0; pickIndex < 0; round++) {
      for (final byte in sha256.convert(utf8.encode('$salt:$b:$round')).bytes) {
        if (byte < limit) {
          pickIndex = byte % m;
          break;
        }
      }
    }
    final liveAt = layouts[pickIndex].toSet();
    for (var i = 0; i < size; i++) {
      out.add(liveAt.contains(i) ? Arm.live : Arm.replay);
    }
  }
  return out;
}

String armsText(List<Arm> arms) => arms.map((a) => a == Arm.live ? 'L' : 'R').join();
List<Arm>? armsFrom(Object? text) {
  if (text is! String || !RegExp(r'^[LR]*$').hasMatch(text)) return null;
  return [for (final c in text.split('')) c == 'L' ? Arm.live : Arm.replay];
}

/// A new random salt (32 bytes, hex) from the phone's secure generator.
String newSalt([math.Random? random]) {
  final r = random ?? math.Random.secure();
  return [for (var i = 0; i < 32; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

/// The hidden part: the salt and the schedule it gives. Never shown before a reveal.
class Sealed {
  const Sealed(this.salt, this.arms);

  factory Sealed.draw(String salt) => Sealed(salt, allocate(salt, CheckRule.maxSessions ~/ CheckRule.blockSize));

  final String salt;
  final List<Arm> arms;

  Map<String, Object?> toJson() => {'salt': salt, 'allocation': armsText(arms)};
  String get sha => sha256Hex(canonicalJson(toJson()));

  /// True when the schedule is the one the salt gives (nobody edited one without the other).
  bool get consistent => armsText(allocate(salt, arms.length ~/ CheckRule.blockSize)) == armsText(arms);

  static Sealed? fromJson(Object? j) {
    if (j is! Map || j['salt'] is! String) return null;
    final arms = armsFrom(j['allocation']);
    return arms == null ? null : Sealed(j['salt'] as String, arms);
  }
}

/// The frozen plan, saved with its hash before the first randomised session (the research's pre-registration).
/// [version] 2 (plans frozen from 2026-11-19 on) adds meditation's silent minutes as a secondary measure
/// (DECISIONS 423); a version-1 plan keeps its own text, so its saved hash still agrees.
class CheckPlan {
  const CheckPlan({required this.kind, required this.frozen, required this.allocationSha256, this.version = 2});

  final SessionKind kind;
  final DateTime frozen;
  final String allocationSha256;
  final int version;

  /// The plan names the silent minutes as a measure (only those are ever tested).
  bool get testsSilent => version >= 2 && kind == SessionKind.meditation;

  Map<String, Object?> toJson() => {
    'version': version,
    'kind': kind.name,
    'frozen': frozen.toIso8601String(),
    'design':
        'whole sessions, live or a replay of your own earlier live session of this kind; shuffled blocks of '
        '${CheckRule.blockSize} (${CheckRule.livePerBlock} live, ${CheckRule.blockSize - CheckRule.livePerBlock} replay)',
    'blockSize': CheckRule.blockSize,
    'livePerBlock': CheckRule.livePerBlock,
    'donorsFirst': CheckRule.donorsFirst,
    'plannedSessions': CheckRule.plannedSessions,
    'maxSessions': CheckRule.maxSessions,
    'revealEvery': CheckRule.revealEvery,
    'replayed':
        'the sound-control stream (bed settings and rewards) of the last 10 live sessions of this kind, '
        'closest reward rate first, least used first, spliced to the session length; live muscle, blink, '
        'signal and sleep gates act the same in both kinds of session',
    'primary': kind == SessionKind.meditation
        ? 'mean log10 alpha (O1/O2, personal band) during the sound minus the same session\'s silent eyes-closed '
              'median, on awake clean steps; live minus replay'
        : 'mean log10(theta/alpha) during the sound minus the same session\'s silent eyes-closed median, on '
              'awake clean steps; live minus replay',
    'secondary': [
      'calm rating after the session (1-5)',
      'guess live / replay / not sure, with confidence (0-100)',
      'how in control of the sound (1-5)',
      'how random the sound seemed (1-5)',
      'probably-asleep minutes',
      if (testsSilent)
        'the silent minutes after the sound (2 min, eyes closed, no sound): mean log10 alpha minus the same '
            'session\'s silent eyes-closed median, on awake clean steps, with at least 60 s counted; live minus '
            'replay, with the same within-block permutation test',
    ],
    'exclusions':
        'a session with over ${(100 * 0.3).round()} % of its run asleep, gated or without signal is '
        'reported but left out of the primary test',
    'analysis':
        'difference of the mean primary measure, live minus replay; two-sided permutation test shuffling '
        'labels within blocks (all orders up to 200000, else 50000 seeded draws); guesses against chance with an '
        'exact binomial test',
    'honesty':
        'every session is reported; no early stop on a good result, only for safety; the primary measure '
        'does not change after a reveal; a null result is shown as clearly as a positive one',
    'allocationSha256': allocationSha256,
  };

  String get sha => sha256Hex(canonicalJson(toJson()));

  static CheckPlan? fromJson(Object? j) {
    if (j is! Map || (j['version'] != 1 && j['version'] != 2)) return null;
    final kind = SessionKind.byName(j['kind']), frozen = DateTime.tryParse('${j['frozen']}');
    final a = j['allocationSha256'];
    if (kind == null || frozen == null || a is! String || a.length != 64) return null;
    return CheckPlan(kind: kind, frozen: frozen, allocationSha256: a, version: j['version'] as int);
  }
}

/// After-session answers. [calm] and the two sound items 1-5, [guess] 'live', 'replay' or 'unsure',
/// [confidence] 0-100 (how sure of the guess).
class CheckRatings {
  const CheckRatings({
    required this.calm,
    required this.guess,
    required this.confidence,
    required this.control,
    required this.random,
  });

  final int calm;
  final String guess;
  final int confidence;
  final int control;
  final int random;

  static const Set<String> guesses = {'live', 'replay', 'unsure'};

  Map<String, Object?> toJson() => {
    'calm': calm,
    'guess': guess,
    'confidence': confidence,
    'control': control,
    'random': random,
  };

  static CheckRatings? fromJson(Object? j) {
    if (j is! Map) return null;
    int? scale(Object? v, int lo, int hi) => v is int && v >= lo && v <= hi ? v : null;
    final calm = scale(j['calm'], 1, 5), conf = scale(j['confidence'], 0, 100);
    final control = scale(j['control'], 1, 5), random = scale(j['random'], 1, 5), guess = j['guess'];
    if (calm == null || conf == null || control == null || random == null) return null;
    if (guess is! String || !guesses.contains(guess)) return null;
    return CheckRatings(calm: calm, guess: guess, confidence: conf, control: control, random: random);
  }
}

/// One randomised session as kept: its place in the schedule, the session files' stem, the arm and donors
/// (read only by the reveal), the measures and the answers.
class CheckRecord {
  const CheckRecord({
    required this.index,
    required this.stem,
    required this.start,
    required this.arm,
    this.donors = const [],
    required this.runS,
    required this.outcome,
    this.silent,
    required this.excludedShare,
    required this.asleepS,
    this.ratings,
  });

  final int index;
  final String stem;
  final DateTime start;
  final Arm arm;
  final List<String> donors;
  final double runS;
  final double? outcome;

  /// Meditation: the silent minutes' number (meditation/silent_block.dart); null without them.
  final double? silent;
  final double excludedShare;
  final double asleepS;
  final CheckRatings? ratings;

  int get block => index ~/ CheckRule.blockSize;
  bool get excluded => outcome == null || excludedShare > 0.3;

  CheckRecord withRatings(CheckRatings r) => CheckRecord(
    index: index,
    stem: stem,
    start: start,
    arm: arm,
    donors: donors,
    runS: runS,
    outcome: outcome,
    silent: silent,
    excludedShare: excludedShare,
    asleepS: asleepS,
    ratings: r,
  );

  Map<String, Object?> toJson() => {
    'index': index,
    'stem': stem,
    'start': start.toIso8601String(),
    'arm': arm.name,
    'donors': donors,
    'runS': runS,
    'outcome': outcome,
    if (silent != null) 'silent': silent,
    'excludedShare': excludedShare,
    'asleepS': asleepS,
    if (ratings != null) 'ratings': ratings!.toJson(),
  };

  static CheckRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    final index = j['index'], stem = j['stem'], start = DateTime.tryParse('${j['start']}');
    final arm = Arm.values.where((a) => a.name == j['arm']).firstOrNull;
    final runS = j['runS'], outcome = j['outcome'], ex = j['excludedShare'], asleep = j['asleepS'];
    final donors = j['donors'], silent = j['silent'];
    if (index is! int || index < 0 || stem is! String || start == null || arm == null) return null;
    if (runS is! num || ex is! num || ex < 0 || ex > 1 || asleep is! num) return null;
    if (outcome != null && (outcome is! num || !outcome.isFinite)) return null;
    return CheckRecord(
      index: index,
      stem: stem,
      start: start,
      arm: arm,
      donors: [
        if (donors is List)
          for (final d in donors)
            if (d is String) d,
      ],
      runS: runS.toDouble(),
      outcome: (outcome as num?)?.toDouble(),
      silent: silent is num && silent.isFinite ? silent.toDouble() : null,
      excludedShare: ex.toDouble(),
      asleepS: asleep.toDouble(),
      ratings: j.containsKey('ratings') ? CheckRatings.fromJson(j['ratings']) : null,
    );
  }
}

enum SlotPhase { donor, randomised, finished }

/// What the next session of a kind is. [arm] and [donors] stay inside the controller; the screen only learns
/// [phase], [index] and [donorsHave].
class Slot {
  const Slot({
    required this.kind,
    required this.phase,
    this.index,
    this.arm = Arm.live,
    this.donors = const [],
    this.donorsHave = 0,
  });
  final SessionKind kind;
  final SlotPhase phase;

  /// Place in the schedule (randomised sessions only).
  final int? index;
  final Arm arm;
  final List<String> donors;

  /// Live sessions that could be replayed so far (donor phase).
  final int donorsHave;

  /// Words for the screen: never the arm.
  String get status => switch (phase) {
    SlotPhase.donor =>
      'Live session ${donorsHave + 1} of ${CheckRule.donorsFirst} before the check begins: it needs your own sessions to replay.',
    SlotPhase.randomised =>
      'Check session ${index! + 1} of ${CheckRule.plannedSessions}-${CheckRule.maxSessions}. Results after every ${CheckRule.revealEvery}.',
    SlotPhase.finished => 'The check has its ${CheckRule.maxSessions} sessions; this one is a normal live session.',
  };
}

/// The next session: donor phase until [CheckRule.donorsFirst] candidates exist, then the schedule's next arm
/// (with donors for a replay), then finished. [records]: this kind's randomised sessions so far.
Slot nextSlot({
  required SessionKind kind,
  required Sealed? sealed,
  required List<CheckRecord> records,
  required List<DonorCandidate> candidates,
  required double neededS,
}) {
  final usable = candidates.where((c) => c.runS >= 60).length;
  if (usable < CheckRule.donorsFirst) return Slot(kind: kind, phase: SlotPhase.donor, donorsHave: usable);
  final index = records.length;
  if (sealed == null || index >= sealed.arms.length || index >= CheckRule.maxSessions) {
    return Slot(kind: kind, phase: SlotPhase.finished);
  }
  final arm = sealed.arms[index];
  final used = <String, int>{};
  for (final r in records) {
    for (final d in r.donors) {
      used[d] = (used[d] ?? 0) + 1;
    }
  }
  return Slot(
    kind: kind,
    phase: SlotPhase.randomised,
    index: index,
    arm: arm,
    donors: arm == Arm.replay ? pickDonors(candidates, neededS, used) : const [],
  );
}
