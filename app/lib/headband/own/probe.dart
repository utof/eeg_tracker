// The probe of our own connection on the owner's BrainBit Black, on the phone: the same steps and the same
// checks as the laptop's scripts/ble_probe.py. About 3 minutes of steps with the headband on (1.5 without).
//
// It settles what protocol.dart marks TO VERIFY: the service and its characteristics, the status bytes, the signal
// packet (size, counter, 250 Hz), the channel order (eyes closed: alpha shows on the two back electrodes; lifting
// one electrode at a time names each slot), command 2 (stop), 4 (resistance, and its order), 5 (signal + resistance
// together), whether the signal starts again after resistance, and whether pairing is needed.
//
// Everything goes to files/own-ble/probe/<stamp>/ in the app's private folder (Export data takes it to the
// laptop): gatt.txt (services, characteristics and properties, every readable value), raw.txt (every notification
// as one hex line: seconds since start, step, characteristic, bytes, hex), decoded.csv (signal per sample in wire
// order: raw counts), probe.log, summary.txt and summary.json (with the verdict the page shows).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../recorder/chunk_writer.dart' show fileStem, logTime, recordBytes;
import 'driver.dart';
import 'protocol.dart';
import 'settings.dart';
import 'transport.dart';

const double liftS = 4, restS = 3;
const Map<String, String> where = {'O1': 'LEFT BACK', 'O2': 'RIGHT BACK', 'T3': 'LEFT TEMPLE', 'T4': 'RIGHT TEMPLE'};

/// What a step asks of the owner: which tone the page plays with it.
enum ProbeCue { none, closeEyes, openEyes, next }

/// One step as the page shows it.
class ProbeStep {
  const ProbeStep(this.name, this.seconds, this.text, this.cue, this.index, this.total);

  /// `signal`, `eyes_closed`, `lift_O1`, ... (the names in raw.txt and summary.json).
  final String name;
  final double seconds;

  /// What to do, or null for a step that needs nothing from the owner.
  final String? text;
  final ProbeCue cue;

  /// Seconds of steps before this one and in all, for a progress bar.
  final double index, total;
}

// ---- analysis (plain numbers) ----------------------------------------------------------------------------------
/// n, mean, sd, the 1st and 99th percentile around the mean, and the RMS of sample-to-sample steps.
Map<String, num> stats(List<double> values) {
  final n = values.length;
  if (n < 2) return {'n': n};
  final m = values.reduce((a, b) => a + b) / n;
  final dev = [for (final v in values) v - m]..sort();
  var ss = 0.0, ds = 0.0;
  for (final d in dev) {
    ss += d * d;
  }
  for (var i = 0; i < n - 1; i++) {
    final d = values[i + 1] - values[i];
    ds += d * d;
  }
  return {
    'n': n,
    'mean': m,
    'sd': math.sqrt(ss / (n - 1)),
    'p1': dev[(0.01 * (n - 1)).toInt()],
    'p99': dev[(0.99 * (n - 1)).toInt()],
    'diff_rms': math.sqrt(ds / (n - 1)),
  };
}

/// Mean power in lo-hi Hz over 2 s Hann windows with half overlap (x in µV, result in µV²); NaN when too short.
double bandPower(List<double> x, {double lo = 8, double hi = 13, int rate = fs}) {
  final w = 2 * rate;
  if (x.length < w) return double.nan;
  final hann = [for (var k = 0; k < w; k++) 0.5 - 0.5 * math.cos(2 * math.pi * k / (w - 1))];
  final freqs = [for (var j = 0; j <= ((hi - lo) / 0.5).toInt(); j++) lo + 0.5 * j];
  final cosT = [
    for (final f in freqs) [for (var k = 0; k < w; k++) math.cos(2 * math.pi * f * k / rate)],
  ];
  final sinT = [
    for (final f in freqs) [for (var k = 0; k < w; k++) math.sin(2 * math.pi * f * k / rate)],
  ];
  final out = <double>[];
  for (var s = 0; s + w <= x.length; s += w ~/ 2) {
    var m = 0.0;
    for (var k = 0; k < w; k++) {
      m += x[s + k];
    }
    m /= w;
    final seg = [for (var k = 0; k < w; k++) (x[s + k] - m) * hann[k]];
    var p = 0.0;
    for (var j = 0; j < freqs.length; j++) {
      var re = 0.0, im = 0.0;
      for (var k = 0; k < w; k++) {
        re += seg[k] * cosT[j][k];
        im -= seg[k] * sinT[j][k];
      }
      p += re * re + im * im;
    }
    out.add(p / (w * w));
  }
  return out.reduce((a, b) => a + b) / out.length;
}

/// `'O2,T3,T4,O1'` if the four lifts named four different slots, else null.
String? orderFrom(Map<String, Map<String, Object?>> lifts) {
  if (lifts.length != 4) return null;
  final slots = {for (final e in lifts.entries) e.value['slot']! as int: e.key};
  if (slots.length != 4) return null;
  return [for (var j = 0; j < 4; j++) slots[j]].join(',');
}

/// Noise level (RMS of sample-to-sample steps, µV) per channel in the middle of a recording made with BrainBit's
/// SDK, for a rough check of the scale.
Map<String, Map<String, num>> sdkReference(File f32, {double seconds = 60}) {
  final data = ByteData.sublistView(f32.readAsBytesSync());
  final n = data.lengthInBytes ~/ recordBytes;
  final k = (seconds * fs).toInt();
  final start = math.max(0, n ~/ 2 - k ~/ 2);
  final cols = [for (var j = 0; j < 4; j++) <double>[]];
  for (var i = start; i < math.min(n, start + k); i++) {
    for (var j = 0; j < 4; j++) {
      cols[j].add(data.getFloat32(recordBytes * i + 4 + 4 * j, Endian.little) * 1e6);
    }
  }
  return {for (var j = 0; j < 4; j++) names[j]: _round(stats(cols[j]))};
}

Map<String, num> _round(Map<String, num> m) => {
  for (final e in m.entries) e.key: e.value is int ? e.value : _r2(e.value.toDouble()),
};

double _r2(double v) => v.isFinite ? (v * 100).roundToDouble() / 100 : v;

/// JSON has no NaN or infinity.
Object? _json(Object? v) {
  if (v is double && !v.isFinite) return v.isNaN ? null : (v > 0 ? 'inf' : '-inf');
  if (v is Map) return {for (final e in v.entries) '${e.key}': _json(e.value)};
  if (v is Iterable) return [for (final x in v) _json(x)];
  return v;
}

/// What the probe found, in plain words.
class ProbeVerdict {
  ProbeVerdict({
    required this.passed,
    required this.worn,
    required this.command5,
    required this.needsPairing,
    required this.lines,
    required this.line,
    this.layout,
  });

  /// Our connection can be used: the signal arrives as expected, stops and starts again, and (worn) the channel
  /// order is settled.
  final bool passed;
  final bool worn;
  final bool command5;
  final bool needsPairing;

  /// One sentence for the top of the page.
  final String line;

  /// One sentence per check: (ok or not or unknown, words).
  final List<(bool?, String)> lines;

  /// The channel order to use when the lifts showed another one than protocol.dart assumes; null = as assumed.
  final Layout? layout;
}

class ProbeResult {
  ProbeResult(this.stamp, this.dir, this.summary, this.text, this.verdict);
  final String stamp;
  final Directory dir;
  final Map<String, Object?> summary;

  /// summary.txt.
  final String text;
  final ProbeVerdict verdict;

  /// The short note kept in the settings file.
  ProbeNote note() => ProbeNote(
    at: stamp,
    passed: verdict.passed,
    worn: verdict.worn,
    command5: verdict.command5,
    folder: 'own-ble/probe/$stamp',
    line: verdict.line,
  );
}

class BandProbe {
  BandProbe({
    required this.transport,
    required this.folder,
    this.address,
    this.name,
    Layout? layout,
    this.worn = true,
    this.pair = false,
    this.onStep,
    this.ready,
    this.sdkRef,
    this.timeScale = 1,
    this.callTimeout = const Duration(seconds: 20),
    this.scanFor = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : layout = layout ?? defaultLayout,
       _now = clock ?? DateTime.now;

  final BleTransport transport;

  /// `files/own-ble/probe`: this run makes its own folder inside.
  final Directory folder;
  final String? address;
  final String? name;
  final Layout layout;

  /// The headband is on the head (false: lying on the desk, protocol steps only).
  final bool worn;
  final bool pair;
  final void Function(ProbeStep step)? onStep;

  /// Completes when the owner has the headband on and tapped Ready (worn runs).
  final Future<void> Function()? ready;

  /// A recording made with BrainBit's SDK, worn, to compare the noise level with.
  final File? sdkRef;

  /// Tests: shorter steps.
  final double timeScale;
  final Duration callTimeout;
  final Duration scanFor;
  final DateTime Function() _now;

  late final DateTime _t0;
  String _phase = 'connect';
  BrainBitBle? _drv;
  final Flag _cancel = Flag();
  final List<(String, DateTime, DateTime)> _phases = [];
  final List<(DateTime, String, SignalPacket)> _signal = [];
  final List<(DateTime, String, Uint8List)> _resist = [];
  final Map<(String, String, int), int> _other = {};
  final List<(String, BandStatus)> _status = [];
  final List<String> _gatt = [];
  IOSink? _raw;
  IOSink? _logFile;
  double _done = 0;

  /// The owner gave up: the probe ends at the next step with what it has.
  void cancel() => _cancel.set();

  /// The steps of a run, for the page's progress bar (seconds, before any time scale).
  double get totalSeconds => worn ? 179 : 77;

  void _log(String msg) => _logFile?.writeln('${logTime(_now())} $msg');

  void _onRaw(String uuid, Uint8List data, DateTime now) {
    final u8 = uuid.substring(0, 8);
    _raw?.writeln(
      '${(now.difference(_t0).inMicroseconds / 1e6).toStringAsFixed(3)} $_phase $u8 ${data.length} ${hex(data)}',
    );
    final key = (_phase, u8, data.length);
    _other[key] = (_other[key] ?? 0) + 1;
    if (u8 == '7e400005') _resist.add((now, _phase, Uint8List.fromList(data)));
  }

  /// One timed step; a dropped link ends the probe with what it has (HeadbandLost).
  Future<void> _step(String stepName, double seconds, [String? text, ProbeCue cue = ProbeCue.none]) async {
    _phase = stepName;
    onStep?.call(ProbeStep(stepName, seconds * timeScale, text, text == null ? ProbeCue.none : cue, _done, totalSeconds));
    _done += seconds;
    final t = _now();
    final lost = _drv?.lost;
    final ended = lost == null
        ? await _cancel.wait(_scaled(seconds))
        : await Flag.either([lost, _cancel], _scaled(seconds));
    _phases.add((stepName, t, _now()));
    if (ended && (lost?.isSet ?? false)) throw HeadbandLost('link dropped (${_drv?.lostReason})');
    if (_cancel.isSet) throw HeadbandError('stopped by you');
  }

  /// A real wait: [seconds] of the plan, shortened by [timeScale] in tests.
  Duration _scaled(double seconds) => Duration(microseconds: (seconds * timeScale * 1e6).round());

  /// A stretch of the probe's own clock (the analysis skips the first moments of a step).
  static Duration _secs(double seconds) => Duration(microseconds: (seconds * 1e6).round());

  List<SignalPacket> _packets(String stepName, [double skip = 0]) {
    final spans = [
      for (final (n, a, b) in _phases)
        if (n == stepName) (a.add(_secs(skip)), b),
    ];
    return [
      for (final (t, _, p) in _signal)
        if (spans.any((s) => !t.isBefore(s.$1) && t.isBefore(s.$2))) p,
    ];
  }

  /// µV per wire slot (scale per the layout's gain) for one step.
  List<List<double>> _slotSeries(String stepName, [double skip = 0.5]) {
    final scale = layout.voltsPerCount * 1e6;
    final out = [for (var j = 0; j < 4; j++) <double>[]];
    for (final p in _packets(stepName, skip)) {
      for (final c in p.counts) {
        for (var j = 0; j < 4; j++) {
          out[j].add(c[j] * scale);
        }
      }
    }
    return out;
  }

  double _duration(String stepName) {
    var us = 0;
    for (final (n, a, b) in _phases) {
      if (n == stepName) us += b.difference(a).inMicroseconds;
    }
    return us / 1e6;
  }

  bool _ran(String stepName) => _phases.any((p) => p.$1 == stepName);

  Map<String, Object?> _signalCheck(String stepName) {
    final pk = _packets(stepName);
    final dur = _duration(stepName);
    final steps = <int, int>{};
    var lost = 0, nSamples = 0;
    for (var i = 0; i < pk.length; i++) {
      nSamples += pk[i].samples.length;
      if (i + 1 == pk.length) break;
      final d = (pk[i + 1].counter - pk[i].counter) % counterMod;
      steps[d] = (steps[d] ?? 0) + 1;
      lost += math.max(0, counterGap((pk[i].counter + pk[i].samples.length) % counterMod, pk[i + 1].counter));
    }
    final sizes = <int, int>{}, markers = <int, int>{};
    for (final p in pk) {
      final size = header + block * p.samples.length;
      sizes[size] = (sizes[size] ?? 0) + 1;
      for (final m in p.markers) {
        markers[m] = (markers[m] ?? 0) + 1;
      }
    }
    final series = _slotSeries(stepName);
    List<MapEntry<int, int>> top(Map<int, int> m) =>
        (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(5).toList();
    return {
      'packets': pk.length,
      'samples': nSamples,
      'seconds': _r2(dur),
      'samples_per_s': pk.isEmpty || dur <= 0 ? 0 : (nSamples / dur * 10).roundToDouble() / 10,
      'packets_per_s': dur <= 0 ? 0 : _r2(pk.length / dur),
      'sizes': {for (final e in sizes.entries) '${e.key}': e.value},
      'counter_steps': {for (final e in top(steps)) '${e.key}': e.value},
      'lost_samples': lost,
      'first_counters': [for (final p in pk.take(3)) p.counter],
      'markers': {for (final e in top(markers)) '${e.key}': e.value},
      'slots_uv': {for (var j = 0; j < 4; j++) layout.order[j]: _round(stats(series[j]))},
    };
  }

  /// Median ohms per wire slot in one step, or null when no resistance packet came.
  List<double>? _resistValues(String stepName, [double skip = 1]) {
    final spans = [
      for (final (n, a, b) in _phases)
        if (n == stepName) (a.add(_secs(skip)), b),
    ];
    final rows = <List<int>>[];
    for (final (t, _, d) in _resist) {
      if (d.length < 20 || !spans.any((s) => !t.isBefore(s.$1) && t.isBefore(s.$2))) continue;
      final v = ByteData.sublistView(d);
      rows.add([for (var j = 0; j < 4; j++) v.getUint32(4 + 4 * j, Endian.little)]);
    }
    if (rows.isEmpty) return null;
    return [
      for (var j = 0; j < 4; j++) ([for (final r in rows) r[j]]..sort())[rows.length ~/ 2].toDouble(),
    ];
  }

  /// For each lift step, the wire slot whose measure rose most over rest.
  Map<String, Map<String, Object?>> _liftSlots(String prefix, String rest, List<double?>? Function(String) value) {
    final base = value(rest);
    final out = <String, Map<String, Object?>>{};
    for (final n in names) {
      final v = value('$prefix$n');
      if (v == null || base == null || base.contains(null) || v.contains(null)) continue;
      final ratios = [
        for (var j = 0; j < 4; j++) base[j] == 0 ? double.infinity : v[j]! / base[j]!,
      ];
      var best = 0;
      for (var j = 1; j < 4; j++) {
        if (ratios[j] > ratios[best]) best = j;
      }
      out[n] = {'slot': best, 'ratio': _r2(ratios[best]), 'ratios': [for (final r in ratios) _r2(r)]};
    }
    return out;
  }

  int _countsIn(String stepName, String uuid8) {
    var n = 0;
    for (final e in _other.entries) {
      if (e.key.$1 == stepName && e.key.$2 == uuid8) n += e.value;
    }
    return n;
  }

  Future<List<String>> _dumpGatt(BrainBitBle drv) async {
    final lines = <String>[];
    for (final s in drv.gatt) {
      lines.add('service ${s.uuid}');
      for (final c in s.characteristics) {
        var line = '  char ${c.uuid} [${(c.properties.toList()..sort()).join(',')}]';
        if (c.properties.contains('read')) {
          try {
            final v = await drv.readAny(s.uuid, c.uuid);
            final text = v.isNotEmpty && v.every((b) => b >= 32 && b < 127) ? " '${String.fromCharCodes(v)}'" : '';
            line += ' = ${hex(v)}$text';
          } on HeadbandError catch (e) {
            line += ' read failed: $e'; // a read that needs pairing is a finding, not a failure
          }
        }
        lines.add(line);
      }
    }
    return lines;
  }

  /// Runs the whole probe and writes its files. Never throws for a headband problem: the result says what
  /// happened.
  Future<ProbeResult> run() async {
    _t0 = _now();
    final stamp = fileStem(_t0);
    final dir = Directory('${folder.path}/$stamp')..createSync(recursive: true);
    _raw = File('${dir.path}/raw.txt').openWrite();
    _logFile = File('${dir.path}/probe.log').openWrite();
    final drv = _drv = BrainBitBle(
      transport: transport,
      address: address,
      name: name,
      layout: layout,
      pair: pair,
      timeout: callTimeout,
      scanFor: scanFor,
      stall: const Duration(days: 1), // the probe watches stalls itself; the driver must not resend commands
      log: _log,
      clock: _now,
    );
    drv.onRaw = _onRaw;
    drv.onSamples = (p, at, _) => _signal.add((at, _phase, p));
    drv.onStatus = (st) => _status.add((_phase, st));
    _log('probe folder ${dir.path}; address ${address ?? 'unknown: scanning by name'}; layout ${layout.describe()}');
    final summary = <String, Object?>{
      'started': logTime(_t0).substring(0, 19),
      'app': 'phone',
      'transport': transport.describe,
      'address': address,
      'layout': layout.describe(),
      'head': worn,
      'paired_first': pair,
      'steps': <String, Object?>{},
    };
    try {
      BandInfo info;
      try {
        info = await drv.connect();
      } on HeadbandError catch (e) {
        if (address == null) rethrow;
        _log('the known address did not answer ($e): scanning by name');
        summary['direct_connect'] = 'failed: $e';
        await drv.scanForBand();
        info = await drv.connect();
      }
      summary['direct_connect'] ??= address == null ? 'not tried (no address known)' : 'worked';
      _gatt.addAll(['mtu ${info.mtu ?? 'unknown'} (the signal needs $mtuNeeded)', ...await _dumpGatt(drv)]);
      final mine = {charUuid(info.service, statusChar), charUuid(info.service, signalChar), charUuid(info.service, resistChar)};
      for (final s in drv.gatt) {
        for (final c in s.characteristics) {
          if (mine.contains(c.uuid.toLowerCase()) || !c.notifies) continue;
          try {
            await drv.alsoSubscribe(s.uuid, c.uuid, (d) => _onRaw(c.uuid.toLowerCase(), d, _now()));
            _gatt.add('also subscribed to ${c.uuid}');
          } on HeadbandError catch (e) {
            _gatt.add('could not subscribe to ${c.uuid}: $e');
          }
        }
      }
      summary.addAll({
        'address': info.address,
        'name': info.name,
        'rssi': info.rssi,
        'service': info.service,
        'device': info.info,
        'mtu': info.mtu,
        'status_at_connect': info.status?.text(),
      });
      _log('connected ${info.name} ${info.address}; service ${info.service}; ${info.info}; status ${info.status?.text() ?? '?'}');
      if (worn) {
        _phase = 'ready';
        onStep?.call(
          ProbeStep(
            'ready',
            0,
            'Put the headband on, electrodes on the skin, sit still and relaxed. Tap Ready.',
            ProbeCue.none,
            0,
            totalSeconds,
          ),
        );
        final wait = ready;
        if (wait != null) await Future.any([wait(), _cancel.wait(const Duration(hours: 1))]);
        if (_cancel.isSet) throw HeadbandError('stopped by you');
      }
      await drv.command(cmdSignal);
      await _step('signal', 30, worn ? 'Sit still, eyes open, relax. 30 seconds.' : null, ProbeCue.next);
      if (worn) {
        await _step('eyes_closed', 20, 'Close your eyes now. Open them at the two rising tones.', ProbeCue.closeEyes);
        await _step('eyes_open', 20, 'Open your eyes. Look at one spot for 20 seconds.', ProbeCue.openEyes);
        for (final n in names) {
          await _step('rest', restS, 'Next: ${where[n]} electrode, $n. Wait for the tone.');
          await _step('lift_$n', liftS, 'Lift the ${where[n]} electrode off the skin now.', ProbeCue.next);
        }
        await _step('rest', restS, 'Let it go. Thank you.', ProbeCue.next);
      }
      await drv.command(cmdIdle);
      await _step('idle_after_signal', 3);
      await drv.command(cmdResist);
      await _step('resist', 12, worn ? 'Contact check for 12 seconds: sit still.' : null);
      if (worn) {
        for (final n in names) {
          await _step('resist_rest', restS, 'Next: ${where[n]} electrode, $n. Wait for the tone.');
          await _step('resist_lift_$n', liftS, 'Lift the ${where[n]} electrode off the skin now.', ProbeCue.next);
        }
        await _step('resist_rest', restS, 'Let it go.', ProbeCue.next);
      }
      await drv.command(cmdIdle);
      await _step('idle_after_resist', 2);
      await drv.command(cmdSignalResist);
      await _step('signal_resist', 20, worn ? 'Signal and contact together, 20 seconds: sit still.' : null);
      await drv.command(cmdIdle);
      await _step('idle_after_signal_resist', 2);
      await drv.command(cmdSignal);
      await _step('signal_again', 8);
      try {
        summary['status_at_end'] = (await drv.readStatus()).text();
      } on HeadbandError catch (e) {
        summary['status_at_end'] = 'read failed: $e';
      }
    } on HeadbandError catch (e) {
      _log('STOPPED in step $_phase: $e');
      summary['error'] = '$_phase: $e';
    } catch (e) {
      _log('STOPPED in step $_phase by a bug: $e');
      summary['error'] = '$_phase: unexpected: $e';
    } finally {
      await drv.close(idle: true);
    }
    onStep?.call(ProbeStep('done', 0, 'Done. You can take the headband off.', ProbeCue.next, totalSeconds, totalSeconds));
    final result = _writeResults(stamp, dir, summary);
    await _raw?.close();
    await _logFile?.close();
    return result;
  }

  ProbeResult _writeResults(String stamp, Directory dir, Map<String, Object?> summary) {
    final st = summary['steps']! as Map<String, Object?>;
    for (final n in ['signal', 'eyes_closed', 'eyes_open', 'signal_resist', 'signal_again']) {
      if (_ran(n)) st[n] = {..._signalCheck(n), 'resist_packets': _countsIn(n, '7e400005')};
    }
    for (final n in ['idle_after_signal', 'idle_after_resist', 'idle_after_signal_resist']) {
      if (_ran(n)) {
        st[n] = {'signal_packets_after_1s': _packets(n, 1).length, 'resist_packets': _countsIn(n, '7e400005')};
      }
    }
    if (_ran('resist')) {
      final sizes = <int, int>{};
      for (final (_, ph, d) in _resist) {
        if (ph == 'resist') sizes[d.length] = (sizes[d.length] ?? 0) + 1;
      }
      final med = _resistValues('resist');
      st['resist'] = {
        'packets': sizes.values.fold<int>(0, (a, b) => a + b),
        'sizes': {for (final e in sizes.entries) '${e.key}': e.value},
        'signal_packets': _packets('resist', 1).length,
        'median_ohms_wire_order': med,
        'decoded': med == null ? null : {for (var j = 0; j < 4; j++) layout.resistOrder[j]: med[j]},
      };
    }
    final byPhase = <String, Set<String>>{};
    for (final (ph, s) in _status) {
      byPhase.putIfAbsent(ph, () => {}).add(hex(s.raw));
    }
    summary['status_raw_by_step'] = {for (final e in byPhase.entries) e.key: e.value.toList()..sort()};
    final other = _other.entries.toList()
      ..sort((a, b) => '${a.key}'.compareTo('${b.key}'));
    summary['other_notifications'] = [
      for (final e in other) {'step': e.key.$1, 'char': e.key.$2, 'bytes': e.key.$3, 'count': e.value},
    ];
    final v = <String, bool?>{};
    final sig = st['signal'] as Map<String, Object?>?;
    if (sig != null) {
      final rate = sig['samples_per_s']! as num;
      v['rate_250'] = rate >= 235 && rate <= 265;
      v['packet_108_bytes'] = (sig['sizes']! as Map).keys.join(',') == '108';
      final steps = sig['counter_steps']! as Map;
      v['counter_counts_samples'] = steps.isNotEmpty && steps.keys.first == '8';
      v['no_lost_samples'] = sig['lost_samples'] == 0;
    }
    if (st.containsKey('eyes_closed') && st.containsKey('eyes_open')) {
      final ec = _slotSeries('eyes_closed'), eo = _slotSeries('eyes_open');
      final rise = [
        for (var j = 0; j < 4; j++) () {
          final open = bandPower(eo[j]);
          return open > 0 ? bandPower(ec[j]) / open : double.nan;
        }(),
      ];
      final ranked = [0, 1, 2, 3]..sort((a, b) => (rise[b].isNaN ? 0.0 : rise[b]).compareTo(rise[a].isNaN ? 0.0 : rise[a]));
      summary['alpha_rise_by_wire_slot'] = {
        for (var j = 0; j < 4; j++) 'slot$j (${layout.order[j]})': _r2(rise[j]),
      };
      v['alpha_on_assumed_back_slots'] = {layout.order[ranked[0]], layout.order[ranked[1]]}.containsAll(['O1', 'O2']);
    }
    String? found, rfound;
    if (worn && sig != null) {
      final lifts = _liftSlots('lift_', 'signal', (n) {
        if (!_ran(n)) return null;
        return [for (final x in _slotSeries(n)) stats(x)['diff_rms']?.toDouble()];
      });
      summary['signal_lifts'] = lifts;
      found = orderFrom(lifts);
      summary['suggested_order'] = found;
      v['order_matches_default'] = found == null ? null : found == layout.order.join(',');
      final rl = _liftSlots('resist_lift_', 'resist', (n) => _ran(n) ? _resistValues(n) : null);
      summary['resist_lifts'] = rl;
      rfound = orderFrom(rl);
      summary['suggested_resist_order'] = rfound;
      v['resist_order_matches_default'] = rfound == null ? null : rfound == layout.resistOrder.join(',');
    }
    final idle = st['idle_after_signal'] as Map<String, Object?>?;
    if (idle != null) v['command2_stops_signal'] = idle['signal_packets_after_1s'] == 0;
    final res = st['resist'] as Map<String, Object?>?;
    if (res != null) v['command4_gives_resistance'] = (res['packets']! as int) > 0;
    final sr = st['signal_resist'] as Map<String, Object?>?;
    if (sr != null) {
      v['command5_signal'] = (sr['samples_per_s']! as num) > 200;
      v['command5_resistance'] = (sr['resist_packets']! as int) > 0;
    }
    final again = st['signal_again'] as Map<String, Object?>?;
    if (again != null) v['signal_restarts_after_resistance'] = (again['samples_per_s']! as num) > 200;
    summary['verdict'] = v;
    final ref = sdkRef;
    if (ref != null && sig != null) {
      try {
        final sdk = sdkReference(ref);
        final ours = sig['slots_uv']! as Map<String, Object?>;
        final ratio = <String, double>{};
        for (final n in names) {
          final a = (ours[n] as Map?)?['diff_rms'] as num?, b = sdk[n]?['diff_rms'];
          if (a != null && b != null && a > 0 && b > 0) ratio[n] = _r2(a / b);
        }
        summary['sdk_reference'] = {'file': ref.uri.pathSegments.last, 'sdk': sdk, 'ratio_diff_rms': ratio};
      } on FileSystemException catch (e) {
        summary['sdk_reference'] = 'failed: ${e.message}';
      }
    }
    final verdict = _verdict(summary, v, found, rfound);
    summary['plain'] = {
      'passed': verdict.passed,
      'worn': verdict.worn,
      'command5': verdict.command5,
      'needs_pairing': verdict.needsPairing,
      'line': verdict.line,
      'lines': [for (final (ok, text) in verdict.lines) '${ok == null ? '?' : (ok ? 'yes' : 'NO')}: $text'],
      'layout_to_use': verdict.layout?.toJson(),
    };
    File('${dir.path}/gatt.txt').writeAsStringSync(_gatt.isEmpty ? 'not connected\n' : '${_gatt.join('\n')}\n');
    File('${dir.path}/summary.json').writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(_json(summary))}\n');
    final csv = StringBuffer('t,step,counter,k,marker,${[for (var j = 0; j < 4; j++) 'slot${j}_${layout.order[j]}'].join(',')}\n');
    for (final (t, ph, p) in _signal) {
      final at = (t.difference(_t0).inMicroseconds / 1e6).toStringAsFixed(3);
      for (var k = 0; k < p.counts.length; k++) {
        final c = p.counts[k];
        csv.writeln('$at,$ph,${p.counter},$k,${p.markers[k]},${c[0]},${c[1]},${c[2]},${c[3]}');
      }
    }
    File('${dir.path}/decoded.csv').writeAsStringSync(csv.toString());
    final text = summaryText(summary);
    File('${dir.path}/summary.txt').writeAsStringSync(text);
    return ProbeResult(stamp, dir, summary, text, verdict);
  }

  ProbeVerdict _verdict(Map<String, Object?> s, Map<String, bool?> v, String? found, String? rfound) {
    final error = s['error'] as String?;
    final needsPairing = error != null && error.contains('pairing');
    final lines = <(bool?, String)>[];
    void add(String key, String yes, String no, [String unknown = '']) {
      if (!v.containsKey(key)) return;
      final ok = v[key];
      lines.add((ok, ok == null ? unknown : (ok ? yes : no)));
    }

    if (error != null) lines.add((false, 'It stopped early: $error'));
    add('rate_250', 'The signal arrives at 250 samples a second.', 'The signal does not arrive at 250 samples a second.');
    add('packet_108_bytes', 'Packets have the expected size (108 bytes).', 'Packets have another size than expected.');
    add('counter_counts_samples', 'The headband numbers its samples as expected.', 'The packet counter does not step by 8.');
    if (v.containsKey('no_lost_samples')) {
      // Losing a packet now and then is Bluetooth, not a failed check: said, never marked as a failure.
      lines.add(v['no_lost_samples'] == true
          ? (true, 'No sample was lost.')
          : (null, 'Some samples were lost on the way (not a failure; they are counted).'));
    }
    add('command2_stops_signal', 'Stop works.', 'The signal did not stop when asked.');
    add('command4_gives_resistance', 'The contact check works.', 'The contact check gave nothing.');
    add('signal_restarts_after_resistance', 'The signal starts again after a contact check, without a new connection.',
        'The signal did NOT start again after the contact check.');
    final cmd5 = v['command5_signal'] == true && v['command5_resistance'] == true;
    if (v.containsKey('command5_signal')) {
      lines.add((cmd5, cmd5 ? 'Signal and contact together (command 5) works: contact can be measured all night.'
          : 'Signal and contact together (command 5) does not work; contact is checked at the start only.'));
    }
    add('alpha_on_assumed_back_slots', 'Eyes closed: the rhythm rose on the two back electrodes, as assumed.',
        'Eyes closed: the rhythm did not rise where the back electrodes are assumed.');
    Layout? layout;
    final want = this.layout.order.join(','), rwant = this.layout.resistOrder.join(',');
    if (worn && v.containsKey('order_matches_default')) {
      if (found == null) {
        lines.add((null, 'The lifts did not name four different electrodes: the channel order is not settled.'));
      } else if (found == want) {
        lines.add((true, 'Channel order as assumed (${want.replaceAll(',', ' ')}).'));
      } else {
        lines.add((true, 'Channel order found by the lifts: ${found.replaceAll(',', ' ')} (assumed ${want.replaceAll(',', ' ')}). The app will use what it found.'));
      }
      if (rfound != null && rfound != rwant) {
        lines.add((true, 'Contact order found by the lifts: ${rfound.replaceAll(',', ' ')}. The app will use it.'));
      } else if (rfound == null && v['command4_gives_resistance'] == true) {
        lines.add((null, 'The lifts did not settle which contact value belongs to which electrode.'));
      }
      if (found != null && (found != want || (rfound != null && rfound != rwant))) {
        layout = Layout(order: parseOrder(found), resistOrder: parseOrder(rfound ?? rwant), gain: this.layout.gain);
      }
    }
    final ref = s['sdk_reference'];
    if (ref is Map && (ref['ratio_diff_rms'] as Map).isNotEmpty) {
      final ratios = (ref['ratio_diff_rms'] as Map).values.cast<num>().toList()..sort();
      final mid = ratios[ratios.length ~/ 2];
      final ok = mid > 0.6 && mid < 1.6;
      lines.add((ok ? true : null, ok
          ? 'Noise level close to an SDK recording (x${mid.toStringAsFixed(2)}): the scale looks right.'
          : 'Noise level x${mid.toStringAsFixed(2)} of an SDK recording: the scale may be off by 2 (tell the assistant).'));
    }
    final protocol = error == null &&
        v['rate_250'] == true &&
        v['packet_108_bytes'] == true &&
        v['counter_counts_samples'] == true &&
        v['command2_stops_signal'] == true &&
        v['signal_restarts_after_resistance'] == true;
    final passed = protocol && worn && found != null;
    final String line;
    if (needsPairing) {
      line = 'The headband asks for pairing. Hold its button 4 seconds until it blinks fast, then run the probe again with pairing on.';
    } else if (error != null) {
      line = 'The probe stopped early. Our own connection is not ready; BrainBit\'s SDK stays in use.';
    } else if (passed) {
      line = 'Passed. Our own connection can be tried for a night.';
    } else if (protocol && !worn) {
      line = 'The protocol steps passed. Run it once with the headband on to settle the channel order.';
    } else if (protocol) {
      line = 'The connection works, but the channel order is not settled. Run it again and lift one electrode at a time.';
    } else {
      line = 'Not passed. Our own connection is not ready; BrainBit\'s SDK stays in use.';
    }
    return ProbeVerdict(
      passed: passed,
      worn: worn,
      command5: cmd5,
      needsPairing: needsPairing,
      lines: lines,
      line: line,
      layout: layout,
    );
  }
}

/// summary.txt: the laptop probe's layout, so both read alike.
String summaryText(Map<String, Object?> s) {
  final v = (s['verdict'] as Map?)?.cast<String, bool?>() ?? const <String, bool?>{};
  String yes(String k) => !v.containsKey(k) ? 'not run' : (v[k] == null ? 'not settled' : (v[k]! ? 'yes' : 'NO'));
  final steps = (s['steps'] as Map).cast<String, Object?>();
  final plain = (s['plain'] as Map?)?.cast<String, Object?>();
  final lines = <String>[
    'BrainBit Black probe (phone) ${s['started']}  ${s['name'] ?? '?'} ${s['address']}',
    if (plain != null) 'VERDICT: ${plain['line']}',
    if (plain != null) ...[for (final l in plain['lines']! as List) '  $l'],
    'service ${s['service']}  device ${s['device']}  mtu ${s['mtu']}  via ${s['transport']}',
    'connected without a scan: ${s['direct_connect'] ?? 'not reached'}   paired first: ${s['paired_first']}',
    'status at connect: ${s['status_at_connect']}  at end: ${s['status_at_end']}',
    'assumed layout: ${s['layout']}',
    if (s['error'] != null) 'STOPPED EARLY: ${s['error']}',
  ];
  final sig = steps['signal'] as Map?;
  if (sig != null) {
    lines.add(
      'signal (command 3): ${sig['samples_per_s']} samples/s, ${sig['packets_per_s']} packets/s, sizes ${sig['sizes']}, '
      'counter steps ${sig['counter_steps']}, lost ${sig['lost_samples']}, markers ${sig['markers']}',
    );
    for (final e in (sig['slots_uv']! as Map).entries) {
      final x = e.value as Map;
      if (!x.containsKey('sd')) continue;
      final mean = (x['mean'] as num) / 1e6;
      lines.add(
        '  slot ${e.key}: DC ${mean >= 0 ? '+' : ''}${mean.toStringAsFixed(4)} V  sd ${(x['sd'] as num).toStringAsFixed(1)} uV  '
        'p1..p99 ${(x['p1'] as num).toStringAsFixed(0)}..${(x['p99'] as num).toStringAsFixed(0)} uV  '
        'step rms ${(x['diff_rms'] as num).toStringAsFixed(2)} uV',
      );
    }
  }
  lines.addAll([
    '250 Hz: ${yes('rate_250')}   108-byte packets: ${yes('packet_108_bytes')}   counter counts samples (+8): '
        '${yes('counter_counts_samples')}   no lost samples: ${yes('no_lost_samples')}',
    'alpha rise by slot (eyes closed / open): ${s['alpha_rise_by_wire_slot'] ?? 'not run'}  '
        '-> back electrodes where assumed: ${yes('alpha_on_assumed_back_slots')}',
    'signal order from the lifts: ${s['suggested_order'] ?? 'not settled'}  (matches the default: ${yes('order_matches_default')})',
    'resistance order from the lifts: ${s['suggested_resist_order'] ?? 'not settled'}  '
        '(matches the default: ${yes('resist_order_matches_default')})',
    'command 2 stops the signal: ${yes('command2_stops_signal')}   command 4 gives resistance: '
        '${yes('command4_gives_resistance')}  ${(steps['resist'] as Map?)?['decoded']}',
    'command 5: signal ${yes('command5_signal')}, resistance ${yes('command5_resistance')}   '
        'signal starts again after resistance: ${yes('signal_restarts_after_resistance')}',
  ]);
  final ref = s['sdk_reference'];
  if (ref is Map) {
    lines.add('noise vs the SDK recording (ours / SDK, about 1 if the gain is right, 2 or 0.5 if not): ${ref['ratio_diff_rms']}');
  }
  final other = (s['other_notifications'] as List?) ?? const [];
  lines.add(
    'other notifications: ${[for (final o in other.take(40)) '${(o as Map)['step']} ${o['char']} ${o['bytes']} B x${o['count']}'].join('; ')}',
  );
  return '${lines.join('\n')}\n';
}

/// The newest recording in [recordings] that BrainBit's SDK made (its `.log` does not name our own driver) and
/// that is long enough to compare noise levels with; null when there is none.
File? newestSdkRecording(Directory recordings, {int minSamples = 60 * fs}) {
  final List<File> files;
  try {
    files = [
      for (final f in recordings.listSync().whereType<File>())
        if (f.path.endsWith('.f32')) f,
    ]..sort((a, b) => b.path.compareTo(a.path));
  } on FileSystemException {
    return null;
  }
  for (final f in files.take(40)) {
    try {
      if (f.lengthSync() < minSamples * recordBytes) continue;
      final log = File('${f.path.substring(0, f.path.length - 4)}.log');
      if (log.existsSync() && log.readAsStringSync().contains('driver own Bluetooth')) continue;
      return f;
    } on FileSystemException {
      continue;
    }
  }
  return null;
}
