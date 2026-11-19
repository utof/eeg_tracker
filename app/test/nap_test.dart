// The nap coach without a phone: its rules, its file, and whole naps through the controller with the dream
// catcher's fake headband (a synthetic eyes-closed signal streamed fast, alpha fading on cue) and a scripted sleep
// model (ONNX cannot run in `flutter test`; the real model is checked in analysis/tests).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/nap/audio.dart';
import 'package:eeg_tracker/nap/controller.dart';
import 'package:eeg_tracker/nap/rules.dart';
import 'package:eeg_tracker/nap/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show recordBytes;
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/session_keeper.dart';
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dream_test.dart' show DriftBand, OneFinder;
import 'live_stager_test.dart' show ScriptedModel, scaleNow;

LiveStage st(int epoch, String stage) => LiveStage(epoch, stage, 0.9, 4);

const fast = NapTiming(
  link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
  tick: Duration(milliseconds: 20),
);

Future<void> until(NapController c, bool Function() done, {Duration max = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(max);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('stuck in ${c.stage} (${c.message}) at ${c.seconds.round()} s');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('rules', () {
    test('deep sleep counts after two epochs in a row read as N3; a gap or a hole starts again', () {
      final r = NapRules(lengthS: 1800);
      expect([for (final s in [st(10, 'N2'), st(11, 'N3'), st(12, 'gap'), st(13, 'N3')]) r.stage(s)], everyElement(false));
      expect(r.stage(st(15, 'N3')), isFalse, reason: 'epoch 14 is missing: not in a row');
      expect(r.due(100), isNull);
      expect(r.stage(st(16, 'N3')), isTrue);
      expect(r.deepEpoch, 16);
      expect(r.due(100), NapEnd.deepSleep);
      expect(r.stage(st(17, 'N3')), isFalse, reason: 'once only');
    });

    test('the length ends the nap when deep sleep never comes', () {
      final r = NapRules(lengthS: 1200);
      for (var e = 0; e < 40; e++) {
        r.stage(st(e, e.isEven ? 'N2' : 'N3'));
      }
      expect(r.due(1199.9), isNull);
      expect(r.due(1200), NapEnd.length);
      expect(() => NapRules(lengthS: 0), throwsArgumentError);
    });

    test('the wake cue starts quiet and rises to the full volume, never over it', () {
      expect([for (var k = 0; k < 7; k++) wakeVolume(k, 0.175)], [
        closeTo(0.175, 1e-12),
        closeTo(0.2625, 1e-12),
        closeTo(0.39375, 1e-12),
        closeTo(0.595, 1e-12),
        closeTo(0.875, 1e-12),
        closeTo(0.875, 1e-12),
        closeTo(0.875, 1e-12),
      ]);
      expect(wakeVolume(4, 0.5), 1.0);
      expect(NapRule.lengthsMin, contains(NapRule.defaultMin));
    });
  });

  group('the nap file', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nap'));
    tearDown(() => tmp.deleteSync(recursive: true));

    NapSession session(DateTime start, {String stages = '....WW1122223'}) => NapSession(
      start: start,
      lengthMin: 30,
      recording: '2026-11-19-143000',
      live: const NapLiveInfo(mode: LiveMode.full, calls: 12, medianMs: 1800, maxMs: 2400, poorEpochs: 0),
      endS: 412.3,
      end: NapEnd.deepSleep,
      wakeS: 400,
      upS: 431.5,
      baselineS: 61,
      drowsyS: 119,
      onsetS: 90,
      deepEpoch: 12,
      stages: stages,
      contact: const {'O1': 4e5, 'T4': null},
    );

    test('saved and read back, newest first; minutes per stage from the letters', () {
      final store = NapStore(napDirFor('${tmp.path}/recordings'));
      store.save(session(DateTime(2026, 11, 19, 14, 30)));
      store.save(session(DateTime(2026, 11, 20, 15), stages: 'W1'));
      File('${store.dir.path}/broken.nap.json').writeAsStringSync('{');
      File('${store.dir.path}/other.nap.json').writeAsStringSync('{"version": 1}');
      final all = store.list();
      expect([for (final s in all) s.start.day], [20, 19]);
      final s = all[1];
      expect(s.toJson(), session(DateTime(2026, 11, 19, 14, 30)).toJson());
      expect(s.minutes, {'.': 2.0, 'W': 1.0, '1': 1.0, '2': 2.0, '3': 0.5});
      expect(s.asleepMin, 3.5);
      expect(s.contact, {'O1': 4e5, 'T4': null});
      expect(store.dir.path, endsWith('/naps'));
    });

    test('a file with an unknown stage letter or end is not read', () {
      final j = session(DateTime(2026, 11, 19)).toJson();
      expect(NapSession.fromJson({...j, 'stages': 'WXN'}), isNull);
      expect(NapSession.fromJson({...j, 'end': 'exploded'}), isNull);
      expect(NapSession.fromJson({...j, 'lengthMin': 0}), isNull);
      expect(NapSession.fromJson({...j, 'end': null})?.end, isNull, reason: 'a nap the app never finished');
    });
  });

  group('naps through the controller', () {
    late Directory tmp;
    late NapStore store;
    late Directory recordings;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('nap');
      recordings = Directory('${tmp.path}/recordings');
      store = NapStore(napDirFor(recordings.path));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    NapController controller(DriftBand? band, SilentNapSound sound, {LiveModel Function()? model}) => NapController(
      finder: OneFinder(band),
      sound: () => sound,
      model: model,
      store: store,
      recordingsDir: recordings,
      scale: scaleNow,
      timing: fast,
    );

    test('deep sleep starts: woken about 3 minutes into it, before it settles; the report keeps why', () async {
      // alpha fades at 4 min (asleep by the detector at about 5); the model sees light sleep from epoch 10 and
      // deep sleep from epoch 24 (12 min)
      final band = DriftBand((t) => t < 240 ? 1 : 0.3);
      final sound = SilentNapSound();
      final model = ScriptedModel((e) => e < 10 ? 'W' : (e < 24 ? 'N2' : 'N3'));
      final c = controller(band, sound, model: () => model);
      await c.start(lengthMin: 45);
      expect(c.stage, NapStage.resting);
      expect(c.live, NapLive.starting);
      await until(c, () => c.stage == NapStage.waking);
      expect(c.end, NapEnd.deepSleep);
      // epochs 24 and 25 read 2 minutes behind: known once epoch 29 is complete (14.5 min); the fake headband
      // streams on while the scripted call completes, so a few seconds more
      expect(c.seconds, inInclusiveRange(29 * 30, 29 * 30 + 60));
      expect(sound.cues, isNotEmpty);
      expect(sound.cues.first, closeTo(sound.firstVolume, 1e-12));
      await c.awake();
      expect(c.stage, NapStage.done);
      final s = c.last!;
      expect(s.end, NapEnd.deepSleep);
      expect(s.deepEpoch, 25);
      expect(s.stages.substring(0, 26), '${'W' * 10}${'2' * 14}33');
      expect(s.stages.substring(26), matches(RegExp(r'^\.+$')), reason: 'the last 2 minutes and the wake are not scored');
      expect(s.onsetS, inInclusiveRange(230, 270), reason: 'the drift-off detector\'s onset is the "asleep" time');
      expect(s.upS, greaterThanOrEqualTo(s.wakeS!));
      expect(s.live.mode, LiveMode.full);
      expect(s.live.calls, greaterThanOrEqualTo(20));
      expect(model.seen.every((call) => call.runs == 3), isTrue);
      expect(model.closed, isTrue, reason: 'the model is released at the wake');
      expect(sound.stopped, isTrue);
      expect(band.calls.last, 'disconnect');
      // saved, and the EEG is a normal recording with markers
      expect(store.list().single.toJson(), s.toJson());
      final f32 = File('${recordings.path}/${s.recording}.f32');
      expect(f32.lengthSync() ~/ recordBytes, greaterThan(29 * 30 * 250));
      final markers = [
        for (final l in File('${recordings.path}/${s.recording}.markers.jsonl').readAsLinesSync()) '${(jsonDecode(l) as Map)['text']}',
      ];
      expect(markers.first, startsWith('nap coach: lights off; length 45 min'));
      expect(markers, contains(startsWith('nap coach: deep sleep starting (epoch 25')));
      expect(markers, containsAllInOrder(['nap coach: wake (deepSleep)', "nap coach: I'm awake", 'nap coach: end (deepSleep)']));
      expect(nightsIn(recordings).single.recordings.single.path, f32.path);
      c.dispose();
    });

    test('no deep sleep: the length wakes you, and the cue rises every 20 s until you tap', () async {
      final band = DriftBand((t) => t < 120 ? 1 : 0.3);
      final sound = SilentNapSound();
      final c = controller(band, sound, model: () => ScriptedModel((e) => e < 8 ? 'W' : 'N2'));
      await c.start(lengthMin: 20);
      await until(c, () => c.stage == NapStage.waking);
      expect(c.end, NapEnd.length);
      expect(c.seconds, inInclusiveRange(1200, 1210));
      await until(c, () => sound.cues.length >= 3);
      expect(sound.cues.take(3), [for (var k = 0; k < 3; k++) closeTo(wakeVolume(k, sound.firstVolume), 1e-12)]);
      await c.awake();
      final s = c.last!;
      expect(s.end, NapEnd.length);
      expect(s.deepEpoch, isNull);
      expect(s.upS! - s.wakeS!, greaterThanOrEqualTo(40));
      expect(s.asleepMin, greaterThan(10));
      c.dispose();
    });

    test('a failing model: the timer alone ends the nap, and the screen and the report say why', () async {
      final band = DriftBand((t) => 1);
      final sound = SilentNapSound();
      final c = controller(band, sound, model: () => ScriptedModel((_) => 'W')..fail = StateError('no ONNX Runtime'));
      await c.start(lengthMin: 20);
      await until(c, () => c.live == NapLive.timer);
      expect(c.liveNote, contains('no ONNX Runtime'));
      expect(c.liveNote, contains('timer alone'));
      await until(c, () => c.stage == NapStage.waking);
      expect(c.end, NapEnd.length);
      await c.awake();
      expect(c.last!.live.mode, LiveMode.timer);
      expect(c.last!.live.why, contains('no ONNX Runtime'));
      expect(c.last!.stages, matches(RegExp(r'^\.+$')));
      c.dispose();
    });

    test('a model call that never returns: Stop still ends and saves the nap at once', () async {
      final band = DriftBand((t) => 1);
      final model = ScriptedModel((_) => 'W')..gate = Completer<void>(); // never completed
      final c = controller(band, SilentNapSound(), model: () => model);
      await c.start(lengthMin: 90);
      await until(c, () => model.seen.isNotEmpty);
      await c.stop().timeout(const Duration(seconds: 5));
      expect(c.stage, NapStage.done);
      expect(c.last!.end, NapEnd.stopped);
      expect(store.list().single.end, NapEnd.stopped, reason: 'the final record, not the last once-a-minute save');
      expect(band.calls.last, 'disconnect');
      expect(model.closed, isFalse, reason: 'never closed under a call that is still running');
      c.dispose();
    });

    test('a model call past its deadline: the timer alone ends the nap, and the screen says why', () async {
      final model = ScriptedModel((_) => 'W')..gate = Completer<void>();
      final c = NapController(
        finder: OneFinder(DriftBand((t) => 1)),
        sound: SilentNapSound.new,
        model: () => model,
        store: store,
        recordingsDir: recordings,
        scale: scaleNow,
        timing: const NapTiming(
          link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
          tick: Duration(milliseconds: 20),
          modelDeadline: Duration(milliseconds: 300),
        ),
      );
      await c.start(lengthMin: 20);
      await until(c, () => c.live == NapLive.timer);
      expect(c.liveNote, contains('did not answer'));
      expect(model.seen.length, 1, reason: 'no new call after one that hung');
      await until(c, () => c.stage == NapStage.waking);
      await c.awake();
      expect(c.last!.live.mode, LiveMode.timer);
      model.gate!.complete(); // the hung call ends at last: only now is the model closed
      await until(c, () => model.closed);
      c.dispose();
    });

    test('without the model the timer works from the start', () async {
      final sound = SilentNapSound();
      final c = controller(DriftBand((t) => 1), sound);
      await c.start(lengthMin: 20);
      expect(c.live, NapLive.timer);
      expect(c.liveNote, contains('not available'));
      await c.stop();
      expect(c.last!.live.why, contains('not available'));
      c.dispose();
    });

    test('Stop before the wake: no cue, the nap is kept as stopped', () async {
      final sound = SilentNapSound();
      final c = controller(DriftBand((t) => 1), sound, model: () => ScriptedModel((_) => 'W'));
      await c.start(lengthMin: 30);
      await until(c, () => c.seconds > 400);
      await c.stop();
      expect(c.stage, NapStage.done);
      expect(sound.cues, isEmpty);
      final s = c.last!;
      expect(s.end, NapEnd.stopped);
      expect(s.wakeS, isNull);
      expect(s.endS, greaterThan(400));
      expect(s.stages.contains('W'), isTrue);
      expect(store.list().single.end, NapEnd.stopped);
      c.dispose();
    });

    test('nobody taps "I\'m awake": the cue gives up after 5 minutes and the nap is kept', () async {
      final sound = SilentNapSound();
      final c = controller(DriftBand((t) => 1), sound, model: () => ScriptedModel((_) => 'W'));
      await c.start(lengthMin: 20);
      await until(c, () => c.stage == NapStage.done, max: const Duration(seconds: 90));
      final s = c.last!;
      expect(s.end, NapEnd.length);
      expect(s.upS, isNull);
      expect(sound.cues.length, NapRule.wakeForS ~/ NapRule.wakeEveryS);
      expect(sound.cues.last, closeTo(wakeVolume(9, sound.firstVolume), 1e-12));
      c.dispose();
    });

    test('the live checks wait while last night is being scored, and the screen says so', () async {
      var nightScoring = true;
      final model = ScriptedModel((_) => 'N2');
      final c = NapController(
        finder: OneFinder(DriftBand((t) => 1)),
        sound: SilentNapSound.new,
        model: () => model,
        store: store,
        recordingsDir: recordings,
        mayRunModel: () => !nightScoring,
        scale: scaleNow,
        timing: fast,
      );
      await c.start(lengthMin: 30);
      await until(c, () => (c.stager?.waited ?? 0) > 1);
      expect(c.live, NapLive.starting);
      expect(c.liveNote, contains('last night'));
      expect(model.seen, isEmpty);
      nightScoring = false;
      await until(c, () => c.live == NapLive.on);
      await c.stop();
      expect(c.last!.live.waited, greaterThan(1));
      c.dispose();
    });

    test('no headband: the nap does not start and says what to check', () async {
      final c = controller(null, SilentNapSound());
      await c.start();
      expect(c.stage, NapStage.failed);
      expect(c.message, contains('Headband not found'));
      expect(store.list(), isEmpty);
      c.dispose();
    });

    test('the sound cannot start: no nap without a way to wake you', () async {
      final band = DriftBand((t) => 1);
      final c = controller(band, SilentNapSound()..failStart = StateError('no audio device'));
      await c.start();
      expect(c.stage, NapStage.failed);
      expect(c.message, contains('could not wake you'));
      expect(band.calls.last, 'disconnect');
      c.dispose();
    });

    test('Lights off holds the session service until the nap is saved; its Stop is "I\'m awake"', () async {
      final band = DriftBand((t) => 1);
      final sound = SilentNapSound();
      String? atRelease;
      final keeper = _WatchKeeper(() => atRelease = store.list().singleOrNull?.end?.name);
      final c = NapController(
        finder: OneFinder(band),
        sound: () => sound,
        store: store,
        recordingsDir: recordings,
        scale: scaleNow,
        timing: fast,
        keeper: keeper,
        clock: () => DateTime(2026, 11, 19, 14, 30),
      );
      await c.start(lengthMin: 20);
      expect(keeper.held, isTrue, reason: 'a locked phone must not freeze the nap: the wake cue depends on it');
      expect((keeper.spec!.title, keeper.spec!.text, keeper.spec!.headband), ('Nap', 'Wakes you by 14:50', true));
      expect(keeper.spec!.focus, isFalse, reason: 'nothing plays until the wake: a podcast you fall asleep to goes on');
      await until(c, () => c.stage == NapStage.waking);
      keeper.onStop!(); // Stop on the lock screen while the cue plays: "I'm awake"
      await until(c, () => c.stage == NapStage.done);
      expect(c.last!.upS, isNotNull);
      expect(keeper.log, ['hold', 'release']);
      expect(atRelease, NapEnd.length.name, reason: 'released only after the final record');
      c.dispose();
    });

    test('Stop on the notification before the wake ends the nap; a failed start lets the service go', () async {
      final keeper = FakeSessionKeeper();
      final c = NapController(finder: OneFinder(DriftBand((t) => 1)), sound: SilentNapSound.new, store: store, timing: fast, keeper: keeper);
      await c.start(lengthMin: 20);
      keeper.onStop!();
      await until(c, () => c.stage == NapStage.done);
      expect((c.last!.end, keeper.held), (NapEnd.stopped, false));
      final none = FakeSessionKeeper();
      final failed = NapController(finder: OneFinder(null), sound: SilentNapSound.new, store: store, timing: fast, keeper: none);
      await failed.start();
      expect(failed.stage, NapStage.failed);
      expect(none.log, ['hold', 'release']);
      c.dispose();
      failed.dispose();
    });

    test('a clock correction does not move the wake: the nap counts on a monotonic clock', () async {
      var wall = DateTime(2026, 11, 19, 14);
      var mono = Duration.zero;
      final band = DriftBand((t) => 1);
      final c = NapController(
        finder: OneFinder(band),
        sound: SilentNapSound.new,
        store: store,
        recordingsDir: recordings,
        scale: scaleNow,
        timing: fast,
        clock: () => wall,
        monotonic: () => mono,
      );
      await c.start(lengthMin: 20);
      band.paused = true;
      final at = c.seconds;
      wall = wall.add(const Duration(hours: 2)); // the phone's clock corrected two hours ahead
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.stage, NapStage.resting, reason: 'not woken by the wall clock');
      expect(c.seconds, closeTo(at, 1));
      mono += const Duration(minutes: 21);
      await until(c, () => c.stage == NapStage.waking);
      expect(c.end, NapEnd.length);
      await c.stop();
      c.dispose();
    });

    test('Stop while the sound starts: the sound that just started is stopped too (no engine left open)', () async {
      final band = DriftBand((t) => 1);
      final sound = _GatedNapSound();
      final c = controller(band, sound);
      final started = c.start(lengthMin: 20);
      await until(c, () => sound.asked);
      await c.stop();
      sound.gate.complete();
      await started;
      expect(sound.started, isTrue);
      expect(sound.stopped, isTrue, reason: 'the engine opened during Stop is closed');
      expect(c.stage, NapStage.setup);
      expect(band.calls.last, 'disconnect');
      c.dispose();
    });

    test('the drift-off detector\'s states reach the screen', () async {
      final c = controller(DriftBand((t) => t < 90 ? 1 : 0.3), SilentNapSound());
      await c.start(lengthMin: 20);
      expect(c.driftState, isNull, reason: 'the first minute is the baseline');
      await until(c, () => c.driftState == DriftState.asleep);
      await c.stop();
      expect(c.last!.onsetS, isNotNull);
      expect(c.last!.drowsyS, lessThan(c.last!.onsetS! + 6 * 30));
      c.dispose();
    });
  });
}

/// A nap sound whose start waits for the test.
class _GatedNapSound extends SilentNapSound {
  final Completer<void> gate = Completer<void>();
  bool asked = false;

  @override
  Future<void> start() async {
    asked = true;
    await gate.future;
    await super.start();
  }
}

/// A keeper that looks at the files when it is let go.
class _WatchKeeper extends FakeSessionKeeper {
  _WatchKeeper(this.onRelease);
  final void Function() onRelease;

  @override
  Future<void> release() async {
    if (held) onRelease();
    await super.release();
  }
}
