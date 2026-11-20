// A made-up app folder with weeks of history, for the read-count tests (DECISIONS 620-629): a scored report, a nap, a
// dream catcher session, a check-in, a lucid night (answered, searched) and a work session every day, with Was this
// you?, the study reminders, the lucid cues and Unusual for you switched on. Made-up numbers only.
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/lucid/plan.dart' show LucidAnswers;
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/nap/rules.dart' show NapEnd;
import 'package:eeg_tracker/nap/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem, indexBytes, recordBytes;
import 'package:eeg_tracker/sleep/live_stager.dart' show LiveMode;
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/study/schedule.dart' show StudySettings;
import 'package:eeg_tracker/study/store.dart';
import 'package:eeg_tracker/unusual/store.dart';
import 'package:eeg_tracker/wearer/wearer.dart' show WearerStore, wearerDirFor;
import 'package:eeg_tracker/work/store.dart';

import '../dream_test.dart' show sessionWith;
import '../wearer_test.dart' show checkIn, night;

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A work session of [minutes] from [start]: one alert or drowsy half minute after another.
Map<String, Object?> workSession(DateTime start, {int minutes = 90}) => {
  'kind': 'work_session',
  'version': 1,
  'start': start.toIso8601String(),
  'end': start.add(Duration(minutes: minutes)).toIso8601String(),
  'ended': 'stopped',
  'worn_min': minutes.toDouble(),
  'minutes': {'alert': minutes * 0.8, 'getting_drowsy': minutes * 0.2},
  'epochs': [
    for (var i = 0; i < minutes * 2; i++)
      {'at': start.add(Duration(seconds: 30 * i)).toIso8601String(), 'level': i % 5 == 0 ? 'getting_drowsy' : 'alert'},
  ],
  'hints': const <Object?>[],
  'breaks': const <Object?>[],
  'ratings': const <Object?>[],
};

/// A run of [seconds] of zeros from [start] with its `.idx` (two batches), as the recorder leaves it.
void writeRun(Directory rec, DateTime start, {int seconds = 10}) {
  final stem = fileStem(start);
  File('${rec.path}/$stem.f32').writeAsBytesSync(Uint8List(seconds * 250 * recordBytes));
  final idx = ByteData(2 * indexBytes);
  final t0 = start.millisecondsSinceEpoch / 1000;
  idx.setFloat64(0, t0, Endian.little);
  idx.setFloat64(indexBytes, t0 + seconds, Endian.little);
  idx.setUint64(indexBytes + 8, (seconds - 1) * 250, Endian.little);
  File('${rec.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
}

/// Fills `<root>/files/` with [days] days of history up to the night before [today]; returns the recordings folder.
/// [runs]: recorder runs per night (a dropped headband starts a new one), each a small `.f32` with its `.idx`.
String fakeAppFolder(Directory root, {int days = 60, required DateTime today, int runs = 0}) {
  final rec = Directory('${root.path}/files/recordings')..createSync(recursive: true);
  final reports = NightReportStore(nightsDirFor(rec.path));
  final naps = NapStore(napDirFor(rec.path));
  final dreams = DreamStore(dreamDirFor(rec.path));
  final mornings = MorningStore(morningsDirFor(rec.path));
  final lucid = LucidStore(lucidDirFor(rec.path));
  final work = WorkStore(workDirFor(rec.path));
  final first = today.subtract(Duration(days: days));
  lucid.setOn(true, first);
  for (var i = 0; i < days; i++) {
    final evening = DateTime(first.year, first.month, first.day + i);
    reports.write(night(_date(evening), iaf: 9.8 + 0.05 * (i % 4)));
    final morning = DateTime(evening.year, evening.month, evening.day + 1, 7, 40);
    mornings.save(checkIn(morning), morning);
    naps.save(
      NapSession(
        start: DateTime(evening.year, evening.month, evening.day, 14, 30),
        lengthMin: 20,
        recording: fileStem(DateTime(evening.year, evening.month, evening.day, 14, 30)),
        live: const NapLiveInfo(mode: LiveMode.full, calls: 10),
        endS: 1200,
        end: NapEnd.length,
        stages: '....WW1122',
      ),
    );
    dreams.save(sessionWith(DateTime(evening.year, evening.month, evening.day, 23, 10), const []));
    final nightStart = DateTime(evening.year, evening.month, evening.day, 23);
    for (var k = 0; k < runs; k++) {
      writeRun(rec, nightStart.add(Duration(minutes: 10 * k)));
    }
    final r = LucidNightRecord(
      startMs: nightStart.millisecondsSinceEpoch,
      index: i,
      cuesFromMs: nightStart.add(const Duration(hours: 4)).millisecondsSinceEpoch,
      phase: 'done',
    );
    lucid.saveNight(r);
    lucid.saveAnswers(r.stamp, const LucidAnswers(lucid: 'no', heard: 'no', recall: 2), morning);
    lucid.saveSignals(r.stamp, NightSignals(made: morning, signals: const [], sweepUv: 120));
    work.save(workSession(DateTime(morning.year, morning.month, morning.day, 10)));
  }
  WearerStore(wearerDirFor(rec.path)).setOn(true, first);
  StudyStore(studyDirFor(rec.path)).saveSettings(const StudySettings(on: true, eveningMin: 1260, morningMin: 540));
  UnusualStore(unusualDirFor(rec.path)).setOn(true, first);
  return rec.path;
}
