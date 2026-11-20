// The dream sleep check on the phone (DECISIONS 740-749), beyond what the cross-check with the Python reference
// covers: what the report keeps (`probs`, `rem_check`) and how an older report reads, the counter fed as the night pass
// feeds it, the eye pair of a many-channel recording found by name wherever it sits, and the section on the report
// page. Made-up signals and nights only.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart' show EpochQuality;
import 'package:eeg_tracker/recorder/chunk_writer.dart' show indexBytes;
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/model.dart' show phoneModelId;
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/rem_check.dart';
import 'package:eeg_tracker/ui/rem_check_view.dart';
import 'package:eeg_tracker/ui/sleep_report_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _n(String s, int k) => List.filled(k, s);

/// 5 min awake, then 60 min asleep with two dream-sleep blocks, then 5 min awake.
final List<String> _stages = [..._n('W', 10), ..._n('N2', 50), ..._n('R', 20), ..._n('N3', 30), ..._n('R', 20), ..._n('W', 10)];

/// p(R) 0.6 in dream sleep, 0.05 elsewhere; the rest on the scored stage or spread.
List<double> _probs(List<String> stages) => [
  for (final s in stages) ...switch (s) {
    'R' => [0.1, 0.1, 0.1, 0.1, 0.6],
    'W' => [0.8, 0.05, 0.05, 0.05, 0.05],
    'N3' => [0.05, 0.05, 0.25, 0.6, 0.05],
    _ => [0.05, 0.1, 0.7, 0.1, 0.05],
  },
];

Map<String, dynamic> _build({NightSeen? seen, List<double>? probs, String? extrasError}) => jsonDecode(
  jsonEncode(
    buildReport(
      nightOf: '2026-11-19',
      built: DateTime(2026, 11, 20, 9),
      scoringSeconds: 90,
      start: DateTime(2026, 11, 20, 2, 59, 6),
      lengthSeconds: _stages.length * 30.0,
      inputs: const {'2026-11-20-025858.f32': 1000},
      model: phoneModelId,
      stages: _stages,
      confidence: List.filled(_stages.length, 0.7),
      probabilities: probs,
      seen: seen,
      extrasError: extrasError,
    ),
  ),
) as Map<String, dynamic>;

NightSeen _seen(EyeSeen? eye) => NightSeen(
  quality: List.filled(_stages.length, EpochQuality.good),
  bursts: const [],
  moves: const [],
  eye: eye,
);

void main() {
  group('the report keeps', () {
    test('the probabilities and the check, which reads back the same from the report itself', () {
      final eye = [for (var e = 0; e < _stages.length; e++) _stages[e] == 'R' ? 9 : e % 7 == 0 ? null : 2];
      final json = _build(seen: _seen(EyeSeen.measured('T3-T4', eye)), probs: _probs(_stages));
      final r = SleepReport(json);
      expect(r.probabilities!.first, [800, 50, 50, 50, 50]);
      expect(r.probabilities!.length, _stages.length);
      final c = json['rem_check'] as Map<String, dynamic>;
      expect((c['asleep_min'], c['rem_min'], c['rem_share'], c['first_rem_min']), (60.0, 20.0, 0.333, 25.0));
      expect(c['thirds_rem_min'], [0.0, 10.0, 10.0]); // epochs 10-49, 50-89, 90-129
      expect(c['rem_prob_min'], (40 * 600 + 80 * 50) / 2000); // the period's 120 epochs
      final e = c['eye'] as Map<String, dynamic>;
      expect((e['pair'], e['rem_per_min'], e['other_per_min']), ('T3-T4', 18.0, 4.0));
      expect(r.remCheckNumbers, same(json['rem_check'])); // the report's own
      expect(
        jsonDecode(jsonEncode(remCheck(
          stages: r.stages,
          periods: [(10, 129)],
          probs: r.probabilities,
          eye: EyeSeen.measured('T3-T4', eyeFromText(e['epochs'])!),
        ))),
        c,
      );
      expect(scoredByOlder(r, model: phoneModelId), isFalse);
    });

    test('without the signal pass: says why, and the stages still checked', () {
      final failed = _build(extrasError: 'Bad state: no memory');
      expect((failed['rem_check'] as Map)['eye'], {
        'pair': null,
        'why': 'not measured: the signal pass failed (see extras_error)',
      });
      expect(failed['probs'], isNull); // the model's probabilities were not given
      expect(remCheckLines(SleepReport(failed).remCheckNumbers!).last,
          'Eye movements: not measured: the signal pass failed (see extras_error).');
      expect((_build(seen: _seen(null))['rem_check'] as Map)['eye'], {'pair': null, 'why': 'not measured'});
      expect(_build(probs: [0.2, 0.2])['probs'], isNull, reason: 'not five a stage: left out, never misread');
    });

    test('an older report: the stage-only check, and "Score again"', () {
      final json = _build(seen: _seen(null))
        ..remove('rem_check')
        ..remove('probs');
      final r = SleepReport(json);
      final c = r.remCheckNumbers!;
      expect((c['rem_min'], c['first_rem_min'], c['rem_prob_min'], c['eye']), (20.0, 25.0, null, null));
      expect(remCheckLines(c).last, startsWith('This report is older than the check'));
      expect(scoredByOlder(r, model: phoneModelId), isTrue);
      expect(isStale(const {'2026-11-20-025858.f32': 1000}, r), isFalse); // never scored again by itself (row 580)
    });

    test('an unscored report has no check', () {
      final json = buildReport(nightOf: '2026-11-19', built: DateTime(2026, 11, 20), scoringSeconds: 0.1,
          start: DateTime(2026, 11, 20, 3), lengthSeconds: 120, inputs: const {}, model: phoneModelId);
      expect((json['probs'], json['rem_check']), (null, null));
      expect(SleepReport(jsonDecode(jsonEncode(json)) as Map<String, dynamic>).remCheckNumbers, isNull);
    });
  });

  group('the counter', () {
    test('a partial last second and epoch are left out; a gap second is not counted', () {
      final c = EyeMoveCounter();
      for (var i = 0; i < 250 * 59 + 100; i++) {
        c.push(1000.0, -1000.0, missing: i < 10);
      }
      expect(c.finish(), [0]);
    });

    test('glances on a many-channel recording are read from its own eye pair, by name', () {
      final dir = Directory.systemTemp.createTempSync('rem_wide');
      addTearDown(() => dir.deleteSync(recursive: true));
      const names = ['O1', 'F7', 'O2', 'T3', 'F8', 'T4', 'Cz', 'Pz'];
      final h = RecordingHeader(channels: [for (final n in names) HeaderChannel(n, site: n == 'T3' ? 'T7' : n == 'T4' ? 'T8' : n)]);
      expect(eyePairOf(h)?.label, 'F7-F8');
      const n = 250 * 60 * 2; // four epochs; glances in the first, on F7 and F8 only
      final rng = math.Random(4);
      final rb = 4 + 4 * names.length;
      final rec = ByteData(n * rb);
      for (var i = 0; i < n; i++) {
        final s = i ~/ 250, k = i % 250;
        final glance = s < 30 && s % 3 == 1 && k >= 50 && k < 200 ? 20.0 : 0.0; // 40 µV apart: swings ~69, then ~32
        rec.setUint32(i * rb, i % 2048, Endian.little);
        for (var c = 0; c < names.length; c++) {
          final v = 2 * (rng.nextDouble() - 0.5) + (c == 1 ? glance : c == 4 ? -glance : 0);
          rec.setFloat32(i * rb + 4 + 4 * c, v * 1e-6, Endian.little);
        }
      }
      final f32 = File('${dir.path}/2026-11-20-030000.f32')..writeAsBytesSync(rec.buffer.asUint8List());
      writeHeader(f32, h);
      final idx = ByteData(n ~/ 250 * indexBytes);
      final t0 = DateTime(2026, 11, 20, 3).millisecondsSinceEpoch / 1000;
      for (var k = 0; k < n ~/ 250; k++) {
        idx
          ..setFloat64(k * indexBytes, t0 + k + 1, Endian.little)
          ..setUint64(k * indexBytes + 8, k * 250, Endian.little);
      }
      File('${dir.path}/2026-11-20-030000.idx').writeAsBytesSync(idx.buffer.asUint8List());
      final seen = seeNight([f32])!;
      expect(seen.eye!.pair, 'F7-F8');
      expect(seen.eye!.epochs.first, 10); // seconds 1, 4, ..., 28
      expect(seen.eye!.epochs.length, 4);
      expect(seen.quality, hasLength(4)); // the detectors still read O1 O2 T3 T4
    });
  });

  group('on the report page', () {
    testWidgets('the dream sleep check, in words', (tester) async {
      final eye = [for (final s in _stages) s == 'R' ? 9 : 2];
      final r = SleepReport(_build(seen: _seen(EyeSeen.measured('T3-T4', eye)), probs: _probs(_stages)));
      var info = 0;
      await tester.pumpWidget(MaterialApp(
        theme: nightTheme(),
        home: SleepReportView(nightOf: '2026-11-19', report: r, onDreamInfo: () => info++),
      ));
      await tester.scrollUntilVisible(find.text('Dream sleep check'), 400);
      expect(find.textContaining('Dream sleep 20\u00a0min (33\u00a0%). Usual for adults is 20-25\u00a0%; '
          'this night is above it.'), findsOneWidget);
      expect(find.textContaining('18.0 seconds a minute with them in dream sleep, 4.0 in other sleep'), findsOneWidget);
      await tester.tap(find.byTooltip('Why dream sleep may be under-counted'));
      expect(info, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('little dream sleep says the scorer may under-count it', (tester) async {
      final check = remCheck(stages: [..._n('N2', 90), ..._n('R', 10)], periods: [(0, 99)]);
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: Scaffold(body: DreamSleepCheck(check: check))));
      expect(find.textContaining("this headband's scorer may under-count it."), findsOneWidget);
      expect(find.byType(IconButton), findsNothing); // no "i" without a note to open
    });
  });
}
