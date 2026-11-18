// Cross-check of the night extras against the Python reference (analysis/night_extras.py; fixture made by
// analysis/make_extras_fixture.py, no clock times or device numbers):
// - three recorder runs built from the recorded excerpts of detectors.json, joined and fed through the detectors as
//   the scorer does (`seeNight`), must give the reference's epoch quality, bursts and movements;
// - the events of a whole recorded night with its stages must give the reference's extras, every number equal.
// The whole night itself (recordings to extras) is compared on the laptop: app/tool/night_extras.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show indexBytes, recordBytes;
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// µV rows of a detectors.json excerpt (gzip-compressed int32 differences / scale), as its cross-check decodes them.
List<List<double>> _excerpt(Map<String, dynamic> e, int scale) {
  final n = e['n'] as int;
  final d = Uint8List.fromList(gzip.decode(base64Decode(e['signal'] as String))).buffer.asInt32List();
  final rows = [for (var i = 0; i < n; i++) List<double>.filled(4, 0)];
  for (var c = 0; c < 4; c++) {
    var q = 0;
    for (var i = 0; i < n; i++) {
      q += d[c * n + i];
      rows[i][c] = q / scale;
    }
  }
  return rows;
}

/// A recorder run as make_extras_fixture.py writes it: one index row per [batch] samples, its time just after the
/// batch's last sample.
File _writeRun(Directory dir, String name, double t0, List<List<double>> uv, int batch, double arrival) {
  final n = uv.length;
  final rec = ByteData(n * recordBytes);
  for (var i = 0; i < n; i++) {
    rec.setUint32(i * recordBytes, i % 2048, Endian.little);
    for (var c = 0; c < 4; c++) {
      rec.setFloat32(i * recordBytes + 4 + 4 * c, uv[i][c] * 1e-6, Endian.little);
    }
  }
  final f = File('${dir.path}/$name.f32')..writeAsBytesSync(rec.buffer.asUint8List());
  final rows = (n + batch - 1) ~/ batch;
  final idx = ByteData(rows * indexBytes);
  for (var k = 0; k < rows; k++) {
    final last = (k + 1) * batch < n ? (k + 1) * batch : n;
    idx
      ..setFloat64(k * indexBytes, t0 + last / 250 + arrival, Endian.little)
      ..setUint64(k * indexBytes + 8, k * batch, Endian.little);
  }
  File('${dir.path}/$name.idx').writeAsBytesSync(idx.buffer.asUint8List());
  return f;
}

const _kinds = {'jaw': BurstKind.jaw, 'one-sided': BurstKind.oneSided, 'movement': BurstKind.movement};
const _qualities = {'good': EpochQuality.good, 'degraded': EpochQuality.degraded, 'missing': EpochQuality.missing};
const _charQuality = {'g': EpochQuality.good, 'd': EpochQuality.degraded, 'm': EpochQuality.missing};
const _charStage = {'W': 'W', '1': 'N1', '2': 'N2', '3': 'N3', 'R': 'R', '-': 'gap'};

void main() {
  final fixture = _json('test/fixtures/night_extras.json');

  test('recorded excerpts joined from three runs: the same quality, bursts and movements as the reference', () {
    final f = fixture['files'] as Map<String, dynamic>;
    final source = _json('test/fixtures/detectors.json');
    final excerpts = {for (final e in (source['excerpts'] as List).cast<Map<String, dynamic>>()) e['name']: e};
    final dir = Directory.systemTemp.createTempSync('extras_cross');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = [
      for (final r in (f['runs'] as List).cast<Map<String, dynamic>>())
        _writeRun(dir, r['file'] as String, (r['t0'] as num).toDouble(),
            _excerpt(excerpts[r['excerpt']]!, source['scale'] as int), f['batch'] as int, (f['arrival_s'] as num).toDouble()),
    ];
    expect(joinLayout(files).samples, f['samples']);
    final seen = seeNight(files)!;
    expect(seen.quality, [for (final q in f['quality'] as List) _qualities[q]]);
    expect([for (final b in seen.bursts) (b.start, b.end, b.kind)],
        [for (final b in (f['bursts'] as List).cast<List<Object?>>()) (b[0], b[1], _kinds[b[2]])]);
    expect([for (final (a, b) in seen.moves) [a, b]], f['moves']);
  });

  test('a whole recorded night: the same extras as the reference, every number', () {
    final n = fixture['night'] as Map<String, dynamic>;
    final out = nightExtras(
      quality: [for (final c in (n['quality'] as String).split('')) _charQuality[c]!],
      bursts: [
        for (final b in (n['bursts'] as List).cast<List<Object?>>()) Burst(b[0]! as int, b[1]! as int, _kinds[b[2]]!, 0),
      ],
      moves: [for (final m in (n['moves'] as List).cast<List<Object?>>()) (m[0]! as int, m[1]! as int)],
      stages: [for (final c in (n['stages'] as String).split('')) _charStage[c]!],
      periods: [for (final p in (n['periods'] as List).cast<List<Object?>>()) (p[0]! as int, p[1]! as int)],
      firstEdge: n['first_edge_s'] as int,
    );
    final want = n['expected'] as Map<String, dynamic>;
    expect(jsonDecode(jsonEncode(out)), want);
    expect((want['asleep'] as Map)['jaw_bursts'], greaterThan(0)); // the night has events to count
    expect((want['hours'] as List).length, greaterThan(10));
  });
}
