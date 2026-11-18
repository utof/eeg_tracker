// What the recorder isolate tells the screen, about once a second. Plain maps cross the isolate port.
import '../detectors/drift_off.dart' show DriftState;
import 'contact.dart';

enum Phase { idle, searching, connecting, checkingContact, recording, reconnecting, stopping }

const int sampleRateHz = 250;

/// Length of one cell of the night strip: half an hour of clock time.
const int slotMs = 30 * 60 * 1000;

class RecorderStatus {
  const RecorderStatus({
    this.phase = Phase.idle,
    this.nightStartMs = 0,
    this.nightSamples = 0,
    this.lastDataMs,
    this.rssi,
    this.battery,
    this.contactOhms = const {},
    this.runs = 0,
    this.note = '',
    this.slots = const {},
    this.sentMs = 0,
    this.drift,
    this.lightsOffMs,
    this.driftOnsetMs,
  });

  final Phase phase;

  /// When Start was pressed (unix ms); 0 when no night is running.
  final int nightStartMs;

  /// Samples saved this night, all file sets together.
  final int nightSamples;

  /// Arrival time of the newest batch (unix ms).
  final int? lastDataMs;

  /// Signal strength in dBm, as the scan saw it before connecting (the SDK gives no live value).
  final int? rssi;

  /// Headband battery in percent.
  final int? battery;

  /// From the start-of-night contact check; null = no reading or off the head (infinite).
  final Map<String, double?> contactOhms;

  /// File sets written this night (a new one after every drop or restart).
  final int runs;

  /// Last notable event in plain words.
  final String note;

  /// Samples received per half hour of clock time (key = unix ms ~/ 30 min).
  final Map<int, int> slots;

  final int sentMs;

  /// The live drift-off detector's state (live_drift.dart); null while it is off.
  final DriftState? drift;

  /// When Lights off was tapped tonight (unix ms); null while lights off counts from the night's first sample.
  final int? lightsOffMs;

  /// The detector's first "probably asleep" onset since lights off (unix ms).
  final int? driftOnsetMs;

  double get minutesRecorded => nightSamples / sampleRateHz / 60;

  Contact contactOf(String channel) => classifyOhms(contactOhms[channel]);

  bool get hasContact => contactOhms.isNotEmpty;

  RecorderStatus copyWith({
    Phase? phase,
    int? nightStartMs,
    int? nightSamples,
    int? lastDataMs,
    int? rssi,
    int? battery,
    Map<String, double?>? contactOhms,
    int? runs,
    String? note,
    Map<int, int>? slots,
  }) => RecorderStatus(
    phase: phase ?? this.phase,
    nightStartMs: nightStartMs ?? this.nightStartMs,
    nightSamples: nightSamples ?? this.nightSamples,
    lastDataMs: lastDataMs ?? this.lastDataMs,
    rssi: rssi ?? this.rssi,
    battery: battery ?? this.battery,
    contactOhms: contactOhms ?? this.contactOhms,
    runs: runs ?? this.runs,
    note: note ?? this.note,
    slots: slots ?? this.slots,
    sentMs: sentMs,
    drift: drift,
    lightsOffMs: lightsOffMs,
    driftOnsetMs: driftOnsetMs,
  );

  /// The same status with the drift-off fields replaced (null clears them).
  RecorderStatus withDrift({DriftState? drift, int? lightsOffMs, int? onsetMs}) => RecorderStatus(
    phase: phase,
    nightStartMs: nightStartMs,
    nightSamples: nightSamples,
    lastDataMs: lastDataMs,
    rssi: rssi,
    battery: battery,
    contactOhms: contactOhms,
    runs: runs,
    note: note,
    slots: slots,
    sentMs: sentMs,
    drift: drift,
    lightsOffMs: lightsOffMs,
    driftOnsetMs: onsetMs,
  );

  Map<String, Object?> toMap({required int nowMs}) => {
    'kind': 'status',
    'phase': phase.name,
    'nightStartMs': nightStartMs,
    'nightSamples': nightSamples,
    'lastDataMs': lastDataMs,
    'rssi': rssi,
    'battery': battery,
    'contact': [for (final n in channelNames) _finite(contactOhms[n])],
    'contactKnown': contactOhms.isNotEmpty,
    'runs': runs,
    'note': note,
    'slots': [
      for (final e in slots.entries) ...[e.key, e.value],
    ],
    'sentMs': nowMs,
    'drift': drift?.name,
    'lightsOffMs': lightsOffMs,
    'driftOnsetMs': driftOnsetMs,
  };

  /// Parses a message from the recorder; returns null for anything else.
  static RecorderStatus? fromMap(Object? data) {
    if (data is! Map || data['kind'] != 'status') return null;
    final phase = Phase.values.where((p) => p.name == data['phase']).firstOrNull ?? Phase.idle;
    final contact = data['contact'];
    final flat = data['slots'];
    final known = data['contactKnown'] == true && contact is List && contact.length == channelNames.length;
    return RecorderStatus(
      phase: phase,
      nightStartMs: _int(data['nightStartMs']) ?? 0,
      nightSamples: _int(data['nightSamples']) ?? 0,
      lastDataMs: _int(data['lastDataMs']),
      rssi: _int(data['rssi']),
      battery: _int(data['battery']),
      contactOhms: known
          ? {for (var i = 0; i < channelNames.length; i++) channelNames[i]: _double(contact[i])}
          : const {},
      runs: _int(data['runs']) ?? 0,
      note: data['note'] is String ? data['note'] as String : '',
      slots: flat is List && flat.length.isEven
          ? {
              for (var i = 0; i + 1 < flat.length; i += 2)
                if (flat[i] is int && flat[i + 1] is int) flat[i] as int: flat[i + 1] as int,
            }
          : const {},
      sentMs: _int(data['sentMs']) ?? 0,
      drift: DriftState.values.where((d) => d.name == data['drift']).firstOrNull,
      lightsOffMs: _int(data['lightsOffMs']),
      driftOnsetMs: _int(data['driftOnsetMs']),
    );
  }
}

double? _finite(double? v) => v == null || v.isNaN || v.isInfinite ? null : v;
int? _int(Object? v) => v is num ? v.toInt() : null;
double? _double(Object? v) => v is num ? v.toDouble() : null;
