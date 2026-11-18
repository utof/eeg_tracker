// When you fell asleep after lights off, by the drift-off detector (DECISIONS 62, 88) and by the sleep model: the
// sleep report's `drift_off` and the running check toward "within 5 minutes on 4 of 5 nights" (DECISIONS 180-184).
// The rules of analysis/night_drift.py (the Python reference; scripts/sleep_report.py writes the same fields):
// - lights off: the latest lights-off marker of the night's recordings (the night screen's Lights off, the dream
//   catcher's, a fall-asleep sound session's quiet minute), else the night's first sample ("night start");
// - it lands on the next of the night's 30 s epochs (the sleep model's), so both count the same epochs;
// - the detector runs over the night from there (the night pass in extras.dart); the sleep model's onset is the
//   first of 10 epochs in a row not scored awake, missing epochs skipped (analysis/validate_detectors.py);
// - they agree when the two onsets are at most 5 minutes apart, disagree when only one found sleep; a night counts
//   toward the check when lights off was given (not the night start) and at least one of them found sleep.
// Plain Dart: the night pass runs it in a background isolate, the screens read the report.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../detectors/detectors.dart' show Second;
import '../detectors/drift_off.dart';
import 'periods.dart' show gapStage;
import 'report.dart' show SleepReport, isoLocal;

/// Of the report's `drift_off` object.
const int driftVersion = 1;
const String driftRules =
    'drift-off detector (DECISIONS 88, planning values) from lights off against the sleep model\'s first 10 '
    'epochs in a row not scored awake; they agree within 5 min';

/// The sleep model's onset: this many epochs in a row not scored awake.
const int modelOnsetRun = 10;
const double agreeMin = 5;

/// The check (DECISIONS 62): agreement on [checkNeeded] of the newest [checkNights] counted nights.
const int checkNights = 5, checkNeeded = 4;

const int _epochS = 30;

/// The marker the night screen's Lights off writes into the night's recording.
const String lightsOffMarker = 'lights off';

enum LightsOffFrom { button, dreamCatcher, sound, nightStart }

const Map<LightsOffFrom, String> lightsOffName = {
  LightsOffFrom.button: 'button',
  LightsOffFrom.dreamCatcher: 'dream catcher',
  LightsOffFrom.sound: 'sound',
  LightsOffFrom.nightStart: 'night start',
};

/// The app's marker texts that mean lights off; null for any other marker.
LightsOffFrom? lightsOffFrom(String text) {
  if (text == lightsOffMarker) return LightsOffFrom.button;
  if (text.startsWith('dream catcher: lights off')) return LightsOffFrom.dreamCatcher;
  if (text == 'sound: quiet minute (eyes closed)') return LightsOffFrom.sound;
  return null;
}

typedef LightsOff = ({double t, LightsOffFrom from});

/// The latest lights-off marker (by its unix time `t`) in the `.markers.jsonl` files beside [f32Files]; null when
/// there is none. Lines that are not markers are skipped, as the laptop skips them.
LightsOff? lightsOffIn(List<File> f32Files) {
  LightsOff? best;
  for (final f in f32Files) {
    final mf = File(f.path.replaceFirst(RegExp(r'\.f32$'), '.markers.jsonl'));
    if (!mf.existsSync()) continue;
    for (final line in mf.readAsLinesSync()) {
      Object? m;
      try {
        m = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (m is! Map || m['t'] is! num || m['text'] is! String) continue;
      final from = lightsOffFrom(m['text'] as String);
      final t = (m['t'] as num).toDouble();
      if (from != null && t.isFinite && (best == null || t >= best.t)) best = (t: t, from: from);
    }
  }
  return best;
}

/// The second (counted from the night's first sample, [startUnix]) the detector starts at: lights off at unix time
/// [t] rounded up to the night's 30 s epochs, 0 when it came before the first sample.
int lightsOffSecond(double t, int startUnix) => math.max(0, ((t - startUnix) / _epochS).ceil() * _epochS);

/// The sleep model's onset: the first epoch at or after [from] of [run] epochs in a row not scored awake, missing
/// (`gap`) epochs skipped; null when there is none.
int? modelOnset(List<String> stages, int from, {int run = modelOnsetRun}) {
  final scored = [
    for (var i = math.max(0, from); i < stages.length; i++)
      if (stages[i] != gapStage) i,
  ];
  var inRow = 0;
  for (var j = 0; j < scored.length; j++) {
    inRow = stages[scored[j]] == 'W' ? 0 : inRow + 1;
    if (inRow == run) return scored[j - run + 1];
  }
  return null;
}

/// What the detector saw over a night from lights off; seconds from the night's first sample.
class DriftSeen {
  const DriftSeen({
    required this.lightsOffS,
    required this.from,
    this.tapped,
    this.baselineS,
    this.drowsyS,
    this.onsetS,
    this.knownS,
    this.epochs = '',
  });

  final int lightsOffS;
  final LightsOffFrom from;

  /// Unix time of the lights-off marker; null for the night start.
  final double? tapped;

  /// When the 60 clean seconds were complete, drowsy was first known, the first "probably asleep" run began and
  /// when it was known.
  final int? baselineS;
  final int? drowsyS;
  final int? onsetS;
  final int? knownS;

  /// The detector's state after each epoch from lights off: b (learning the baseline), a, d, s, or - (skipped).
  final String epochs;
}

/// The detector's state after each epoch (b a d s, - for a skipped one), as the dream catcher's session keeps it.
String driftEpochs(DriftOff d) => [
  for (final e in d.epochs)
    e.faded == null
        ? (e.state == DriftState.baseline ? 'b' : '-')
        : switch (e.state) {
            DriftState.baseline => 'b',
            DriftState.awake => 'a',
            DriftState.drowsy => 'd',
            DriftState.asleep => 's',
          },
].join();

/// The detector in the night pass: fed every whole second (Detectors.onSecond) and running from lights off. Its
/// own failure is kept as [error] and never stops the pass (the extras go on without it).
class NightDrift {
  NightDrift(List<File> f32Files, int startUnix) {
    try {
      final lo = lightsOffIn(f32Files);
      _lightsOff = lo;
      final k = lo == null ? 0 : lightsOffSecond(lo.t, startUnix);
      _d = DriftOff(k);
    } on Object catch (e) {
      error = '$e';
    }
  }

  LightsOff? _lightsOff;
  DriftOff? _d;
  String? error;

  void second(Second s) {
    final d = _d;
    if (d == null || s.k < d.lightsOff) return;
    try {
      final a = s.backAlpha;
      d.second(s.k, a.alpha, a.clean, s.movement, s.sem, s.blinks);
    } on Object catch (e) {
      error = '$e';
      _d = null;
    }
  }

  /// Null when it failed ([error] says why).
  DriftSeen? get seen {
    final d = _d;
    if (d == null) return null;
    final lo = _lightsOff;
    return DriftSeen(
      lightsOffS: d.lightsOff,
      from: lo?.from ?? LightsOffFrom.nightStart,
      tapped: lo?.t,
      baselineS: d.baselineDone,
      drowsyS: d.drowsyAt,
      onsetS: d.onset,
      knownS: d.asleepAt,
      epochs: driftEpochs(d),
    );
  }
}

/// The report's `drift_off` from what the detector saw and the night's stages (per 30 s from [start], the night's
/// first sample).
Map<String, Object?> driftReport(DriftSeen s, List<String> stages, DateTime start) {
  final lo = s.lightsOffS;
  final ref = modelOnset(stages, lo ~/ _epochS);
  final modelS = ref == null ? null : ref * _epochS;
  double? after(int? k) => k == null ? null : (k - lo) / 60;
  String? at(int? k) => k == null ? null : isoLocal(start.add(Duration(seconds: k)));
  final on = after(s.onsetS), model = after(modelS);
  final diff = on != null && model != null ? on - model : null;
  final bool? agree = on == null && model == null ? null : diff != null && diff.abs() <= agreeMin;
  final tapped = s.tapped;
  return {
    'version': driftVersion,
    'rules': driftRules,
    'validated': false,
    'lights_off': at(lo),
    'lights_off_s': lo,
    'source': lightsOffName[s.from],
    'tapped': tapped == null ? null : isoLocal(DateTime.fromMicrosecondsSinceEpoch((tapped * 1e6).round())),
    'baseline_s': s.baselineS,
    'drowsy_s': s.drowsyS,
    'onset_s': s.onsetS,
    'known_s': s.knownS,
    'model_onset_s': modelS,
    'onset': at(s.onsetS),
    'model_onset': at(modelS),
    'onset_min': on,
    'model_onset_min': model,
    'diff_min': diff,
    'agree': agree,
    'counted': s.from != LightsOffFrom.nightStart && agree != null,
    'epochs': s.epochs,
  };
}

/// A report's `drift_off` read back; null when missing or damaged (reports from before it have none).
class DriftResult {
  const DriftResult({
    required this.lightsOff,
    required this.from,
    required this.agree,
    required this.counted,
    this.onset,
    this.modelOnset,
    this.onsetMin,
    this.modelOnsetMin,
    this.diffMin,
  });

  final DateTime lightsOff;
  final LightsOffFrom from;
  final DateTime? onset;
  final DateTime? modelOnset;
  final double? onsetMin;
  final double? modelOnsetMin;
  final double? diffMin;

  /// Null: neither found sleep after lights off.
  final bool? agree;
  final bool counted;

  static DriftResult? read(Object? json) {
    if (json is! Map) return null;
    try {
      DateTime? time(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
      double? number(Object? v) => (v as num?)?.toDouble();
      final from = lightsOffName.entries.where((e) => e.value == json['source']).firstOrNull?.key;
      if (from == null) return null;
      return DriftResult(
        lightsOff: time(json['lights_off'])!,
        from: from,
        onset: time(json['onset']),
        modelOnset: time(json['model_onset']),
        onsetMin: number(json['onset_min']),
        modelOnsetMin: number(json['model_onset_min']),
        diffMin: number(json['diff_min']),
        agree: json['agree'] as bool?,
        counted: json['counted'] == true,
      );
    } on Object {
      return null;
    }
  }
}

/// How the detector is doing against the sleep model: [agree] of the newest [nights] counted nights (at most 5).
class DriftCheck {
  const DriftCheck(this.agree, this.nights);
  final int agree;
  final int nights;

  /// Five counted nights exist.
  bool get decided => nights >= checkNights;

  /// 4 of the newest 5 agree: the detector can be trusted (DECISIONS 62).
  bool get trusted => decided && agree >= checkNeeded;
}

/// The check over [reports]: the newest 5 nights that count (lights off given, sleep found by either).
DriftCheck driftCheck(Iterable<SleepReport> reports) {
  final counted = [
    for (final r in reports)
      if (r.json['drift_off'] case final Map<String, dynamic> d when d['counted'] == true) (r.nightOf, d['agree'] == true),
  ]..sort((a, b) => b.$1.compareTo(a.$1));
  final newest = counted.take(checkNights).toList();
  return DriftCheck(newest.where((n) => n.$2).length, newest.length);
}
