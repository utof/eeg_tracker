// What the night recorder needs from a headband. The BrainBit implementation is in brainbit.dart;
// tests use a fake, so the recorder's rules can be checked without a phone.
import 'chunk_writer.dart';

/// One connected headband. Every call except the streams goes to the vendor SDK.
abstract class Headband {
  String get name;
  String get address;
  String get serial;

  /// dBm seen by the scan before connecting.
  int get rssi;

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
}

/// The phone side of the log: power state and why the last process ended. Optional in tests.
abstract class PhoneProbe {
  /// One line such as `battery-opt exempt yes, power save no, standby bucket 10`, or null.
  Future<String?> powerLine();

  /// Exit records of earlier app processes newer than [sinceMs], one line each.
  Future<List<String>> exitReasons(int sinceMs);
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
  });

  final bool active;
  final int startMs;
  final int samples;
  final int runs;
  final bool contactTried;
  final Map<String, double?> contactOhms;

  /// Samples saved per half hour of clock time: key = unix ms ~/ slotMs (status.dart).
  final Map<int, int> slots;

  NightState copyWith({
    bool? active,
    int? startMs,
    int? samples,
    int? runs,
    bool? contactTried,
    Map<String, double?>? contactOhms,
    Map<int, int>? slots,
  }) => NightState(
    active: active ?? this.active,
    startMs: startMs ?? this.startMs,
    samples: samples ?? this.samples,
    runs: runs ?? this.runs,
    contactTried: contactTried ?? this.contactTried,
    contactOhms: contactOhms ?? this.contactOhms,
    slots: slots ?? this.slots,
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
