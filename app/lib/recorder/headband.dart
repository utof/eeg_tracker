// What the night recorder needs from a headband. The BrainBit implementation is in brainbit.dart;
// tests use a fake, so the recorder's rules can be checked without a phone.
import 'battery.dart';
import 'chunk_writer.dart';
import 'header.dart';
import 'packets.dart';
import 'status.dart' show BoardLive;

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

/// One connected headband: BrainBit's SDK (brainbit.dart) or our own connection (headband/own/).
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

/// A line a headband wants in the night's `.log` (our own connection: its drops, reconnects, lost packets), and /
/// or the news that the headband's packet numbers start again (a new stream inside the same connection object).
class BandNote {
  const BandNote(this.line, {this.newStream = false});
  final String? line;
  final bool newStream;
}

/// A headband that has such notes. BrainBit's SDK has none; our own connection does.
abstract class BandNotes {
  /// Notes made before anyone listened are kept and delivered to the first listener.
  Stream<BandNote> get notes;
}

/// A board that is not a BrainBit (the DIY ADS1299 board, headband/diy/): its own channels, and no contact or
/// battery reading. The night recorder skips the contact check and the battery lines for it, never feeds its samples
/// to the drift-off detector or the smart alarm (DECISIONS rows 360-369), writes its [header] beside its files and
/// shows [board] on the night screen.
abstract class OtherBoard {
  BoardLive get board;

  /// What its samples hold: how many channels, which, where, at what rate (header.dart; DECISIONS 630-639).
  RecordingHeader get header;
}

/// What [band]'s samples hold: a board's own header, else the BrainBit's (O1 O2 T3 T4 at 250 Hz).
RecordingHeader headerOf(Headband band) => band is OtherBoard ? (band as OtherBoard).header : brainBitHeader;

/// A headband that mends a drop by itself (our own connection, DECISIONS 213): it sends the start command again on a
/// stall, reconnects to the same address, and says "out of range" once it gives up. The recorder does not restart its
/// stream (that would start the mending over, every 10 s); its own no-data rule stays the backstop.
abstract class MendsDrops {}

/// This connection can reach that headband only through a scan, not directly (BrainBit's SDK and a headband that
/// our own connection reached: its id has no SDK sensor family). The recorder then scans in the same try.
class NeedsScan implements Exception {
  NeedsScan(this.message);
  final String message;

  @override
  String toString() => message;
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
    this.lightsOffMs,
    this.alarmEndMs,
    this.alarmWindowMin,
    this.alarmScoring = false,
    this.alarmOff = false,
    this.recording,
    this.sleepKit = true,
    this.spans = const [],
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

  /// When Lights off was last tapped tonight (unix ms); null until then (DECISIONS 180).
  final int? lightsOffMs;

  /// Tonight's smart alarm (alarm/rule.dart `AlarmPlan`): wake by [alarmEndMs] (unix ms), at the earliest
  /// [alarmWindowMin] minutes before; null without one (DECISIONS 230-236).
  final int? alarmEndMs;
  final int? alarmWindowMin;

  /// The alarm's live sleep model was running when this was saved: a process that finds it set did not end
  /// cleanly while the model ran, so the model stays off for the rest of the night (the phone's alarm stays).
  final bool alarmScoring;

  /// The alarm's live model is done for tonight (it woke you, the window ended, it was switched off, or Alarm off).
  final bool alarmOff;

  /// The recording's id: its first file set's stem (Record first, DECISIONS 882); null until that set opens.
  final String? recording;

  /// The sleep kit is attached (the drift-off detector, the live sleep model, the smart alarm, the sound cues): a
  /// sleep span is open. False for a recording started with Record until Sleep is pressed. A state saved by a build
  /// from before reads as true (every recording was a night).
  final bool sleepKit;

  /// The recording's spans as their file lines (span.dart `Span.toLine`), in order; before the first file set opens
  /// their ids start with `?` and nothing is in the spans file yet.
  final List<Map<String, Object?>> spans;

  /// This state with the sleep kit switched [on] for a new sleep span: Lights off and the alarm start afresh.
  NightState withSleepKit({required bool on, int? alarmEndMs, int? alarmWindowMin}) => NightState(
    active: active,
    startMs: startMs,
    samples: samples,
    runs: runs,
    contactTried: contactTried,
    contactOhms: contactOhms,
    slots: slots,
    band: band,
    directPending: directPending,
    directOff: directOff,
    phoneBattery: phoneBattery,
    packets: packets,
    alarmEndMs: on ? alarmEndMs : null,
    alarmWindowMin: on ? alarmWindowMin : null,
    recording: recording,
    sleepKit: on,
    spans: spans,
  );

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
    int? lightsOffMs,
    int? alarmEndMs,
    int? alarmWindowMin,
    bool? alarmScoring,
    bool? alarmOff,
    String? recording,
    List<Map<String, Object?>>? spans,
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
    lightsOffMs: lightsOffMs ?? this.lightsOffMs,
    alarmEndMs: alarmEndMs ?? this.alarmEndMs,
    alarmWindowMin: alarmWindowMin ?? this.alarmWindowMin,
    alarmScoring: alarmScoring ?? this.alarmScoring,
    alarmOff: alarmOff ?? this.alarmOff,
    recording: recording ?? this.recording,
    sleepKit: sleepKit,
    spans: spans ?? this.spans,
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
    'lightsOffMs': lightsOffMs,
    'alarmEndMs': alarmEndMs,
    'alarmWindowMin': alarmWindowMin,
    'alarmScoring': alarmScoring,
    'alarmOff': alarmOff,
    'recording': recording,
    'sleepKit': sleepKit,
    'spans': spans,
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
      lightsOffMs: (j['lightsOffMs'] as num?)?.toInt(),
      alarmEndMs: (j['alarmEndMs'] as num?)?.toInt(),
      alarmWindowMin: (j['alarmWindowMin'] as num?)?.toInt(),
      alarmScoring: j['alarmScoring'] == true,
      alarmOff: j['alarmOff'] == true,
      recording: j['recording'] is String ? j['recording'] as String : null,
      sleepKit: j['sleepKit'] != false,
      spans: [
        if (j['spans'] case final List<Object?> l)
          for (final x in l)
            if (x is Map) {for (final e in x.entries) '${e.key}': e.value},
      ],
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
