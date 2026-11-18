// Cross-check: the laptop's parser (scripts/brainbit_ble.py) and the phone's (lib/headband/own/protocol.dart) must
// read the same packets to the very same numbers. The vectors come from the Python fake headband and parser
// (test/fixtures/make_own_ble_vectors.py); a Python test checks the file still matches the Python side.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/headband/own/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _load() =>
    jsonDecode(File('test/fixtures/own_ble_vectors.json').readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _cases(Map<String, Object?> v, String key) =>
    [for (final c in v[key]! as List) (c as Map).cast<String, Object?>()];

void main() {
  final v = _load();

  test('every constant equals the Python driver\'s', () {
    final c = (v['constants']! as Map).cast<String, Object?>();
    expect(names, c['names']);
    expect(fs, c['fs']);
    expect([statusChar, commandChar, signalChar, resistChar], [
      c['status_char'],
      c['command_char'],
      c['signal_char'],
      c['resist_char'],
    ]);
    expect([cmdPowerDown, cmdIdle, cmdSignal, cmdResist, cmdSignalResist], [
      c['cmd_power_down'],
      c['cmd_idle'],
      c['cmd_signal'],
      c['cmd_resist'],
      c['cmd_signal_resist'],
    ]);
    expect([header, block, resistHeader, resistOpen], [c['header'], c['block'], c['resist_header'], c['resist_open']]);
    expect(vref, c['vref']);
    expect(gain, c['gain']);
    expect(signalOrder, c['signal_order']);
    expect(resistOrder, c['resist_order']);
    expect(namePrefixes, c['name_prefixes']);
    expect(deviceInfo, c['device_info']);
    expect(stallAfter.inMilliseconds / 1000, c['stall_s']);
    expect([for (final d in backoff) d.inMilliseconds / 1000], c['backoff']);
    expect(statusEvery.inMilliseconds / 1000, c['status_every_s']);
    expect(contactFor.inMilliseconds / 1000, c['contact_s']);
    expect(defaultLayout.voltsPerCount, c['volts_per_count']); // the very same 64-bit number
    expect({for (final e in modeNames.entries) '${e.key}': e.value}, c['mode_names']);
    expect(
      defaultLayout.describe().replaceAll('the probe', 'scripts/ble_probe.py'),
      c['layout_text'],
    );
  });

  test('signal packets decode to the same samples, counts and markers', () {
    var packets = 0, samples = 0, errors = 0;
    for (final c in _cases(v, 'signal')) {
      final layout = Layout(order: (c['order']! as List).cast<String>(), gain: c['gain']! as int);
      final data = unhex(c['hex']! as String);
      if (c['error'] == true) {
        expect(() => decodeSignal(data, layout), throwsFormatException, reason: '${c['name']}');
        errors++;
        continue;
      }
      final p = decodeSignal(data, layout);
      expect(p.counter, c['counter'], reason: '${c['name']}');
      expect(p.markers, c['markers'], reason: '${c['name']}');
      expect(p.counts, c['counts'], reason: '${c['name']}');
      final want = (c['samples']! as List).cast<List<Object?>>();
      expect(p.samples.length, want.length);
      for (var i = 0; i < want.length; i++) {
        final s = p.samples[i];
        // Exact: both sides multiply the same integer by the same 64-bit scale.
        expect(s.pack, want[i][0], reason: '${c['name']} sample $i');
        expect([s.o1, s.o2, s.t3, s.t4], [for (final x in want[i].skip(1)) (x! as num).toDouble()],
            reason: '${c['name']} sample $i');
        samples++;
      }
      packets++;
    }
    expect(packets, greaterThanOrEqualTo(13));
    expect(samples, greaterThanOrEqualTo(80));
    expect(errors, 7);
  });

  test('resistance packets decode to the same ohms', () {
    for (final c in _cases(v, 'resist')) {
      final layout = Layout(resistOrder: (c['resist_order']! as List).cast<String>());
      final data = unhex(c['hex']! as String);
      if (c['error'] == true) {
        expect(() => decodeResist(data, layout), throwsFormatException);
        continue;
      }
      final want = (c['ohms']! as Map).map((k, x) => MapEntry('$k', x == 'inf' ? double.infinity : (x as num).toDouble()));
      expect(decodeResist(data, layout), want, reason: '${c['name']}');
    }
  });

  test('status bytes decode the same, with the same text', () {
    for (final c in _cases(v, 'status')) {
      final data = unhex(c['hex']! as String);
      if (c['error'] == true) {
        expect(() => decodeStatus(data), throwsFormatException);
        continue;
      }
      final st = decodeStatus(data);
      expect([st.battery, st.cmdError, st.state, st.text()], [c['battery'], c['cmd_error'], c['state'], c['text']]);
    }
  });

  test('counter gaps and characteristic UUIDs agree', () {
    for (final c in _cases(v, 'counter_gap')) {
      expect(counterGap(c['expected'] as int?, c['counter']! as int), c['gap'], reason: '$c');
    }
    for (final c in _cases(v, 'uuids')) {
      expect(charUuid(c['service']! as String, c['n']! as int), c['uuid']);
      expect(serviceRe.hasMatch(c['service']! as String), c['is_service']);
    }
  });

  test('a layout must name each channel once', () {
    expect(() => Layout(order: ['O1', 'O1', 'T3', 'T4']), throwsFormatException);
    expect(() => Layout(gain: 0), throwsFormatException);
    expect(parseOrder(' o2, t3 ,T4,O1 '), ['O2', 'T3', 'T4', 'O1']);
    final l = Layout(order: ['T3', 'T4', 'O1', 'O2'], gain: 12);
    expect(Layout.fromJson(jsonDecode(jsonEncode(l.toJson())))!.describe(), l.describe());
    expect(Layout.fromJson({'order': ['O1'], 'resistOrder': ['O1'], 'gain': 6}), isNull);
    expect(isBrainBit('BB Black'), isTrue);
    expect(isBrainBit('BrainBit 123'), isTrue);
    expect(isBrainBit('Mi Band'), isFalse);
    expect(isBrainBit(null), isFalse);
  });
}
