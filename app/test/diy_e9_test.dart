// The phone's E9 decoder (lib/headband/diy/e9.dart) against the laptop's (scripts/diy_board.py) on the very same
// bytes: test/fixtures/diy_vectors.json is made by test/fixtures/make_diy_vectors.py from the Python driver, the
// firmware's own golden frames and the fake board's encoder, and analysis/tests/test_diy_vectors.py fails when the
// file no longer matches the Python side. Every field, every volt (to the last bit), every refusal, every byte
// stream chunk by chunk and every tracker step must be the same.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/headband/diy/e9.dart';
import 'package:flutter_test/flutter_test.dart';

final Map<String, Object?> _v =
    jsonDecode(File('test/fixtures/diy_vectors.json').readAsStringSync()) as Map<String, Object?>;

Uint8List _hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

List<Map<String, Object?>> _list(String key) => [for (final x in _v[key]! as List) x as Map<String, Object?>];

void _sameFrame(E9Frame f, Map<String, Object?> w, String name) {
  expect(
    [f.channels, f.flags, f.gain, f.fs, f.seq, f.timeUs, f.overruns, f.status],
    [w['channels'], w['flags'], w['gain'], w['fs'], w['seq'], w['time_us'], w['overruns'], w['status']],
    reason: name,
  );
  expect(f.counts, w['counts'], reason: name);
  expect([f.mode, f.modeText, f.overrunFlag], [w['mode'], w['mode_text'], w['overrun_flag']], reason: name);
  expect([f.leadOffP, f.leadOffN, f.gpio], [w['lead_off_p'], w['lead_off_n'], w['gpio']], reason: name);
  expect(f.config, w['config'], reason: name);
  final volts = w['volts']! as Map<String, Object?>;
  for (final e in volts.entries) {
    final want = [for (final x in e.value! as List) (x as num).toDouble()];
    expect(f.volts(double.parse(e.key)), want, reason: '$name at ${e.key} V'); // bit for bit
  }
}

void main() {
  test('the constants are the laptop driver\'s', () {
    final c = _v['constants']! as Map<String, Object?>;
    expect(e9Magic, c['magic']);
    expect(e9Version, c['version']);
    expect(e9HeaderSize, c['header']);
    expect(e9Channels, c['channels']);
    expect(e9Gains, c['gains']);
    expect(e9Rates, c['rates']);
    expect(e9MaxSize, c['max_size']);
    expect(maxTextLine, c['max_text']);
    expect(defaultVref, c['default_vref']);
    expect(diyUdpPort, c['udp_port']);
    expect(staleWindow, c['stale_window']);
    for (final e in (c['frame_sizes']! as Map).entries) {
      expect(frameSize(int.parse(e.key as String)), e.value);
    }
    for (final e in (c['volts_per_count']! as Map).entries) {
      expect(voltsPerCount(int.parse(e.key as String)), (e.value as num).toDouble());
    }
    expect(crc16(ascii.encode('123456789')), c['crc_check']);
    expect(crc16(ascii.encode('123456789')), 0x29B1); // CRC-16/CCITT-FALSE's published check value
  });

  test('every frame case decodes to the same fields, or is refused by the same check', () {
    final cases = _list('frames');
    expect(cases.length, greaterThan(40));
    var ok = 0;
    for (final c in cases) {
      final name = c['name']! as String;
      final data = _hex(c['hex']! as String);
      if (c.containsKey('frame')) {
        _sameFrame(decodeFrame(data), c['frame']! as Map<String, Object?>, name);
        ok++;
      } else {
        expect(() => decodeFrame(data), throwsA(isA<FrameError>().having((e) => e.reason, 'reason', c['error'])), reason: name);
      }
    }
    expect(ok, greaterThanOrEqualTo(20)); // the firmware's 4 golden frames and the fake board's
  });

  test('every single-bit flip of the test signal frame is refused by the same check', () {
    final b = _v['bit_flips']! as Map<String, Object?>;
    final base = _hex(b['hex']! as String);
    final want = b['refused_by']! as List;
    expect(want.length, base.length * 8);
    for (var bit = 0; bit < base.length * 8; bit++) {
      final d = Uint8List.fromList(base)..[bit ~/ 8] ^= 1 << (bit % 8);
      String got;
      try {
        decodeFrame(d);
        got = 'ok';
      } on FrameError catch (e) {
        got = e.reason;
      }
      expect(got, want[bit], reason: 'bit $bit');
    }
    expect(want, isNot(contains('ok')));
  });

  test('byte streams give the same frames, text lines and counts, chunk by chunk', () {
    for (final s in _list('streams')) {
      final name = s['name']! as String;
      final data = _hex(s['hex']! as String);
      final dec = StreamDecoder();
      var pos = 0;
      final steps = s['steps']! as List;
      final chunks = s['chunks']! as List;
      for (var i = 0; i < chunks.length; i++) {
        final n = chunks[i] as int;
        final got = dec.feed(data.sublist(pos, (pos + n).clamp(0, data.length)));
        pos += n;
        final w = steps[i] as List;
        expect([for (final f in got) f.seq], w[0], reason: '$name, chunk $i');
        expect(dec.takeLines(), w[1], reason: '$name, chunk $i');
        expect([dec.bufferLength, dec.textLength], [w[2], w[3]], reason: '$name, chunk $i');
      }
      expect([dec.frames, dec.badFrames, dec.discardedBytes], [s['frames'], s['bad_frames'], s['discarded_bytes']], reason: name);
      expect(dec.bufferLength, lessThan(e9MaxSize));
    }
  });

  test('the tracker takes the same steps: gaps, board misses, repeats, late frames, restarts, new modes', () {
    for (final t in _list('tracker')) {
      final name = t['name']! as String;
      final tr = Tracker();
      final frames = t['frames']! as List;
      final steps = t['steps']! as List;
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i] as Map<String, Object?>;
        final ch = f['channels']! as int;
        final step = tr.observe(
          E9Frame(
            channels: ch,
            flags: f['flags']! as int,
            gain: f['gain']! as int,
            fs: f['fs']! as int,
            seq: f['seq']! as int,
            timeUs: f['time_us']! as int,
            overruns: f['overruns']! as int,
            status: 0xC00000,
            counts: List.filled(ch, 0),
          ),
        );
        final w = steps[i] as Map<String, Object?>;
        expect([step.kind.name, step.lost, step.boardMissed], [w['kind'], w['lost'], w['board_missed']], reason: '$name, frame $i');
      }
      expect(
        [tr.accepted, tr.lost, tr.boardMissed, tr.duplicates, tr.stale, tr.timingAnomalies],
        [t['accepted'], t['lost'], t['board_missed'], t['duplicates'], t['stale'], t['timing_anomalies']],
        reason: name,
      );
    }
  });

  test('the firmware\'s text lines are told apart the same way', () {
    for (final t in _list('text_kinds')) {
      expect(textKind(t['line']! as String).name, t['kind'], reason: t['line'] as String?);
    }
  });

  test('volts by hand: the 1.875 mV test square at gain 24 and 4.5 V', () {
    final f = decodeFrame(_hex(_list('frames').firstWhere((c) => c['name'] == 'golden breadboard_test_signal')['hex']! as String));
    expect(f.counts.take(2), [83886, 83886]);
    expect(f.volts()[0], closeTo(4.5 / 2400, 1e-8)); // VREF / 2400 (SBAS499C p.47); 83886 is that rounded to a count
    expect(f.volts()[2], closeTo(-4.5 / 2400, 1e-8));
    expect(f.mode, 'test');
    expect(f.modeText, contains('not EEG'));
  });
}
