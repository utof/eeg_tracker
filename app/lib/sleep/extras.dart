// The night extras of the sleep report (ROADMAP row 9, DECISIONS 140-145): what the shared detectors saw over a
// scored night, the rules of analysis/night_extras.py (the Python reference; night_extras_cross_check_test.dart):
// - per 30 s epoch from the first sample: signal quality good / degraded / missing (`g d m`);
// - muscle bursts at T3/T4 by kind (jaw = both sides, one-sided, movement inside) and movements (3+ channels
//   jumping at once), each counted in the epoch where it starts; events after the last whole epoch are dropped;
// - the same per clock hour (the first and last hours partial) and over the asleep epochs inside the sleep
//   periods, with jaw bursts and movements per hour asleep: a trend to compare nights, not a bruxism count (row 65).
// The detectors' pass reads the night's recordings once more, sample by sample (a few kilobytes of memory), in a
// background isolate while the sleep model runs. Plain Dart: no Flutter.
import 'dart:io';
import 'dart:isolate';

import '../detectors/detectors.dart';
import 'night_signal.dart';
import 'periods.dart' show asleepStages;

/// Of the report's `extras` object (its own number: the report's `version` covers the whole file).
const int extrasVersion = 1;
const String extrasRules = 'shared detectors, DECISIONS 85-87 (planning values)';
const int _epochS = 30, _hourS = 3600;

const Map<EpochQuality, String> _qualityChar = {
  EpochQuality.good: 'g',
  EpochQuality.degraded: 'd',
  EpochQuality.missing: 'm',
};
const Map<BurstKind, String> _kindKey = {
  BurstKind.jaw: 'jaw_bursts',
  BurstKind.oneSided: 'one_sided_bursts',
  BurstKind.movement: 'movement_bursts',
};

/// What the detectors saw over a night: quality per whole epoch from the first sample, muscle bursts and movement
/// spans (first and last second).
class NightSeen {
  const NightSeen({required this.quality, required this.bursts, required this.moves});
  final List<EpochQuality> quality;
  final List<Burst> bursts;
  final List<(int, int)> moves;
}

typedef SeeFn = Future<NightSeen?> Function(List<File> recordings);

/// The night's recordings (oldest first) joined on the clock as the sleep model reads them and fed through the
/// detectors; null when there are no samples.
NightSeen? seeNight(List<File> f32Files) {
  final layout = joinLayout(f32Files);
  if (layout.samples == 0) return null;
  final det = Detectors();
  layout.forEachRow((row, missing) => det.push(row, missing: missing));
  det.finish();
  return NightSeen(quality: [for (final e in det.epochs) e.quality], bursts: det.bursts, moves: det.movement);
}

Future<NightSeen?> seeInBackground(List<File> recordings) =>
    Isolate.run(() => seeNight(recordings), debugName: 'night-extras');

/// Seconds from a night's first sample (local clock) to the next whole clock hour; 0 on the hour.
int firstEdgeS(DateTime start) {
  final l = start.toLocal();
  return (_hourS - (l.minute * 60 + l.second)) % _hourS;
}

/// [count] per hour over [epochs] 30-s epochs, to 0.1 with halves up, in integers (as the Python reference).
double? perHour(int count, int epochs) => epochs == 0 ? null : ((2 * count * 1200 + epochs) ~/ (2 * epochs)) / 10;

Map<String, Object?> _tally() => {
  'min': 0.0,
  'good_min': 0.0,
  'degraded_min': 0.0,
  'missing_min': 0.0,
  'jaw_bursts': 0,
  'one_sided_bursts': 0,
  'movement_bursts': 0,
  'moves': 0,
};

int _hourOf(int epoch, int firstEdge) {
  final s = epoch * _epochS;
  if (firstEdge == 0) return s ~/ _hourS;
  return s < firstEdge ? 0 : 1 + (s - firstEdge) ~/ _hourS;
}

int _hourFrom(int h, int firstEdge) {
  if (firstEdge == 0) return h * _hourS;
  return h == 0 ? 0 : firstEdge + (h - 1) * _hourS;
}

/// The report's `extras` from what the detectors saw and the night's stages; each hour has `from_s` (seconds from
/// the first sample), the report adds its clock time. [periods]: (first, last) asleep epoch of each sleep period.
Map<String, Object?> nightExtras({
  required List<EpochQuality> quality,
  required List<Burst> bursts,
  required List<(int, int)> moves,
  required List<String> stages,
  required List<(int, int)> periods,
  required int firstEdge,
}) {
  final n = stages.length;
  if (quality.length != n) throw ArgumentError('${quality.length} quality epochs for $n stages');
  final inside = List.filled(n, false);
  for (final (a, b) in periods) {
    inside.fillRange(a, b + 1, true);
  }
  final asleep = [for (var e = 0; e < n; e++) inside[e] && asleepStages.contains(stages[e])];
  final hours = <Map<String, Object?>>[];
  final night = _tally(), sleep = _tally();
  void bump(Map<String, Object?> t, String key, num by) => t[key] = (t[key]! as num) + by;
  for (var e = 0; e < n; e++) {
    final h = _hourOf(e, firstEdge);
    while (hours.length <= h) {
      hours.add({'from_s': _hourFrom(hours.length, firstEdge), ..._tally(), 'asleep_min': 0.0});
    }
    final q = '${quality[e].name}_min';
    for (final t in [hours[h], night, if (asleep[e]) sleep]) {
      bump(t, 'min', 0.5);
      bump(t, q, 0.5);
    }
    if (asleep[e]) bump(hours[h], 'asleep_min', 0.5);
  }
  void add(int second, String key) {
    final e = second ~/ _epochS;
    if (e >= n) return;
    for (final t in [hours[_hourOf(e, firstEdge)], night, if (asleep[e]) sleep]) {
      bump(t, key, 1);
    }
  }

  for (final b in bursts) {
    add(b.start, _kindKey[b.kind]!);
  }
  for (final (a, _) in moves) {
    add(a, 'moves');
  }
  final asleepEpochs = asleep.where((a) => a).length;
  sleep['jaw_per_hour'] = perHour(sleep['jaw_bursts']! as int, asleepEpochs);
  sleep['moves_per_hour'] = perHour(sleep['moves']! as int, asleepEpochs);
  return {
    'version': extrasVersion,
    'rules': extrasRules,
    'validated': false,
    'epoch_s': _epochS,
    'quality': quality.map((q) => _qualityChar[q]).join(),
    'night': night,
    'asleep': sleep,
    'hours': hours,
  };
}

/// Minutes and counts of a stretch of the night (the whole recording, the time asleep, or one hour).
class ExtrasTally {
  ExtrasTally.of(Map<String, dynamic> j)
    : min = (j['min'] as num).toDouble(),
      goodMin = (j['good_min'] as num).toDouble(),
      degradedMin = (j['degraded_min'] as num).toDouble(),
      missingMin = (j['missing_min'] as num).toDouble(),
      jawBursts = (j['jaw_bursts'] as num).toInt(),
      oneSidedBursts = (j['one_sided_bursts'] as num).toInt(),
      movementBursts = (j['movement_bursts'] as num).toInt(),
      moves = (j['moves'] as num).toInt();

  final double min;
  final double goodMin;
  final double degradedMin;
  final double missingMin;
  final int jawBursts;
  final int oneSidedBursts;
  final int movementBursts;
  final int moves;

  /// The share of this stretch read through noise or with no usable channel (0 when empty).
  double get noisyShare => min == 0 ? 0 : (degradedMin + missingMin) / min;
}

/// The time asleep inside the sleep periods, with the rates per hour (null with no sleep).
class ExtrasAsleep extends ExtrasTally {
  ExtrasAsleep.of(super.j)
    : jawPerHour = (j['jaw_per_hour'] as num?)?.toDouble(),
      movesPerHour = (j['moves_per_hour'] as num?)?.toDouble(),
      super.of();

  final double? jawPerHour;
  final double? movesPerHour;
}

class ExtrasHour {
  ExtrasHour(this.start, this.minutes, this.asleepMin, this.tally);
  final DateTime start;
  final double minutes;
  final double asleepMin;
  final ExtrasTally tally;
}

/// A report's `extras` read back; null when missing or damaged (older reports have none).
class NightExtras {
  NightExtras._(this.quality, this.night, this.asleep, this.hours);

  /// Per 30 s epoch from the report's `data_start`; null for a character it does not know.
  final List<EpochQuality?> quality;
  final ExtrasTally night;
  final ExtrasAsleep asleep;
  final List<ExtrasHour> hours;

  static const Map<String, EpochQuality> _fromChar = {
    'g': EpochQuality.good,
    'd': EpochQuality.degraded,
    'm': EpochQuality.missing,
  };

  static NightExtras? read(Object? json, DateTime dataStart) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return NightExtras._(
        [for (final c in (json['quality'] as String).split('')) _fromChar[c]],
        ExtrasTally.of(json['night'] as Map<String, dynamic>),
        ExtrasAsleep.of(json['asleep'] as Map<String, dynamic>),
        [
          for (final h in (json['hours'] as List).cast<Map<String, dynamic>>())
            ExtrasHour(
              dataStart.add(Duration(seconds: (h['from_s'] as num).toInt())),
              (h['min'] as num).toDouble(),
              (h['asleep_min'] as num).toDouble(),
              ExtrasTally.of(h),
            ),
        ],
      );
    } on Object {
      return null;
    }
  }
}
