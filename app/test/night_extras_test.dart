// The night extras (jaw, movement and signal quality per hour; lib/sleep/extras.dart): the hand-worked cases of
// analysis/tests/test_night_extras.py, the night's samples streamed through the detectors in the order the sleep
// model reads them, and the report fields. night_extras_cross_check_test.dart compares with the Python reference.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/ui/sleep_extras_view.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 'W', n2 = 'N2', n3 = 'N3', r = 'R';
List<String> rep(String s, int n) => List.filled(n, s);

const _g = EpochQuality.good, _d = EpochQuality.degraded, _m = EpochQuality.missing;

void main() {
  group('summary, as night_extras.py', () {
    test('the first whole clock hour', () {
      expect(firstEdgeS(DateTime(2026, 11, 18, 1, 58, 25)), 95);
      expect(firstEdgeS(DateTime(2026, 11, 18, 2)), 0);
      expect(firstEdgeS(DateTime(2026, 11, 18, 23, 0, 1)), 3599);
    });

    test('hours follow the clock and count events by the epoch they start in', () {
      final stages = [...rep(w, 4), ...rep(n2, 60), ...rep(n3, 30), ...rep(r, 32), ...rep(w, 4)];
      final quality = List.filled(130, _g);
      quality[0] = _m;
      quality.fillRange(5, 9, _d);
      quality[124] = _d;
      const bursts = [
        Burst(10, 12, BurstKind.jaw, 5),
        Burst(125, 125, BurstKind.jaw, 5),
        Burst(300, 301, BurstKind.oneSided, 5),
        Burst(1800, 1805, BurstKind.movement, 5),
        Burst(3700, 3702, BurstKind.jaw, 5),
        Burst(3899, 3899, BurstKind.jaw, 5),
        Burst(3900, 3901, BurstKind.jaw, 5), // past the scored epochs: dropped
      ];
      const moves = [(29, 31), (600, 600), (3680, 3681), (3901, 3903)];
      final out = nightExtras(
        quality: quality,
        bursts: bursts,
        moves: moves,
        stages: stages,
        periods: const [(4, 125)],
        firstEdge: 50,
      );
      expect(out['quality'], 'm${'g' * 4}dddd${'g' * 115}d${'g' * 5}');
      final hours = (out['hours'] as List).cast<Map<String, dynamic>>();
      expect([for (final h in hours) (h['from_s'], h['min'])], [(0, 1.0), (50, 60.0), (3650, 4.0)]);
      final [h0, h1, h2] = hours;
      expect((h0['asleep_min'], h0['good_min'], h0['degraded_min'], h0['missing_min']), (0.0, 0.5, 0.0, 0.5));
      expect((h0['jaw_bursts'], h0['moves']), (1, 1));
      expect((h1['asleep_min'], h1['good_min'], h1['degraded_min'], h1['missing_min']), (59.0, 58.0, 2.0, 0.0));
      expect((h1['jaw_bursts'], h1['one_sided_bursts'], h1['movement_bursts'], h1['moves']), (1, 1, 1, 1));
      expect((h2['asleep_min'], h2['jaw_bursts'], h2['moves'], h2['degraded_min']), (2.0, 2, 1, 0.5));
      final night = out['night'] as Map<String, dynamic>;
      expect((night['min'], night['good_min'], night['degraded_min'], night['missing_min']), (65.0, 62.0, 2.5, 0.5));
      expect((night['jaw_bursts'], night['one_sided_bursts'], night['movement_bursts'], night['moves']), (4, 1, 1, 3));
      final asleep = out['asleep'] as Map<String, dynamic>;
      expect((asleep['min'], asleep['good_min'], asleep['degraded_min'], asleep['missing_min']), (61.0, 58.5, 2.5, 0.0));
      expect((asleep['jaw_bursts'], asleep['one_sided_bursts'], asleep['movement_bursts'], asleep['moves']), (2, 1, 1, 2));
      expect((asleep['jaw_per_hour'], asleep['moves_per_hour']), (2.0, 2.0));
      expect((out['validated'], out['epoch_s'], out['version']), (false, 30, extrasVersion));
    });

    test('asleep means inside a sleep period; rates round half up', () {
      final stages = [...rep(n2, 6), ...rep(w, 200), ...rep(n2, 480), ...rep(w, 10)];
      final out = nightExtras(
        quality: List.filled(stages.length, _g),
        bursts: const [Burst(30, 31, BurstKind.jaw, 5), Burst(6200, 6201, BurstKind.jaw, 5)],
        moves: const [],
        stages: stages,
        periods: const [(206, 685)],
        firstEdge: 0,
      );
      final asleep = out['asleep'] as Map<String, dynamic>;
      expect((asleep['min'], asleep['jaw_bursts'], asleep['jaw_per_hour'], asleep['moves_per_hour']), (240.0, 1, 0.3, 0.0));
      expect([for (final h in out['hours'] as List) (h as Map)['from_s']], [0, 3600, 7200, 10800, 14400, 18000]);
      expect((out['night'] as Map)['jaw_bursts'], 2);
    });

    test('no sleep gives no rates; stages and quality must cover the same epochs', () {
      final out = nightExtras(
        quality: List.filled(20, _g),
        bursts: const [Burst(5, 6, BurstKind.jaw, 5)],
        moves: const [],
        stages: rep(w, 20),
        periods: const [],
        firstEdge: 0,
      );
      final asleep = out['asleep'] as Map<String, dynamic>;
      expect((asleep['min'], asleep['jaw_per_hour'], asleep['moves_per_hour']), (0.0, null, null));
      expect(
        () => nightExtras(quality: List.filled(9, _g), bursts: const [], moves: const [], stages: rep(w, 10),
            periods: const [], firstEdge: 0),
        throwsArgumentError,
      );
    });
  });

  group('the night streamed from its recordings', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('extras_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    /// A recorder run at [t0] (unix s): [values] (µV, one row per sample), one batch a second in the .idx.
    File writeRun(double t0, List<List<double>> values) {
      final n = values.length;
      final rec = ByteData(n * recordBytes);
      for (var i = 0; i < n; i++) {
        rec.setUint32(i * recordBytes, i % 2048, Endian.little);
        for (var c = 0; c < 4; c++) {
          rec.setFloat32(i * recordBytes + 4 + 4 * c, values[i][c] * 1e-6, Endian.little);
        }
      }
      final stem = fileStem(DateTime.fromMillisecondsSinceEpoch((t0 * 1000).round()));
      final f = File('${dir.path}/$stem.f32')..writeAsBytesSync(rec.buffer.asUint8List());
      final rows = n ~/ 250;
      final idx = ByteData(rows * indexBytes);
      for (var k = 0; k < rows; k++) {
        idx
          ..setFloat64(k * indexBytes, t0 + k + 1, Endian.little)
          ..setUint64(k * indexBytes + 8, k * 250, Endian.little);
      }
      File('${dir.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
      return f;
    }

    test('every sample in clock order: held gaps marked missing, values clipped as the BDF holds them', () async {
      final rng = math.Random(5);
      List<List<double>> noise(int seconds) =>
          [for (var i = 0; i < seconds * 250; i++) [for (var c = 0; c < 4; c++) 80000 + 8 * (rng.nextDouble() - 0.5)]];
      final a = noise(40)..[0][2] = 450000; // T3 past the file's range for one sample: clipped, railed
      final b = noise(50);
      const t0 = 1795468320.0; // a whole second
      final files = [writeRun(t0, a), writeRun(t0 + 46, b)]; // 6 s missing between them
      final layout = joinLayout(files);
      final got = <(List<double>, bool)>[];
      layout.forEachRow((row, missing) => got.add(([...row], missing)));
      expect(got.length, layout.samples);
      expect(got.length, 96 * 250);
      expect(got[0].$1[2], 400000);
      expect(got[1].$1, [for (var c = 0; c < 4; c++) closeTo(a[1][c], 1e-2)]);
      expect({for (var i = 0; i < got.length; i++) if (got[i].$2) i ~/ 250}, {40, 41, 42, 43, 44, 45});
      expect(got[40 * 250].$1, got[40 * 250 - 1].$1); // held at the last value
      for (var c = 0; c < 4; c++) {
        final ch = layout.channel(c);
        expect([for (final g in got) g.$1[c]], ch, reason: 'the same samples the sleep model reads, channel $c');
      }

      final seen = seeNight(files)!;
      expect(seen.quality.length, 3); // 96 s: three whole epochs
      expect(seen.quality[1], EpochQuality.missing); // 6 gap seconds in 30-59 s

      // the scorer's way: in a background isolate, the same result comes back
      final back = (await seeInBackground(files))!;
      expect(back.quality, seen.quality);
      expect(back.quality[1] == EpochQuality.missing, isTrue);
      expect([for (final b in back.bursts) (b.start, b.end, b.kind)], [for (final b in seen.bursts) (b.start, b.end, b.kind)]);
      expect(back.moves, seen.moves);
    });

    test('no samples: nothing seen', () => expect(seeNight(const []), isNull));
  });

  group('report', () {
    final start = DateTime(2026, 11, 18, 1, 58, 25);
    final stages = [...rep(w, 4), ...rep(n2, 100), ...rep(n3, 30), ...rep(w, 6)];
    final seen = NightSeen(
      quality: [...List.filled(130, _g), ...List.filled(10, _d)],
      bursts: const [Burst(200, 202, BurstKind.jaw, 6)],
      moves: const [(400, 401)],
    );

    Map<String, dynamic> build({NightSeen? seen, String? error}) =>
        jsonDecode(jsonEncode(buildReport(
          nightOf: '2026-11-17',
          built: start.add(const Duration(hours: 2)),
          scoringSeconds: 40,
          start: start,
          lengthSeconds: stages.length * 30.0,
          inputs: const {'a.f32': 1000},
          model: phoneModelId,
          stages: stages,
          confidence: List.filled(stages.length, 0.8),
          seen: seen,
          extrasError: error,
        ))) as Map<String, dynamic>;

    test('extras sit beside the laptop fields, with each hour on the clock', () {
      final json = build(seen: seen);
      expect(json['version'], reportVersion);
      expect(reportVersion, 2);
      final x = json['extras'] as Map<String, dynamic>;
      expect(json['extras_error'], isNull);
      final hours = (x['hours'] as List).cast<Map<String, dynamic>>();
      expect([for (final h in hours) h['start']], [isoLocal(start), isoLocal(DateTime(2026, 11, 18, 2)), isoLocal(DateTime(2026, 11, 18, 3))]);
      expect([for (final h in hours) h['from_s']], [0, 95, 3695]);
      expect((x['asleep'] as Map)['jaw_bursts'], 1);

      final report = SleepReport(json);
      final e = report.extras!;
      expect(e.quality.length, stages.length);
      expect(e.quality.last, EpochQuality.degraded);
      expect(e.asleep.min, report.asleepMin);
      expect((e.asleep.jawBursts, e.asleep.jawPerHour, e.asleep.moves), (1, 0.9, 1));
      expect(e.hours.map((h) => h.start), [start, DateTime(2026, 11, 18, 2), DateTime(2026, 11, 18, 3)]);
      expect(e.hours[1].minutes, 60);
      expect(e.asleep.noisyShare, closeTo(4 / 130, 1e-9)); // the last 4 asleep epochs were noisy
      expect(e.night.noisyShare, closeTo(5 / 70, 1e-9));
    });

    test('without the detectors pass, or when it failed: no extras, and why', () {
      expect(SleepReport(build()).extras, isNull);
      final failed = build(seen: seen, error: 'Bad state: out of memory');
      expect((failed['extras'], failed['extras_error']), (null, 'Bad state: out of memory'));
      final short = NightSeen(quality: List.filled(9, _g), bursts: const [], moves: const []);
      final broken = build(seen: short);
      expect(broken['extras'], isNull);
      expect(broken['extras_error'], contains('quality'));
    });

    test('an older report without extras, or a damaged extras field, still reads', () {
      final json = build(seen: seen)..remove('extras');
      expect(SleepReport(json).extras, isNull);
      expect(SleepReport(build(seen: seen)..['extras'] = {'quality': 3}).extras, isNull);
      expect(SleepReport.read(File('test/fixtures/does-not-exist')), isNull);
    });
  });

  test('the honest note\'s sentence on noise', () {
    NightExtras x(double good, double noisy, double none, {bool asleep = true}) {
      Map<String, Object?> t(double g, double d, double m) => {
        'min': g + d + m, 'good_min': g, 'degraded_min': d, 'missing_min': m,
        'jaw_bursts': 0, 'one_sided_bursts': 0, 'movement_bursts': 0, 'moves': 0,
      };
      return NightExtras.read({
        'quality': 'g',
        'night': t(good + 10, noisy, none),
        'asleep': {...asleep ? t(good, noisy, none) : t(0, 0, 0), 'jaw_per_hour': null, 'moves_per_hour': null},
        'hours': <Object>[],
      }, DateTime(2026))!;
    }

    expect(noiseSentence(x(300, 0, 0)), 'The signal was clean for all of your sleep.');
    expect(noiseSentence(x(260, 30, 10)),
        'It read 10\u00a0% of your sleep through noise (movement, muscle or a loose electrode) and 3\u00a0% with no '
        'usable electrode.');
    expect(noiseSentence(x(290, 0, 10)), 'It read 3\u00a0% of your sleep with no usable electrode.');
    expect(noiseSentence(x(999, 1, 0)), 'It read under 1\u00a0% of your sleep through noise (movement, muscle or a '
        'loose electrode).');
    expect(noiseSentence(x(50, 50, 0, asleep: false)), startsWith('It read 45\u00a0% of the recording through noise'));
    expect(rateText(22.8), '23\u00a0an\u00a0hour');
    expect(rateText(6.94), '6.9\u00a0an\u00a0hour');
    expect(rateText(null), '–');
  });
}
