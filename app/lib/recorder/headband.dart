// What the night recorder needs from a headband. The BrainBit implementation is in brainbit.dart;
// tests use a fake, so the recorder's rules can be checked without a phone.
import 'battery.dart';
import 'chunk_writer.dart';
import 'packets.dart';

/// What it takes to reach the same headband again without a scan: the SDK's sensor info minus the signal
/// strength. Plain data, kept with the night, so a restarted app process can try it too.
class BandId {
  const BandId({
    required this.name,
    required this.address,
    this.serial = '',
    this.family = '',
    this.model = 0,
    this.pairingRequired = false,
  });

  final String name;

  /// Bluetooth address.
  final String address;
  final String serial;

  /// The SDK's sensor family by name (e.g. `leBrainBitBlack`) and its model number.
  final String family;
  final int model;
  final bool pairingRequired;

  Map<String, Object?> toJson() => {
    'name': name,
    'address': address,
    'serial': serial,
    'family': family,
    'model': model,
    'pairingRequired': pairingRequired,
  };

  /// Null unless [j] has at least a name and an address.
  static BandId? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    final address = j['address'];
    if (name is! String || address is! String || address.isEmpty) return null;
    final serial = j['serial'];
    final family = j['family'];
    final model = j['model'];
    return BandId(
      name: name,
      address: address,
      serial: serial is String ? serial : '',
      family: family is String ? family : '',
      model: model is num ? model.toInt() : 0,
      pairingRequired: j['pairingRequired'] == true,
    );
  }
}

/// One connected headband. Every call except the streams goes to the vendor SDK.
abstract class Headband {
  String get name;
  String get address;
  String get serial;
  BandId get id;

  /// dBm seen by the scan before connecting; null after a direct connection (no scan, no reading).
  int? get rssi;

  /// Batches of samples as they arrive.
  Stream<List<Sample>> get signal;

  /// Contact resistance in ohms per channel (`O1 O2 T3 T4`), infinite when off the head.
  Stream<Map<String, double>> get resistance;

  /// Connection changes: false = out of range. The SDK does not send an initial value.
  Stream<bool> get rangeChanges;

  Future<void> startSignal();
  Future<void> stopSignal();
  Future<void> startResist();
  Future<void> stopResist();
  Future<bool> isInRange();
  Future<int> battery();

  /// Only for a headband that is still in range (the laptop SDK crashed on a lost one).
  Future<void> disconnectAndDispose();
}

abstract class HeadbandFinder {
  /// Fresh scan for up to [scanFor], then a new sensor object for the best headband found, which also
  /// connects. Returns null when none was seen. [onFound] fires between the scan and the connection.
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound});

  /// A new sensor object for the headband [id] without a scan, which connects to its address. Throws when
  /// the SDK cannot reach it (out of range, or it insists on a scan first). Never touches an earlier sensor
  /// object of the same headband: that one may be out of range.
  Future<Headband> connectDirect(BandId id);
}

/// The phone side of the log: power state and why the last process ended. Optional in tests.
abstract class PhoneProbe {
  /// One line such as `battery-opt exempt yes, power save no, standby bucket 10`, or null.
  Future<String?> powerLine();

  /// Exit records of earlier app processes newer than [sinceMs], one line each.
  Future<List<String>> exitReasons(int sinceMs);

  /// The phone's own battery now (level, charge counter, current, charger, temperature), or null.
  Future<PhoneBattery?> battery();
}

/// Night state that must survive the app process being restarted by Android.
class NightState {
  const NightState({
    this.active = false,
    this.startMs = 0,
    this.samples = 0,
    this.runs = 0,
    this.contactTried = false,
    this.contactOhms = const {},
    this.slots = const {},
    this.band,
    this.directPending = false,
    this.directOff = false,
    this.phoneBattery = const BatteryTrack(),
    this.packets = const PacketCounts(),
  });

  final bool active;
  final int startMs;
  final int samples;
  final int runs;
  final bool contactTried;
  final Map<String, double?> contactOhms;

  /// Samples saved per half hour of clock time: key = unix ms ~/ slotMs (status.dart).
  final Map<int, int> slots;

  /// The headband recorded tonight, reconnected without a scan after a drop.
  final BandId? band;

  /// A direct connection was under way when this was saved. Still set when a new process starts means the
  /// old one died inside it (the laptop SDK crashed on reconnects), so the new one scans only.
  final bool directPending;

  /// No more direct connections tonight (see [directPending]).
  final bool directOff;

  /// The phone battery's first and last reading tonight (the end-of-night drain line).
  final BatteryTrack phoneBattery;

  /// Missing and repeated packet numbers tonight, over all runs.
  final PacketCounts packets;

  NightState copyWith({
    bool? active,
    int? startMs,
    int? samples,
    int? runs,
    bool? contactTried,
    Map<String, double?>? contactOhms,
    Map<int, int>? slots,
    BandId? band,
    bool? directPending,
    bool? directOff,
    BatteryTrack? phoneBattery,
    PacketCounts? packets,
  }) => NightState(
    active: active ?? this.active,
    startMs: startMs ?? this.startMs,
    samples: samples ?? this.samples,
    runs: runs ?? this.runs,
    contactTried: contactTried ?? this.contactTried,
    contactOhms: contactOhms ?? this.contactOhms,
    slots: slots ?? this.slots,
    band: band ?? this.band,
    directPending: directPending ?? this.directPending,
    directOff: directOff ?? this.directOff,
    phoneBattery: phoneBattery ?? this.phoneBattery,
    packets: packets ?? this.packets,
  );

  Map<String, Object?> toJson() => {
    'active': active,
    'startMs': startMs,
    'samples': samples,
    'runs': runs,
    'contactTried': contactTried,
    // JSON has no infinity: an infinite (off the head) or missing reading is stored as null.
    'contact': {
      for (final e in contactOhms.entries)
        e.key: e.value == null || e.value!.isInfinite || e.value!.isNaN ? null : e.value,
    },
    'slots': {for (final e in slots.entries) '${e.key}': e.value},
    'band': band?.toJson(),
    'directPending': directPending,
    'directOff': directOff,
    'phoneBattery': phoneBattery.toJson(),
    'packets': packets.toJson(),
  };

  static NightState fromJson(Object? j) {
    if (j is! Map) return const NightState();
    final c = j['contact'];
    final sl = j['slots'];
    return NightState(
      active: j['active'] == true,
      startMs: (j['startMs'] as num?)?.toInt() ?? 0,
      samples: (j['samples'] as num?)?.toInt() ?? 0,
      runs: (j['runs'] as num?)?.toInt() ?? 0,
      contactTried: j['contactTried'] == true,
      contactOhms: c is Map ? {for (final e in c.entries) '${e.key}': (e.value as num?)?.toDouble()} : const {},
      slots: sl is Map
          ? {
              for (final e in sl.entries)
                if (int.tryParse('${e.key}') != null && e.value is num) int.parse('${e.key}'): (e.value as num).toInt(),
            }
          : const {},
      band: BandId.fromJson(j['band']),
      directPending: j['directPending'] == true,
      directOff: j['directOff'] == true,
      phoneBattery: BatteryTrack.fromJson(j['phoneBattery']),
      packets: PacketCounts.fromJson(j['packets']),
    );
  }
}

abstract class NightStore {
  Future<NightState> load();
  Future<void> save(NightState state);
}

class MemoryNightStore implements NightStore {
  NightState state = const NightState();

  @override
  Future<NightState> load() async => state;

  @override
  Future<void> save(NightState s) async => state = s;
}
