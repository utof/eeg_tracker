// A working day with the headband (owner, 2026-11-20, in a Zoom meeting; DECISIONS 680-689): worn is skin contact,
// not a readable signal; calibration learns only from quiet half minutes; meetings give no verdict and no hint; the
// raw EEG is a recording that is no night (kept, packed and exported like one), and the laptop's meeting word.
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/auto/laptop.dart';
import 'package:eeg_tracker/auto/rules.dart' show LaptopWork;
import 'package:eeg_tracker/export/store.dart' show storedFiles;
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/recorder/packed.dart';
import 'package:eeg_tracker/work/breaks.dart';
import 'package:eeg_tracker/work/drowsiness.dart';
import 'package:eeg_tracker/work/worn.dart';
import 'package:flutter_test/flutter_test.dart';

const int ep = 30;

/// [n] seconds of the same input.
void feed(
  WorkDrowsiness d,
  int n, {
  double alpha = 10,
  int blinkEvery = 10,
  int moveEvery = 7,
  bool muscle = false,
  bool movement = false,
  bool meeting = false,
  bool away = false,
  int noisyOf10 = 0,
}) {
  for (var i = 0; i < n; i++) {
    final noisy = (i % 10) < noisyOf10;
    d.second(
      WorkInput(
        alpha: alpha,
        theta: 6,
        sem: 20,
        backClean: true,
        sideClean: true,
        blinks: blinkEvery > 0 && (i % ep) % blinkEvery == 0 ? 1 : 0,
        eyeMoves: moveEvery > 0 && (i % ep) % moveEvery == 0 ? 1 : 0,
        muscle: muscle || noisy,
        movement: movement,
        meeting: meeting,
        away: away,
      ),
    );
  }
}

/// [seconds] of 4 channels at 250 Hz: [f] gives µV per channel at time t.
void signal(SignalWornJudge j, int seconds, List<double> Function(double t) f) {
  for (var i = 0; i < seconds * 250; i++) {
    j.push(f(i / 250));
  }
}

void main() {
  group('worn is skin contact in the signal (DECISIONS 680)', () {
    double s(double hz, double t) => math.sin(2 * math.pi * hz * t);

    test('talking and moving on every channel are worn; flat, railed or wild channels are not', () {
      final talk = SignalWornJudge();
      // jaw movement at 4 Hz (160-300 µV), muscle at 80 Hz on T3/T4, alpha at the back
      signal(talk, 20, (t) {
        final jaw = (t % 10 < 9) ? s(4, t) : 0.0;
        return [10 * s(10, t) + 160 * jaw, 9 * s(10, t) + 170 * jaw, 300 * jaw + 40 * s(80, t), 280 * jaw - 40 * s(80, t)];
      });
      expect(talk.worn, isTrue);

      final flat = SignalWornJudge();
      signal(flat, 20, (t) => [12000.0, -8000.0, 20000.0, -15000.0]);
      expect(flat.worn, isFalse);

      final railed = SignalWornJudge();
      signal(railed, 20, (t) => [400000.0, 400000.0, 400000.0, 400000.0]);
      expect(railed.worn, isFalse);

      final wild = SignalWornJudge();
      signal(wild, 20, (t) => [2000 * s(50, t), 1800 * s(50, t), -2000 * s(50, t), 2200 * s(50, t)]);
      expect(wild.worn, isFalse);
    });

    test('one electrode off is still worn (the eye readings pause instead); three are not', () {
      final one = SignalWornJudge();
      signal(one, 20, (t) => [10 * s(10, t), 9 * s(10, t), 5 * s(3, t), 400000.0]);
      expect(one.worn, isTrue);
      final three = SignalWornJudge();
      signal(three, 20, (t) => [10 * s(10, t), 400000.0, 400000.0, 400000.0]);
      expect(three.worn, isFalse);
    });

    test("under 10 s of signal: the contact check's answer; a single sample at the rails counts for 20 s", () {
      final j = SignalWornJudge();
      expect(j.worn, isNull);
      j.contact({'O1': double.infinity, 'O2': null, 'T3': double.infinity, 'T4': null});
      expect(j.worn, isFalse);
      j.contact({'O1': 4e5, 'O2': 6e5, 'T3': 1.2e6, 'T4': 1.5e6});
      expect(j.worn, isTrue);
      signal(j, 5, (t) => [400000.0, 400000.0, 400000.0, 400000.0]);
      expect(j.worn, isTrue, reason: 'under 10 s of signal');
      signal(j, 10, (t) => [400000.0, 400000.0, 400000.0, 400000.0]);
      expect(j.worn, isFalse);
      signal(j, 10, (t) => [10 * s(10, t), 9 * s(10, t), 5 * s(3, t), 5 * s(4, t)]);
      expect(j.worn, isFalse, reason: 'the rails still in the last 20 s');
      signal(j, 11, (t) => [10 * s(10, t), 9 * s(10, t), 5 * s(3, t), 5 * s(4, t)]);
      expect(j.worn, isTrue);
    });
  });

  group('calibration learns from quiet half minutes only (DECISIONS 682)', () {
    test('talking half minutes (over 10 noisy seconds) do not go into the baseline; it waits and says so', () {
      final d = WorkDrowsiness();
      feed(d, 2 * ep); // settling in
      expect(d.waitingForQuiet, isFalse);
      // 6 of every 10 seconds talking: 12 readable seconds (alpha is still read from the clean ones)
      feed(d, 4 * ep, alpha: 40, noisyOf10: 6);
      expect(d.epochs.last.alpha, isNotNull, reason: 'scored, but not quiet enough for the baseline');
      expect(d.baselineLeft, WorkRule.baselineEpochs);
      expect(d.waitingForQuiet, isTrue);
      feed(d, 6 * ep);
      expect(d.calibrated, isTrue);
      expect(d.baseline!.alpha, closeTo(10, 1e-9), reason: 'the talking half minutes left no trace');
    });

    test('up to 10 noisy seconds in a half minute still count, and blinks never make one noisy', () {
      final d = WorkDrowsiness();
      feed(d, 2 * ep);
      feed(d, 6 * ep, noisyOf10: 3, blinkEvery: 2); // 9 noisy seconds, a blink every 2 s
      expect(d.calibrated, isTrue);
    });

    test('a break or a meeting is not learned from; restartBaseline starts over with a settling minute', () {
      final d = WorkDrowsiness();
      feed(d, 2 * ep);
      feed(d, 3 * ep);
      expect(d.baselineLeft, 3);
      feed(d, 4 * ep, away: true);
      feed(d, 4 * ep, meeting: true);
      expect(d.baselineLeft, 3);
      expect(d.waitingForQuiet, isFalse, reason: 'a meeting says so itself');
      d.restartBaseline();
      expect(d.baselineLeft, WorkRule.baselineEpochs);
      expect(d.settleLeft, WorkRule.settleEpochs);
      feed(d, 2 * ep, alpha: 50); // the new settling minute: left out
      feed(d, 6 * ep);
      expect(d.calibrated, isTrue);
      expect(d.baseline!.alpha, closeTo(10, 1e-9));
      d.restartBaseline();
      expect(d.calibrated, isTrue, reason: 'a finished baseline is kept all session (DECISIONS 441)');
    });
  });

  group('meetings give no verdict (DECISIONS 685)', () {
    test('meeting half minutes are never scored or closed eyes; the level reads "not sure" while it lasts', () {
      final d = WorkDrowsiness();
      feed(d, 14 * ep);
      expect(d.level, DrowsyLevel.alert);
      feed(d, 3 * ep, alpha: 60, blinkEvery: 0, moveEvery: 0, meeting: true); // would read eyes closed
      final m = d.epochs.last;
      expect(m.meeting, isTrue);
      expect(m.index, isNull);
      expect(m.eyesClosed, isFalse);
      expect(m.toJson()['meeting'], isTrue);
      expect(d.level, DrowsyLevel.unknown);
      expect(d.window, isNull);
      feed(d, 6 * ep);
      expect(d.level, DrowsyLevel.alert, reason: '6 of the last 10 read again');
    });

    test('the planner decides no hint during a meeting and counts its minutes as worn; the first tick after decides', () {
      final p = BreakPlanner();
      final t0 = DateTime(2026, 11, 20, 10);
      for (var m = 0; m <= 70; m++) {
        expect(p.tick(t0.add(Duration(minutes: m)), worn: true, meeting: true), isNull);
      }
      expect(p.stretchMin, closeTo(70, 1e-9));
      final h = p.tick(t0.add(const Duration(minutes: 71)), worn: true);
      expect(h?.reason, HintReason.stretch);
    });

    test('while calibrating (no automatic breaks) the headband off only pauses the worn count', () {
      final p = BreakPlanner();
      final t0 = DateTime(2026, 11, 20, 10);
      p.tick(t0, worn: true);
      for (var m = 1; m <= 20; m++) {
        p.tick(t0.add(Duration(minutes: m)), worn: false, autoBreak: false);
      }
      expect(p.onBreak, isFalse);
      expect(p.breaks, isEmpty);
      expect(p.activeS, 0);
      for (var m = 21; m <= 24; m++) {
        p.tick(t0.add(Duration(minutes: m)), worn: false);
      }
      expect(p.onBreak, isFalse, reason: 'the off time counts from when breaks may start');
      p.tick(t0.add(const Duration(minutes: 26)), worn: false);
      expect(p.onBreak, isTrue);
      expect(p.breaks.single.start, t0.add(const Duration(minutes: 21)));
    });
  });

  group("the laptop's meeting word (POST /work, DECISIONS 685)", () {
    final t0 = DateTime(2026, 11, 20, 10);

    test('a word that only changes the meeting asks for no headband check; a start does', () {
      final on = LaptopWork(working: true, at: t0, meeting: false);
      expect(asksForCheck(null, on), isTrue);
      expect(asksForCheck(LaptopWork(working: false, at: t0), on), isTrue);
      expect(asksForCheck(on, LaptopWork(working: true, at: t0.add(const Duration(minutes: 40)), meeting: true)), isFalse);
      expect(asksForCheck(on, LaptopWork(working: true, at: t0.add(const Duration(minutes: 40)))), isTrue, reason: 'an older tray');
      expect(asksForCheck(on, LaptopWork(working: true, at: t0.add(const Duration(hours: 13)), meeting: false)), isTrue);
      expect(asksForCheck(on, LaptopWork(working: false, at: t0, meeting: false)), isFalse);
    });

    test('the meeting is believed while the word says so, for 3 hours at most; it is kept in laptop.json', () {
      lastLaptopWord = LaptopWork(working: true, at: t0, meeting: true);
      expect(laptopMeetingNow(t0.add(const Duration(minutes: 30))), isTrue);
      expect(laptopMeetingNow(t0.add(const Duration(hours: 3))), isFalse);
      lastLaptopWord = LaptopWork(working: false, at: t0, meeting: true);
      expect(laptopMeetingNow(t0), isFalse, reason: 'the session ended');
      lastLaptopWord = null;
      expect(laptopMeetingNow(t0), isFalse);

      final tmp = Directory.systemTemp.createTempSync('laptop-word');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final store = LaptopStore(tmp);
      store.save(LaptopWork(working: true, at: t0, meeting: true));
      expect(store.load()!.meeting, isTrue);
      store.save(LaptopWork(working: true, at: t0));
      expect(store.load()!.meeting, isNull);
      expect(File('${tmp.path}/laptop.json').readAsStringSync(), isNot(contains('meeting')));
    });
  });

  group("a work session's raw EEG is a recording, never a night (DECISIONS 683)", () {
    late Directory files, rec;
    setUp(() {
      files = Directory.systemTemp.createTempSync('work-raw');
      rec = Directory('${files.path}/recordings')..createSync();
      forgetNightSets();
    });
    tearDown(() => files.deleteSync(recursive: true));

    /// A file set from [start] with [seconds] of samples arriving each second, its header saying [session].
    String writeSet(DateTime start, int seconds, {String? session}) {
      final w = ChunkWriter.open(rec, start, header: brainBitHeader.forSession(session));
      for (var s = 0; s < seconds; s++) {
        final at = start.add(Duration(seconds: s + 1));
        w.addBatch(at, [for (var i = 0; i < 250; i++) Sample.four(pack: i, o1: 1e-5, o2: 2e-5, t3: 3e-5, t4: 4e-5)]);
      }
      w.close();
      return w.stem;
    }

    test('the nights leave out a work set, with or without samples; a night and a nap beside it stay', () {
      final night = writeSet(DateTime(2026, 11, 19, 23), 60);
      final nap = writeSet(DateTime(2026, 11, 20, 0, 30), 30, session: 'nap');
      // 09:00 the next morning: by the evening date it would join that night
      final work = writeSet(DateTime(2026, 11, 20, 9), 120, session: sessionWork);
      final empty = writeSet(DateTime(2026, 11, 20, 0, 10), 0, session: sessionWork);
      final nights = nightsIn(rec);
      expect(nights, hasLength(1));
      final names = nights.single.files.map((f) => f.uri.pathSegments.last).join(' ');
      expect(names, contains(night));
      expect(names, contains(nap));
      expect(names, isNot(contains(work)));
      expect(names, isNot(contains(empty)), reason: 'a work set without samples joins no night either');
      expect(readHeader(File('${rec.path}/$work.f32')).isSleep, isFalse);
      expect(readHeader(File('${rec.path}/$night.f32')).isSleep, isTrue);
    });

    test('Export data and Share on Wi-Fi list it; it is packed after a day like a night and stays no night', () {
      final work = writeSet(DateTime(2026, 11, 18, 9), 120, session: sessionWork);
      final paths = [for (final f in storedFiles(files)) f.path];
      for (final ext in ['f32', 'idx', 'log', 'header.json']) {
        expect(paths, contains('recordings/$work.$ext'));
      }
      final f32 = File('${rec.path}/$work.f32');
      f32.setLastModifiedSync(DateTime(2026, 11, 18, 11));
      final todo = packCandidates(files, DateTime(2026, 11, 20, 12));
      expect(todo.map((f) => f.path), [f32.path]);
      packOne(f32.path);
      expect(f32.existsSync(), isFalse);
      expect(File('${f32.path}.gz').existsSync(), isTrue);
      expect(readHeader(f32).session, sessionWork, reason: 'the header is never packed');
      expect(storedFiles(files).map((f) => f.path), contains('recordings/$work.f32.gz'));
      forgetNightSets();
      expect(nightsIn(rec), isEmpty);
    });
  });
}
