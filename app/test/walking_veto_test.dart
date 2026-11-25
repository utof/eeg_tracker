// The walking veto where the phone scores sleep (DECISIONS 920): the night's report (the detectors' pass finds the
// walking epochs, the scorer scores them awake) the live scorer (the walking detector beside the model) and "Sleep so far"
// (the walking detector over each of its windows). The signal is the walking cross-check fixture's first case (walk, stop, run on O1 O2 T3 T4; the walking rule itself is
// compared with the Python reference in walking_cross_check_test.dart), then quiet noise; the fake model calls every
// epoch deep sleep.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/live_prep.dart';
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/prep.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/sleep/so_far.dart';
import 'package:eeg_tracker/walking/detector.dart';
import 'package:flutter_test/flutter_test.dart';

const int _rate = 250;

/// [minutes] of signal, sample-major rows of µV as the files hold them (float32 volts): the fixture's first case,
/// then quiet noise.
List<Float32List> _night(double minutes) {
  final fx = jsonDecode(File('test/fixtures/walking.json').readAsStringSync()) as Map<String, Object?>;
  final c = (fx['cases']! as List).cast<Map<String, Object?>>().first;
  expect(c['channels'], ['O1', 'O2', 'T3', 'T4']);
  expect(c['sample_rate'], _rate);
  final n = c['n']! as int, scale = fx['scale']! as int;
  final d = Uint8List.fromList(gzip.decode(base64Decode(c['signal']! as String))).buffer.asInt32List();
  final total = (minutes * 60 * _rate).round();
  final rng = math.Random(5);
  final q = List.filled(4, 0);
  return [
    for (var i = 0; i < total; i++)
      () {
        final row = Float32List(4);
        for (var ch = 0; ch < 4; ch++) {
          if (i < n) {
            q[ch] += d[ch * n + i];
            row[ch] = q[ch] / scale * 1e-6;
          } else {
            row[ch] = 20e-6 * (rng.nextDouble() - 0.5);
          }
        }
        return row;
      }(),
  ];
}

/// The walking detector's own answer per epoch over [rows], as the files give them back (µV).
List<bool> _walking(List<Float32List> rows, int epochs) {
  final det = WalkWindows(4, _rate);
  for (final r in rows) {
    det.push([for (final v in r) v * 1e6]);
  }
  return walkingEpochs(det.windows, epochs);
}

class _DeepRun implements StageRun {
  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) =>
      throw UnimplementedError('this night fits one piece');

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    final out = Float32List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      out[e * 5 + 3] = 3;
    }
    return out;
  }
}

class _DeepModel implements LiveModel {
  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    final p = Float64List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      for (var k = 0; k < 5; k++) {
        p[e * 5 + k] = k == 3 ? 0.8 : 0.05;
      }
    }
    return p;
  }

  @override
  Future<void> close() async {}
}

/// [rows] as one recorder file set in [recordings] that began at [start].
void _write(Directory recordings, List<Float32List> rows, DateTime start) {
  final rec = ByteData(rows.length * recordBytes);
  for (var i = 0; i < rows.length; i++) {
    rec.setUint32(i * recordBytes, i % 2048, Endian.little);
    for (var c = 0; c < 4; c++) {
      rec.setFloat32(i * recordBytes + 4 + 4 * c, rows[i][c], Endian.little);
    }
  }
  final stem = fileStem(start);
  File('${recordings.path}/$stem.f32').writeAsBytesSync(rec.buffer.asUint8List());
  final seconds = rows.length ~/ _rate;
  final idx = ByteData(seconds * indexBytes);
  for (var k = 0; k < seconds; k++) {
    idx
      ..setFloat64(k * indexBytes, start.millisecondsSinceEpoch / 1000 + k + 1, Endian.little)
      ..setUint64(k * indexBytes + 8, k * _rate, Endian.little);
  }
  File('${recordings.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
}

void main() {
  test("the night's report: walking epochs are scored awake, the rest stays as the model said", () async {
    final root = Directory.systemTemp.createTempSync('walk_veto');
    addTearDown(() => root.deleteSync(recursive: true));
    final recordings = Directory('${root.path}/recordings')..createSync();
    final store = NightReportStore(nightsDirFor(recordings.path));
    final rows = _night(14);
    final start = DateTime(2026, 11, 20, 19, 0);
    _write(recordings, rows, start);

    final scorer = SleepScorer(
      recordingsDir: recordings,
      store: store,
      openRun: (run) async => _DeepRun(),
      prepare: (files) async => prepareNight(files),
      see: (files) async => seeNight(files),
    );
    final report = await scorer.score(scorer.due().single);
    final want = _walking(rows, 28);
    expect(want.sublist(0, 5), [true, true, true, false, false], reason: 'walk 90 s, stop 60 s');
    expect(want.sublist(8), everyElement(isFalse), reason: 'quiet noise is not walking');
    final w = report.json['walking']! as Map<String, dynamic>;
    final walkingEpochsN = want.where((x) => x).length;
    expect(w['detector'], walkDetector);
    expect(w['epochs'], want.map((x) => x ? '1' : '0').join());
    expect([w['walking_min'], w['changed_min']], [walkingEpochsN * 0.5, walkingEpochsN * 0.5]);
    expect(report.json['stages'], want.map((x) => x ? 'W' : '3').join());
    expect(report.walkingChangedMin, walkingEpochsN * 0.5);
    expect(report.asleepMin, (28 - walkingEpochsN) * 0.5);
    expect(scorer.olderScorer(report), isFalse);
    // a report from before the veto offers "Score again"
    expect(scorer.olderScorer(SleepReport(Map.of(report.json)..remove('walking'))), isTrue);
  });

  test('"Sleep so far" scores a walking epoch awake too; without the rule it is what the model said', () async {
    final root = Directory.systemTemp.createTempSync('walk_so_far');
    addTearDown(() => root.deleteSync(recursive: true));
    final rows = _night(14); // 28 epochs: walk, stop, run, then quiet
    Future<List<String>> look(String name, {required bool rule}) async {
      final recordings = Directory('${root.path}/$name/recordings')..createSync(recursive: true);
      _write(recordings, rows, DateTime(2026, 11, 20, 19, 0));
      final s = SoFarScorer(
        recordingsDir: recordings,
        openRun: (run) async => _DeepRun(),
        plan: (d, since) async => planSoFar(d, since),
        prepare: (l, w0, w1, to) async => prepareWindow(l, w0, w1, to),
        walking: rule ? (l, w0, w1, to) async => walkingOfWindow(l, w0, w1, to) : null,
      );
      return (await s.update())!.stages;
    }

    final want = _walking(rows, 28);
    final got = await look('rule', rule: true);
    expect(got, hasLength(28 - soFarBehind));
    expect(got, [for (var e = 0; e < got.length; e++) want[e] ? 'W' : 'N3']);
    expect(got.take(5), ['W', 'W', 'W', 'N3', 'N3'], reason: 'walk 90 s, stop 60 s');
    expect(got.where((s) => s == 'W').length, want.where((w) => w).length);
    expect(await look('plain', rule: false), everyElement('N3'));
  });

  test('the live scorer hands a walking epoch out awake; without the veto it is what the model said', () async {
    final rows = _night(7.5); // 15 epochs
    Future<List<LiveStage>> run({required bool veto}) async {
      final s = LiveStager(
        model: _DeepModel(),
        prep: LivePrep(window: 12),
        scale: (w) async => scaleWindow(w),
        walkingVeto: veto,
      );
      for (var i = 0; i < rows.length; i++) {
        s.push([for (final v in rows[i]) v * 1e6]);
        if (i % inputEpochSamples == inputEpochSamples - 1) {
          for (var k = 0; k < 8; k++) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }
      await s.idle();
      await s.close();
      return s.stages;
    }

    final got = await run(veto: true);
    final want = _walking(rows, 15);
    expect(got.length, greaterThanOrEqualTo(10));
    expect([for (final g in got) g.epoch], [for (var e = 0; e < got.length; e++) e]);
    expect([for (final g in got) g.stage], [for (var e = 0; e < got.length; e++) want[e] ? 'W' : 'N3']);
    expect([for (final g in got) g.walking], want.sublist(0, got.length));
    expect(got.take(5).map((g) => g.stage), ['W', 'W', 'W', 'N3', 'N3']);
    final plain = await run(veto: false);
    expect(plain.map((g) => g.stage), everyElement('N3'));
  });

  test('a hole in the live stream is no walking', () async {
    final s = LiveStager(model: _DeepModel(), prep: LivePrep(window: 12), scale: (w) async => scaleWindow(w));
    final rows = _night(1.5); // the walk's first 90 s
    for (final r in rows) {
      s.push([for (final v in r) v * 1e6]);
    }
    s.hold(4 * inputEpochSamples);
    for (var i = 0; i < 9 * inputEpochSamples + 40; i++) {
      s.push([3.0 * math.sin(i * 0.3), 2.0, -1.0, 0.5 * (i % 5)]);
      if (i % inputEpochSamples == 0) await Future<void>.delayed(Duration.zero);
    }
    await s.idle();
    await s.close();
    final by = {for (final g in s.stages) g.epoch: g};
    expect([by[0]!.stage, by[1]!.stage], ['W', 'W']);
    expect([for (var e = 3; e < 7; e++) by[e]!.stage], everyElement('gap'));
    expect([for (var e = 8; e < 10; e++) by[e]!.stage], everyElement('N3'));
  });
}
