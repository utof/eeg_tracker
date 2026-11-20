// Electrode contact: the BrainBit's channel names and the `contact ohms` log line. The words (good, ok, poor, none) and
// their limits are the one judge's (signal/quality.dart, DECISIONS 850).
export '../signal/quality.dart' show Contact, classifyOhms, QualityVerdict;

/// BrainBit channel names, in the order the headband sends them.
const List<String> channelNames = ['O1', 'O2', 'T3', 'T4'];

/// `O1=123456 O2=inf ...` as in the laptop's `contact ohms` log line.
String ohmsLine(Map<String, double?> ohms) => channelNames
    .map((n) {
      final v = ohms[n];
      final s = v == null || v.isNaN ? 'none' : (v.isInfinite ? 'inf' : v.round().toString());
      return '$n=$s';
    })
    .join(' ');
