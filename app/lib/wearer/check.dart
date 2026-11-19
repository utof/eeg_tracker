// "Was this you?" (DECISIONS rows 370-379): a soft question when a night or a check-in does not look like the
// owner's usual brain signal. The line-by-line port of analysis/wearer_check.py, checked against a fixture made by
// it (analysis/make_wearer_fixture.py, app/test/wearer_cross_check_test.dart):
// - a recording's signal: alpha speed (Hz), alpha strength (log10 µV²) and the 1/f slope at O1 and O2 combined,
//   the morning check-in's own measures (morning/measures.dart); from a check-in's 2 minutes with eyes closed, or
//   from a night's awake 30 s epochs in the 10 minutes after Lights off; a minute of clean signal on both back
//   channels and an alpha peak, or the recording is not checked;
// - the profile: the newest 20 accepted recordings of the same kind; silent until 10 were accepted on 5 days;
// - the distance: the root mean square of the three z-scores, each spread widened by a floor and for the mean's own
//   uncertainty; over 2.5 the recording "does not look like you";
// - a recording joins the profile while learning, when it looked like you, or when you said it was you; never when
//   you said someone else wore the headband.
// Plain Dart: the night pass runs the signal part in a background isolate, the screens the rest.
import 'dart:math' as math;
import 'dart:typed_data';

import '../morning/measures.dart';

const int wearerVersion = 1;
const int wearerFs = 250;
const int _epochS = 30;

const List<String> wearerFeatures = ['iaf', 'alpha', 'slope'];

/// The smallest spread of each number in a profile (planning values, DECISIONS row 373).
const Map<String, double> wearerFloors = {'iaf': 0.25, 'alpha': 0.08, 'slope': 0.10};

const int enrolN = 10;
const int enrolDays = 5;
const int profileMax = 20;
const double wearerThreshold = 2.5;
const double minCleanS = 60.0;
const int nightWindowS = 600;

const String whyLightsOff = 'no lights off';
const String whyClean = 'too little clean signal';
const String whyPeak = 'no alpha peak';

const String kindCheckIn = 'check-in', kindNight = 'night';
const String answerMe = 'me', answerSomeoneElse = 'someone else';

typedef WearerSignal = Map<String, double>;

/// The owner's answer kept in a night report or a check-in result (its `wearer` object: `answer`, `at`), or null.
String? wearerAnswerIn(Map<String, Object?> json) {
  final w = json['wearer'];
  return w is Map && w['answer'] is String ? w['answer'] as String : null;
}

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

double _log10(double v) => math.log(v) / math.ln10;

// ---------------------------------------------------------------- the signal of one recording

/// The three numbers of a check-in result (`<start>.morning.json`), or (null, why).
(WearerSignal?, String?) checkInSignal(Map<String, Object?> m) {
  final ch = m['channels'] is Map ? m['channels']! as Map : const <String, Object?>{};
  for (final n in backChannels) {
    final c = ch[n] is Map ? _num((ch[n] as Map)['clean_s_ec']) : null;
    if (c == null || c < minCleanS) return (null, whyClean);
  }
  final back = m['back'] is Map ? m['back']! as Map : const <String, Object?>{};
  final iaf = _num(back['iaf_hz']), alpha = _num(back['alpha_ec_uv2']), slope = _num(back['aperiodic_slope_ec']);
  if (iaf == null || alpha == null || alpha <= 0 || slope == null) return (null, whyPeak);
  return ({'iaf': iaf, 'alpha': _log10(alpha), 'slope': slope}, null);
}

/// The back channels of a night's first minutes after Lights off: samples from [fromS] seconds after the night's
/// first sample (a multiple of 30 s), and which of them were filled in.
class NightWindow {
  NightWindow(this.fromS, this.o1, this.o2, this.missing);
  final int fromS;
  final Float64List o1, o2;
  final List<bool> missing;
  int get length => math.min(o1.length, o2.length);
}

/// Collects a [NightWindow] while the night pass reads the night sample by sample (extras.dart).
class NightWindowSampler {
  NightWindowSampler(this.fromS);

  /// Lights off (seconds from the night's first sample); null: the night had none, nothing is kept.
  final int? fromS;
  final Float64List _o1 = Float64List(nightWindowS * wearerFs), _o2 = Float64List(nightWindowS * wearerFs);
  final List<bool> _missing = List.filled(nightWindowS * wearerFs, false);
  int _at = 0, _kept = 0;

  /// One row of the night (O1 O2 T3 T4 in µV) and whether it was filled in.
  void push(Float64List row, bool missing) {
    final from = fromS;
    if (from != null && _at >= from * wearerFs && _kept < _o1.length) {
      _o1[_kept] = row[0];
      _o2[_kept] = row[1];
      _missing[_kept] = missing;
      _kept++;
    }
    _at++;
  }

  NightWindow? get window {
    final from = fromS;
    if (from == null) return null;
    return NightWindow(
      from,
      Float64List.sublistView(_o1, 0, _kept),
      Float64List.sublistView(_o2, 0, _kept),
      _missing.sublist(0, _kept),
    );
  }
}

/// The awake epochs, with no filled-in sample, among the 20 from the epoch of Lights off (wearer_check.night_epochs).
List<int> nightEpochs(List<String> stages, NightWindow w) {
  final e0 = w.fromS ~/ _epochS;
  final out = <int>[];
  for (var e = e0; e < math.min(e0 + nightWindowS ~/ _epochS, stages.length); e++) {
    final a = (e - e0) * _epochS * wearerFs, b = (e - e0 + 1) * _epochS * wearerFs;
    if (stages[e] != 'W' || b > w.length) continue;
    var gap = false;
    for (var i = a; i < b && !gap; i++) {
      gap = w.missing[i];
    }
    if (gap) continue;
    out.add(e);
  }
  return out;
}

/// The report's `wearer_signal` object for a night: its first minutes after Lights off ([w], null: no Lights off)
/// under the full-night stages (one per 30 s from the night's first sample), as wearer_check.night_signal.
Map<String, Object?> nightSignal(NightWindow? w, List<String> stages) {
  final info = <String, Object?>{
    'version': wearerVersion,
    'from_s': w?.fromS,
    'epochs': 0,
    'clean_s': null,
    'iaf_hz': null,
    'alpha_uv2': null,
    'slope': null,
    'why': null,
  };
  if (w == null) return info..['why'] = whyLightsOff;
  final eps = nightEpochs(stages, w);
  info['epochs'] = eps.length;
  if (eps.isEmpty) return info..addAll({'clean_s': 0.0, 'why': whyClean});
  final n = eps.length * _epochS * wearerFs;
  final o1 = Float64List(n), o2 = Float64List(n);
  final e0 = w.fromS ~/ _epochS;
  for (final (k, e) in eps.indexed) {
    final a = (e - e0) * _epochS * wearerFs;
    o1.setRange(k * _epochS * wearerFs, (k + 1) * _epochS * wearerFs, w.o1, a);
    o2.setRange(k * _epochS * wearerFs, (k + 1) * _epochS * wearerFs, w.o2, a);
  }
  final ch = {'O1': channelMeasures(o1, null), 'O2': channelMeasures(o2, null)};
  final back = backSummary(ch);
  final clean = math.min(ch['O1']!.cleanSEc, ch['O2']!.cleanSEc);
  info.addAll({
    'clean_s': clean,
    'iaf_hz': back['iaf_hz'],
    'alpha_uv2': back['alpha_ec_uv2'],
    'slope': back['aperiodic_slope_ec'],
  });
  if (clean < minCleanS) return info..['why'] = whyClean;
  final alpha = back['alpha_ec_uv2'];
  if (back['iaf_hz'] == null || alpha == null || alpha <= 0) return info..['why'] = whyPeak;
  return info;
}

/// The three numbers from a night report's `wearer_signal` object, or (null, why); (null, null) when it has none.
(WearerSignal?, String?) reportSignal(Object? ws) {
  if (ws is! Map || ws['version'] != wearerVersion) return (null, null);
  if (ws['why'] is String) return (null, ws['why'] as String);
  final iaf = _num(ws['iaf_hz']), alpha = _num(ws['alpha_uv2']), slope = _num(ws['slope']);
  if (iaf == null || alpha == null || alpha <= 0 || slope == null) return (null, whyPeak);
  return ({'iaf': iaf, 'alpha': _log10(alpha), 'slope': slope}, null);
}

// ---------------------------------------------------------------- the distance

double _mean(List<double> v) => v.fold(0.0, (s, x) => s + x) / v.length;

double _sd(List<double> v) {
  if (v.length < 2) return 0;
  final m = _mean(v);
  return math.sqrt(v.fold(0.0, (s, x) => s + (x - m) * (x - m)) / (v.length - 1));
}

/// Root mean square of the three z-scores of [x] against [profile], and the z-scores.
(double, Map<String, double>) wearerDistance(List<WearerSignal> profile, WearerSignal x) {
  final n = profile.length;
  final z = <String, double>{};
  for (final f in wearerFeatures) {
    final v = [for (final p in profile) p[f]!];
    final sd = _sd(v), floor = wearerFloors[f]!;
    final scale = math.sqrt(sd * sd + floor * floor) * math.sqrt(1 + 1 / n);
    z[f] = (x[f]! - _mean(v)) / scale;
  }
  final sq = wearerFeatures.fold(0.0, (s, f) => s + z[f]! * z[f]!);
  return (math.sqrt(sq / wearerFeatures.length), z);
}

// ---------------------------------------------------------------- judging a history

/// A night (id: its date) or a check-in (id: its file stem), when it began, its day, its signal or why not, and
/// the owner's answer (`me`, `someone else` or null).
class WearerRecording {
  const WearerRecording({
    required this.id,
    required this.kind,
    required this.time,
    required this.day,
    required this.signal,
    this.why,
    this.answer,
  });
  final String id, kind;
  final DateTime time;
  final String day;
  final WearerSignal? signal;
  final String? why, answer;
}

enum WearerState { unchecked, learning, likeYou, notLikeYou }

const Map<WearerState, String> wearerStateName = {
  WearerState.unchecked: 'unchecked',
  WearerState.learning: 'learning',
  WearerState.likeYou: 'like you',
  WearerState.notLikeYou: 'not like you',
};

/// What the check says of one recording: unchecked (why), learning (have of [enrolN], days of [enrolDays]), like
/// you or not (distance, z-scores, the profile's size and means, and the number furthest from it).
class WearerVerdict {
  const WearerVerdict({
    required this.id,
    required this.kind,
    required this.state,
    this.why,
    this.have = 0,
    this.days = 0,
    this.distance,
    this.z = const {},
    this.profileN = 0,
    this.usual = const {},
    this.biggest,
  });
  final String id, kind;
  final WearerState state;
  final String? why;
  final int have, days;
  final double? distance;
  final Map<String, double> z;
  final int profileN;
  final Map<String, double> usual;
  final String? biggest;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'state': wearerStateName[state],
    'why': why,
    'have': have,
    'days': days,
    'distance': distance,
    'z': z.isEmpty ? null : z,
    'profile_n': profileN,
    'usual': usual.isEmpty ? null : usual,
    'biggest': biggest,
  };
}

/// Whether a judged recording joins the profile: while learning unless someone else wore the headband; once it
/// speaks, when it looked like you (unless someone else) or when you said it was you.
bool joinsProfile(WearerState state, String? answer) => switch (state) {
  WearerState.unchecked => false,
  WearerState.learning => answer != answerSomeoneElse,
  WearerState.likeYou => answer != answerSomeoneElse,
  WearerState.notLikeYou => answer == answerMe,
};

/// Every recording in time order (ties by id), each against the profile of the earlier accepted ones of its kind.
List<WearerVerdict> judgeWearer(List<WearerRecording> recordings) {
  final out = <WearerVerdict>[];
  final accepted = <String, List<WearerSignal>>{};
  final days = <String, Set<String>>{};
  final sorted = [...recordings]
    ..sort((a, b) {
      final t = a.time.compareTo(b.time);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
  for (final r in sorted) {
    final acc = accepted.putIfAbsent(r.kind, () => []), dd = days.putIfAbsent(r.kind, () => {});
    final s = r.signal;
    if (s == null) {
      out.add(WearerVerdict(id: r.id, kind: r.kind, state: WearerState.unchecked, why: r.why, have: acc.length, days: dd.length));
      continue;
    }
    if (acc.length < enrolN || dd.length < enrolDays) {
      out.add(WearerVerdict(id: r.id, kind: r.kind, state: WearerState.learning, have: acc.length, days: dd.length));
    } else {
      final prof = acc.length > profileMax ? acc.sublist(acc.length - profileMax) : acc;
      final (d, z) = wearerDistance(prof, s);
      final state = d > wearerThreshold ? WearerState.notLikeYou : WearerState.likeYou;
      var biggest = wearerFeatures.first;
      for (final f in wearerFeatures) {
        if (z[f]!.abs() > z[biggest]!.abs()) biggest = f;
      }
      out.add(WearerVerdict(
        id: r.id,
        kind: r.kind,
        state: state,
        have: acc.length,
        days: dd.length,
        distance: d,
        z: z,
        profileN: prof.length,
        usual: {for (final f in wearerFeatures) f: _mean([for (final p in prof) p[f]!])},
        biggest: biggest,
      ));
    }
    if (joinsProfile(out.last.state, r.answer)) {
      acc.add(s);
      dd.add(r.day);
    }
  }
  return out;
}
