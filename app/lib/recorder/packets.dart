// Packet accounting for the night's `.log` (DECISIONS row 71): how many BrainBit packet numbers were
// missing, repeated, and the longest gap. The headband numbers its samples one by one (one packet = one
// sample, 250 a second), so a gap in the numbers is a gap in samples.
import 'chunk_writer.dart';

/// The packet number is an 11-bit counter (the SDK says "PackNum cannot be more than 2047"), so it
/// wraps from 2047 to 0. Any wrap width that is a power of two from 2048 up gives the same result
/// modulo 2048, so a counter that really wraps later (the number is stored as uint32) is handled too.
const int packetWrap = 2048;

/// A forward step up to this many numbers is a gap (4.1 s at 250 Hz). A "step" beyond it is far more likely
/// the number going backwards (an old number sent again, or batches out of order) than 4 s or more lost, so
/// it counts as a repeat. A real loss that long is still seen in the arrival times (`.idx`) and as a drop.
const int maxGapSamples = packetWrap ~/ 2;

/// What the night's packet numbers showed so far.
class PacketCounts {
  const PacketCounts({this.samples = 0, this.missing = 0, this.gaps = 0, this.repeated = 0, this.longestGap = 0});

  /// Samples compared (every sample but the first of each run).
  final int samples;

  /// Packet numbers skipped, summed over all gaps.
  final int missing;

  /// Number of gaps.
  final int gaps;

  /// Samples whose number was the same as the one before, or older.
  final int repeated;

  /// The most numbers skipped in one gap.
  final int longestGap;

  PacketCounts copyWith({int? samples, int? missing, int? gaps, int? repeated, int? longestGap}) => PacketCounts(
    samples: samples ?? this.samples,
    missing: missing ?? this.missing,
    gaps: gaps ?? this.gaps,
    repeated: repeated ?? this.repeated,
    longestGap: longestGap ?? this.longestGap,
  );

  /// `packets: 7200000 samples, missing 3 in 2 gaps, repeated 1, longest gap 2 samples`
  String logLine() =>
      'packets: $samples samples, missing $missing in $gaps gaps, repeated $repeated, longest gap $longestGap samples';

  Map<String, Object?> toJson() => {
    'samples': samples,
    'missing': missing,
    'gaps': gaps,
    'repeated': repeated,
    'longestGap': longestGap,
  };

  static PacketCounts fromJson(Object? j) {
    if (j is! Map) return const PacketCounts();
    int n(String k) => (j[k] is num && (j[k] as num) >= 0) ? (j[k] as num).toInt() : 0;
    return PacketCounts(
      samples: n('samples'),
      missing: n('missing'),
      gaps: n('gaps'),
      repeated: n('repeated'),
      longestGap: n('longestGap'),
    );
  }
}

/// Compares each sample's packet number with the one before it.
///
/// Each run (one connection of the headband) starts afresh with [startRun]: the first number after a
/// reconnect is not compared with the last number of the run before, because the headband may restart
/// its counter on a new connection and the real gap in time is known from the drop and reconnect lines.
class PacketAccount {
  PacketAccount([this.counts = const PacketCounts()]);

  PacketCounts counts;
  int? _last;

  void startRun() => _last = null;

  void add(List<Sample> rows) {
    var c = counts;
    var last = _last;
    for (final s in rows) {
      final p = s.pack % packetWrap;
      if (last != null) {
        final step = (p - last) % packetWrap; // Dart's % is never negative
        c = c.copyWith(samples: c.samples + 1);
        if (step == 0 || step > maxGapSamples) {
          c = c.copyWith(repeated: c.repeated + 1);
        } else if (step > 1) {
          final lost = step - 1;
          c = c.copyWith(
            missing: c.missing + lost,
            gaps: c.gaps + 1,
            longestGap: lost > c.longestGap ? lost : c.longestGap,
          );
        }
      }
      last = p; // always follow the stream, even after a repeat or a backward step
    }
    _last = last;
    counts = c;
  }
}
