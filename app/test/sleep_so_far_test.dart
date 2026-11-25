// "Sleep so far" (lib/sleep/so_far.dart, DECISIONS 640-649): the night that records is scored in kept 80-minute
// windows plus its newest minutes, only what is new at each look. Real recorder files that grow between looks, the
// real preparation (in this isolate), and fake model runs whose outputs follow from their inputs (ONNX cannot run in
// `flutter test`), so equal inputs give equal stages and every model call is counted.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/packed.dart' show packRaw;
import 'package:eeg_tracker/sleep/live_log.dart';
import 'package:eeg_tracker/sleep/live_prep.dart' show LiveWindow;
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/night_scorer.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/sleep/periods.dart' show gapStage;
import 'package:eeg_tracker/sleep/prep.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/sleep/so_far.dart';
import 'package:flutter_test/flutter_test.dart';

/// One recorder file set that grows as a night records: one batch a second, its `.idx` row just after its last sample.
/// With [names], a recording of that many channels with its header (header.dart); channel `names[i]` carries what the
/// BrainBit's channel of the same name would (O1 O2 T3 T4), any other a signal of its own.
class GrowingRun {
  GrowingRun(this.dir, this.start, {this.names}) : stem = fileStem(start) {
    final n = names;
    if (n != null) {
      writeHeader(f32, RecordingHeader(channels: [for (final c in n) HeaderChannel(c, site: c == 'T3' ? 'T7' : c)]));
    }
  }
  final Directory dir;
  final DateTime start;
  final String stem;
  final List<String>? names;
  int samples = 0;

  int get width => names?.length ?? 4;

  /// The BrainBit channel a column carries (0-3), or another signal (4 on).
  int _source(int column) {
    final n = names;
    if (n == null) return column;
    final i = const ['O1', 'O2', 'T3', 'T4'].indexOf(n[column]);
    return i >= 0 ? i : 4 + column;
  }

  File get f32 => File('${dir.path}/$stem.f32');

  /// Sample [i] of this run in volts: slow waves of a few changing sizes, so the windows' stages differ.
  double _v(int i, int c) {
    final t = (i + start.second * 250) / 250;
    final slow = math.sin(t * 0.9 + c) * (40 + 30 * math.sin(t / 700 + c));
    final fast = math.sin(t * 61.0 + c * 2) * (5 + 4 * math.cos(t / 300));
    return (slow + fast + 12000 * (c.isEven ? 1 : -1)) * 1e-6;
  }

  void grow(double minutes) {
    final n = (minutes * 60 * 250).round();
    final rb = 4 + 4 * width;
    final rec = ByteData(n * rb);
    for (var j = 0; j < n; j++) {
      final i = samples + j;
      rec.setUint32(j * rb, i % 2048, Endian.little);
      for (var c = 0; c < width; c++) {
        rec.setFloat32(j * rb + 4 + 4 * c, _v(i, _source(c)), Endian.little);
      }
    }
    final rows = n ~/ 250;
    final idx = ByteData(rows * indexBytes);
    for (var k = 0; k < rows; k++) {
      final first = samples + k * 250;
      idx
        ..setFloat64(k * indexBytes, start.millisecondsSinceEpoch / 1000 + first / 250 + 1, Endian.little)
        ..setUint64(k * indexBytes + 8, first, Endian.little);
    }
    f32.writeAsBytesSync(rec.buffer.asUint8List(), mode: FileMode.append);
    File('${dir.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List(), mode: FileMode.append);
    samples += n;
  }
}

/// A model run whose logits follow from its input; every call is counted in [calls]. [onCall] runs after each.
class FakeRun implements StageRun {
  FakeRun(this.run, this.calls, {this.onCall});
  final int run;
  final List<String> calls;
  final void Function(int calls)? onCall;

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    calls.add('r$run logits $epochs');
    final out = Float32List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      for (var k = 0; k < 5; k++) {
        final a = x[(e * epochSamples + k * 131) * 4 + k % 4];
        final b = x[(e * epochSamples + 1900 + k * 7) * 4 + (k + 1) % 4];
        out[e * 5 + k] = 1.7 * a - b + (means == null ? 0 : means[(e + k) % means.length]) + run * k * 0.01;
      }
    }
    onCall?.call(calls.length);
    return out;
  }

  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) async {
    calls.add('r$run sums $from-$to/$epochs');
    final s = Float32List(4 * meansWidth), n = Float32List(meansWidth);
    for (var i = 0; i < s.length; i++) {
      s[i] = x[(i * 7 + run) % x.length] * (to - from);
    }
    n.fillRange(0, n.length, (to - from).toDouble());
    onCall?.call(calls.length);
    return (sums: s, counts: n);
  }
}

void main() {
  late Directory root, recordings;
  setUp(() {
    root = Directory.systemTemp.createTempSync('sleep_so_far_test');
    recordings = Directory('${root.path}/recordings')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  final start = DateTime(2026, 11, 19, 23, 0, 0); // in the past: the live lines are written now

  /// The app's so-far scorer on [dir]: the preparation in this isolate, fake runs counting into [calls].
  SoFarScorer soFar(Directory dir, List<String> calls, {void Function(int calls)? onCall}) => SoFarScorer(
    recordingsDir: dir,
    openRun: (run) async => FakeRun(run, calls, onCall: onCall),
    plan: (d, since) async => planSoFar(d, since),
    prepare: (l, w0, w1, to) async => prepareWindow(l, w0, w1, to),
    walking: (l, w0, w1, to) async => walkingOfWindow(l, w0, w1, to),
  );

  /// The after-night scorer on [dir], the preparation in this isolate, no detectors' pass.
  SleepScorer afterNight(Directory dir, List<String> calls) => SleepScorer(
    recordingsDir: dir,
    store: NightReportStore(nightsDirFor(dir.path)),
    openRun: (run) async => FakeRun(run, calls),
    prepare: (files) async => prepareNight(files),
    see: (files) async => null,
  );

  const charStage = {'W': 'W', '1': 'N1', '2': 'N2', '3': 'N3', 'R': 'R', '-': gapStage};

  group('the layout read in stretches', () {
    test('channelRange gives what channel gives, over gaps, file sets, the edges and past the end', () {
      final a = GrowingRun(recordings, start)..grow(3);
      final b = GrowingRun(recordings, start.add(const Duration(minutes: 3, seconds: 40)))..grow(2);
      final layout = joinLayout([a.f32, b.f32]);
      expect(layout.bad.where((x) => x.text == 'BAD_gap'), isNotEmpty, reason: 'a 40 s hole between the sets');
      final rng = math.Random(7);
      for (var c = 0; c < 4; c++) {
        final whole = layout.channel(c);
        final ranges = [
          (0, layout.samples),
          (0, 1),
          (44990, 55010), // across the hole
          (layout.samples - 300, layout.samples + 500), // past the end: the last value held
          for (var k = 0; k < 6; k++) (rng.nextInt(layout.samples ~/ 2), layout.samples ~/ 2 + rng.nextInt(layout.samples ~/ 2)),
        ];
        for (final (from, to) in ranges) {
          final got = layout.channelRange(c, from, to);
          for (var i = from; i < to; i++) {
            final want = whole[math.min(i, whole.length - 1)];
            expect(got[i - from], want, reason: 'channel $c sample $i of $from-$to');
          }
        }
      }
    });
  });

  group('any number of channels, picked by name', () {
    test('a recording of 8 channels with its header gives the stages of the same 4 in a BrainBit file', () async {
      final wide = Directory('${root.path}/wide/recordings')..createSync(recursive: true);
      final eight = ['Fp1', 'O2', 'Cz', 'T3', 'O1', 'Fz', 'T4', 'Pz'];
      GrowingRun(wide, start, names: eight).grow(170);
      GrowingRun(recordings, start).grow(170);
      final layout = joinLayout([File('${wide.path}/${fileStem(start)}.f32')]);
      final plain = joinLayout([File('${recordings.path}/${fileStem(start)}.f32')]);
      for (var c = 0; c < 4; c++) {
        expect(layout.channelRange(c, 123456, 201234), plain.channelRange(c, 123456, 201234), reason: 'channel $c');
        expect(layout.channelRange(c, 0, 9000), layout.channel(c).sublist(0, 9000));
      }
      final a = (await soFar(wide, <String>[]).update())!, b = (await soFar(recordings, <String>[]).update())!;
      expect(a.stages, b.stages);
    });

    test('a recording without T3 and T4 is refused in words, never read from other channels', () async {
      GrowingRun(recordings, start, names: ['O1', 'O2', 'Fz', 'Cz']).grow(30);
      final calls = <String>[];
      await expectLater(
        soFar(recordings, calls).update(),
        throwsA(
          isA<MissingSites>().having((e) => e.message, 'message', allOf(startsWith('Sleep so far needs'), contains('T3, T4'))),
        ),
      );
      expect(calls, isEmpty);
    });
  });

  group('looks while the night records', () {
    test('each look scores only what is new; a new scorer (the app restarted) reuses what was kept', () async {
      final run = GrowingRun(recordings, start)..grow(60);
      final calls = <String>[];
      final s = soFar(recordings, calls);
      final first = (await s.update())!;
      expect(first.stages, hasLength(120 - soFarBehind), reason: 'up to 2 minutes behind the newest epoch');
      expect(first.unscored, 0);
      expect(calls, hasLength(3), reason: 'one window, three runs');
      expect(first.start, start);

      // nothing new: nothing scored
      await s.update();
      expect(calls, hasLength(3));

      // 90 minutes more in the same file: two stretches are complete, and the newest minutes
      run.grow(90);
      final second = (await s.update())!;
      expect(calls, hasLength(3 + 9));
      expect(second.stages, hasLength(300 - soFarBehind));
      final cache = SoFarStore(soFarDirFor(recordings.path)).read('2026-11-19')!;
      expect(cache.stretches.keys, [0, 1]);
      expect(cache.looks, 3);
      expect(cache.calls, 12);

      // the app restarts: a new scorer on the same folders scores only the newest minutes after 10 more
      run.grow(10);
      final again = soFar(recordings, calls);
      expect(again.cached()!.stages, second.stages, reason: 'the page opens on the last look');
      final third = (await again.update())!;
      expect(calls, hasLength(12 + 3));
      expect(third.stages.sublist(0, 256), second.stages.sublist(0, 256), reason: 'kept stretches stay');
    });

    test('incremental looks give what one look over the same data gives', () async {
      final run = GrowingRun(recordings, start)..grow(40);
      final calls = <String>[];
      final s = soFar(recordings, calls);
      for (final more in [35.0, 50.0, 20.0, 66.5]) {
        await s.update();
        run.grow(more);
      }
      final incremental = (await s.update())!;
      // the same files, scored at once by a scorer with nothing kept
      final copy = Directory('${root.path}/copy/recordings')..createSync(recursive: true);
      for (final f in recordings.listSync().whereType<File>()) {
        f.copySync('${copy.path}/${f.uri.pathSegments.last}');
      }
      final once = <String>[];
      final scratch = (await soFar(copy, once).update())!;
      expect(incremental.stages, scratch.stages);
      expect(incremental.stages.toSet().length, greaterThan(1), reason: 'the fake model reads different stages');
      expect(calls.length, greaterThan(once.length), reason: 'the newest minutes are scored again at each look');
      expect(calls.length, lessThan(once.length + 5 * 3), reason: 'but a kept stretch never again');
    });

    test('Stop: the report is scored from scratch, unchanged by the looks; a short night is the same stages', () async {
      final run = GrowingRun(recordings, start)..grow(50);
      final calls = <String>[];
      final looked = (await soFar(recordings, calls).update())!;
      // a night under 74 minutes is one window from its first sample: the after-night scorer's own result
      final now = afterNight(recordings, <String>[]);
      final short = await now.score(now.due().single);
      final want = [for (final c in short.json['stages'].toString().split('')) charStage[c]!];
      expect(looked.stages, want.sublist(0, looked.stages.length));

      // a longer night with several looks, then Stop: the report equals one scored in a folder never looked at
      for (final more in [70.0, 45.0, 80.0]) {
        run.grow(more);
        await soFar(recordings, calls).update();
      }
      final copy = Directory('${root.path}/copy/recordings')..createSync(recursive: true);
      for (final f in recordings.listSync().whereType<File>()) {
        f.copySync('${copy.path}/${f.uri.pathSegments.last}');
      }
      final a = afterNight(recordings, <String>[]), b = afterNight(copy, <String>[]);
      final ra = await a.score(a.due().single), rb = await b.score(b.due().single);
      for (final k in ['stages', 'periods', 'total', 'data_start', 'data_end']) {
        expect(ra.json[k], rb.json[k], reason: k);
      }
    });

    test('a drop and a new file set: the stretches before it stay, the hole shows as no data', () async {
      final a = GrowingRun(recordings, start)..grow(150);
      final calls = <String>[];
      final s = soFar(recordings, calls);
      await s.update();
      expect(calls, hasLength(9), reason: 'two stretches and the newest minutes');
      final store = SoFarStore(soFarDirFor(recordings.path));
      final before = store.read('2026-11-19')!.stretches;

      // the headband dropped at 150 min and came back 2 minutes later: a new file set
      GrowingRun(recordings, start.add(const Duration(minutes: 152))).grow(60);
      final r = (await s.update())!;
      expect(calls, hasLength(9 + 6), reason: 'only the third stretch and the newest minutes');
      final after = store.read('2026-11-19')!.stretches;
      for (final k in [0, 1]) {
        expect(after[k]!.stages, before[k]!.stages);
        expect(after[k]!.key, before[k]!.key);
      }
      expect(r.stages.sublist(300, 304), everyElement(gapStage));
      expect(r.missingMin, 2);
      expect(r.stages, hasLength(424 - soFarBehind));

      // the first set packed after a day reads the same: nothing is scored again
      packRaw(a.f32);
      expect(a.f32.existsSync(), isFalse);
      final packed = (await soFar(recordings, calls).update())!;
      expect(calls, hasLength(15));
      expect(packed.stages, r.stages);
    });

    test('a stretch whose recordings changed under it is dropped and scored again', () async {
      final run = GrowingRun(recordings, start)..grow(160);
      final calls = <String>[];
      final s = soFar(recordings, calls);
      await s.update();
      final store = SoFarStore(soFarDirFor(recordings.path));
      expect(store.read('2026-11-19')!.stretches.keys, [0, 1]);
      // a crash lost the end of the file: stretch 1 is no longer complete
      final raf = run.f32.openSync(mode: FileMode.append);
      raf.truncateSync(130 * 60 * 250 * recordBytes);
      raf.closeSync();
      final r = (await s.update())!;
      expect(store.read('2026-11-19')!.stretches.keys, [0]);
      expect(r.stages, hasLength(260 - soFarBehind));
    });

    test('a damaged cache is not used; an older night is not tonight', () async {
      GrowingRun(recordings, start).grow(30);
      final store = SoFarStore(soFarDirFor(recordings.path));
      store.dir.createSync(recursive: true);
      store.fileFor('2026-11-19').writeAsStringSync('{"version": 1, "stretches": [');
      final calls = <String>[];
      final s = soFar(recordings, calls);
      expect(s.cached(), isNull);
      expect((await s.update())!.stages, hasLength(60 - soFarBehind));
      // Start pressed after the newest night's last data: nothing recorded tonight yet
      final since = start.add(const Duration(hours: 2)).millisecondsSinceEpoch;
      expect(await s.update(sinceMs: since), isNull);
      expect(s.cached(sinceMs: since), isNull);
    });
  });

  group('the live sleep model', () {
    test('while it runs a look waits (none of its calls); what was kept stays, and the next look goes on', () async {
      GrowingRun(recordings, start).grow(160);
      final live = liveStagesDirFor(recordings.path);
      final log = LiveStageLog(live);
      final calls = <String>[];
      // the smart alarm's model starts just as the first stretch is done
      final s = soFar(recordings, calls, onCall: (n) {
        if (n == 3) log.on(['smart alarm']);
      });
      await expectLater(
        s.update(),
        throwsA(isA<ScoringPaused>().having((e) => e.why, 'why', 'the live sleep model runs for the smart alarm')),
      );
      expect(calls, hasLength(3), reason: 'it stops before the next model call');
      expect(SoFarStore(soFarDirFor(recordings.path)).read('2026-11-19')!.stretches.keys, [0]);
      expect(s.latest!.stages.sublist(0, 128).contains(unscoredStage), isFalse);
      expect(s.liveModelFor(), 'smart alarm');

      // a look while it runs scores nothing at all
      await expectLater(s.update(), throwsA(isA<ScoringPaused>()));
      expect(calls, hasLength(3));

      // its epochs stand in for the minutes left unscored; once it is freed the look goes on
      for (var e = 140; e < 150; e++) {
        log.epoch((start.millisecondsSinceEpoch ~/ 1000 + 30 * e + 7) * 1000, 'N3', 0.8);
      }
      // a look that waits shows them at once (the page keeps the scorer's latest)
      await expectLater(s.update(), throwsA(isA<ScoringPaused>()));
      expect(s.latest!.stages.sublist(140, 150), everyElement('N3'));
      final shown = s.cached()!;
      expect(shown.stages.sublist(140, 150), everyElement('N3'));
      expect(shown.liveEpochs, 10);
      expect(shown.stages[130], unscoredStage);
      log.off();
      expect(s.liveModelFor(), isNull);
      await s.update();
      expect(calls, hasLength(3 + 6), reason: 'the second stretch and the newest minutes, not the first again');
    });

    test('a model whose process ended (no off line) counts as running only while its file is fresh', () {
      final live = liveStagesDirFor(recordings.path)..createSync(recursive: true);
      final f = File('${live.path}/2026-11-19-230000.live')..writeAsStringSync('on 1 lucid cues\ne 1000 R 0.700\n');
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(readLiveStages(live, fromMs: 0, nowMs: now).runningFor, 'lucid cues');
      f.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 4)));
      final stale = readLiveStages(live, fromMs: 0, nowMs: now);
      expect(stale.runningFor, isNull);
      expect(stale.epochs, {1000: 'R'});
      f.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
      readLiveStages(live, fromMs: 0, nowMs: now);
      expect(f.existsSync(), isFalse, reason: 'old lines are removed');
    });

    test('the night scorer writes its start, each epoch and its end', () async {
      final live = Directory('${root.path}/live');
      final scorer = NightScorer(
        model: () => _N2Model(),
        scale: (LiveWindow w) async => Float32List(w.epochs * 3840 * 4),
        log: LiveStageLog(live),
      );
      final t0 = start.millisecondsSinceEpoch;
      final l = _All();
      scorer.join(l);
      for (var s = 0; s < 8 * 60; s++) {
        scorer.add(
          DateTime.fromMillisecondsSinceEpoch(t0 + (s + 1) * 1000),
          [for (var j = 0; j < 250; j++) Sample.four(pack: 0, o1: 1e-5, o2: 1e-5, t3: 1e-5, t4: 1e-5)],
          firstOfFile: s == 0,
        );
        await Future<void>.delayed(Duration.zero);
      }
      await scorer.stager?.idle();
      await scorer.close();
      final lines = File(live.listSync().single.path).readAsLinesSync();
      expect(lines.first, startsWith('on '));
      expect(lines.first, endsWith(' all'));
      expect(lines.last, startsWith('off '));
      final epochs = lines.where((x) => x.startsWith('e ')).toList();
      expect(epochs, isNotEmpty);
      expect(epochs.first, 'e $t0 2 0.900');
      expect(epochs.length, l.got);
    });
  });
}

class _N2Model implements LiveModel {
  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    final p = Float64List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      p.setAll(e * 5, [0.025, 0.025, 0.9, 0.025, 0.025]);
    }
    return p;
  }

  @override
  Future<void> close() async {}
}

class _All implements StageListener {
  int got = 0;

  @override
  String get who => 'all';

  @override
  bool needs(double t0Ms) => true;

  @override
  void scored(LiveStage st, int epochStartMs) => got++;

  @override
  void modelChanged() {}
}
