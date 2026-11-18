// The morning check-in's numbers on the phone against the laptop's own analysis (scripts/morning_check.py): a
// fixture made by the Python from a recorded check-in (app/test/fixtures/make_morning_fixture.py) goes through the
// Dart port, which must give the same values, the same kept segments and the same comparison rows.
//
// With MORNING_F32=<path to a recorder .f32 holding a check-in> and MORNING_JSON=<the laptop's .morning.json for it>
// the test also runs the whole check-in from the raw file (local only; never committed).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/morning/measures.dart';
import 'package:eeg_tracker/morning/pyfmt.dart';
import 'package:eeg_tracker/morning/result.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _load() =>
    jsonDecode(File('test/fixtures/morning.json').readAsStringSync()) as Map<String, Object?>;

/// One channel of µV from the fixture's gzip-compressed int32 differences (value = integer / scale).
Float64List _decode(String blob, int scale) {
  final bytes = Uint8List.fromList(gzip.decode(base64Decode(blob)));
  final d = bytes.buffer.asInt32List(0, bytes.length ~/ 4);
  final out = Float64List(d.length);
  var acc = 0;
  for (var i = 0; i < d.length; i++) {
    acc += d[i];
    out[i] = acc / scale;
  }
  return out;
}

void _close(Object? actual, Object? expected, String what, {double tol = 1e-9}) {
  if (expected == null || expected is bool || expected is String) {
    expect(actual, expected, reason: what);
    return;
  }
  expect(actual, isA<num>(), reason: what);
  final e = (expected as num).toDouble(), a = (actual! as num).toDouble();
  expect((a - e).abs(), lessThanOrEqualTo(tol * (1 + e.abs())), reason: '$what: $a vs $e');
}

void main() {
  final fixture = _load();
  final scale = fixture['scale']! as int;
  final cases = (fixture['cases']! as List).cast<Map<String, Object?>>();

  for (final c in cases) {
    final name = c['name']! as String;
    final signals = (c['signals']! as Map).cast<String, Map<String, Object?>>();
    Float64List sig(String ch, String ph) => _decode(signals[ch]![ph]! as String, scale);

    test('$name: the same kept segments as the laptop', () {
      final keep = (c['keep']! as Map).cast<String, Map<String, Object?>>();
      for (final ch in backChannels) {
        for (final ph in ['ec', 'eo']) {
          final mine = cleanSegments(sig(ch, ph)).keep;
          expect(mine, (keep[ch]![ph]! as List).cast<bool>(), reason: '$ch $ph');
        }
      }
    });

    test('$name: the same measures as the laptop', () {
      final channels = <String, ChannelMeasures>{};
      final expected = (c['channels']! as Map).cast<String, Map<String, Object?>>();
      for (final ch in backChannels) {
        final m = channelMeasures(sig(ch, 'ec'), sig(ch, 'eo'));
        channels[ch] = m;
        final mine = m.toJson();
        expect(mine.keys.toSet(), expected[ch]!.keys.toSet(), reason: ch);
        for (final k in expected[ch]!.keys) {
          _close(mine[k], expected[ch]![k], '$ch $k');
        }
      }
      final back = backSummary(channels);
      final eb = (c['back']! as Map).cast<String, Object?>();
      expect(back.keys.toSet(), eb.keys.toSet());
      for (final k in eb.keys) {
        _close(back[k], eb[k], 'back $k');
      }
    });

    if (c['detail'] != null) {
      test('$name: the filter, the spectrum and the 1/f line step by step', () {
        final d = (c['detail']! as Map).cast<String, Object?>();
        final x = sig('O1', 'ec');
        final f = bandpass1to40(x);
        final every = (d['filtered_every_50']! as List).cast<num>();
        for (var i = 0; i < every.length; i++) {
          expect((f[i * 50] - every[i]).abs(), lessThan(1e-7), reason: 'filtered sample ${i * 50}');
        }
        final seg = cleanSegments(x);
        final p = meanSpectrum(seg.kept);
        final psd = (d['psd_0_to_50hz']! as List).cast<num>();
        for (var k = 0; k < psd.length; k++) {
          _close(p[k], psd[k], 'psd bin $k', tol: 1e-8);
        }
        final line = aperiodicFit(p);
        _close(line.slope, d['slope'], 'slope', tol: 1e-8);
        _close(line.intercept, d['intercept'], 'intercept', tol: 1e-8);
      });
    }
  }

  test('the comparison rows match morning_check.compared', () {
    final cmp = (fixture['comparison']! as Map).cast<String, Object?>();
    final today = (cmp['today']! as Map).cast<String, Object?>();
    final past = (cmp['past']! as List).cast<Map<String, Object?>>();
    void same(List<Map<String, Object?>> mine, List<Object?> expected) {
      expect(mine.length, expected.length);
      for (var i = 0; i < mine.length; i++) {
        final e = (expected[i]! as Map).cast<String, Object?>();
        expect(mine[i].keys.toSet(), e.keys.toSet(), reason: '${e['key']}');
        for (final k in e.keys) {
          _close(mine[i][k], e[k], '${e['key']} $k');
        }
      }
    }

    same(compareRows(today, past), cmp['compared']! as List);
    same(compareRows(today, const []), cmp['first']! as List);
    same(compareRows(today, past.sublist(0, 1)), cmp['one']! as List);
  });

  test("Python's number formatting: exact ties go to the even digit", () {
    expect(pyFixed(28.25, 1), '28.2');
    expect(pyFixed(28.75, 1), '28.8');
    expect(pyFixed(2.675, 2), '2.67'); // 2.67499999... in binary
    expect(pyFixed(-1.5, 0), '-2');
    expect(pyFixed(0.125, 2), '0.12');
    expect(pyRound(9.615, 3), 9.615);
    expect(pyG3(28.25), '28.2');
    expect(pyG3(33), '33');
    expect(pyG3(-1.538), '-1.54');
    expect(pyG3(97.4), '97.4');
    expect(pyG3(0.5), '0.5');
    expect(pyG3(1234.5), '1.23e+03');
    expect(pyG3(0.000012345), '1.23e-05');
    expect(pyG3(0.00012345), '0.000123');
    expect(pyG3(9.996), '10');
    expect(pyG3(0), '0');
  });

  final f32 = Platform.environment['MORNING_F32'], json = Platform.environment['MORNING_JSON'];
  test('a whole recorded check-in from its raw file (local)', () {
    final laptop = jsonDecode(File(json!).readAsStringSync()) as Map<String, Object?>;
    final raw = readCheckInRecording(File(f32!));
    expect(raw, isNotNull);
    final r = analyseCheckIn(raw!.phases);
    final lb = (laptop['back']! as Map).cast<String, Object?>();
    final lines = <String>[];
    for (final k in lb.keys) {
      lines.add('back.$k laptop ${lb[k]} phone ${r.back[k]}');
      _close(r.back[k], lb[k], 'back $k');
    }
    final lc = (laptop['channels']! as Map).cast<String, Map<String, Object?>>();
    for (final ch in backChannels) {
      final mine = r.channels[ch]!.toJson();
      for (final k in lc[ch]!.keys) {
        _close(mine[k], lc[ch]![k], '$ch $k');
      }
    }
    expect(raw.ratings, laptop['ratings']);
    // ignore: avoid_print
    print(lines.join('\n'));
  }, skip: f32 == null || json == null ? 'set MORNING_F32 and MORNING_JSON to run' : false);
}
