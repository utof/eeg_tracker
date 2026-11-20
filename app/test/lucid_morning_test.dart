// The lucid cues' morning (DECISIONS 304, 306): dream signals found over the night's recordings, placed on the clock,
// given the full-night scoring's stage and the cue moment they may answer; the night's summary for the results.
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/detectors/gestures.dart';
import 'package:eeg_tracker/lucid/morning.dart';
import 'package:eeg_tracker/lucid/plan.dart';
import 'package:eeg_tracker/lucid/signals.dart';
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-11-26 03:00:00 local.
final DateTime t0 = DateTime(2026, 11, 26, 3);

/// [seconds] of quiet signal with an LRLR (three sweeps of 240 µV, 0.6 s apart) at [lrlrAtS], written as one run.
File writeRun(Directory dir, int seconds, double lrlrAtS) {
  final w = ChunkWriter.open(dir, t0);
  var i = 0;
  for (var s = 0; s < seconds; s++) {
    final rows = <Sample>[];
    for (var j = 0; j < 250; j++, i++) {
      final t = i / 250;
      var eye = 0.0;
      if (t >= lrlrAtS) eye = 120;
      if (t >= lrlrAtS + 0.6) eye = -120;
      if (t >= lrlrAtS + 1.2) eye = 120;
      if (t >= lrlrAtS + 1.8) eye = -120;
      if (t >= lrlrAtS + 2.4) eye = 0;
      rows.add(Sample.four(
        pack: i % 2048,
        o1: (12000 + 10 * math.sin(i * 0.25)) * 1e-6,
        o2: (-8000 + 8 * math.cos(i * 0.1)) * 1e-6,
        t3: (20000 + eye / 2 + 2 * math.sin(i * 0.7)) * 1e-6,
        t4: (-15000 - eye / 2 + 2 * math.cos(i * 0.9)) * 1e-6,
      ));
    }
    w.addBatch(t0.add(Duration(milliseconds: (s + 1) * 1000)), rows);
    w.append();
  }
  w.close();
  return File('${dir.path}/${w.stem}.f32');
}

void main() {
  test('found signals get their clock time, the night\'s stage and the cue moment they follow', () {
    final start = t0.millisecondsSinceEpoch ~/ 1000;
    final found = FoundSignals([const DreamSignal(250 * 100, 250 * 102, 3, 240)], [
      const Gesture(GestureKind.clench, 2000, 2013, 403, 25),
    ]);
    final cues = [CueMoment(atMs: (start + 50) * 1000, step: 0, period: 1, confidence: 0.9)];
    final stages = ['W', 'R', 'R', 'R', 'R', 'R', 'R', 'R', 'R', 'R', 'R', 'R', 'R', 'R', 'N2'];
    final out = placeSignals(found, startUnix: start, stages: stages, stagesFromUnix: start, cues: cues);
    expect(out.map((s) => s.kind), ['lrlr', 'clench']);
    expect(out[0].atMs, (start + 102) * 1000);
    expect(out[0].stage, 'R');
    expect(out[0].pairs, 2);
    expect(out[0].afterCueS, 52);
    expect(out[1].atMs, (start + 200) * 1000, reason: 'the first clench, tick 2000');
    expect(out[1].stage, 'R');
    expect(out[1].afterCueS, isNull, reason: 'over 2 minutes after the cue');
  });

  test('without a scored night the stages are unknown', () {
    final out = placeSignals(
      const FoundSignals([DreamSignal(0, 750, 3, 200)], []),
      startUnix: 100,
      stages: const [],
      stagesFromUnix: null,
      cues: const [],
    );
    expect(out.single.stage, isNull);
  });

  test('the whole pass over a recorded night finds the drawn LRLR', () async {
    final dir = Directory.systemTemp.createTempSync('lucid_morning');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = writeRun(dir, 60, 30);
    final s = searchNight([f], sweepUv: 80, clench: null, stages: const [], stagesFromUnix: null, cues: const []);
    expect(s.signals, hasLength(1));
    final at = DateTime.fromMillisecondsSinceEpoch(s.signals.single.atMs);
    expect(at.difference(t0).inSeconds, inInclusiveRange(30, 32));
    expect(s.staged, isFalse);
  });

  test('a night for the results: its cue moments, arousals, signals in dream sleep and answers', () {
    final rec = LucidNightRecord(
      startMs: 1,
      index: 4,
      cuesFromMs: 2,
      cues: const [
        CueMoment(atMs: 10, step: 0, period: 1, confidence: 0.8, aroused: true),
        CueMoment(atMs: 40, step: 1, period: 1, confidence: 0.8),
      ],
    );
    final n = nightForResults(
      rec,
      answers: const LucidAnswers(lucid: 'yes', heard: 'dream', recall: 2),
      signals: NightSignals(
        made: DateTime(2026),
        sweepUv: 80,
        signals: const [FoundSignal(atMs: 30, kind: 'lrlr', stage: 'R'), FoundSignal(atMs: 50, kind: 'lrlr', stage: 'W')],
      ),
      practices: [PracticeRecord(start: DateTime(2026), end: DateTime(2026), cues: 16, completed: true)],
      practisedFor: (_) => true,
    );
    expect((n.index, n.cueMoments, n.arousedMoments, n.signalsInDreamSleep, n.practised), (4, 2, 1, 1, true));
    expect(n.answers!.lucid, 'yes');
  });

  test('a practice counts for a night when it ends from 3 hours before the night\'s start to 2 hours after', () {
    final p = PracticeRecord(start: DateTime(2026, 11, 25, 22), end: DateTime(2026, 11, 25, 22, 15), cues: 16, completed: true);
    expect(practisedBefore(DateTime(2026, 11, 26, 0, 30).millisecondsSinceEpoch, [p]), isTrue);
    expect(practisedBefore(DateTime(2026, 11, 26, 2).millisecondsSinceEpoch, [p]), isFalse);
    expect(practisedBefore(DateTime(2026, 11, 25, 21).millisecondsSinceEpoch, [p]), isTrue, reason: 'in bed, after Start');
    expect(practisedBefore(DateTime(2026, 11, 25, 20).millisecondsSinceEpoch, [p]), isFalse);
    final cut = PracticeRecord(start: DateTime(2026, 11, 25, 22), end: DateTime(2026, 11, 25, 22, 3), cues: 2, completed: false);
    expect(practisedBefore(DateTime(2026, 11, 26, 0, 30).millisecondsSinceEpoch, [cut]), isFalse);
  });
}
