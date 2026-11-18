// The BrainBit Black's Bluetooth protocol as our own connection assumes it: every constant and every byte layout
// lives in THIS file, so the probe's result changes one file. A port of scripts/brainbit_ble.py (same names, same
// numbers; app/test/fixtures/own_ble_vectors.json pins both parsers to the same samples).
//
// Sources (facts only, no code copied; BrainBit's binaries were never decompiled, DECISIONS 68):
// - Neiry's `web_sdk_neiry` 1.1.5 on npm (MIT): the service family, the characteristic numbering, the one-byte
//   commands, the status bytes and the 4 + 13 k signal framing;
// - NeuroSDK2's public C header: amplifier mode 5 = SignalResist;
// - our own NeuroSDK2 recordings of this headband: 8 samples per batch, 250 Hz, a packet number that counts
//   samples, the name "BB Black".
// **TO VERIFY** marks what rests on one unconfirmed source or on a guess; the probe (laptop: scripts/ble_probe.py,
// phone: the "Own connection" page) checks each on the owner's headband (docs/own-ble-driver.md).
import 'dart:typed_data';

/// Order of every sample this driver returns and of the `.f32` records.
const List<String> names = ['O1', 'O2', 'T3', 'T4'];

/// Verified: NeuroSDK2 reports 250 Hz for this headband and delivered 250 samples a second.
const int fs = 250;

/// The service is found by this pattern. TO VERIFY the last digit: 7 (npm, "BrainBitBlack") or 9 (one hobby script
/// for the Black); either works.
final RegExp serviceRe = RegExp(r'^7e400001-b534-f393-68a9-e50e24dcca9[0-9a-f]$');

/// Characteristic numbers (the 8th hex digit of the UUID). 2-4: npm. 5 = resistance: TO VERIFY.
const int statusChar = 2, commandChar = 3, signalChar = 4, resistChar = 5;

/// One-byte commands (npm). Power down is never sent.
const int cmdPowerDown = 1, cmdIdle = 2, cmdSignal = 3, cmdResist = 4;

/// TO VERIFY: NeuroSDK2's mode number for SignalResist; not yet sent to our headband.
const int cmdSignalResist = 5;

const Map<int, String> modeNames = {
  cmdIdle: 'idle',
  cmdSignal: 'signal',
  cmdResist: 'resistance',
  cmdSignalResist: 'signal+resistance',
};

/// Signal packet: a uint32 counter first. TO VERIFY little-endian (hobby script).
const int header = 4;

/// One marker byte + 4 channels x 3 bytes (npm).
const int block = 13;

/// TO VERIFY that the counter is a full uint32 (seen above 2.6 million through the SDK).
const int counterMod = 1 << 32;

/// Volts.
const double vref = 2.4;

/// TO VERIFY: gain 6 gives the vendor's +-0.4 V range; one hobby script assumed 12 (half the volts).
const int gain = 6;

/// Wire order of a signal block. TO VERIFY: the one Black script; a Headband script says T3 T4 O1 O2.
const List<String> signalOrder = ['O2', 'T3', 'T4', 'O1'];

/// Wire order of the resistance packet. TO VERIFY, as above.
const List<String> resistOrder = ['O2', 'T3', 'T4', 'O1'];

/// Resistance packet: a uint32 counter, then four uint32 little-endian ohms. TO VERIFY (hobby scripts).
const int resistHeader = 4;

/// TO VERIFY what an electrode without contact reads; taken as infinity.
const int resistOpen = 0xFFFFFFFF;

/// "BB Black": verified (NeuroSDK2 scan of our headband).
const List<String> namePrefixes = ['BB Black', 'BrainBit'];

/// Device Information service (standard) and its characteristics by 16-bit number.
const String deviceInfoService = '180a';
const Map<String, String> deviceInfo = {
  'model': '2a24',
  'serial': '2a25',
  'firmware': '2a26',
  'hardware': '2a27',
  'manufacturer': '2a29',
};

/// No signal for this long: send the start command again; twice as long: reconnect.
const Duration stallAfter = Duration(seconds: 5);

/// Pauses between reconnect attempts; the last one repeats.
const List<Duration> backoff = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
];

/// Read the status (battery) this often while streaming.
const Duration statusEvery = Duration(seconds: 60);

/// A contact check in resistance mode lasts this long (the SDK recorder used 6 s).
const Duration contactFor = Duration(seconds: 6);

/// The signal packet is 108 bytes, so the link must carry 111 (Android starts at 23 until asked). TO VERIFY that
/// the headband grants it.
const int mtuWanted = 517, mtuNeeded = 111;

const String pairingHint =
    'the headband may need pairing: hold its button 4 s until it blinks fast, then try again with pairing on '
    '(pairing never removes other devices)';

String uuid16(String short) => '0000$short-0000-1000-8000-00805f9b34fb';

/// Characteristic [n] of a 7e4000xx service: the 8th hex digit of the first group is n (npm's changeUUID).
String charUuid(String serviceUuid, int n) => '${serviceUuid.substring(0, 7)}$n${serviceUuid.substring(8)}';

bool isBrainBit(String? name) => name != null && name.isNotEmpty && namePrefixes.any(name.startsWith);

/// Where the four channels sit in a packet and how counts become volts. All TO VERIFY by the probe.
class Layout {
  Layout({List<String>? order, List<String>? resistOrder, int? gain})
    : order = List.unmodifiable(order ?? signalOrder),
      resistOrder = List.unmodifiable(resistOrder ?? _resistOrder),
      gain = gain ?? _gain {
    for (final o in [this.order, this.resistOrder]) {
      if (o.length != 4 || !names.every(o.contains)) {
        throw FormatException('channel order must name ${names.join(' ')} once each, got ${o.join(' ')}');
      }
    }
    if (this.gain <= 0) throw const FormatException('gain must be positive');
  }

  final List<String> order;
  final List<String> resistOrder;
  final int gain;

  double get voltsPerCount => vref / (gain * (1 << 23));

  String describe() =>
      'wire order ${order.join(' ')}, resistance order ${resistOrder.join(' ')}, gain $gain '
      '(${(voltsPerCount * 1e6).toStringAsFixed(4)} uV per count); TO VERIFY by the probe';

  Map<String, Object?> toJson() => {'order': order, 'resistOrder': resistOrder, 'gain': gain};

  /// Null unless [j] is a complete, valid layout.
  static Layout? fromJson(Object? j) {
    if (j is! Map) return null;
    final o = j['order'], r = j['resistOrder'], g = j['gain'];
    if (o is! List || r is! List || g is! num) return null;
    try {
      return Layout(order: [for (final x in o) '$x'], resistOrder: [for (final x in r) '$x'], gain: g.toInt());
    } on FormatException {
      return null;
    }
  }
}

const List<String> _resistOrder = resistOrder;
const int _gain = gain;

final Layout defaultLayout = Layout();

/// `'O2,T3,T4,O1'` -> `['O2', 'T3', 'T4', 'O1']`; [Layout] checks it names each channel once.
List<String> parseOrder(String text) => [
  for (final x in text.split(','))
    if (x.trim().isNotEmpty) x.trim().toUpperCase(),
];

/// One sample: the packet number and O1 O2 T3 T4 in volts (one `.f32` record).
typedef BleSample = ({int pack, double o1, double o2, double t3, double t4});

class SignalPacket {
  const SignalPacket(this.counter, this.samples, this.markers, this.counts);
  final int counter;
  final List<BleSample> samples;

  /// First byte of each block: the device's marker / status byte (meaning TO VERIFY).
  final List<int> markers;

  /// Raw signed counts in wire order, for the probe.
  final List<List<int>> counts;
}

/// One signal notification -> its samples. Throws [FormatException] on a length that is not 4 + 13 k bytes.
SignalPacket decodeSignal(Uint8List data, [Layout? layout]) {
  final lay = layout ?? defaultLayout;
  final n = (data.length - header) ~/ block;
  if (data.length < header + block || (data.length - header) % block != 0) {
    throw FormatException('signal packet of ${data.length} bytes (expected 4 + 13 x samples)');
  }
  final counter = data[0] | data[1] << 8 | data[2] << 16 | data[3] << 24;
  final where = [for (final name in names) lay.order.indexOf(name)];
  final scale = lay.voltsPerCount;
  final samples = <BleSample>[];
  final markers = <int>[];
  final counts = <List<int>>[];
  for (var k = 0; k < n; k++) {
    final b = header + block * k;
    markers.add(data[b]);
    final c = List<int>.filled(4, 0);
    for (var j = 0; j < 4; j++) {
      final at = b + 1 + 3 * j;
      final u = data[at] | data[at + 1] << 8 | data[at + 2] << 16;
      c[j] = u >= 0x800000 ? u - 0x1000000 : u; // signed 24-bit, little-endian (TO VERIFY)
    }
    counts.add(c);
    samples.add((
      pack: (counter + k) % counterMod,
      o1: c[where[0]] * scale,
      o2: c[where[1]] * scale,
      t3: c[where[2]] * scale,
      t4: c[where[3]] * scale,
    ));
  }
  return SignalPacket(counter, samples, markers, counts);
}

/// One resistance notification -> ohms per electrode in [names] order (infinity = no contact).
Map<String, double> decodeResist(Uint8List data, [Layout? layout]) {
  final lay = layout ?? defaultLayout;
  if (data.length < resistHeader + 16) {
    throw FormatException('resistance packet of ${data.length} bytes (expected at least 20)');
  }
  final view = ByteData.sublistView(data);
  final got = <String, double>{};
  for (var j = 0; j < 4; j++) {
    final v = view.getUint32(resistHeader + 4 * j, Endian.little);
    got[lay.resistOrder[j]] = v == resistOpen ? double.infinity : v.toDouble();
  }
  return {for (final name in names) name: got[name]!};
}

class BandStatus {
  const BandStatus(this.battery, this.cmdError, this.state, this.raw);

  /// Percent (npm: byte 0). TO VERIFY against the SDK's reading.
  final int battery;

  /// npm: byte 1, signed.
  final int cmdError;

  /// npm: byte 2 "status", signed; meaning TO VERIFY.
  final int state;
  final Uint8List raw;

  String text() => 'battery $battery% command error $cmdError state $state raw ${hex(raw)}';
}

BandStatus decodeStatus(Uint8List data) {
  if (data.length < 3) throw FormatException('status of ${data.length} bytes (expected at least 3)');
  int signed(int b) => b >= 0x80 ? b - 0x100 : b;
  return BandStatus(data[0], signed(data[1]), signed(data[2]), Uint8List.fromList(data));
}

/// Samples missing before a packet: 0 = continuous, > 0 = lost, < 0 = the counter went back (a restarted stream or
/// a repeated packet). Modular, so the 32-bit wrap reads as continuous.
int counterGap(int? expected, int counter) {
  if (expected == null) return 0;
  final d = (counter - expected) % counterMod;
  return d < counterMod ~/ 2 ? d : d - counterMod;
}

String hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Uint8List unhex(String text) =>
    Uint8List.fromList([for (var i = 0; i + 1 < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)]);
