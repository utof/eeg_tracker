// The night extras of the sleep report (ROADMAP row 9, DECISIONS 140-145): what the shared detectors saw over a
// scored night, the rules of analysis/night_extras.py (the Python reference; night_extras_cross_check_test.dart):
// - per 30 s epoch from the first sample: signal quality good / degraded / missing (`g d m`);
// - muscle bursts at T3/T4 by kind (jaw = both sides, one-sided, movement inside) and movements (3+ channels
//   jumping at once), each counted in the epoch where it starts; events after the last whole epoch are dropped;
// - the same per clock hour (the first and last hours partial) and over the asleep epochs inside the sleep
//   periods, with jaw bursts and movements per hour asleep: a trend to compare nights, not a bruxism count (row 65).
// The detectors' pass reads the night's recordings once more, sample by sample (streamed: one 330 KB read at a time), in a
// background isolate while the sleep model runs. Plain Dart: no Flutter.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../detectors/detectors.dart';
import '../recorder/header.dart' show readHeader;
import '../walking/detector.dart' show WalkWindows, walkingEpochs;
import '../wearer/check.dart' show NightWindow, NightWindowSampler;
import 'drift.dart';
import 'night_signal.dart';
import 'periods.dart' show asleepStages;
import 'rem_check.dart';

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
/// spans (first and last second), the drift-off detector from lights off (drift.dart; null with [driftError]
/// when it failed), the back channels of the 10 minutes after a Lights off marker for "Was this you?"
/// ([wearer], wearer/check.dart; null without a marker), and the side-to-side eye movements per epoch for the dream
/// sleep check ([eye], rem_check.dart; null when this pass did not look), and whether each epoch is walking
/// ([walking], walking/detector.dart over every channel the night's recordings share; null when this pass did not
/// look): the scorer scores those epochs awake (DECISIONS 920).
class NightSeen {
  const NightSeen({
    required this.quality,
    required this.bursts,
    required this.moves,
    this.drift,
    this.driftError,
    this.wearer,
    this.eye,
    this.walking,
  });
  final List<EpochQuality> quality;
  final List<Burst> bursts;
  final List<(int, int)> moves;
  final DriftSeen? drift;
  final String? driftError;
  final NightWindow? wearer;
  final EyeSeen? eye;
  final List<bool>? walking;
}

typedef SeeFn = Future<NightSeen?> Function(List<File> recordings);

/// The night's recordings (oldest first) joined on the clock as the sleep model reads them and fed through the
/// detectors, the drift-off detector running from the night's lights off (drift.dart), and the eye-movement counter
/// on the night's eye pair (rem_check.dart: T3-T4 on the BrainBit; read in the same pass), and the walking detector
/// on every channel all the recordings hold (only as far as its veto needs: `quick`); null when there are no samples.
NightSeen? seeNight(List<File> f32Files) {
  final (pair, why) = nightEyePair(f32Files);
  final names = [...channelNames];
  var li = -1, ri = -1;
  if (pair != null) {
    final h = readHeader(f32Files.first);
    int column(String name) {
      final at = h.indexOf(name);
      for (var k = 0; k < channelNames.length; k++) {
        if (h.indexOf(channelNames[k]) == at) return k;
      }
      names.add(name);
      return names.length - 1;
    }

    li = column(pair.leftName);
    ri = column(pair.rightName);
  }
  if (f32Files.isNotEmpty) {
    // the walking detector reads every channel, as the laptop's report: add those not yet read (by their column)
    final h = readHeader(f32Files.first);
    final have = {for (final n in names) h.indexOf(n)};
    for (final name in sharedChannels(f32Files)) {
      if (have.add(h.indexOf(name))) names.add(name);
    }
  }
  final layout = joinLayout(f32Files, names: names);
  if (layout.samples == 0) return null;
  final drift = NightDrift(f32Files, layout.startUnix);
  final det = Detectors(onSecond: drift.second);
  final wearer = NightWindowSampler(drift.markedLightsOffS);
  final eye = pair == null ? null : EyeMoveCounter(sampleRate: sampleRate);
  final walk = WalkWindows(names.length, sampleRate, quick: true);
  final four = Float64List(4);
  final wide = names.length > 4;
  layout.forEachRow((row, missing) {
    final r = wide ? (four..setRange(0, 4, row)) : row;
    det.push(r, missing: missing);
    wearer.push(r, missing);
    eye?.push(row[li], row[ri], missing: missing);
    walk.push(row, missing: missing);
  });
  det.finish();
  return NightSeen(
    quality: [for (final e in det.epochs) e.quality],
    bursts: det.bursts,
    moves: det.movement,
    drift: drift.seen,
    driftError: drift.error,
    wearer: wearer.window,
    eye: eye == null ? EyeSeen.not(why ?? noEyePair) : EyeSeen.measured(pair!.label, eye.finish()),
    walking: walkingEpochs(walk.windows, det.epochs.length),
  );
}

/// The channel names every one of [f32Files] holds, in the first one's order.
List<String> sharedChannels(List<File> f32Files) {
  if (f32Files.isEmpty) return const [];
  final heads = [for (final f in f32Files) readHeader(f)];
  return [
    for (final name in heads.first.names)
      if (heads.every((h) => h.indexOf(name) != null)) name,
  ];
}

/// The eye pair of a night (rem_check.dart [eyePairOf]) by its first recording's header, when every recording holds
/// both channels; else null and why.
(EyePair?, String?) nightEyePair(List<File> f32Files) {
  if (f32Files.isEmpty) return (null, noEyePair);
  final pair = eyePairOf(readHeader(f32Files.first));
  if (pair == null) return (null, noEyePair);
  for (final f in f32Files.skip(1)) {
    final h = readHeader(f);
    if (h.indexOf(pair.leftName) == null || h.indexOf(pair.rightName) == null) {
      return (null, "not measured: the night's recordings do not all hold ${pair.label}");
    }
  }
  return (pair, null);
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
