// The dream sleep (REM) check of a night's report (DECISIONS 740-749). Measurement only: nothing here changes a stage.
// It makes later scoring fixes checkable: on the owner's two phone nights REM came out at 7-10 % of sleep against a
// usual 20-25 %, and the report kept only the stage letters.
//
// A port of analysis/rem_check.py (the Python reference) with the same constants: the same input gives the same
// numbers and the same sentences (rem_check_cross_check_test.dart, fixture made by analysis/make_rem_fixture.py).
// - `probs`: the sleep model's per-epoch probabilities in the report next to `stages`: permille (0-1000) as
//   little-endian uint16, 5 per epoch (W N1 N2 N3 R), epoch-major, base64 ([encodeProbs], [decodeProbs]).
// - The eye-movement detector: side-to-side eye movements from a left-right pair of channels near the eyes taken from
//   the recording's header ([eyePairOf]: T3-T4 on the BrainBit; any count and placement of electrodes), counted per
//   30 s epoch ([EyeMoveCounter], sample by sample). Planning values from the research note of 2026-11-20, not
//   validated.
// - The night's numbers ([remCheck], the report's `rem_check`) and their words ([remCheckLines]).
// Numbers are rounded with integer arithmetic (halves up), as the reference rounds them. Plain Dart: no Flutter.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/filters.dart';
import '../recorder/header.dart';
import 'periods.dart' show asleepStages, gapStage;

/// Of the report's `rem_check` object.
const int remCheckVersion = 1;
const String remCheckRules = 'measurement only; planning values (DECISIONS 740-749)';
const int _epochS = 30;
const List<String> _asleep = ['N1', 'N2', 'N3', 'R'];

// ---- the probabilities in the report ----
const String probOrder = 'W N1 N2 N3 R';
const int probPer = 1000;

/// The eye-movement detector (planning values: the research note's, chosen once on night 11-19 and not tuned).
abstract final class EyeMoveRule {
  /// The pair's signals: 2nd-order Butterworth high-pass and low-pass, forward only from the first value.
  static const double lowHz = 0.5, highHz = 5;

  /// An eye-movement second: left minus right swings more than this peak to peak (µV) while left and right move in
  /// opposite directions (their correlation in that second below [maxR]).
  static const double swingUv = 40, maxR = -0.3;

  /// An epoch where either channel, high-passed at [artefactHpHz], goes past [artefactUv] is not measured.
  static const double artefactHpHz = 0.3, artefactUv = 1500;

  /// An epoch is measured when at least this many of its 30 seconds have no missing sample.
  static const int measuredS = 27;

  /// An epoch with at least this many eye-movement seconds is "dense".
  static const int denseS = 4;
}

/// 10-10 pairs that see side-to-side eye movements, nearest the eyes first (T3 and T4 are T7 and T8).
const List<(String, String)> eyePairs = [
  ('F7', 'F8'),
  ('F9', 'F10'),
  ('AF7', 'AF8'),
  ('FT9', 'FT10'),
  ('FT7', 'FT8'),
  ('T9', 'T10'),
  ('T7', 'T8'),
];

/// Electrodes placed by hand (no 10-10 site in the header, a direction given): a left-right pair whose left one lies
/// within [eyeCornerMax] of the left outer eye corner (polar 105, azimuth -40 degrees: an estimate) and whose right
/// one is within [mirrorMax] of its mirror image.
const List<double> eyeCorner = [-0.621, 0.740, -0.259];
const double eyeCornerMax = 0.6, mirrorMax = 0.2;
const String noEyePair = 'not available on this layout (no left-right pair of electrodes near the eyes)';

/// The words: usual values for adults (textbook; the research note), a red flag and never a target.
const List<int> usualSharePct = [20, 25];
const List<int> usualFirstH = [1, 2];

/// The model's REM likelihood counts as "about" what it scored within this many minutes or this share of it.
const double closeMin = 5, closeShare = 0.15;

const String _digits = '0123456789abcdefghijklmnopqrstu';

int _halfUp(int a, int b) => (2 * a + b) ~/ (2 * b);

double? _share(int a, int b) => b == 0 ? null : _halfUp(1000 * a, b) / 1000;

// ---- probabilities ----

/// A probability as an integer 0-1000, halves up.
int permille(double p) => math.min(probPer, math.max(0, (p * probPer + 0.5).floor()));

/// The report's `probs` from per-epoch probabilities, epochs x 5 (W N1 N2 N3 R) in one list.
Map<String, Object> encodeProbs(List<double> probs) {
  if (probs.length % 5 != 0) throw ArgumentError('five probabilities per epoch (W N1 N2 N3 R)');
  final b = ByteData(probs.length * 2);
  for (var i = 0; i < probs.length; i++) {
    b.setUint16(2 * i, permille(probs[i]), Endian.little);
  }
  return {'order': probOrder, 'per': probPer, 'data': base64Encode(b.buffer.asUint8List())};
}

/// Permille per epoch (W N1 N2 N3 R) from a report's `probs`; null when missing or not one.
List<List<int>>? decodeProbs(Object? json) {
  if (json is! Map || json['order'] != probOrder || json['per'] != probPer || json['data'] is! String) return null;
  final Uint8List raw;
  try {
    raw = base64Decode(json['data'] as String);
  } on FormatException {
    return null;
  }
  if (raw.length % 10 != 0) return null;
  final d = ByteData.sublistView(raw);
  final out = <List<int>>[];
  for (var e = 0; e < raw.length ~/ 10; e++) {
    final row = [for (var k = 0; k < 5; k++) d.getUint16(10 * e + 2 * k, Endian.little)];
    if (row.any((v) => v > probPer)) return null;
    out.add(row);
  }
  return out;
}

// ---- the eye pair ----

/// The left and right channel of the eye-movement detector, by index in the record and name.
class EyePair {
  const EyePair(this.left, this.right, this.leftName, this.rightName);
  final int left;
  final int right;
  final String leftName;
  final String rightName;
  String get label => '$leftName-$rightName';

  @override
  bool operator ==(Object other) =>
      other is EyePair && other.left == left && other.right == right && other.label == label;

  @override
  int get hashCode => Object.hash(left, right, label);

  @override
  String toString() => 'EyePair($label, $left, $right)';
}

double _dist(List<double> a, List<double> b) {
  var s = 0.0;
  for (var k = 0; k < 3; k++) {
    s += (a[k] - b[k]) * (a[k] - b[k]);
  }
  return math.sqrt(s);
}

/// The pair the eye-movement detector reads in a recording with [header], or null ([noEyePair]): the first of
/// [eyePairs] it holds, else two electrodes placed by hand at the eye corners ([eyeCorner]).
EyePair? eyePairOf(RecordingHeader header) {
  for (final (l, r) in eyePairs) {
    final i = header.indexOf(l), j = header.indexOf(r);
    if (i != null && j != null && i != j) return EyePair(i, j, header.channels[i].name, header.channels[j].name);
  }
  final placed = [
    for (var k = 0; k < header.channels.length; k++)
      if (header.channels[k].xyz != null && header.channels[k].site == null) (k, header.channels[k].xyz!),
  ];
  final rightCorner = [-eyeCorner[0], eyeCorner[1], eyeCorner[2]];
  (double, int, int)? best;
  for (final (i, a) in placed) {
    if (a[0] >= 0 || _dist(a, eyeCorner) > eyeCornerMax) continue;
    for (final (j, b) in placed) {
      if (b[0] <= 0 || _dist([-a[0], a[1], a[2]], b) > mirrorMax) continue;
      final d = _dist(a, eyeCorner) + _dist(b, rightCorner);
      if (best == null || d < best.$1) best = (d, i, j);
    }
  }
  if (best == null) return null;
  return EyePair(best.$2, best.$3, header.channels[best.$2].name, header.channels[best.$3].name);
}

// ---- the detector ----

/// Eye-movement seconds per 30 s epoch from the first sample (the stages' epochs), sample by sample: feed each sample
/// of the pair in µV, as the night is joined (held over gaps, [push]'s `missing` set there), then [finish]. An epoch
/// with a gross artefact, or with under [EyeMoveRule.measuredS] seconds free of missing samples, is null (not
/// measured).
class EyeMoveCounter {
  EyeMoveCounter({this.sampleRate = 250, this.trace})
    : _bandL = Chain([highPass(EyeMoveRule.lowHz, sampleRate: sampleRate), lowPass(EyeMoveRule.highHz, sampleRate: sampleRate)]),
      _bandR = Chain([highPass(EyeMoveRule.lowHz, sampleRate: sampleRate), lowPass(EyeMoveRule.highHz, sampleRate: sampleRate)]),
      _hpL = Chain([highPass(EyeMoveRule.artefactHpHz, sampleRate: sampleRate)]),
      _hpR = Chain([highPass(EyeMoveRule.artefactHpHz, sampleRate: sampleRate)]),
      _a = Float64List(sampleRate),
      _b = Float64List(sampleRate);

  final int sampleRate;

  /// For tests: each whole second's swing (µV) and correlation, as the reference's `eye_seconds` gives them.
  final List<(double swing, double r, double big)>? trace;

  final Chain _bandL, _bandR, _hpL, _hpR;
  final Float64List _a, _b;
  int _i = 0;
  bool _gap = false;
  double _big = 0;

  // the epoch under way
  int _seconds = 0, _ok = 0, _moved = 0;
  bool _artefact = false;
  final List<int?> _epochs = [];

  void push(double left, double right, {bool missing = false}) {
    _a[_i] = _bandL.step(left);
    _b[_i] = _bandR.step(right);
    final hl = _hpL.step(left).abs(), hr = _hpR.step(right).abs();
    if (hl > _big) _big = hl;
    if (hr > _big) _big = hr;
    if (missing) _gap = true;
    if (++_i == sampleRate) _second();
  }

  void _second() {
    final n = sampleRate, a = _a, b = _b;
    var lo = double.infinity, hi = double.negativeInfinity, sa = 0.0, sb = 0.0;
    for (var k = 0; k < n; k++) {
      final d = a[k] - b[k];
      if (d < lo) lo = d;
      if (d > hi) hi = d;
      sa += a[k];
      sb += b[k];
    }
    final ma = sa / n, mb = sb / n;
    var sxy = 0.0, sxx = 0.0, syy = 0.0;
    for (var k = 0; k < n; k++) {
      final x = a[k] - ma, y = b[k] - mb;
      sxy += x * y;
      sxx += x * x;
      syy += y * y;
    }
    final swing = hi - lo, r = sxy / math.sqrt(sxx * syy);
    trace?.add((swing, r, _big));
    if (_big > EyeMoveRule.artefactUv) _artefact = true;
    if (!_gap) {
      _ok++;
      if (swing > EyeMoveRule.swingUv && r < EyeMoveRule.maxR) _moved++;
    }
    _i = 0;
    _gap = false;
    _big = 0;
    if (++_seconds == _epochS) {
      _epochs.add(_artefact || _ok < EyeMoveRule.measuredS ? null : _moved);
      _seconds = _ok = _moved = 0;
      _artefact = false;
    }
  }

  /// The whole epochs so far (a partial last second or epoch is left out).
  List<int?> finish() => List.unmodifiable(_epochs);
}

/// One character per epoch: 0-9 then a-u for 10-30 eye-movement seconds, `-` not measured.
String eyeText(List<int?> epochs) => [for (final n in epochs) n == null ? '-' : _digits[n]].join();

List<int?>? eyeFromText(Object? text) {
  if (text is! String) return null;
  final out = <int?>[];
  for (final c in text.split('')) {
    if (c == '-') {
      out.add(null);
    } else {
      final k = _digits.indexOf(c);
      if (k < 0) return null;
      out.add(k);
    }
  }
  return out;
}

/// What [remCheck] takes for a night's eye movements: measured with [pair] (its label), or not, with [why].
class EyeSeen {
  const EyeSeen.measured(String this.pair, this.epochs) : why = null;
  const EyeSeen.not(String this.why) : pair = null, epochs = const [];
  final String? pair;
  final List<int?> epochs;
  final String? why;
}

// ---- the night's numbers ----

/// The report's `rem_check` from the [stages] (W N1 N2 N3 R or gap per 30 s epoch), the sleep [periods] (first and
/// last epoch, inclusive), the model's probabilities in permille ([decodeProbs]; null for a report without them) and
/// the [eye] movements (null for a report from before the check). Only epochs inside the sleep periods count, as the
/// report's totals count them.
Map<String, Object?> remCheck({
  required List<String> stages,
  required List<(int, int)> periods,
  List<List<int>>? probs,
  EyeSeen? eye,
}) {
  final n = stages.length;
  final inside = List.filled(n, false);
  for (final (a, b) in periods) {
    for (var e = math.max(0, a); e <= math.min(n - 1, b); e++) {
      inside[e] = true;
    }
  }
  final asleep = [for (var e = 0; e < n; e++) inside[e] && asleepStages.contains(stages[e])];
  final rem = [for (var e = 0; e < n; e++) inside[e] && stages[e] == 'R'];
  final nAsleep = asleep.where((x) => x).length, nRem = rem.where((x) => x).length;
  double? firstRem;
  List<double>? thirds;
  if (periods.isNotEmpty && nAsleep > 0) {
    final i0 = periods.map((p) => p.$1).reduce(math.min);
    final i1 = math.min(n - 1, periods.map((p) => p.$2).reduce(math.max));
    int? hit;
    for (var e = i0; e < n; e++) {
      if (rem[e]) {
        hit = e;
        break;
      }
    }
    firstRem = hit == null ? null : (hit - i0) / 2;
    final span = i1 - i0 + 1;
    final edge = [for (var t = 0; t < 4; t++) i0 + t * span ~/ 3];
    thirds = [
      for (var t = 0; t < 3; t++) rem.sublist(edge[t], edge[t + 1]).where((x) => x).length / 2,
    ];
  }
  double? prob;
  if (probs != null && probs.length >= n) {
    var mass = 0;
    for (var e = 0; e < n; e++) {
      if (inside[e] && stages[e] != gapStage) mass += probs[e][4];
    }
    prob = _halfUp(mass, 200) / 10; // permille x 0.5 min = mass / 2000 min, to 0.1 min
  }
  return {
    'version': remCheckVersion,
    'rules': remCheckRules,
    'validated': false,
    'asleep_min': nAsleep / 2,
    'rem_min': nRem / 2,
    'rem_share': _share(nRem, nAsleep),
    'first_rem_min': firstRem,
    'thirds_rem_min': thirds,
    'rem_prob_min': prob,
    'eye': eye == null ? null : _eyeNumbers(stages, asleep, eye),
  };
}

Map<String, Object?> _eyeNumbers(List<String> stages, List<bool> asleep, EyeSeen eye) {
  final pair = eye.pair;
  if (pair == null) return {'pair': null, 'why': eye.why ?? noEyePair};
  final n = stages.length;
  final ep = [for (var e = 0; e < n; e++) e < eye.epochs.length ? eye.epochs[e] : null];
  final measured = {for (final s in _asleep) s: 0};
  final seconds = {for (final s in _asleep) s: 0};
  final dense = {for (final s in _asleep) s: 0};
  for (var e = 0; e < n; e++) {
    final v = ep[e];
    if (!asleep[e] || v == null) continue;
    final st = stages[e];
    measured[st] = measured[st]! + 1;
    seconds[st] = seconds[st]! + v;
    if (v >= EyeMoveRule.denseS) dense[st] = dense[st]! + 1;
  }
  final allM = measured.values.reduce((a, b) => a + b), allS = seconds.values.reduce((a, b) => a + b);
  final otherM = allM - measured['R']!, otherS = allS - seconds['R']!;
  return {
    'pair': pair,
    'why': null,
    'epochs': eyeText(ep),
    'measured_min': allM / 2,
    'in_rem_share': _share(seconds['R']!, allS),
    'rem_epoch_share': _share(measured['R']!, allM),
    'rem_per_min': measured['R'] == 0 ? null : _halfUp(20 * seconds['R']!, measured['R']!) / 10,
    'other_per_min': otherM == 0 ? null : _halfUp(20 * otherS, otherM) / 10,
    'dense_share': {
      for (final s in _asleep)
        if (measured[s]! > 0) s: _share(dense[s]!, measured[s]!),
    },
  };
}

// ---- the words ----

/// `43 min`, `2 h 05 min` (halves up), with plain spaces.
String remDuration(double minutes) {
  final total = (minutes + 0.5).floor();
  return total < 60 ? '$total min' : '${total ~/ 60} h ${(total % 60).toString().padLeft(2, '0')} min';
}

int _pct(double share) => (share * 100 + 0.5).floor();

double _num(Object? v) => (v as num).toDouble();

/// The night report's "Dream sleep check" in words, not a score: the sentences analysis/rem_check.py `check_lines`
/// gives for the same check.
List<String> remCheckLines(Map<String, Object?> c) {
  final asleep = _num(c['asleep_min']), rem = _num(c['rem_min']);
  if (asleep == 0) return const ['No sleep was scored, so there is no dream sleep to check.'];
  final lo = usualSharePct[0], hi = usualSharePct[1];
  final pct = _halfUp((rem * 2).round() * 100, (asleep * 2).round());
  final note = pct < lo
      ? "this headband's scorer may under-count it."
      : pct <= hi
      ? 'this night is within it.'
      : 'this night is above it.';
  final out = ['Dream sleep ${remDuration(rem)} ($pct %). Usual for adults is $lo-$hi %; $note'];
  final first = c['first_rem_min'], thirds = c['thirds_rem_min'];
  if (first == null || thirds is! List || thirds.isEmpty) {
    out.add('No dream sleep was scored inside the sleep periods.');
  } else {
    out.add(
      'First dream sleep ${remDuration(_num(first))} after falling asleep (usual: ${usualFirstH[0]}-${usualFirstH[1]} '
      'h). Last third of the night ${remDuration(_num(thirds[2]))}, first third ${remDuration(_num(thirds[0]))}; '
      'usually the last third has the most.',
    );
  }
  final p = c['rem_prob_min'];
  if (p != null) {
    final prob = _num(p);
    final head = "The scorer's own dream-sleep likelihood adds up to ${remDuration(prob)}";
    if ((prob - rem).abs() <= math.max(closeMin, closeShare * rem)) {
      out.add('$head, about the ${remDuration(rem)} it scored: it was seldom unsure, so a different cut-off would add little.');
    } else if (prob > rem) {
      out.add('$head, more than the ${remDuration(rem)} it scored: some stretches were close calls.');
    } else {
      out.add('$head, less than the ${remDuration(rem)} it scored.');
    }
  }
  final eye = c['eye'];
  if (eye is! Map) {
    out.add(
      "This report is older than the check: score the night again to add the scorer's likelihood and the eye "
      'movements.',
    );
  } else if (eye['pair'] == null) {
    out.add('Eye movements: ${eye['why'] ?? noEyePair}.');
  } else if (eye['measured_min'] == null || _num(eye['measured_min']) == 0) {
    out.add('Side-to-side eye movements (${eye['pair']}): no clean stretch of sleep to measure.');
  } else if (eye['rem_per_min'] == null) {
    out.add(
      'Side-to-side eye movements (${eye['pair']}): ${_num(eye['other_per_min']).toStringAsFixed(1)} seconds a minute '
      'with them in sleep; none of the measured sleep was scored as dream sleep.',
    );
  } else {
    out
      ..add(
        'Side-to-side eye movements (${eye['pair']}): ${_pct(_num(eye['in_rem_share'] ?? 0))} % of them fell in dream '
        'sleep, which is ${_pct(_num(eye['rem_epoch_share']))} % of the measured sleep; '
        '${_num(eye['rem_per_min']).toStringAsFixed(1)} seconds a minute with them in dream sleep, '
        '${_num(eye['other_per_min'] ?? 0).toStringAsFixed(1)} in other sleep.',
      )
      ..add(
        'Dream sleep usually holds the most of them: many in light sleep next to dream sleep can mean it was cut '
        'short.',
      );
  }
  return out;
}
