// Sleep periods (the cases of analysis/tests/test_sleep_report.py), the report file, the staleness rule, and a
// whole night scored by SleepScorer with a fake model in place of ONNX Runtime (it cannot run in `flutter test`).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/onnx_runs.dart';
import 'package:eeg_tracker/sleep/periods.dart';
import 'package:eeg_tracker/sleep/prep.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 'W', n1 = 'N1', n2 = 'N2', n3 = 'N3', r = 'R', gap = 'gap';
List<String> rep(String s, int n) => List.filled(n, s);

void main() {
  group('periods, as sleep_report.py', () {
    test('split on an hour of wake or missing data', () {
      final stages = [
        ...rep(w, 40), ...rep(n2, 240), ...rep(w, 14), ...rep(n3, 60), ...rep(w, 6), ...rep(r, 40), ...rep(w, 60),
        ...rep(n2, 20), ...rep(w, 80), ...rep(gap, 40), // 40 min awake + 20 min missing = 60 min: a new period
        ...rep(n1, 4), ...rep(n2, 116), ...rep(w, 240), ...rep(n1, 6), ...rep(w, 10),
      ];
      final found = sleepPeriods(stages);
      expect([for (final p in found.periods) (p.first, p.last)], [(40, 479), (600, 719)]);
      final night = found.periods[0], nap = found.periods[1];
      expect(night.asleepMin, 180);
      expect(night.stageMin, {'W': 40, 'N1': 0, 'N2': 130, 'N3': 30, 'R': 20});
      expect([for (final x in night.wakeUps) x.awakeMin], [7, 30]); // the 3-minute one is not over 5 min
      expect(night.missingMin, 0);
      expect((nap.asleepMin, nap.stageMin['N1'], nap.wakeUps.length), (60, 2, 0));
      expect(found.straySleepMin, 3); // the 3-minute blip after 2 h awake is too short to be a period
    });

    test('boundaries', () {
      expect(sleepPeriods([...rep(n2, 30), ...rep(w, 119), ...rep(n2, 30)]).periods, hasLength(1));
      expect(sleepPeriods([...rep(n2, 30), ...rep(w, 120), ...rep(n2, 30)]).periods, hasLength(2));
      expect(sleepPeriods([...rep(n2, 30), ...rep(w, 10), ...rep(n2, 30)]).periods.single.wakeUps, isEmpty);
      expect(sleepPeriods([...rep(n2, 30), ...rep(w, 11), ...rep(n2, 30)]).periods.single.wakeUps, hasLength(1));
      final p = sleepPeriods([...rep(n2, 30), ...rep(w, 6), ...rep(gap, 20), ...rep(w, 4), ...rep(n2, 30)]).periods.single;
      expect((p.wakeUps.length, p.missingMin), (0, 10));
      final short = sleepPeriods([...rep(w, 10), ...rep(n2, 19), ...rep(w, 10)]);
      expect((short.periods.length, short.straySleepMin), (0, 9.5));
      expect(sleepPeriods([]).periods, isEmpty);
    });

    test('confidence is the mean top probability over the scored epochs', () {
      final stages = [...rep(n2, 20), ...rep(w, 2), ...rep(gap, 1), ...rep(r, 2)];
      final p = sleepPeriods(stages, confidence: [...List.filled(12, 0.9), ...List.filled(13, 0.5)]).periods.single;
      expect(p.confidence, closeTo((12 * 0.9 + 12 * 0.5) / 24, 1e-3));
    });
  });

  group('report file', () {
    final start = DateTime(2026, 11, 18, 2, 40, 13);

    test('fields and totals use the laptop names', () {
      final stages = [...rep(w, 4), ...rep(n2, 20), ...rep(n3, 6), ...rep(w, 12), ...rep(r, 4), ...rep(gap, 2), ...rep(w, 2)];
      final json = buildReport(
        nightOf: '2026-11-17',
        built: DateTime(2026, 11, 18, 9),
        scoringSeconds: 81.26,
        start: start,
        lengthSeconds: stages.length * 30.0,
        inputs: {'2026-11-18-024013.f32': 2000},
        model: phoneModelId,
        stages: stages,
        confidence: List.filled(stages.length, 0.81234),
      );
      final round = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      for (final k in ['version', 'night_of', 'built', 'scoring_s', 'data_start', 'data_end', 'inputs', 'scored',
          'note', 'validated', 'rules', 'periods', 'total', 'hypnogram', 'sleep_json', 'bdf', 'model',
          'cross_check']) {
        expect(round.containsKey(k), isTrue, reason: k);
      }
      expect(round['scoring_s'], 81.3);
      expect(round['validated'], isFalse);
      expect(round['stages'], 'WWWW${'2' * 20}333333${'W' * 12}RRRR--WW');
      final p = (round['periods'] as List).single as Map<String, dynamic>;
      expect(p['start'], isoLocal(start.add(const Duration(minutes: 2))));
      expect(p['end'], isoLocal(start.add(const Duration(minutes: 23))));
      expect((p['asleep_min'], p['light_min'], p['deep_min'], p['dream_min'], p['awake_min']), (15, 10, 3, 2, 6));
      expect((p['wake_ups'], p['confidence']), (1, 0.812));
      expect((p['wake_up_list'] as List).single, {'start': isoLocal(start.add(const Duration(minutes: 15))), 'awake_min': 6.0});
      final t = round['total'] as Map<String, dynamic>;
      expect((t['asleep_min'], t['periods'], t['recorded_min'], t['missing_min'], t['wake_ups']), (15, 1, 24, 1, 1));

      final back = SleepReport(round);
      expect(back.stages.length, stages.length);
      expect(back.stages.sublist(46, 48), [gap, gap]);
      expect(back.periods.single.deepMin, 3);
      expect(back.dataStart, start);
    });

    test('under 5 minutes: an unscored report', () {
      final json = buildReport(nightOf: '2026-11-17', built: start, scoringSeconds: 0.2, start: start, lengthSeconds: 170,
          inputs: const {}, model: phoneModelId);
      expect((json['scored'], (json['periods'] as List).length, (json['total'] as Map)['recorded_min']), (false, 0, 2.8));
      expect(SleepReport(jsonDecode(jsonEncode(json)) as Map<String, dynamic>).stages, isEmpty);
    });

    test('ISO time with the zone offset, like Python', () {
      final t = DateTime(2026, 11, 18, 3, 16, 55);
      final off = t.timeZoneOffset;
      final sign = off.isNegative ? '-' : '+';
      final hh = (off.inMinutes.abs() ~/ 60).toString().padLeft(2, '0');
      final mm = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
      expect(isoLocal(t), '2026-11-18T03:16:55$sign$hh:$mm');
      expect(DateTime.parse(isoLocal(t)).isAtSameMomentAs(t), isTrue);
    });

    test('out of date by the data only: missing, a file gone or shrunk, 10+ minutes new', () {
      SleepReport report(Map<String, int> inputs, {int version = reportVersion}) => SleepReport({
        'version': version,
        'inputs': [for (final e in inputs.entries) {'file': e.key, 'bytes': e.value}],
        'drift_off': null,
      });
      const min = 60 * 250 * 20; // bytes per minute
      final files = {'a.f32': 60 * min, 'b.f32': 30 * min};
      expect(isStale(files, null), isTrue);
      expect(isStale(files, report(files)), isFalse);
      expect(isStale(files, report({'a.f32': 60 * min, 'b.f32': 21 * min})), isFalse); // 9 min behind
      expect(isStale(files, report({'a.f32': 60 * min, 'b.f32': 20 * min})), isTrue);
      expect(isStale(files, report({'a.f32': 60 * min})), isTrue); // b.f32 is new
      expect(isStale(files, report({...files, 'gone.f32': 20})), isTrue);
      // DECISIONS row 580: an older version, a report from before drift_off and another model are kept as they are
      final phone = SleepReport({...report(files).json, 'scored': true, 'model': phoneModelId});
      final older = [
        report(files, version: 0),
        SleepReport({...phone.json}..remove('drift_off')),
        SleepReport({...phone.json, 'model': 'old pieces'}),
      ];
      for (final r in older) {
        expect(isStale(files, r), isFalse);
        expect(scoredByOlder(r, model: phoneModelId), isTrue);
      }
      expect(scoredByOlder(phone, model: phoneModelId), isFalse);
      expect(scoredByOlder(SleepReport({...phone.json, 'scored': false, 'model': null}), model: phoneModelId), isFalse);
    });
  });

  group('SleepScorer', () {
    late Directory root, recordings;
    late NightReportStore store;

    setUp(() {
      root = Directory.systemTemp.createTempSync('scorer_test');
      recordings = Directory('${root.path}/recordings')..createSync();
      store = NightReportStore(nightsDirFor(recordings.path));
    });
    tearDown(() => root.deleteSync(recursive: true));

    /// A recorder run of [minutes] at [start]: noise, one batch a second in the .idx.
    void writeRun(DateTime start, double minutes) {
      final n = (minutes * 60 * 250).round();
      final rng = math.Random(1);
      final rec = ByteData(n * recordBytes);
      for (var i = 0; i < n; i++) {
        rec.setUint32(i * recordBytes, i % 2048, Endian.little);
        for (var c = 0; c < 4; c++) {
          rec.setFloat32(i * recordBytes + 4 + 4 * c, 20e-6 * (rng.nextDouble() - 0.5), Endian.little);
        }
      }
      final stem = fileStem(start);
      File('${recordings.path}/$stem.f32').writeAsBytesSync(rec.buffer.asUint8List());
      final rows = n ~/ 250;
      final idx = ByteData(rows * indexBytes);
      for (var k = 0; k < rows; k++) {
        idx
          ..setFloat64(k * indexBytes, start.millisecondsSinceEpoch / 1000 + k + 1, Endian.little)
          ..setUint64(k * indexBytes + 8, k * 250, Endian.little);
      }
      File('${recordings.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
    }

    /// Stages by epoch from the start of the night: 2 min W, 6 min N2, 2 min N3, 2 min R, then W.
    StageRun fake(List<int> calls) => _FakeRun(calls, (e) => e < 4 ? 0 : e < 16 ? 2 : e < 20 ? 3 : e < 24 ? 4 : 0);

    test('scores a due night, writes its report, and skips it the second time', () async {
      writeRun(DateTime(2026, 11, 18, 23, 0), 14);
      final calls = <int>[];
      final steps = <String>[];
      final scorer = SleepScorer(
        recordingsDir: recordings,
        store: store,
        openRun: (run) async => fake(calls),
        prepare: (files) async => prepareNight(files),
        see: (files) async => seeNight(files),
      );
      final due = scorer.due();
      expect(due.map((n) => n.name), ['2026-11-18']);
      final report = await scorer.score(due.single, progress: steps.add);
      expect(steps.first, 'Preparing the recording');
      expect(steps.sublist(1, 4), ['Sleep model 0 % (run 1 of 3)', 'Sleep model 33 % (run 2 of 3)', 'Sleep model 66 % (run 3 of 3)']);
      expect(steps.last, 'Counting jaw, movement and signal'); // one step at a time: the detectors after the model
      expect(calls, [28, 28, 28]); // 14 minutes = 28 epochs, one piece, three runs
      expect(report.scored, isTrue);
      expect(report.periods.single.asleepMin, 10);
      expect(report.periods.single.deepMin, 2);
      expect(store.read('2026-11-18')!.json['stages'], startsWith('WWWW2222'));
      final extras = report.extras!; // the detectors' pass over the same samples
      expect(extras.quality, hasLength(28));
      expect(extras.asleep.min, 10);
      expect(report.json['extras_error'], isNull);
      expect(store.markerFor('2026-11-18').existsSync(), isFalse);
      expect(scorer.due(), isEmpty);

      writeRun(DateTime(2026, 11, 18, 23, 20), 12); // 12 minutes more the same night: out of date again
      expect(scorer.due().single.recordings, hasLength(2));
    });

    test('a failed detectors\' pass leaves the report without extras, saying why', () async {
      writeRun(DateTime(2026, 11, 18, 23, 0), 14);
      final steps = <String>[];
      final scorer = SleepScorer(
        recordingsDir: recordings,
        store: store,
        openRun: (run) async => fake([]),
        prepare: (files) async => prepareNight(files),
        see: (files) => Future.delayed(const Duration(milliseconds: 50), () => throw StateError('no memory')),
      );
      final report = await scorer.score(scorer.due().single, progress: steps.add);
      expect(report.scored, isTrue);
      expect(report.periods.single.asleepMin, 10);
      expect((report.extras, report.json['extras_error']), (null, 'Bad state: no memory'));
      expect(steps.last, 'Counting jaw, movement and signal'); // the model was done first
      expect(store.markerFor('2026-11-18').existsSync(), isFalse);
    });

    test('a failed or interrupted night is blocked until "Try again"', () async {
      writeRun(DateTime(2026, 11, 18, 23, 0), 6);
      final scorer = SleepScorer(
        recordingsDir: recordings,
        store: store,
        openRun: (run) async => throw StateError('no memory'),
        prepare: (files) async => prepareNight(files),
      );
      await expectLater(scorer.score(scorer.due().single), throwsStateError);
      expect(scorer.blocked(), {'2026-11-18': 'Bad state: no memory'});
      expect(scorer.due(), isEmpty);
      scorer.unblock('2026-11-18');
      expect(scorer.due(), hasLength(1));
    });

    test('the bundled models: the real three load from the assets, a copy is made once and renewed on change',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      for (var r = 1; r <= anySleepRuns; r++) {
        final data = await rootBundle.load(anySleepAsset(r));
        expect(data.lengthInBytes, greaterThan(5e6)); // listed in pubspec.yaml and present
      }
      final dir = Directory('${root.path}/models');
      final bundle = _Bundle(Uint8List.fromList(List.generate(1000, (i) => i % 251)));
      final first = await modelFile(1, dir, bundle: bundle);
      final again = await modelFile(1, dir, bundle: bundle);
      expect(again.path, first.path);
      bundle.bytes = Uint8List.fromList(List.generate(1000, (i) => (i * 7) % 251)); // a new export, same size
      final updated = await modelFile(1, dir, bundle: bundle);
      expect(updated.path, isNot(first.path));
      expect(dir.listSync().map((f) => f.uri.pathSegments.last), [updated.uri.pathSegments.last]);
      expect(updated.readAsBytesSync(), bundle.bytes);
    });

    test('pieces cover every epoch once and each sees its context (more in sleep_two_pass_test.dart)', () {
      expect(pieces(175), [(w0: 0, w1: 175, c0: 0, c1: 175)]);
      expect(pieces(176), [(w0: 0, w1: 144, c0: 0, c1: 128), (w0: 112, w1: 176, c0: 128, c1: 176)]);
      final ps = pieces(1000);
      expect(ps.first, (w0: 0, w1: 152, c0: 0, c1: 128)); // 1000 - 152 is a multiple of 16
      expect(ps.last, (w0: 880, w1: 1000, c0: 896, c1: 1000));
      final kept = [for (final p in ps) for (var e = p.c0; e < p.c1; e++) e];
      expect(kept, List.generate(1000, (e) => e));
      expect(ps.every((p) => p.w1 - p.w0 <= maxWindowEpochs), isTrue);
    });

    test('a model that returns the wrong number of values is an error, not a report', () async {
      final input = ModelInput(startUnix: 0, epochs: 12, gap: List.filled(12, false),
          channels: List.generate(4, (_) => Float32List(12 * epochSamples)), percentiles: const [],
          recordedSamples: 12 * 7500, missingSamples: 0);
      await expectLater(stageProbabilities(input, 1, (_) async => _FakeRun([], (e) => 0, short: true)),
          throwsStateError);
    });
  });
}

class _Bundle extends CachingAssetBundle {
  _Bundle(this.bytes);
  Uint8List bytes;

  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(bytes);
}

class _FakeRun implements StageRun {
  _FakeRun(this.calls, this.stageAt, {this.short = false});
  final List<int> calls;
  final int Function(int epoch) stageAt;
  final bool short;

  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) =>
      throw UnimplementedError('these nights fit one piece');

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    expect((x.length, means), (epochs * epochSamples * 4, null));
    calls.add(epochs);
    final out = Float32List((short ? epochs - 1 : epochs) * 5);
    for (var e = 0; e < out.length ~/ 5; e++) {
      out[e * 5 + stageAt(e)] = 3; // softmax: about 0.83 for the stage
    }
    return out;
  }
}
