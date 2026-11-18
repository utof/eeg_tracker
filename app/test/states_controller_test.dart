// Sound-for-states sessions through the controller, without a phone: the sound alone on its timer (a fake clock), the
// fallback when the headband is not found, a relax session with the quiet minute and the readout (a fake headband
// streaming a synthetic eyes-closed signal far faster than real time), and "fall asleep" fading out once the drift-off
// detector says probably asleep, with its EEG kept and the night recording started afterwards.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sound/state_sound.dart';
import 'package:eeg_tracker/states/controller.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/states/timers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dream_test.dart' show DriftBand, OneFinder;

const fast = StatesTiming(
  link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
  tick: Duration(milliseconds: 20),
);

Future<void> until(StatesController c, bool Function() done, {Duration max = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(max);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('stuck in ${c.stage} (${c.message}) at ${c.seconds.round()} s');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root;
  late Directory recordings;
  late SoundStore store;
  setUp(() {
    root = Directory.systemTemp.createTempSync('states');
    recordings = Directory('${root.path}/recordings')..createSync();
    store = SoundStore(soundStatesDirFor(recordings.path));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('sound only: plays at once, fades for the plan\'s last 20 s, then is silent and saved', () async {
    var now = DateTime(2026, 11, 18, 14);
    final sound = SilentStateSound();
    final c = StatesController(finder: OneFinder(null), sound: () => sound, store: store, timing: fast, clock: () => now);
    await c.start(SoundPlan.of(SoundState.relax, beat: Beat.pulsed), useHeadband: false);
    expect(c.stage, SoundStage.playing);
    expect(sound.plan!.beat, Beat.pulsed);
    expect(sound.fadeIn, 6);
    expect(c.secondsLeft, closeTo(600, 1));
    expect(c.rateNow, 10);
    expect(store.list().single.end, SoundEnd.running, reason: 'a file exists from the start of the sound');
    now = now.add(const Duration(seconds: 581));
    await until(c, () => c.stage == SoundStage.fading);
    expect(sound.fades.single, closeTo(19, 1));
    expect(c.stopWhy, StopWhy.time);
    now = now.add(const Duration(seconds: 20));
    await until(c, () => c.stage == SoundStage.done);
    expect(sound.stopped, isTrue);
    final s = store.list().single;
    expect((s.headband, s.end, s.soundStartS, s.fadeFromS, s.offAtS), (HeadbandUse.soundOnly, SoundEnd.time, 0, 580, 600));
    expect(s.summary, isNull, reason: 'nothing measured');
    expect(s.recording, isNull);
    expect(s.events.map((e) => e.text), ['sound on: Ocean, pulsed noise 10 Hz', 'time: fading out', 'silent (time)']);
    c.rate(4);
    expect(store.list().single.rating, 4);
    c.dispose();
  });

  test('fall asleep without the headband: the timer alone, never past 45 minutes', () async {
    var now = DateTime(2026, 11, 18, 23);
    final sound = SilentStateSound();
    final c = StatesController(finder: OneFinder(null), sound: () => sound, store: store, timing: fast, clock: () => now);
    await c.start(SoundPlan.of(SoundState.asleep, minutes: 45), useHeadband: false, why: HeadbandUse.nightRecording, thenNight: true);
    expect(c.thenNight, isFalse, reason: 'the night is already recording');
    expect(sound.fadeIn, 45);
    now = now.add(const Duration(minutes: 43));
    await until(c, () => c.stage == SoundStage.fading);
    expect(sound.fades.single, closeTo(120, 1), reason: 'the 2.5 min fade, two of them still to go');
    expect(c.stopWhy, StopWhy.cap);
    now = now.add(const Duration(minutes: 2));
    await until(c, () => c.stage == SoundStage.done);
    final s = store.list().single;
    expect((s.headband, s.end, s.offAtS), (HeadbandUse.nightRecording, SoundEnd.cap, 2700));
    c.dispose();
  });

  test('headband not found: says so and plays the sound on its timer', () async {
    final sound = SilentStateSound();
    final c = StatesController(finder: OneFinder(null), sound: () => sound, store: store, timing: fast);
    await c.start(SoundPlan.of(SoundState.pause));
    expect(c.stage, SoundStage.playing);
    expect(c.headband, HeadbandUse.notFound);
    expect(c.message, contains('not found'));
    await c.stop();
    expect(store.list().single.headband, HeadbandUse.notFound);
    expect(store.list().single.end, SoundEnd.stopped);
    c.dispose();
  });

  test('relax with the headband: a quiet minute, then the sound and the readout against it', () async {
    final band = DriftBand((t) => 1);
    final sound = SilentStateSound();
    final c = StatesController(finder: OneFinder(band), sound: () => sound, store: store, recordingsDir: recordings, timing: fast);
    final plan = SoundPlan.of(SoundState.relax, beat: Beat.isochronic, minutes: 5);
    await c.start(plan);
    expect(c.stage, SoundStage.quiet);
    expect(sound.started, isFalse, reason: 'the quiet minute is silent');
    await until(c, () => c.stage == SoundStage.playing);
    expect(c.quietS, greaterThanOrEqualTo(fast.quietCleanS));
    expect(c.hasBaseline, isTrue);
    await until(c, () => c.live != null);
    expect(c.live!.alpha, inInclusiveRange(0.5, 2), reason: 'the same calm signal as the quiet minute');
    await until(c, () => c.stage == SoundStage.done);
    final s = store.list().single;
    expect(s.headband, HeadbandUse.used);
    expect(s.end, SoundEnd.time);
    expect(s.soundStartS, inInclusiveRange(fast.quietCleanS, fast.quietMaxS));
    expect(s.offAtS! - s.soundStartS!, 300);
    expect(s.baselineS, greaterThanOrEqualTo(fast.quietCleanS));
    expect(s.summary!.cleanS, greaterThan(200));
    expect(s.summary!.echo, isNotNull, reason: 'a beat: its echo is measured (on this fake signal there is none)');
    expect(s.epochs.length, greaterThanOrEqualTo(9));
    expect(s.contact['O1'], 4e5);
    expect(s.recording, isNull, reason: 'only fall asleep keeps its EEG');
    expect(recordings.listSync(), isEmpty);
    expect(band.calls, contains('disconnect'));
    c.dispose();
  });

  test('fall asleep with the headband: fades out over 2.5 min once probably asleep, keeps the EEG, starts the night', () async {
    final band = DriftBand((t) => t < 240 ? 1 : 0.25); // alpha fades for good 4 minutes after lights off
    final sound = SilentStateSound();
    var nightStarted = 0;
    final c = StatesController(
      finder: OneFinder(band),
      sound: () => sound,
      store: store,
      recordingsDir: recordings,
      timing: fast,
      startNight: () async {
        nightStarted++;
        return null;
      },
    );
    await c.start(SoundPlan.of(SoundState.asleep, beat: Beat.pulsed, minutes: 45), thenNight: true);
    await until(c, () => c.stage == SoundStage.fading);
    expect(c.stopWhy, StopWhy.asleep);
    expect(c.driftState, DriftState.asleep);
    expect(sound.fades.single, closeTo(150, 1.5));
    await until(c, () => c.stage == SoundStage.done);
    final s = store.list().single;
    expect(s.end, SoundEnd.asleep);
    final asleepAt = s.drift['asleepAtS']! as int;
    expect(asleepAt, inInclusiveRange(240 + 5 * 30, 240 + 8 * 30), reason: 'six faded epochs after alpha fell');
    expect((s.fadeFromS, s.offAtS), (asleepAt + 1, asleepAt + 151));
    expect((s.drift['epochs']! as String).contains('s'), isTrue);
    expect(s.night, 'started');
    expect(nightStarted, 1);
    // the EEG is a normal recording with the events as markers, so it joins that night
    expect(s.recording, isNotNull);
    expect(File('${recordings.path}/${s.recording}.f32').lengthSync(), greaterThan(0));
    final markers = File('${recordings.path}/${s.recording}.markers.jsonl').readAsLinesSync().map((l) => jsonDecode(l)['text']);
    expect(markers, containsAll(['sound: sound on: Pink noise, pulsed noise 10 → 3 Hz', 'sound: probably asleep: fading out']));
    expect(nightsIn(recordings).single.files.any((f) => f.path.endsWith('.f32')), isTrue);
    c.dispose();
  });

  test('Stop in the quiet minute: no sound ever started, the session is kept as stopped', () async {
    final band = DriftBand((t) => 1, perTick: 5); // slow: the quiet minute is still running when Stop comes
    final sound = SilentStateSound();
    final c = StatesController(finder: OneFinder(band), sound: () => sound, store: store, timing: fast);
    await c.start(SoundPlan.of(SoundState.relax));
    expect(c.stage, SoundStage.quiet);
    await c.stop();
    expect(c.stage, SoundStage.done);
    expect(sound.started, isFalse);
    final s = store.list().single;
    expect((s.end, s.soundStartS), (SoundEnd.stopped, null));
    c.dispose();
  });

  test('Skip starts the sound at once; too short a quiet minute means no comparison', () async {
    final band = DriftBand((t) => 1, perTick: 5);
    final sound = SilentStateSound();
    final c = StatesController(finder: OneFinder(band), sound: () => sound, store: store, timing: fast);
    await c.start(SoundPlan.of(SoundState.focus));
    c.skipQuiet();
    await until(c, () => c.stage == SoundStage.playing);
    expect(c.hasBaseline, isFalse);
    await c.stop();
    final s = store.list().single;
    expect(s.summary, isNull);
    expect(s.events.map((e) => e.text), contains('quiet minute skipped'));
    c.dispose();
  });

  test('a sound that cannot start ends in a plain failure and lets the headband go', () async {
    final band = DriftBand((t) => 1);
    final c = StatesController(finder: OneFinder(band), sound: () => SilentStateSound()..fail = true, timing: fast);
    await c.start(SoundPlan.of(SoundState.relax));
    await until(c, () => c.stage == SoundStage.failed);
    expect(c.message, contains('sound did not start'));
    expect(band.calls, contains('disconnect'));
    c.dispose();
  });
}
