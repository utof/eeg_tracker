// Measurements for the Battery and Usage pages (DECISIONS 715), one JSON line each in
// `files/logs/metrics-<day>-<engine>.jsonl` (`kind`):
//
//   power    the phone's battery (level, charge counter, current, charger, temperature, voltage), the screen, Doze,
//            the process's CPU time and memory, the features on in this engine (`on`), why it was taken (`why`), and
//            the headband when this engine holds one (`band`: battery, signal strength, contact per channel)
//   frames   frame timings of one screen over a minute: frames, slow (over 17 ms), janky (over 33 ms), the worst
//   startup  from the process's start and from main() to the first frame
//   storage  the bytes of each folder of the app's files, once a day
//
// The power sampler reads every 2 minutes while the app is open with nothing running, every minute while a feature
// runs, and 3 seconds after a feature starts or stops (so each stretch is measured with what was really on). It
// runs only while its engine works: the screen's while the app is open or a session runs, the night's service during
// a night. A read is two BatteryManager calls and a sticky intent (PhoneChannel.kt): nothing wakes, nothing is held.
import 'dart:async';
import 'dart:io';

import 'activity.dart';
import 'files.dart';
import 'log.dart';

/// The phone's power numbers as PhoneChannel.kt `battery` sends them; any may be missing.
class PowerReading {
  const PowerReading({
    this.percent,
    this.chargeUah,
    this.currentUa,
    this.plugged,
    this.tempC,
    this.voltageMv,
    this.screenOn,
    this.doze,
    this.cpuMs,
  });

  final int? percent, chargeUah, currentUa, voltageMv, cpuMs;
  final String? plugged;
  final double? tempC;
  final bool? screenOn, doze;

  static PowerReading? fromMap(Map<Object?, Object?>? m) {
    if (m == null) return null;
    int? i(String k) => m[k] is num ? (m[k]! as num).toInt() : null;
    bool? b(String k) => m[k] is bool ? m[k]! as bool : null;
    final temp = m['tempC'], plug = m['plugged'];
    return PowerReading(
      percent: i('percent'),
      chargeUah: i('chargeUah'),
      currentUa: i('currentUa'),
      plugged: plug is String ? plug : null,
      tempC: temp is num ? temp.toDouble() : null,
      voltageMv: i('voltageMv'),
      screenOn: b('screenOn'),
      doze: b('idle'),
      cpuMs: i('cpuMs'),
    );
  }

  Map<String, Object?> toLine() => {
    if (percent != null) 'pct': percent,
    if (chargeUah != null) 'uah': chargeUah,
    if (currentUa != null) 'ua': currentUa,
    if (plugged != null) 'plug': plugged,
    if (tempC != null) 'temp': tempC,
    if (voltageMv != null) 'mv': voltageMv,
    if (screenOn != null) 'screen': screenOn,
    if (doze != null) 'doze': doze,
    if (cpuMs != null) 'cpu': cpuMs,
  };
}

abstract final class Metrics {
  /// The headband this engine holds, for the power samples: `battery` (%), `rssi` (dBm), `ohms` (per channel), `name`.
  /// Set by whoever holds it (the night recorder), back to null when it lets go.
  static Map<String, Object?>? Function()? band;

  static void write(Map<String, Object?> line) => Logs.current?.write(LogKind.metrics, line);
}

class PowerSampler {
  PowerSampler({
    required this.read,
    this.idleEvery = const Duration(minutes: 2),
    this.busyEvery = const Duration(minutes: 1),
    this.settle = const Duration(seconds: 3),
    bool Function()? enabled,
    int Function()? rss,
    void Function(Map<String, Object?> line)? write,
  }) : _enabled = enabled ?? (() => Logs.current?.settings.battery ?? true),
       _rss = rss ?? processRss,
       _write = write ?? Metrics.write;

  /// PhoneChannel's `battery` (Phone.powerMap on the phone, a fake in tests).
  final Future<Map<Object?, Object?>?> Function() read;
  final Duration idleEvery, busyEvery, settle;
  final bool Function() _enabled;
  final int Function() _rss;
  final void Function(Map<String, Object?> line) _write;

  Timer? _timer, _soon;
  bool _running = false;
  int taken = 0;

  bool get running => _running;

  /// Every minute while anything but the open app runs, else every 2.
  Duration get every => Activity.active.any((f) => f != 'app-open') ? busyEvery : idleEvery;

  void start() {
    if (_running) return;
    _running = true;
    Activity.listen(_changed);
    unawaited(sample('start'));
    _schedule();
  }

  /// A last sample (with what is on now), then no more.
  Future<void> stop({String why = 'stop'}) async {
    if (!_running) return;
    _running = false;
    Activity.unlisten(_changed);
    _timer?.cancel();
    _soon?.cancel();
    _timer = _soon = null;
    await sample(why);
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => unawaited(sample('every')));
  }

  void _changed(String feature, bool on, Duration? lasted) {
    if (!_running) return;
    _soon ??= Timer(settle, () {
      _soon = null;
      if (!_running) return;
      _schedule();
      unawaited(sample('change'));
    });
  }

  /// One reading, written with the features on now. Never throws; nothing is written while "Measure battery" is off
  /// or when Android gives no numbers.
  Future<void> sample(String why) async {
    if (!_enabled()) return;
    final on = Activity.active;
    PowerReading? r;
    try {
      r = PowerReading.fromMap(await read().timeout(const Duration(seconds: 5)));
    } catch (_) {
      r = null;
    }
    if (r == null) return;
    Map<String, Object?>? band;
    try {
      band = Metrics.band?.call();
    } catch (_) {
      band = null;
    }
    final rss = _rss();
    taken++;
    _write({
      'kind': 'power',
      ...r.toLine(),
      if (rss > 0) 'rss': rss,
      'on': on,
      'why': why,
      if (band != null && band.isNotEmpty) 'band': band,
    });
  }
}

/// Bytes of each top-level folder of the app's [filesDir] (files at the top count as `other`). Never throws: what
/// cannot be read is left out. Run it off the screen's thread (a night folder can hold a thousand files).
Map<String, int> storageByCategory(Directory filesDir) {
  final out = <String, int>{};
  if (!filesDir.existsSync()) return out;
  for (final e in filesDir.listSync(followLinks: false)) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    try {
      if (e is Directory) {
        var n = 0;
        for (final f in e.listSync(recursive: true, followLinks: false)) {
          if (f is File) n += f.lengthSync();
        }
        out[name] = (out[name] ?? 0) + n;
      } else if (e is File) {
        out['other'] = (out['other'] ?? 0) + e.lengthSync();
      }
    } catch (_) {}
  }
  return out;
}
