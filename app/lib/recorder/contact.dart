// Electrode contact from the start-of-night resistance check.

/// BrainBit channel names, in the order the headband sends them.
const List<String> channelNames = ['O1', 'O2', 'T3', 'T4'];

enum Contact { good, fair, poor, none }

/// Planning assumption, NOT a measured limit (DECISIONS row 20): dry electrodes at or below 1 MΩ are
/// "good", up to 2.5 MΩ "fair" (BrainBit's README gives 2.5 as the upper limit, unit garbled), above that
/// "poor". Infinity (headband off the head) or no reading is "none". Recalibrate from the owner's nights.
const double goodMaxOhms = 1e6;
const double fairMaxOhms = 2.5e6;

Contact classifyOhms(double? ohms) {
  if (ohms == null || ohms.isNaN || ohms.isInfinite || ohms < 0) return Contact.none;
  if (ohms <= goodMaxOhms) return Contact.good;
  if (ohms <= fairMaxOhms) return Contact.fair;
  return Contact.poor;
}

/// `O1=123456 O2=inf ...` as in the laptop's `contact ohms` log line.
String ohmsLine(Map<String, double?> ohms) => channelNames
    .map((n) {
      final v = ohms[n];
      final s = v == null || v.isNaN ? 'none' : (v.isInfinite ? 'inf' : v.round().toString());
      return '$n=$s';
    })
    .join(' ');
