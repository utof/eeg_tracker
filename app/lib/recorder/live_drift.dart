// The drift-off detector during the night (DECISIONS 180-184). It runs in the recorder's own isolate, on each batch
// right after the batch is buffered for the files: the batches already wake the phone, so it adds no wakeup, and it
// needs no forwarding to a screen that is off most of the night. The night recorder wraps every call (any exception
// switches it off with one log line; so does using more than its share of time), so it can never stop a recording.
//
// It places the batches on the clock exactly as the morning's night pass joins the files (sleep/night_signal.dart:
// a pause over 0.5 s between batches, or a new file set, is held at the last value and marked missing), with the
// samples rounded to the files' float32 and clipped like the BDF, so live and morning find the same onset when the
// night is the recorder's own files. Lights off counts from the night's first sample until the night screen's
// Lights off; each tap starts it again on the night's next 30 s epoch (sleep/drift.dart has the same rule).
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/detectors.dart';
import '../detectors/drift_off.dart';
import '../sleep/night_signal.dart' show limitMicrovolts, minGapSeconds, roundHalfEven, sampleRate;
import 'chunk_writer.dart';

/// The marker the night screen's Lights off writes into the night's recording (sleep/drift.dart reads it).
const String lightsOffMarker = 'lights off';

/// What the screen shows of the detector.
class DriftLive {
  const DriftLive({required this.state, this.lightsOffMs, this.onsetMs});
  final DriftState state;

  /// When Lights off was tapped (unix ms); null while it counts from the first sample.
  final int? lightsOffMs;

  /// The first second of the first "probably asleep" run since lights off (unix ms).
  final int? onsetMs;
}

/// The night recorder's view of a live detector, so a test can put a broken one in.
abstract interface class DriftWatch {
  /// One batch as it arrived; [firstOfFile] for the first batch of a new file set.
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false});

  /// Lights off now: the detector starts again from the night's next 30 s epoch.
  void lightsOff(DateTime at);

  /// Marker texts for its moments since the last call (baseline done, drowsy, asleep, awake).
  List<String> takeEvents();

  /// Null before the first sample.
  DriftLive? get live;

  /// Samples seen, holes included.
  int get samples;
}

class LiveDrift implements DriftWatch {
  final Float32List _f32 = Float32List(4);
  final Float64List _row = Float64List(4);
  late final Detectors _det = Detectors(onSecond: _second);

  /// The night's first sample, a whole unix second (night_signal.dart `joinLayout`).
  int? startUnix;

  /// The detector since the last lights off; null before the first sample.
  DriftOff? driftOff;

  double _lastArrival = 0;
  double? _pendingLightsOff;
  int? _lightsOffMs;
  int _nextK = 0;
  final List<String> _events = [];
  DriftState? _shown;
  bool _baselineShown = false;

  @override
  int get samples => _det.n;

  @override
  DriftLive? get live {
    final d = driftOff, start = startUnix;
    if (d == null || start == null) return null;
    final onset = d.onset;
    return DriftLive(state: d.state, lightsOffMs: _lightsOffMs, onsetMs: onset == null ? null : (start + onset) * 1000);
  }

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (rows.isEmpty) return;
    final arr = unixSeconds(arrival);
    final t0 = arr - rows.length / sampleRate; // a batch arrives just after its last sample
    final start = startUnix;
    if (start == null) {
      final s = _wholeSecond(t0);
      startUnix = s;
      final pending = _pendingLightsOff;
      driftOff = DriftOff(pending == null ? 0 : _lightsOffSecond(pending, s));
      final lead = roundHalfEven((t0 - s) * sampleRate);
      for (var i = 0; i < lead; i++) {
        _push(rows.first, missing: true); // before the first run: its first value, as the night pass holds it
      }
    } else if (firstOfFile || t0 - _lastArrival > minGapSeconds) {
      final want = roundHalfEven((t0 - start) * sampleRate);
      if (want > _det.n) _det.hold(want - _det.n);
    }
    _lastArrival = arr;
    for (final s in rows) {
      _push(s);
    }
    // the detectors' own event lists are not needed here; keep the night's memory flat
    if (_det.blinks.length + _det.eyeMoves.length + _det.bursts.length + _det.movement.length > 256) {
      _det.blinks.clear();
      _det.eyeMoves.clear();
      _det.bursts.clear();
      _det.movement.clear();
    }
    if (_det.epochs.length > 256) _det.epochs.clear();
  }

  @override
  void lightsOff(DateTime at) {
    _lightsOffMs = at.millisecondsSinceEpoch;
    final t = unixSeconds(at);
    final start = startUnix;
    if (start == null) {
      _pendingLightsOff = t;
      return;
    }
    // never a second already fed: the epochs must be whole (the next epoch after the newest second at the latest)
    final next = (_nextK + epochS - 1) ~/ epochS * epochS;
    driftOff = DriftOff(math.max(_lightsOffSecond(t, start), next));
    _shown = null;
    _baselineShown = false;
  }

  @override
  List<String> takeEvents() {
    if (_events.isEmpty) return const [];
    final out = List<String>.of(_events);
    _events.clear();
    return out;
  }

  void _push(Sample s, {bool missing = false}) {
    final f = _f32, row = _row;
    f[0] = s.o1;
    f[1] = s.o2;
    f[2] = s.t3;
    f[3] = s.t4;
    for (var c = 0; c < 4; c++) {
      row[c] = (f[c] * 1e6).clamp(-limitMicrovolts, limitMicrovolts); // the files' float32, in µV, as the BDF clips
    }
    _det.push(row, missing: missing);
  }

  void _second(Second s) {
    _nextK = s.k + 1;
    final d = driftOff;
    if (d == null || s.k < d.lightsOff) return;
    final a = s.backAlpha;
    final state = d.second(s.k, a.alpha, a.clean, s.movement, s.sem, s.blinks);
    if (!_baselineShown && d.baselineDone != null) {
      _baselineShown = true;
      _events.add('drift-off: eyes-closed baseline done');
    }
    final was = _shown;
    _shown = state;
    if (was == null || was == state || state == DriftState.baseline) return;
    switch (state) {
      case DriftState.drowsy:
        _events.add('drift-off: drowsy');
      case DriftState.asleep:
        final onset = d.onsets.last.$1;
        _events.add('drift-off: probably asleep, onset ${_clock(startUnix! + onset)}');
      case DriftState.awake:
        if (was != DriftState.baseline) _events.add(was == DriftState.asleep ? 'drift-off: awake again' : 'drift-off: awake');
      case DriftState.baseline:
        break;
    }
  }

  static int _lightsOffSecond(double t, int startUnix) => math.max(0, ((t - startUnix) / epochS).ceil() * epochS);

  /// `datetime.fromtimestamp(t).replace(microsecond=0)`, as night_signal.dart starts a night.
  static int _wholeSecond(double t) {
    var whole = t.floor();
    if (roundHalfEven((t - whole) * 1e6) >= 1000000) whole += 1;
    return whole;
  }

  static String _clock(int unix) {
    final t = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
