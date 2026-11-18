// Cross-check: a session run by the laptop page's JavaScript core (fixtures/js_session.json, made by
// fixtures/make_js_session.mjs) is fed through the Dart port. Both must take the same decisions: the same
// phases, gates, cues and bells at the same samples. Numbers may differ in the last bits (JS and Dart compute
// sin, exp and log differently), so they are compared with a small tolerance (sound-log.js port notes).
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/feedback/session.dart';
import 'package:eeg_tracker/feedback/session_log.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _load() =>
    jsonDecode(File('test/fixtures/js_session.json').readAsStringSync()) as Map<String, Object?>;

/// Equal, with numbers within [tol] (absolute, or relative for large values).
void _same(Object? dart, Object? js, String where, {double tol = 1e-9}) {
  if (dart is num && js is num) {
    final scale = js.abs() > 1 ? js.abs() : 1;
    expect((dart - js).abs() <= tol * scale, isTrue, reason: '$where: dart $dart, js $js');
  } else if (dart is Map && js is Map) {
    expect(dart.keys.toSet(), js.keys.toSet(), reason: '$where: keys');
    for (final k in js.keys) {
      _same(dart[k], js[k], '$where.$k', tol: tol);
    }
  } else if (dart is List && js is List) {
    expect(dart.length, js.length, reason: '$where: length');
    for (var i = 0; i < js.length; i++) {
      _same(dart[i], js[i], '$where[$i]', tol: tol);
    }
  } else {
    expect(dart, js, reason: where);
  }
}

void main() {
  test('a JavaScript session through the Dart core: same phases, gates, cues and bells', () {
    final saved = _load();
    final jsLines = (saved['lines']! as List).cast<Map<String, Object?>>();
    final dart = replaySession(saved);
    // Through JSON, as both sides would store it.
    final dartLines = (jsonDecode(jsonEncode(dart.log.lines)) as List).cast<Map<String, Object?>>();

    List<int> at(List<Map<String, Object?>> lines, String type) => [
      for (final l in lines)
        if (l['type'] == type) l['n']! as int,
    ];
    expect(at(dartLines, 'bell'), at(jsLines, 'bell'), reason: 'bells at the same samples');
    expect(at(jsLines, 'bell').length, greaterThanOrEqualTo(4));
    expect(at(dartLines, 'cue'), at(jsLines, 'cue'));
    expect(dartLines.length, jsLines.length);

    var zDiffs = 0;
    for (var i = 0; i < jsLines.length; i++) {
      final js = jsLines[i], d = dartLines[i];
      expect(d['type'], js['type'], reason: 'line $i');
      expect(d['n'], js['n'], reason: 'line $i');
      if (js['type'] == 'step') {
        for (final k in ['q', 'v', 's', 'ring']) {
          expect(d[k], js[k], reason: 'line $i ($k) at n ${js['n']}');
        }
        // 3-decimal values: a last-bit difference can flip the rounding of the third decimal
        for (final k in ['z', 'calm', 'rough']) {
          _same(d[k], js[k], 'line $i $k', tol: 0.0011);
          if (d[k] != js[k]) zDiffs++;
        }
      } else {
        _same(d, js, 'line $i (${js['type']})', tol: 1e-6);
      }
    }
    // Last-bit differences are rare, not the rule.
    expect(zDiffs, lessThan(jsLines.length ~/ 100), reason: '$zDiffs rounded values differ');
  });

  test('the JavaScript input decodes to the same float32 samples the JS core used', () {
    final saved = _load();
    final input = decodeInput(saved['input']);
    expect(input.length, 4);
    expect(input[0].length, (saved['input']! as Map)['samples']);
    // Re-encoding gives the same text: the byte layout (float32, little-endian, base64) matches.
    final s = Session();
    for (var i = 0; i < 100; i++) {
      s.push([
        [input[0][i], input[1][i], input[2][i], input[3][i]],
      ]);
    }
    final again = decodeInput(s.log.toJson()['input']);
    for (var c = 0; c < 4; c++) {
      expect(again[c], input[c].sublist(0, 100));
    }
  });
}
