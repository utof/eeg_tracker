// Walking in the app (DECISIONS 800-809): the pass over a made-up recording (any layout and rate, the phone's step
// counter lines in its log, kept until a file or the detector changes), a walk file the laptop wrote, the day numbers
// (each minute once, someone else's nights left out, the headband's steps hidden once the check failed), the Archive's
// Walking lane and queue, and the Trends rows and their notes.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/archive/bands.dart';
import 'package:eeg_tracker/archive/items.dart';
import 'package:eeg_tracker/archive/page.dart';
import 'package:eeg_tracker/cache/file_summaries.dart' show JsonMemo;
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/trends_screen.dart' show walkStepsLine;
import 'package:eeg_tracker/walking/days.dart';
import 'package:eeg_tracker/walking/detector.dart';
import 'package:eeg_tracker/walking/pass.dart';
import 'package:flutter_test/flutter_test.dart';

/// A file set from [start]: [seconds] of noise with steps at [spm] a minute from [walkFrom] to [walkTo] s on every
/// channel of [header], at its rate (batches of a tenth of a second), and [log] lines at their times.
String writeWalk(
  Directory dir,
  DateTime start, {
  required RecordingHeader header,
  int seconds = 180,
  double walkFrom = 20,
  double walkTo = 140,
  double spm = 112,
  List<(int, String)> log = const [],
}) {
  final rate = header.sampleRate.round();
  final w = ChunkWriter.open(dir, start, header: header);
  for (final (s, line) in log) {
    w.log(line, at: start.add(Duration(seconds: s)));
  }
  final rnd = math.Random(7);
  final period = 60 / spm;
  double at(double t, int c) {
    var v = (rnd.nextDouble() - 0.5) * 6 + 1000.0 * (c + 1);
    final k0 = ((t - walkFrom) / period).round();
    for (var k = k0 - 1; k <= k0 + 1; k++) {
      final s = walkFrom + k * period;
      if (k < 0 || s >= walkTo) continue;
      final d = t - s;
      if (d.abs() < 0.2) v += 400 * (k.isEven ? 1 : 0.7) * math.exp(-0.5 * (d / 0.04) * (d / 0.04));
    }
    return v;
  }

  final per = rate ~/ 10;
  for (var b = 0; b < seconds * 10; b++) {
    w.addBatch(start.add(Duration(milliseconds: (b + 1) * 100)), [
      for (var k = 0; k < per; k++)
        Sample(b * per + k, [for (var c = 0; c < header.count; c++) at((b * per + k) / rate, c) * 1e-6]),
    ]);
  }
  w.close();
  return w.stem;
}

WalkResult result(String id, List<WalkMinute> minutes, {int windows = 100}) => WalkResult(
  recording: id,
  start: DateTime(2026, 11, 20, 19),
  channels: const ['O1', 'O2', 'T3', 'T4'],
  sampleRate: 250,
  windows: windows,
  walkingMin: 0,
  headbandSteps: 0,
  walks: const [],
  minutes: minutes,
);

WalkMinute minute(DateTime t, {double walk = 60, double hb = 114, double? pace = 114, double? phone}) {
  final src = phone != null && phone > 0 ? 'phone' : (hb > 0 ? 'headband' : '');
  return WalkMinute(
    t: t.millisecondsSinceEpoch ~/ 1000,
    walkS: walk,
    runS: 0,
    hbSteps: hb,
    hbPace: pace,
    phone: phone,
    steps: src == 'phone' ? phone! : hb,
    source: src,
    walkingS: phone != null && phone >= 60 ? 60 : walk,
  );
}

void main() {
  late Directory root, files, rec;
  setUp(() {
    root = Directory.systemTemp.createTempSync('walking_test');
    files = Directory('${root.path}/files')..createSync();
    rec = Directory('${files.path}/recordings')..createSync();
    forgetArchive();
    JsonMemo.clear();
  });
  tearDown(() => root.deleteSync(recursive: true));

  final start = DateTime(2026, 11, 20, 19, 0, 0);

  group('the pass', () {
    test('a walk on the headband\'s four channels, the phone\'s steps from its log, kept until a file changes', () {
      final id = writeWalk(
        rec,
        start,
        header: brainBitHeader,
        log: [
          (0, 'phone step counter: on'),
          (3, 'phone steps 50000'),
          (63, 'phone steps 50000'), // the phone lay on a desk this minute
          (123, 'phone steps 50113'),
          (183, 'phone steps 50113'),
        ],
      );
      final f32 = [File('${rec.path}/$id.f32')];
      final w = walkAndKeep(files, id, f32);
      expect(w.why, isNull);
      final r = w.walk!;
      expect(r.recording, id);
      expect(r.channels, ['O1', 'O2', 'T3', 'T4']);
      expect(r.phoneCounter, 'on');
      expect(r.walks, hasLength(1));
      final s = r.walks.single.stretches.single;
      expect(s.kind, StretchKind.walking);
      expect((s.pace! - 112).abs(), lessThanOrEqualTo(2));
      expect(s.start.difference(start.add(const Duration(seconds: 20))).inSeconds.abs(), lessThanOrEqualTo(10));
      // minute 19:00 lay still on the phone: the headband's; 19:01 the phone counted 113: the phone's
      final byMinute = {for (final m in r.minutes) DateTime.fromMillisecondsSinceEpoch(m.t * 1000).minute: m};
      expect(byMinute[0]!.source, 'headband');
      expect(byMinute[1]!.source, 'phone');
      expect(byMinute[1]!.steps, 113);
      expect(byMinute[1]!.hbSteps, greaterThan(90));
      expect(r.stepsFrom('phone'), 113);
      expect(r.json['detector'], walkDetector);
      // kept as it is: a marker planted in the file is read back
      final kept = walkFileFor(files, id);
      final j = jsonDecode(kept.readAsStringSync()) as Map;
      j['confidence'] = 'planted';
      kept.writeAsStringSync(jsonEncode(j));
      expect(walkAndKeep(files, id, f32).walk!.confidence, 'planted');
      expect(keptWalks(files)[id]!.walk!.confidence, 'planted');
      // the log changed (a late line): read again
      File('${rec.path}/$id.log').writeAsStringSync('x\n', mode: FileMode.append);
      File('${rec.path}/$id.log').setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      expect(walkAndKeep(files, id, f32).walk!.confidence, isNot('planted'));
    });

    test('any layout: eight channels of another montage at 500 a second', () {
      final h8 = RecordingHeader(
        channels: [for (final n in ['Fp1', 'Fp2', 'C3', 'C4', 'P7', 'P8', 'O1', 'O2']) HeaderChannel(n)],
        sampleRate: 500,
        device: 'DIY board',
        counter: counterSequence,
      );
      final diy = Directory('${files.path}/recordings-diy')..createSync();
      final id = writeWalk(diy, start, header: h8, seconds: 120, walkFrom: 10, walkTo: 100, spm: 104);
      expect(whyNotWalked([File('${diy.path}/$id.f32')]), isNull);
      final r = walkAndKeep(files, id, [File('${diy.path}/$id.f32')]).walk!;
      expect(r.channels, hasLength(8));
      expect(r.sampleRate, 500);
      expect(r.phoneCounter, isNull);
      final s = r.walks.single.stretches.single;
      expect((s.pace! - 104).abs(), lessThanOrEqualTo(2));
      expect(r.minutes.every((m) => m.source == 'headband' || m.source == ''), isTrue);
    });

    test('rest alone: no walk; too slow a rate is refused in words', () {
      final id = writeWalk(rec, start, header: brainBitHeader, seconds: 90, walkFrom: 0, walkTo: 0);
      final r = walkAndKeep(files, id, [File('${rec.path}/$id.f32')]).walk!;
      expect(r.walks, isEmpty);
      expect(r.minutes, isEmpty);
      final slow = RecordingHeader(channels: [HeaderChannel('A')], sampleRate: 20, counter: counterSequence);
      final s = writeWalk(Directory('${files.path}/recordings-diy'), start, header: slow, seconds: 20, walkTo: 0);
      expect(whyNotWalked([File('${files.path}/recordings-diy/$s.f32')]), contains('50 samples a second'));
    });

    test('a walk file the laptop wrote (scripts/walks.py) reads the same', () {
      final j = {
        'format': 'eeg-tracker-walking',
        'version': 1,
        'detector': 'walk-v1',
        'recording': '2026-11-20-175021',
        'start': '2026-11-20T17:50:29+03:00',
        'channels': ['O1', 'O2', 'T3', 'T4'],
        'sample_rate': 250,
        'windows': 2794,
        'phone_counter': null,
        'walking_min': 82.1,
        'headband_steps': 8664,
        'pace': 114.0,
        'confidence': 'sure',
        'walks': [
          {
            'start': '2026-11-20T19:08:36+03:00',
            'end': '2026-11-20T21:14:26+03:00',
            'walking_min': 82.1,
            'stopped_min': 40.4,
            'steps': 8664,
            'pace': 114.0,
            'stops': 11,
            'stretches': [
              {'kind': 'walking', 'start': '2026-11-20T19:08:36+03:00', 'end': '2026-11-20T19:20:31+03:00', 'min': 11.9, 'steps': 1370, 'pace': 115.2, 'score': 8.3, 'confidence': 'sure'},
              {'kind': 'stopped', 'start': '2026-11-20T19:20:31+03:00', 'end': '2026-11-20T19:22:36+03:00', 'min': 2.1, 'steps': 0, 'pace': null, 'score': null, 'confidence': null},
            ],
          },
        ],
        'minutes': [
          [1795190880, 25.0, 0.0, 37.5, 112.8, null, 37.5, 'headband', 25.0],
        ],
      };
      final r = WalkResult.fromJson(j)!;
      expect(r.walkingMin, 82.1);
      expect(r.walks.single.stretches.map((s) => s.kind), [StretchKind.walking, StretchKind.stopped]);
      expect(r.minutes.single.hbPace, 112.8);
      expect(r.minutes.single.phone, isNull);
      expect(WalkResult.fromJson({...j, 'version': 2}), isNull);
    });
  });

  group('the days', () {
    test('each minute once, the 04:00 day, someone else\'s night left out; walking minutes and steps by source', () {
      final a = result('a', [
        minute(DateTime(2026, 11, 20, 19, 0)),
        minute(DateTime(2026, 11, 20, 19, 1), phone: 118),
        minute(DateTime(2026, 11, 21, 3, 59), walk: 30, hb: 50),
      ], windows: 500);
      // a shorter recording with the same minute: the longer one's is kept
      final b = result('b', [minute(DateTime(2026, 11, 20, 19, 0), hb: 999)], windows: 10);
      final c = result('c', [minute(DateTime(2026, 11, 22, 1, 0))]);
      final d = walkDays([b, a, c], notMine: [(DateTime(2026, 11, 22), DateTime(2026, 11, 22, 8))]);
      expect(d.minutes, {'2026-11-20': 2.5});
      expect(d.steps['2026-11-20'], closeTo(114 + 118 + 50, 1e-9));
      expect(d.phoneSteps['2026-11-20'], 118);
      expect(d.sourceOf('2026-11-20'), 'your phone and the headband');
      expect(d.steps.containsKey('2026-11-22'), isFalse);
      expect(d.check.status, CheckStatus.unchecked);
    });

    test('the check against the phone: passed shows the headband\'s steps, failed leaves them out', () {
      final paired = [for (var k = 0; k < 10; k++) minute(DateTime(2026, 11, 20, 19, k), phone: 112)];
      final alone = minute(DateTime(2026, 11, 20, 20, 0), hb: 110);
      final ok = walkDays([result('ok', [...paired, alone])]);
      expect(ok.check.status, CheckStatus.passed);
      expect(ok.steps['2026-11-20'], closeTo(10 * 112 + 110, 1e-9));
      final wrong = [for (var k = 0; k < 10; k++) minute(DateTime(2026, 11, 20, 19, k), hb: 57, pace: 57, phone: 112)];
      final bad = walkDays([result('bad', [...wrong, alone])]);
      expect(bad.check.status, CheckStatus.failed);
      expect(bad.headbandHidden, isTrue);
      expect(bad.steps['2026-11-20'], closeTo(10 * 112, 1e-9));
      expect(bad.minutes['2026-11-20'], closeTo(11, 1e-9));
      expect(walkStepsLine(bad), contains('left out'));
      expect(walkStepsLine(ok), contains('matched your phone in 10 of 10 minutes'));
      expect(walkStepsLine(walkDays([result('x', [alone])])), contains('Not yet checked'));
    });
  });

  group('the Archive', () {
    test('the Walking lane: a band per walking or running stretch with its pace; stops are gaps', () {
      final r = WalkResult.fromJson({
        'format': 'eeg-tracker-walking',
        'version': 1,
        'recording': 'x',
        'start': '2026-11-20T19:00:00+03:00',
        'channels': ['O1'],
        'walks': [
          {
            'start': '2026-11-20T19:01:00+03:00',
            'end': '2026-11-20T19:20:00+03:00',
            'stretches': [
              {'kind': 'walking', 'start': '2026-11-20T19:01:00+03:00', 'end': '2026-11-20T19:10:00+03:00', 'steps': 1020, 'pace': 113.6, 'confidence': 'sure'},
              {'kind': 'stopped', 'start': '2026-11-20T19:10:00+03:00', 'end': '2026-11-20T19:12:00+03:00', 'steps': 0},
              {'kind': 'running', 'start': '2026-11-20T19:12:00+03:00', 'end': '2026-11-20T19:20:00+03:00', 'steps': 1290, 'pace': 161.2, 'confidence': 'unsure'},
            ],
          },
        ],
        'minutes': <Object>[],
      })!;
      final from = DateTime.parse('2026-11-20T19:00:00+03:00').toLocal();
      final item = ArchiveItem(
        id: 'x',
        kind: ArchiveKind.night,
        start: from,
        end: from.add(const Duration(minutes: 30)),
        started: byHand(ArchiveKind.night),
      );
      final tl = timelineOf(item, TimelineInput(walk: r));
      final bands = tl.of(Lane.walking);
      expect([for (final b in bands) b.label], ['Walking, 114 a minute', 'Running, 161 a minute']);
      expect(bands.first.source, contains('about 1020 steps, estimated (sure)'));
      expect(bands.last.tone, BandTone.faint);
      expect(tl.total(Lane.walking), const Duration(minutes: 17));
      expect(foundWords(minutes: {'walking': 17}), ['walking 17 min']);
    });

    test('the list queues each recording for its walking pass once; its minutes show when walked', () {
      final id = writeWalk(rec, start, header: brainBitHeader);
      final page = loadArchivePage(files);
      expect(page.toWalk, [id]);
      walkAndKeep(files, id, [File('${rec.path}/$id.f32')]);
      final again = loadArchivePage(files);
      expect(again.toWalk, isEmpty);
      expect(again.found[id]!['walking'], greaterThan(1.5));
    });
  });

  test('Trends: walking and estimated steps in their own group, with the walking note', () {
    final now = DateTime(2026, 11, 20, 22);
    final m = buildTrends(
      (nights: const [], mornings: const [], sessions: const []),
      now,
      extra: {
        'walk_min': {'2026-11-20': 82.1},
        'walk_steps': {'2026-11-20': 8664},
      },
      notes: {'walk_steps': 'From the headband. Not yet checked.'},
    );
    final rows = m.group(TrendGroup.activity);
    expect([for (final r in rows) r.spec.label], ['Walking', 'Steps (estimated)']);
    expect(rows.first.spec.format(rows.first.value!), '1 h 22 min');
    expect(rows.last.spec.format(rows.last.value!), '8 664 steps');
    expect(rows.last.note, 'From the headband. Not yet checked.');
    expect(rows.every((r) => r.spec.evidence == 'walking'), isTrue);
  });
}
