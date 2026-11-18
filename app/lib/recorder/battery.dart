// The phone's own battery in the night's `.log` (DECISIONS row 71): one line a minute while recording, one
// summary line at the end of the night. The numbers come from Android's BatteryManager (PhoneChannel.kt);
// reading them wakes nothing and holds no wake lock.

/// One reading of the phone battery. Any field Android does not report is null.
class PhoneBattery {
  const PhoneBattery({this.percent, this.chargeUah, this.currentUa, this.plugged, this.tempC});

  /// Charge level, 0-100.
  final int? percent;

  /// BATTERY_PROPERTY_CHARGE_COUNTER: charge left in the battery, microampere-hours.
  final int? chargeUah;

  /// BATTERY_PROPERTY_CURRENT_NOW, microamperes. The sign is not the same on every phone (many report
  /// discharge as negative, some as positive), so the summary never uses it.
  final int? currentUa;

  /// `ac`, `usb`, `wireless`, `dock`, or `no`; null when unknown.
  final String? plugged;

  /// Battery temperature in degrees Celsius.
  final double? tempC;

  bool get isPlugged => plugged != null && plugged != 'no';

  /// Reads the map sent by the Kotlin side; null when it carries nothing usable.
  static PhoneBattery? fromMap(Map<Object?, Object?>? m) {
    if (m == null) return null;
    int? i(String k) => m[k] is num ? (m[k]! as num).toInt() : null;
    final temp = m['tempC'];
    final p = m['plugged'];
    final b = PhoneBattery(
      percent: i('percent'),
      chargeUah: i('chargeUah'),
      currentUa: i('currentUa'),
      plugged: p is String ? p : null,
      tempC: temp is num ? temp.toDouble() : null,
    );
    return b.percent == null && b.chargeUah == null && b.currentUa == null ? null : b;
  }

  /// `battery 87% charge 3612345 uAh current -310250 uA unplugged temp 31.2 C`; `?` for what is missing.
  String logLine() =>
      'battery ${percent ?? '?'}% charge ${chargeUah ?? '?'} uAh current ${currentUa ?? '?'} uA '
      '${plugged == null ? 'plugged ?' : (isPlugged ? 'plugged $plugged' : 'unplugged')} '
      'temp ${tempC == null ? '?' : tempC!.toStringAsFixed(1)} C';
}

/// The first and last reading of a night and whether the charger was ever seen, enough for the drain.
/// Kept in the night state, so a restarted app process continues the same night's numbers.
class BatteryTrack {
  const BatteryTrack({this.first, this.firstMs = 0, this.last, this.lastMs = 0, this.pluggedSeen = false});

  final PhoneBattery? first;
  final int firstMs;
  final PhoneBattery? last;
  final int lastMs;
  final bool pluggedSeen;

  BatteryTrack add(PhoneBattery b, int atMs) => BatteryTrack(
    first: first ?? b,
    firstMs: first == null ? atMs : firstMs,
    last: b,
    lastMs: atMs,
    pluggedSeen: pluggedSeen || b.isPlugged,
  );

  /// Under this the numbers are mostly rounding (the level moves in whole percent).
  static const Duration minSpan = Duration(minutes: 20);

  /// The end-of-night line: drain in percent and mAh per hour, from the first to the last reading.
  String summaryLine() {
    final a = first;
    final z = last;
    if (a == null || z == null) return 'phone battery summary: no readings (Android gave no battery numbers)';
    final hours = (lastMs - firstMs) / 3600000;
    if (hours * 60 < minSpan.inMinutes) {
      return 'phone battery summary: only ${(hours * 60).toStringAsFixed(0)} min between readings, too short for a rate';
    }
    final parts = <String>[];
    if (a.percent != null && z.percent != null) {
      final d = a.percent! - z.percent!;
      parts.add('${d.toString()}% in ${hours.toStringAsFixed(1)} h = ${(d / hours).toStringAsFixed(2)} %/h');
    }
    if (a.chargeUah != null && z.chargeUah != null) {
      final mah = (a.chargeUah! - z.chargeUah!) / 1000;
      parts.add('${mah.toStringAsFixed(0)} mAh = ${(mah / hours).toStringAsFixed(0)} mAh/h');
    }
    if (parts.isEmpty) return 'phone battery summary: the readings had neither level nor charge counter';
    final warn = pluggedSeen ? '; a charger was connected at some point, so this is not a pure drain' : '';
    return 'phone battery summary: ${parts.join(', ')}$warn';
  }

  Map<String, Object?> toJson() => {
    'first': first == null ? null : _toJson(first!),
    'firstMs': firstMs,
    'last': last == null ? null : _toJson(last!),
    'lastMs': lastMs,
    'pluggedSeen': pluggedSeen,
  };

  static BatteryTrack fromJson(Object? j) {
    if (j is! Map) return const BatteryTrack();
    return BatteryTrack(
      first: PhoneBattery.fromMap(_map(j['first'])),
      firstMs: (j['firstMs'] as num?)?.toInt() ?? 0,
      last: PhoneBattery.fromMap(_map(j['last'])),
      lastMs: (j['lastMs'] as num?)?.toInt() ?? 0,
      pluggedSeen: j['pluggedSeen'] == true,
    );
  }

  static Map<String, Object?> _toJson(PhoneBattery b) => {
    'percent': b.percent,
    'chargeUah': b.chargeUah,
    'currentUa': b.currentUa,
    'plugged': b.plugged,
    'tempC': b.tempC,
  };

  static Map<Object?, Object?>? _map(Object? o) => o is Map ? Map<Object?, Object?>.from(o) : null;
}
