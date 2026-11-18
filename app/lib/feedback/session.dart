// The feedback core: samples in, sound settings and bells out. One listening session. A line-by-line port
// of scripts/web/sound-session.js with the same constants and the same log lines (DECISIONS rows 41-47).
//
// Pure and sample-driven: it never reads a clock. Time is the number of samples received, and every
// decision is taken at fixed steps of 25 samples (0.1 s), so the output depends only on the samples, not on
// how they were chunked or when they arrived. That is what makes a logged session replay bit for bit.
//
// Flow per step: quality per channel -> muscle, blink and drift-to-sleep gates -> alpha against the target
// line (z) -> sound settings (S-curve) -> block-wise line -> bell rule.
//
// Phases: 'cal-open' (30 s eyes open, silent) -> 'cal-closed' (60 s eyes closed, silent) -> 'run';
// without calibration: 'learn' (the first 60 s with eyes closed, neutral sound) -> 'run'.
// Calibration ends only once it has 30 s of clean eyes-closed signal.
//
// Phase, quality, gate and cue names are the JS strings, because they go into the log as they are.
import 'dart:math' as math;
import 'dart:typed_data';

import 'features.dart';
import 'mapping.dart';
import 'reward.dart';
import 'session_log.dart';
import 'sleep_guard.dart';

/// Samples per analysis step.
const int stepSamples = 25;

/// 0.1 s.
const double stepS = stepSamples / fs;

abstract final class Cal {
  static const double openS = 30, closedS = 60, learnS = 60, settleS = 5, minCleanS = 30;
  static final double minRise = log10(1.5);
}

abstract final class Run {
  static const double settleS = 1, holdS = 0.5, peakWinS = 4, primeS = 2;
}

/// Muscle gate: the group's 30-45 Hz power against its resting level, the 20th percentile of its own last
/// 2 minutes (a median would be dragged up by a clench lasting half that time); 2x rest = 0, 10x rest = 1.
abstract final class MuscleGate {
  static const double restS = 120, minS = 8, restPct = 0.2, minX = 2, spanX = 5;
}

/// Blink gate: slow wave on O1/O2 over 40 µV and over 5x its usual size (median of the last minute).
abstract final class BlinkGate {
  static const double minUv = 40, x = 5;
  static const int restS = 60;
}

/// Personal alpha band: peak of the eyes-closed spectrum in 7-13 Hz, standing 2x above the median of 6-14 Hz.
abstract final class Iaf {
  static const double lo = 7, hi = 13, specLo = 6, specHi = 14, minRatio = 2, half = 2, thetaLo = 3;
}

const double _logFloor = 1e-6;
double _log10f(double v) => log10(math.max(_logFloor, v));
double _clamp01(double v) => math.min(1, math.max(0, v));

/// Rounded to 3 decimals the JS way, -0 written as 0.
double? r3(double? v) => v == null ? null : jsRound(v * 1000) / 1000 + 0;
double _mean(List<double> a) => a.fold(0.0, (s, v) => s + v) / a.length;

/// What one analysis step decided.
class StepResult {
  const StepResult({
    required this.n,
    required this.t,
    required this.phase,
    required this.cue,
    required this.silent,
    required this.quality,
    required this.reason,
    required this.veto,
    required this.z,
    required this.jaw,
    required this.backMuscle,
    required this.drowsy,
    required this.targets,
    required this.ring,
    required this.blockEnd,
    required this.alphaX,
    required this.block,
    required this.bands,
    required this.bells,
    required this.note,
    required this.rung,
    required this.lastMinute,
    required this.channels,
  });

  /// Samples received so far, and the same in seconds of signal.
  final int n;
  final double t;
  final String phase;

  /// 'close-eyes' or 'calibration-done' when a calibration phase ends at this step.
  final String? cue;

  /// Calibrating: no bed sound.
  final bool silent;

  /// 'good', 'learning', 'settling' or 'poor'.
  final String quality;
  final String reason;

  /// null, 'muscle', 'blink' or 'drowsy'.
  final String? veto;
  final double? z;
  final double? jaw;
  final double? backMuscle;
  final GuardState? drowsy;
  final Targets targets;
  final bool ring;
  final BlockEnd? blockEnd;

  /// Alpha as a multiple of the line.
  final double? alphaX;
  final int? block;
  final ({List<double> alpha, List<double> theta}) bands;

  /// Whether bells can ring now, in words.
  final String bells;
  final String note;

  /// Bells so far, and in the last minute.
  final int rung;
  final int lastMinute;

  /// 'ok', 'off' or 'noisy' per channel name.
  final Map<String, String> channels;
}

class _Muscle {
  final List<double> hist = [];
  double? rest;
}

class _CalStep {
  const _CalStep(this.clean, this.ok);
  final bool clean;
  final List<bool> ok;
}

class _CalPhase {
  final List<List<double>> raw = [for (final _ in back) <double>[]];
  final List<_CalStep> steps = [];
  List<double>? spec;
  List<double>? specF;
  int specN = 0;
}

class Session {
  Session({this.mode = 'training', this.calibrate = true})
    : log = SessionLog({'mode': mode, 'calibrate': calibrate, 'fs': fs, 'names': channelNames, 'step': stepSamples}) {
    if (!BellRule.gapS.containsKey(mode)) throw ArgumentError.value(mode, 'mode', 'training or relax');
    _makeFilters();
    note = calibrate ? '' : 'calibration skipped: the first minute with eyes closed is your baseline';
    _startPhase(calibrate ? 'cal-open' : 'learn');
  }

  final String mode;
  final bool calibrate;
  final SessionLog log;

  /// Samples received.
  int n = 0;
  int steps = 0;
  Map<String, double?>? _contactOhms;
  final List<Ring> _rings = [for (final _ in channelNames) Ring(fs * 8)];
  ({List<double> alpha, List<double> theta}) bands = (alpha: alphaBand, theta: thetaBand);
  late List<BandPower> _alpha, _theta, _musclePow;
  late List<SlowWave> _slow;
  late List<double> _slowMax;
  final Map<String, _Muscle> _muscle = {'side': _Muscle(), 'back': _Muscle()};
  final List<double> _blinkHist = [];
  List<double> _blinkSecond = [];
  double? _blinkRest;
  double _muscleUntil = -1, _blinkUntil = -1;
  double _settleUntil = Run.settleS * fs;
  int _lastGap = 0;
  String note = '';
  TargetLine? line;
  Bells? _bells;
  SleepGuard? _guard;
  int rung = 0;

  /// The personal alpha peak found by calibration (Hz), or null (none found, or not calibrated yet).
  double? iaf;
  String phase = 'cal-open';
  int _phaseN = 0;
  final Map<String, _CalPhase> _cal = {};
  String _calKind = 'open';

  void _makeFilters() {
    _alpha = [for (final _ in back) BandPower(bands.alpha[0], bands.alpha[1])];
    _theta = [for (final _ in back) BandPower(bands.theta[0], bands.theta[1])];
    _musclePow = [
      for (final _ in channelNames) BandPower(muscleBand[0], muscleBand[1], notch: mains, quadrature: false, tau: 0.25),
    ];
    _slow = [for (final _ in back) SlowWave()];
    _slowMax = [for (final _ in back) 0.0];
  }

  void _startPhase(String p) {
    phase = p;
    _phaseN = n;
    if (p != 'run') {
      final kind = p == 'cal-open' ? 'open' : 'closed';
      _cal[kind] = _CalPhase();
      _calKind = kind;
    }
  }

  // ---- inputs (each one is logged, so a replay can repeat it at the same sample) ----

  /// [rows]: [[O1, O2, T3, T4], ...] in µV. Returns the steps completed by these samples.
  List<StepResult> push(Iterable<List<double>> rows) {
    final out = <StepResult>[];
    for (final r in rows) {
      final row = [fround(r[0]), fround(r[1]), fround(r[2]), fround(r[3])];
      log.sample(row);
      _feed(row);
      if (n % stepSamples == 0) out.add(_step());
    }
    return out;
  }

  /// The stream had a hole (dropped link, reconnect): restart the filters and settle 1 s.
  void gap() {
    log.line({'type': 'gap', 'n': n});
    _makeFilters();
    _guard?.reset();
    _settleUntil = n + Run.settleS * fs;
    _lastGap = n;
  }

  /// Contact per channel: {'O1': ohms, or null = no contact, ...}; null = unknown.
  void contact(Map<String, double?>? c) {
    log.line({'type': 'contact', 'n': n, 'contact': c});
    _contactOhms = c;
  }

  void _feed(List<double> row) {
    for (var c = 0; c < 4; c++) {
      _rings[c].push(row[c]);
      _musclePow[c].step(row[c]);
    }
    for (var b = 0; b < back.length; b++) {
      final v = row[back[b]];
      _alpha[b].step(v);
      _theta[b].step(v);
      _slowMax[b] = math.max(_slowMax[b], _slow[b].step(v).abs());
      if (phase != 'run') _cal[_calKind]!.raw[b].add(v);
    }
    n++;
  }

  bool _noContact(String name) {
    final c = _contactOhms;
    return c != null && c.containsKey(name) && c[name] == null;
  }

  // ---- one analysis step ----

  StepResult _step() {
    steps++;
    final t = n / fs, ph = phase;
    final q = [for (var c = 0; c < 4; c++) channelQuality(_rings[c].last(fs), noContact: _noContact(channelNames[c]))];
    final backOk = [
      for (var b = 0; b < back.length; b++)
        if (q[back[b]] == 'ok') b,
    ];
    final sideOk = [
      for (final c in side)
        if (q[c] == 'ok') c,
    ];
    final jaw = _muscleScore('side', sideOk), backMuscle = _muscleScore('back', [for (final b in backOk) back[b]]);
    final blink = _blinkCheck(backOk);
    if ((jaw ?? 0) > jawBlock || (backMuscle ?? 0) > jawBlock) _muscleUntil = n + Run.holdS * fs;
    if (blink) _blinkUntil = n + Run.holdS * fs;
    final muscleOn = n <= _muscleUntil, blinkOn = n <= _blinkUntil;

    final alphaPow = backOk.isNotEmpty ? _mean([for (final b in backOk) _alpha[b].value]) : null;
    final thetaPow = backOk.isNotEmpty ? _mean([for (final b in backOk) _theta[b].value]) : null;
    final alphaLog = alphaPow == null ? null : _log10f(alphaPow);

    var quality = 'good', reason = '';
    if (backOk.isEmpty) {
      quality = 'poor';
      reason = back.any((c) => q[c] == 'noisy') ? 'Back electrodes (O1, O2) moving' : 'Back electrodes (O1, O2) not touching';
    } else if (n <= _settleUntil) {
      quality = 'settling';
      reason = 'Settling the signal (1 s)';
    } else if (ph != 'run') {
      quality = 'learning';
      reason = _calReason();
    }
    final settled = quality != 'poor' && quality != 'settling';

    if (ph != 'run') {
      _calStep(backOk, settled && !muscleOn && !blinkOn && n - _phaseN >= Cal.settleS * fs);
    }

    String? veto;
    GuardState? drowsy;
    double? z;
    if (ph == 'run' && quality == 'good') {
      final guard = _guard!;
      if (!muscleOn && !blinkOn) {
        drowsy = guard.update(alphaPow!, thetaPow!);
        if (steps % (1 / stepS).round() == 0) guard.peak(_alphaPeak(backOk, Iaf.specLo, Iaf.specHi).hz);
      } else {
        drowsy = guard.state;
      }
      veto = muscleOn
          ? 'muscle'
          : blinkOn
          ? 'blink'
          : drowsy.drowsy
          ? 'drowsy'
          : null;
      z = line!.z(alphaLog!);
      if (veto != null) reason = _vetoReason(veto, jaw, backMuscle);
    }

    final targets = mapState(z: z, jaw: jaw, quality: quality, veto: veto);
    var ring = false;
    BlockEnd? blockEnd;
    if (ph == 'run') {
      final counted = quality == 'good' && veto == null;
      blockEnd = line!.update(counted ? z! > 0 : null, stepS);
      ring = _bells!.update(counted && jaw != null, z != null && z > 0);
      if (ring) rung++;
    }

    final silent = ph == 'cal-open' || ph == 'cal-closed';
    log.line({
      'type': 'step',
      'n': n,
      'q': quality,
      'v': veto,
      'z': r3(z),
      'calm': r3(targets.calm),
      'rough': r3(targets.rough),
      if (silent) 's': 1,
      if (ring) 'ring': 1,
    });
    if (blockEnd != null) log.line({'type': 'block', 'n': n, ..._roundBlock(blockEnd)});
    if (ring) log.line({'type': 'bell', 'n': n, 'z': r3(z)});
    final cue = _advancePhase(); // phase changes take effect from the next sample on
    if (cue != null) log.line({'type': 'cue', 'n': n, 'cue': cue});

    final l = line;
    return StepResult(
      n: n,
      t: t,
      phase: ph,
      cue: cue,
      silent: silent,
      quality: quality,
      reason: reason,
      veto: veto,
      z: z,
      jaw: jaw,
      backMuscle: backMuscle,
      drowsy: drowsy?.copy(),
      targets: targets,
      ring: ring,
      blockEnd: blockEnd,
      alphaX: z == null || l == null ? null : math.pow(10, alphaLog! - l.line).toDouble(),
      block: l?.block,
      bands: bands,
      bells: _bellWords(ph, quality, veto, jaw, sideOk),
      note: note,
      rung: rung,
      lastMinute: _bells?.lastMinute ?? 0,
      channels: {for (var c = 0; c < 4; c++) channelNames[c]: q[c]},
    );
  }

  String? _advancePhase() {
    final inPhase = (n - _phaseN) / fs;
    if (phase == 'cal-open' && inPhase >= Cal.openS) {
      _startPhase('cal-closed');
      return 'close-eyes';
    }
    final minS = phase == 'cal-closed' ? Cal.closedS : Cal.learnS;
    if ((phase == 'cal-closed' || phase == 'learn') && inPhase >= minS && _cleanSteps() * stepS >= Cal.minCleanS) {
      final wasCal = phase == 'cal-closed';
      _finishBaseline();
      return wasCal ? 'calibration-done' : null;
    }
    return null;
  }

  int _cleanSteps() => _cal['closed']!.steps.where((s) => s.clean).length;

  String _calReason() {
    final inPhase = (n - _phaseN) / fs;
    if (phase == 'cal-open') {
      return 'Calibrating: eyes open, look at one spot, jaw loose (${(Cal.openS - inPhase).ceil()} s)';
    }
    final left = (phase == 'learn' ? Cal.learnS : Cal.closedS) - inPhase;
    if (left > 0) {
      return phase == 'learn'
          ? 'Close your eyes. Learning your level (${left.ceil()} s)'
          : 'Calibrating: eyes closed, relax (${left.ceil()} s)';
    }
    return 'Keep your eyes closed: needs ${(Cal.minCleanS - _cleanSteps() * stepS).ceil()} s more clean signal';
  }

  /// Seconds of clean eyes-closed signal still needed before calibration can end (0 when enough).
  double get calibrationCleanLeft =>
      _cal.containsKey('closed') ? math.max(0, Cal.minCleanS - _cleanSteps() * stepS) : Cal.minCleanS;

  // ---- gates ----

  /// [group]: 'side' (T3, T4) or 'back' (O1, O2); [chans]: usable channel indexes. 0 = relaxed, 1 = clenched,
  /// null = unknown.
  double? _muscleScore(String group, List<int> chans) {
    final g = _muscle[group]!;
    if (chans.isEmpty) return null;
    final lp = _log10f(_mean([for (final c in chans) _musclePow[c].value]));
    g.hist.add(lp);
    if (g.hist.length > MuscleGate.restS / stepS) g.hist.removeAt(0);
    if (steps % (1 / stepS).round() == 0 && g.hist.length >= MuscleGate.minS / stepS) {
      g.rest = percentile(g.hist, MuscleGate.restPct);
    }
    final rest = g.rest;
    return rest == null ? null : _clamp01((lp - rest - log10(MuscleGate.minX)) / log10(MuscleGate.spanX));
  }

  bool _blinkCheck(List<int> backOk) {
    final amp = backOk.isNotEmpty ? backOk.map((b) => _slowMax[b]).reduce(math.max) : null;
    _slowMax = [for (final _ in back) 0.0];
    if (amp == null) return false;
    _blinkSecond.add(amp);
    if (_blinkSecond.length >= (1 / stepS).round()) {
      _blinkHist.add(median(_blinkSecond));
      _blinkSecond = [];
      if (_blinkHist.length > BlinkGate.restS) _blinkHist.removeAt(0);
      _blinkRest = median(_blinkHist);
    }
    return amp > math.max(BlinkGate.minUv, BlinkGate.x * (_blinkRest ?? 0));
  }

  /// Alpha peak of the last 4 s (mean spectrum of the usable back channels), or hz null.
  ({double? hz, double ratio, Spectrum? spec}) _alphaPeak(List<int> backOk, double lo, double hi) {
    final k = (Run.peakWinS * fs).toInt();
    if (backOk.isEmpty || n - _lastGap < k) return (hz: null, ratio: 0, spec: null);
    final spec = _meanSpectrum([
      for (final b in backOk) spectrum(_rings[back[b]].last(k), fs, Iaf.specLo, Iaf.specHi),
    ]);
    final p = findPeak(spec, lo, hi);
    return (hz: p.ratio >= Iaf.minRatio ? p.hz : null, ratio: p.ratio, spec: spec);
  }

  // ---- calibration and baseline ----

  void _calStep(List<int> backOk, bool clean) {
    final c = _cal[_calKind]!;
    c.steps.add(_CalStep(clean && backOk.isNotEmpty, [for (var b = 0; b < back.length; b++) backOk.contains(b)]));
    if (_calKind == 'closed' && clean && steps % (1 / stepS).round() == 0) {
      final p = _alphaPeak(backOk, Iaf.lo, Iaf.hi);
      final spec = p.spec;
      if (spec != null && n - _phaseN >= Run.peakWinS * fs) {
        final sum = c.spec;
        c.spec = sum != null ? [for (var i = 0; i < sum.length; i++) sum[i] + spec.p[i]] : [...spec.p];
        c.specF = spec.f;
        c.specN++;
      }
    }
  }

  void _finishBaseline() {
    final closed = _cal['closed']!, open = _cal['open'];
    double? iaf;
    var ratio = 0.0;
    if (closed.specN != 0) {
      final pk = findPeak(Spectrum(closed.specF!, closed.spec!), Iaf.lo, Iaf.hi);
      ratio = pk.ratio;
      if (pk.hz != null && pk.ratio >= Iaf.minRatio) iaf = pk.hz;
    }
    bands = iaf == null
        ? (alpha: alphaBand, theta: thetaBand)
        : (alpha: [iaf - Iaf.half, iaf + Iaf.half], theta: [math.max(Iaf.thetaLo, iaf - 6), iaf - Iaf.half]);

    // the line and the sleep guard's baseline come from the eyes-closed part, re-filtered with the personal band
    final c = _rerun(closed, bands);
    final logs = [
      for (var i = 0; i < c.alpha.length; i++)
        if (c.clean[i]) _log10f(c.alpha[i]),
    ];
    final first = firstLine(logs);
    final gb = guardBaseline(c.alpha, c.theta, c.clean, iaf, stepS);
    double? rise;
    if (open != null) {
      final o = _rerun(open, bands);
      final oLogs = [
        for (var i = 0; i < o.alpha.length; i++)
          if (o.clean[i]) _log10f(o.alpha[i]),
      ];
      if (oLogs.length >= 100) rise = median(logs) - median(oLogs);
    }

    // live filters with the personal band, warmed up on the last 2 s so they start settled
    _makeFilters();
    final prime = (Run.primeS * fs).toInt();
    for (var b = 0; b < back.length; b++) {
      for (final v in _rings[back[b]].last(prime)) {
        _alpha[b].step(v);
        _theta[b].step(v);
        _slow[b].step(v);
      }
    }
    for (var ch = 0; ch < 4; ch++) {
      for (final v in _rings[ch].last(prime)) {
        _musclePow[ch].step(v);
      }
    }

    this.iaf = iaf;
    line = TargetLine(first, stepS);
    _bells = Bells(mode, stepS);
    _guard = SleepGuard(gb, stepS);
    final band = '${_fmt(bands.alpha[0])}-${_fmt(bands.alpha[1])} Hz';
    final peakWords = iaf == null ? 'no clear alpha peak, using $band' : 'your alpha peak ${_fmt(iaf)} Hz, band $band';
    final riseWords = rise == null
        ? ''
        : rise >= Cal.minRise
        ? '; eyes closed gave ${math.pow(10, rise).toStringAsFixed(1)}x eyes-open alpha'
        : '; eyes closed gave only ${math.pow(10, rise).toStringAsFixed(1)}x eyes-open alpha, so the sound may not follow you well';
    note = (calibrate ? 'calibrated: ' : 'baseline from the first minute: ') + peakWords + riseWords;
    log.line({
      'type': 'calibration',
      'n': n,
      'iaf': iaf,
      'peakRatio': r3(ratio),
      'alpha': bands.alpha,
      'theta': bands.theta,
      'line': first.line,
      'sd': first.sd,
      'cleanS': r3(logs.length * stepS),
      'rise': r3(rise),
      'guard': gb.toJson(),
    });
    _startPhase('run');
  }

  String _bellWords(String ph, String quality, String? veto, double? jaw, List<int> sideOk) {
    if (ph != 'run' || quality != 'good') return 'off';
    if (veto != null) return 'paused';
    if (sideOk.isEmpty) return 'paused: side electrodes (T3, T4) not usable, so jaw cannot be checked';
    if (jaw == null) return 'paused: learning your resting jaw';
    return 'on';
  }
}

String _vetoReason(String veto, double? jaw, double? backMuscle) {
  if (veto == 'muscle') {
    return (jaw ?? 0) > jawBlock
        ? 'Jaw tense: bells paused, sound neutral'
        : 'Muscle at the back of the head (neck?): bells paused';
  }
  if (veto == 'blink') return 'Blink or eye movement: paused for a moment';
  return 'Alpha slowed or faded (drifting toward sleep, or eyes open): the sound brightens a little';
}

/// Re-filter one calibration phase with the final bands: per step, mean alpha and theta power of the channels
/// that were usable at that step, and whether the step was clean.
({List<double> alpha, List<double> theta, List<bool> clean}) _rerun(
  _CalPhase ph,
  ({List<double> alpha, List<double> theta}) bands,
) {
  final alpha = <double>[], theta = <double>[], clean = <bool>[];
  final fa = [for (final _ in back) BandPower(bands.alpha[0], bands.alpha[1])];
  final ft = [for (final _ in back) BandPower(bands.theta[0], bands.theta[1])];
  for (var s = 0; s < ph.steps.length; s++) {
    for (var b = 0; b < back.length; b++) {
      final raw = ph.raw[b];
      for (var i = s * stepSamples; i < (s + 1) * stepSamples && i < raw.length; i++) {
        fa[b].step(raw[i]);
        ft[b].step(raw[i]);
      }
    }
    final ok = ph.steps[s].ok;
    final use = [
      for (var b = 0; b < back.length; b++)
        if (ok[b]) b,
    ];
    alpha.add(use.isNotEmpty ? _mean([for (final b in use) fa[b].value]) : 0);
    theta.add(use.isNotEmpty ? _mean([for (final b in use) ft[b].value]) : 0);
    clean.add(ph.steps[s].clean);
  }
  return (alpha: alpha, theta: theta, clean: clean);
}

Spectrum _meanSpectrum(List<Spectrum> specs) => Spectrum(specs[0].f, [
  for (var i = 0; i < specs[0].p.length; i++) _mean([for (final s in specs) s.p[i]]),
]);

Map<String, Object?> _roundBlock(BlockEnd b) => {
  'block': b.block,
  'share': r3(b.share),
  'counted': r3(b.counted),
  'from': b.from,
  'to': b.to,
  'moved': b.moved,
};

String _fmt(double v) => jsNum(jsRound(v * 4) / 4);

/// Feeds a saved session (SessionLog.toJson(), from this app or from the laptop page) through a fresh core
/// as fast as possible, with its gaps and contact changes at the same samples. Returns the new core; its
/// log lines equal the saved lines (exactly when the log came from this engine).
Session replaySession(Map<String, Object?> saved, [int chunk = 37]) {
  final header = saved['header'], lines = saved['lines'];
  if (header is! Map || lines is! List) throw const FormatException('not a session file');
  final mode = header['mode'], calibrate = header['calibrate'];
  if (mode is! String || calibrate is! bool) throw const FormatException('session file: bad header');
  final s = Session(mode: mode, calibrate: calibrate);
  final input = decodeInput(saved['input']), total = input[0].length;
  var pos = 0;
  void feedTo(int end) {
    while (pos < end) {
      final stop = math.min(end, pos + chunk), rows = <List<double>>[];
      for (; pos < stop; pos++) {
        rows.add([for (final ch in input) ch[pos]]);
      }
      s.push(rows);
    }
  }

  for (final e in lines) {
    if (e is! Map || (e['type'] != 'gap' && e['type'] != 'contact')) continue;
    final at = e['n'];
    if (at is! int) throw const FormatException('session file: event without a sample number');
    feedTo(at);
    if (e['type'] == 'gap') {
      s.gap();
    } else {
      s.contact(_contactMap(e['contact']));
    }
  }
  feedTo(total);
  return s;
}

Map<String, double?>? _contactMap(Object? c) {
  if (c is! Map) return null;
  return {
    for (final e in c.entries)
      if (e.key is String) e.key as String: e.value is num ? (e.value as num).toDouble() : null,
  };
}

/// Float32 sample rows of a decoded input, for tests and tools.
List<List<double>> inputRows(List<Float32List> input, int from, int to) => [
  for (var i = from; i < to; i++) [for (final ch in input) ch[i]],
];
