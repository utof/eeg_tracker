// The pulse (DECISIONS 810-819): the pass over made-up recordings written as the recorder writes them (the BrainBit's
// four channels, eight of another layout, a rate too slow), its pulse file and cache, the night on a sleep report's
// clock, the words, the night numbers for Trends, and the screens: the sleep report's Pulse lane and line, the Archive's
// Pulse lane and line, the Archive running the pulse pass, rendered at a phone's size (build/screens/pulse_*.png) with no
// overflow at 100 % and 130 % text. The detector itself is checked against the Python reference in
// pulse_cross_check_test.dart.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/archive/bands.dart';
import 'package:eeg_tracker/archive/delete.dart' show ArchiveBusy;
import 'package:eeg_tracker/archive/items.dart';
import 'package:eeg_tracker/archive/page.dart';
import 'package:eeg_tracker/cache/file_summaries.dart' show JsonMemo;
import 'package:eeg_tracker/pulse/detector.dart';
import 'package:eeg_tracker/pulse/night.dart';
import 'package:eeg_tracker/pulse/pass.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/sleep/report.dart' show SleepReport, isoLocal;
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/trends/usual.dart';
import 'package:eeg_tracker/ui/archive_screen.dart';
import 'package:eeg_tracker/ui/pulse_lane.dart';
import 'package:eeg_tracker/ui/recording_view.dart';
import 'package:eeg_tracker/ui/sleep_chart.dart';
import 'package:eeg_tracker/ui/sleep_report_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

/// A pulse wave at [bpm] a minute: its rate and three harmonics, as analysis/make_pulse_fixture.py draws it.
double _wave(double t, double bpm) {
  final p = 2 * math.pi * bpm / 60 * t;
  return math.sin(p) + 0.45 * math.sin(2 * p + 0.7) + 0.25 * math.sin(3 * p + 1.3) + 0.12 * math.sin(4 * p + 2.1);
}

/// A file set of [seconds] from [start] in [dir] as the recorder writes it (batches of 25 samples arriving every 0.1 s
/// at 250 a second), samples in µV from [uv] (sample index, channel).
String _writeSet(Directory dir, DateTime start, RecordingHeader h, int seconds, double Function(int i, int c) uv) {
  final w = ChunkWriter.open(dir, start, header: h);
  final rate = h.sampleRate.toInt(), per = rate ~/ 10;
  for (var b = 0; b < seconds * 10; b++) {
    w.addBatch(start.add(Duration(milliseconds: (b + 1) * 100)), [
      for (var k = 0; k < per; k++) Sample(b * per + k, [for (var c = 0; c < h.count; c++) uv(b * per + k, c) * 1e-6]),
    ]);
  }
  w.close();
  return w.stem;
}

/// EEG-like noise (2 µV) on an electrode offset, and a pulse at [bpm] on channel [on] (14 µV) and half as much on the
/// channel before it.
double Function(int i, int c) _pulseOn(int on, double bpm, int rate, {int seed = 1}) {
  final rnd = math.Random(seed);
  return (i, c) {
    final t = i / rate;
    final g = c == on ? 1.0 : (c == on - 1 ? 0.5 : 0.05);
    return 15000 + c * 300 + (rnd.nextDouble() - 0.5) * 4 + 14 * g * _wave(t, bpm);
  };
}

SleepReport _report(DateTime start, String stages) {
  final end = start.add(Duration(seconds: 30 * stages.length));
  return SleepReport({
    'night_of': '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}',
    'scored': true,
    'data_start': isoLocal(start),
    'data_end': isoLocal(end),
    'stages': stages,
    'total': {'asleep_min': 6.0, 'recorded_min': stages.length / 2, 'missing_min': 0, 'stray_sleep_min': 0},
    'periods': [
      {
        'start': isoLocal(start.add(const Duration(minutes: 1))),
        'end': isoLocal(end),
        'asleep_min': 6.0,
        'light_min': 3.0,
        'deep_min': 1.0,
        'dream_min': 2.0,
        'awake_min': 0,
        'wake_ups': 0,
        'missing_min': 0,
      },
    ],
  });
}

Future<void> _shoot(WidgetTester tester, Widget w, String name, {double scale = 1, double height = 980}) async {
  tester.view.physicalSize = Size(1210, height * 2.75); // about a Xiaomi 12T: 440 x 980 dp
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: w)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  late Directory root, files, rec;
  setUp(() {
    root = Directory.systemTemp.createTempSync('pulse_test');
    files = Directory('${root.path}/files')..createSync();
    rec = Directory('${files.path}/recordings')..createSync();
    JsonMemo.clear();
  });
  tearDown(() => root.deleteSync(recursive: true));

  final start = DateTime(2026, 11, 18, 23, 0);

  group('the pass', () {
    test('a pulse on T4 of the BrainBit is read, kept with its key, and stays after the raw signal goes', () {
      final stem = _writeSet(rec, start, brainBitHeader, 240, _pulseOn(3, 58, 250));
      final f32 = [File('${rec.path}/$stem.f32')];
      expect(whyNoPulse(f32), isNull);
      final got = pulseAndKeep(files, stem, f32);
      final p = got.pulse!;
      expect(got.why, isNull);
      expect(p.channels, ['O1', 'O2', 'T3', 'T4']);
      expect(p.epochs, 8); // 240 s from the first sample a second before the first batch arrives
      expect(p.read, greaterThanOrEqualTo(6));
      for (var e = 0; e < p.epochs; e++) {
        if (p.bpm[e] != null) {
          expect((p.bpm[e]! - 58).abs(), lessThanOrEqualTo(1.0), reason: 'epoch $e');
          expect(p.channel[e], anyOf(2, 3));
        }
      }
      final f = pulseFileFor(files, stem);
      expect(f.existsSync(), isTrue);
      expect(f.path, endsWith('/files/pulse/$stem.pulse.json'));
      // kept: the same files give the same answer without a new pass; a changed file needs one
      final modified = f.lastModifiedSync();
      expect(keptPulse(files, stem, f32), isNotNull);
      expect(pulseAndKeep(files, stem, f32).pulse!.codes, p.codes);
      expect(f.lastModifiedSync(), modified);
      final kept = keptPulses(files)[stem]!;
      expect([kept.detector, kept.epochs, kept.read, kept.startMs], [pulseDetector, 8, p.read, p.startMs]);
      expect(kept.medianBpm, closeTo(58, 1));
      File('${rec.path}/$stem.f32').writeAsBytesSync([0, 0, 0, 0], mode: FileMode.append);
      expect(keptPulse(files, stem, f32), isNull);
      File('${rec.path}/$stem.f32').deleteSync();
      expect(readPulse(files, stem)!.codes, p.codes); // a result, like a sleep report
    });

    test('any layout: eight channels of a DIY board, the pulse on the sixth', () {
      final h = RecordingHeader(
        channels: [for (var i = 1; i <= 8; i++) HeaderChannel('Ch$i')],
        sampleRate: 250,
        device: 'DIY board',
      );
      final stem = _writeSet(rec, start, h, 120, _pulseOn(5, 66, 250, seed: 2));
      final p = pulseAndKeep(files, stem, [File('${rec.path}/$stem.f32')]).pulse!;
      expect(p.channels, hasLength(8));
      expect(p.read, greaterThanOrEqualTo(3));
      final read = {for (final c in p.channel) ?c};
      expect(read, isNotEmpty);
      expect({4, 5}.containsAll(read), isTrue, reason: '$read: the sixth and the one before it carry the pulse');
    });

    test('a rate too slow, and no raw signal, are said in words and kept', () {
      final h = RecordingHeader(channels: const [HeaderChannel('A')], sampleRate: 30, device: 'test');
      final stem = _writeSet(rec, start, h, 60, (i, c) => 0);
      final f32 = [File('${rec.path}/$stem.f32')];
      expect(whyNoPulse(f32), 'The pulse needs 50 samples a second or more; this recording has 30.');
      final got = pulseAndKeep(files, stem, f32);
      expect([got.pulse, got.why], [null, 'The pulse needs 50 samples a second or more; this recording has 30.']);
      expect(keptPulse(files, stem, f32)!.why, got.why);
      expect(whyNoPulse(const []), 'No raw signal on the phone.');
    });
  });

  group('the night', () {
    test('a night\'s pulse on its report\'s clock, the pass run once for it', () {
      final stem = _writeSet(rec, start, brainBitHeader, 240, _pulseOn(3, 55, 250, seed: 3));
      final p0 = DateTime(2026, 11, 18, 22, 59, 29); // the report starts 30 s before the recording
      final got = nightPulse(rec, '2026-11-18', p0.millisecondsSinceEpoch, 10);
      expect(got.why, isNull);
      expect(got.bpm, hasLength(10));
      expect(got.bpm!.first, isNull); // nothing recorded then
      expect(got.bpm!.whereType<double>().every((b) => (b - 55).abs() <= 1), isTrue);
      expect(pulseFileFor(files, stem).existsSync(), isTrue);
      // without the pass: only what is kept
      expect(nightPulse(rec, '2026-11-18', p0.millisecondsSinceEpoch, 10, run: false).bpm, got.bpm);
      expect(nightPulse(rec, '2026-11-19', DateTime(2026, 11, 19, 23).millisecondsSinceEpoch, 10).bpm, isNull);
    });

    test('pulse while asleep per day, from 5 minutes of readings, for Trends', () {
      final stem = _writeSet(rec, start, brainBitHeader, 360, _pulseOn(3, 57, 250, seed: 4));
      pulseAndKeep(files, stem, [File('${rec.path}/$stem.f32')]);
      final p = readPulse(files, stem)!;
      final r = _report(p.start, 'WW${'2' * 10}');
      final days = pulseDayNumbers(files, [r]);
      expect(days.keys, ['2026-11-18']); // the day of its last wake (the period ends before 04:00 of the 19th)
      expect(days.values.single, closeTo(57, 1));
      expect(pulseDayNumbers(files, [_report(p.start, 'WWWWWWWW22')]), isEmpty); // 2 readings asleep: too few
    });

    test('the words', () {
      expect(
        pulseAsleepWords(const PulseAsleep(epochs: 100, read: 22, median: 54.6, lowest: 50.2)),
        'Pulse while asleep: about 55/min (read in 22 % of the night)',
      );
      expect(pulseLowestWords(const PulseAsleep(epochs: 100, read: 22, median: 54.6, lowest: 50.2)), 'Lowest 5 minutes asleep: 50/min');
      expect(
        pulseAsleepWords(const PulseAsleep(epochs: 100, read: 4)),
        'Pulse while asleep: too few readings for a number (read in 4 % of the night)',
      );
      expect(pulseLowestWords(const PulseAsleep(epochs: 100, read: 4, lowest: 50)), isNull);
      expect(pulseAsleepWords(const PulseAsleep(epochs: 100, read: 0)), 'Pulse while asleep: not found in the signal this night');
    });

    test('the lane\'s scale: whole fives, at least 20 a minute', () {
      expect(pulseScale([54.0, null, 57.0]), (45.0, 65.0));
      expect(pulseScale([48.0, 75.0]), (45.0, 75.0));
      expect(pulseScale(const [null]), (50.0, 70.0));
    });
  });

  group('Trends', () {
    test('pulse while asleep is a sleep row: your usual from 7 nights, an arrow from 14 and 5 a minute', () {
      final now = DateTime(2026, 11, 30, 9);
      final days = {for (var k = 1; k <= 16; k++) '2026-11-${(k + 13).toString().padLeft(2, '0')}': 55.0 + (k % 3 - 1)};
      days['2026-11-30'] = 62;
      final m = buildTrends((nights: [], mornings: [], sessions: []), now, extra: {'pulse': days});
      final row = m.rows.singleWhere((r) => r.spec.id == 'pulse');
      expect(row.spec.group, TrendGroup.sleep);
      expect(row.spec.scale, Scale.beats);
      expect([row.day, row.value, row.arrow], ['2026-11-30', 62.0, Arrow.up]);
      expect(row.spec.format(62), '62 a minute');
      expect(row.usual.arrow(59), Arrow.none); // 4 a minute: within the 5 that matter
      expect(row.spec.note, contains('Not yet checked against a watch'));
    });
  });

  group('the screens', () {
    setUpAll(loadFonts);

    final rs = DateTime(2026, 11, 18, 23, 10);
    final stages = 'WWWW${'2' * 30}${'3' * 20}${'R' * 16}${'2' * 30}WW';
    List<double?> pulse() => [
      for (var e = 0; e < stages.length; e++)
        stages[e] == '3' || e % 7 == 3 ? null : 54 + 3 * math.sin(e / 9) + (stages[e] == 'R' ? 2 : 0),
    ];

    for (final s in [100, 130]) {
      testWidgets('pulse_report at $s % text: the lane, its legend and the line with its "i"', (tester) async {
        var info = 0;
        await _shoot(
          tester,
          SleepReportView(nightOf: '2026-11-18', report: _report(rs, stages), pulse: pulse(), onPulseInfo: () => info++),
          'pulse_report_$s',
          scale: s / 100,
          height: 1600,
        );
        final a = pulseAsleep(pulse(), [for (final c in stages.split('')) c == '2' ? 'N2' : (c == '3' ? 'N3' : (c == 'R' ? 'R' : 'W'))]);
        expect(find.text(pulseAsleepWords(a)), findsOneWidget);
        expect(find.textContaining('Pulse while asleep: about 5'), findsOneWidget);
        expect(find.text(pulseLowestWords(a)!), findsOneWidget);
        expect(find.text(PulseAsleepLine.note), findsOneWidget);
        expect(find.text('pulse a minute, where it could be read'), findsOneWidget);
        await tester.tap(find.byTooltip('About the pulse'));
        expect(info, 1);
      });
    }

    testWidgets('the report while the pulse is read, and with none', (tester) async {
      await _shoot(tester, SleepReportView(nightOf: '2026-11-18', report: _report(rs, stages), pulseReading: true), 'pulse_report_reading');
      expect(find.text('Pulse while asleep: reading the night…'), findsOneWidget);
      await _shoot(tester, SleepReportView(nightOf: '2026-11-18', report: _report(rs, stages)), 'pulse_report_none');
      expect(find.textContaining('Pulse while asleep'), findsNothing);
      expect(find.text('pulse a minute, where it could be read'), findsNothing);
    });

    testWidgets('the chart grows a Pulse lane only with a reading', (tester) async {
      Future<double> height(List<double?>? p) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: nightTheme(),
            home: Scaffold(body: SleepChart(start: rs, stages: const ['W', 'N2', 'N2', 'R'], pulse: p)),
          ),
        );
        return tester.getSize(find.byType(SleepChart)).height;
      }

      final none = await height(null);
      expect(await height(const [null, null, null, null]), none);
      expect(await height(const [null, 55, 56, null]), greaterThan(none + SleepChart.pulseHeight));
      expect(tester.takeException(), isNull);
    });

    final item = ArchiveItem(
      id: '2026-11-18-231000',
      kind: ArchiveKind.night,
      start: rs,
      end: rs.add(Duration(seconds: 30 * stages.length)),
      started: byHand(ArchiveKind.night),
      sets: const [],
    );
    PulseResult result() => PulseResult(
      recording: item.id,
      startMs: rs.millisecondsSinceEpoch,
      channels: const ['O1', 'O2', 'T3', 'T4'],
      sampleRate: 250,
      codes: [for (final b in pulse()) b == null ? 'u' : 'r'].join(),
      bpm: pulse(),
    );

    for (final s in [100, 130]) {
      testWidgets('pulse_archive at $s % text: the Pulse lane under the timeline and its line', (tester) async {
        final tl = timelineOf(item, const TimelineInput());
        await _shoot(
          tester,
          RecordingView(model: RecordingViewModel(item: item, timeline: tl, pulse: result()), onPulseInfo: () {}),
          'pulse_archive_$s',
          scale: s / 100,
          height: 1400,
        );
        expect(find.text('Pulse'), findsOneWidget); // the lane's word
        expect(find.textContaining('Pulse: about 5'), findsOneWidget);
        expect(find.textContaining('of the recording). An experiment'), findsOneWidget);
        expect(find.byTooltip('About the pulse'), findsOneWidget);
      });
    }

    testWidgets('the Archive gives each recording its pulse pass after the detectors\' passes', (tester) async {
      final asked = <String>[];
      final page = ArchivePage(ArchiveList([item]), toPulse: [item.id]);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: ArchiveScreen(
            filesPath: files.path,
            load: (_) async => page,
            pulse: (f, id, paths) async {
              asked.add(id);
              return (pulse: null, why: null);
            },
            busy: () async => const ArchiveBusy(),
            now: () => DateTime(2026, 11, 19, 9),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(asked, [item.id]);
    });
  });
}
