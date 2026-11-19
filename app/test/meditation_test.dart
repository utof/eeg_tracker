// The meditation mode without a phone: the tracker's counts on the demo signal, the summary file and its
// checks, the comparison wording, and whole sessions through the controller with a fake headband that streams
// the demo signal fast (calibration, sound cues and bells, report, saved files that replay exactly, a drop).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/detectors/detectors.dart' show EpochQuality;
import 'package:eeg_tracker/dream/band_link.dart' show LinkTiming;
import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/feedback/session.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/learning.dart';
import 'package:eeg_tracker/meditation/silent_block.dart';
import 'package:eeg_tracker/meditation/store.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/sound/feedback_sound.dart';
import 'package:eeg_tracker/training/control.dart';
import 'package:flutter_test/flutter_test.dart';

/// Streams the demo signal (in volts, as the SDK gives it) far faster than real time: [perTick] samples
/// every millisecond. Eyes open for the first 30 s (the calibration's instruction), then closed.
class DemoBand implements Headband {
  DemoBand(this.demo, {this.perTick = 250, this.label = 'A', this.skipAt, this.silentStarts = 0});

  final DemoSignal demo;
  final int perTick;
  final String label;

  /// At this sample, the packet numbers jump by 100 (100 samples lost on the way).
  final int? skipAt;

  /// The first this many [startSignal] calls start nothing (a stream that stays silent until it is restarted).
  final int silentStarts;
  int pack = 0;
  int sent = 0;
  Timer? _timer;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();
  final List<String> calls = [];

  void goOutOfRange() {
    _timer?.cancel();
    _range.add(false);
  }

  @override
  String get name => 'BrainBit $label';
  @override
  String get address => 'AA:BB';
  @override
  String get serial => '1';
  @override
  int? get rssi => -60;
  @override
  BandId get id => const BandId(name: 'BrainBit', address: 'AA:BB', family: 'leBrainBitBlack');
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  @override
  Future<void> startSignal() async {
    calls.add('startSignal');
    if (calls.where((e) => e == 'startSignal').length <= silentStarts) return;
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!_signal.hasListener) return;
      demo.eyes = demo.t < 30 ? 'open' : 'closed';
      final batch = <Sample>[];
      for (final r in demo.next(perTick)) {
        if (skipAt != null && sent == skipAt) pack += 100;
        batch.add((pack: pack % 2048, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6));
        pack++;
        sent++;
      }
      _signal.add(batch);
    });
  }

  @override
  Future<void> stopSignal() async {
    calls.add('stopSignal');
    _timer?.cancel();
  }

  @override
  Future<void> startResist() async {
    calls.add('startResist');
    Timer(const Duration(milliseconds: 1), () => _resist.add({'O1': 4e5, 'O2': 6e5, 'T3': 1.2e6, 'T4': double.infinity}));
  }

  @override
  Future<void> stopResist() async => calls.add('stopResist');
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async {
    calls.add('disconnect');
    _timer?.cancel();
  }
}

class Finder implements HeadbandFinder {
  Finder(this.bands, {this.direct = const []});
  final List<Headband?> bands;
  final List<Headband> direct;
  int found = 0, directTries = 0;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    final b = found < bands.length ? bands[found] : null;
    found++;
    if (b != null) onFound?.call(b.name, -60);
    return b;
  }

  @override
  Future<Headband> connectDirect(BandId id) async {
    if (directTries >= direct.length) throw StateError('out of range');
    return direct[directTries++];
  }
}

/// The first headband, then one direct reconnect target; records every try's kind and when it came (ms).
class TimedFinder implements HeadbandFinder {
  TimedFinder(this.first, this.direct);
  final Headband first;
  final Headband direct;
  final clock = Stopwatch()..start();
  final List<(String, int)> calls = [];
  bool _found = false;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    if (_found) {
      calls.add(('scan', clock.elapsedMilliseconds));
      return null; // the rescan finds nothing
    }
    _found = true;
    onFound?.call(first.name, -60);
    return first;
  }

  @override
  Future<Headband> connectDirect(BandId id) async {
    calls.add(('direct', clock.elapsedMilliseconds));
    if (calls.where((e) => e.$1 == 'direct').length < 3) throw StateError('out of range');
    return direct;
  }
}

const fast = MeditationTiming(
  contactFor: Duration(milliseconds: 5),
  settle: Duration.zero,
  tick: Duration(milliseconds: 20),
  reconnectWaits: [Duration(milliseconds: 5)],
  endRingOut: Duration.zero,
);

Future<void> until(MeditationController c, bool Function() done, {Duration max = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(max);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('stuck in ${c.stage} (${c.message})');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

MeditationSummary summaryOf({double runS = 600, double settledS = 300, DateTime? start, int bells = 10}) =>
    MeditationSummary(
      start: start ?? DateTime(2026, 11, 18, 21, 3),
      lengthMin: 10,
      runS: runS,
      complete: true,
      settledS: settledS,
      longestSettledS: 40,
      bells: bells,
      restless: {Restless.jaw: 2, Restless.blinks: 5, Restless.movement: 1},
      drifting: 1,
      drowsyS: 12.5,
      calm: [0.4, 0.6, 0.55],
      marks: [(31.2, 'jaw'), (200, 'drifting')],
      iafHz: 10,
      note: 'calibrated',
      logFile: '2026-11-18-210300.session.json',
    );

void main() {
  test('tracker: settled time, jaw and blink moments, a drifting minute, calm per 30 s', () {
    final s = Session(), demo = DemoSignal(7), t = MeditationTracker(const Duration(minutes: 5));
    while (!t.done) {
      demo.eyes = demo.t < 30 ? 'open' : 'closed';
      demo.alphaHz = demo.t >= 200 && demo.t < 260 ? 7.5 : 10; // a drowsy minute
      for (final r in s.push(demo.next(25))) {
        t.add(r);
      }
    }
    expect(t.runSeconds, closeTo(300, 0.05));
    expect(t.settledSeconds, inInclusiveRange(30, 240));
    expect(t.longestSettledSeconds, lessThanOrEqualTo(t.settledSeconds));
    // the demo clenches every 45 s (3 s) and blinks every 7 s
    expect(t.restless[Restless.jaw], inInclusiveRange(5, 8));
    expect(t.restless[Restless.blinks], greaterThan(20));
    expect(t.drifting, inInclusiveRange(1, 3));
    expect(t.calm.length, 10);
    expect(t.calm.every((c) => c >= 0 && c <= 1), isTrue);
    expect(t.marks.where((m) => m.$2 == 'jaw').length, t.restless[Restless.jaw]);
    final sum = t.summary(start: DateTime(2026, 11, 18, 21), complete: true, iafHz: s.iaf, note: s.note, logFile: 'x');
    expect(sum.settledShare, closeTo(t.settledSeconds / 300, 0.01));
  });

  test('tracker: the drift-off detector saying drowsy or asleep makes calm steps drifting', () {
    final s = Session(), demo = DemoSignal(7)..blinks = false..jawBursts = false;
    final plain = MeditationTracker(const Duration(minutes: 1)), drifted = MeditationTracker(const Duration(minutes: 1));
    while (!plain.done) {
      demo.eyes = demo.t < 30 ? 'open' : 'closed';
      for (final r in s.push(demo.next(25))) {
        plain.add(r);
        drifted.add(r, drift: plain.runSeconds > 30 ? DriftState.asleep : DriftState.awake);
      }
    }
    expect(plain.asleepS, isNull);
    expect(drifted.asleepS, closeTo(30.1, 0.05));
    expect(drifted.drowsySeconds, greaterThanOrEqualTo(29.9));
    expect(drifted.settledSeconds, lessThanOrEqualTo(plain.settledSeconds));
    final sum = drifted.summary(start: DateTime(2026, 11, 18), complete: true, iafHz: null, note: '', logFile: 'x');
    expect(MeditationSummary.fromJson(jsonDecode(jsonEncode(sum.toJson())))!.asleepS, sum.asleepS);
    expect(sum.toJson().containsKey('asleepS'), isTrue);
    expect(plain.summary(start: DateTime(2026, 11, 18), complete: true, iafHz: null, note: '', logFile: 'x').toJson(),
        isNot(contains('asleepS')), reason: 'older readers see the same file as before');
  });

  test('summary: JSON round trip; damaged or foreign files are refused', () {
    final s = summaryOf();
    final back = MeditationSummary.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
    expect(back.toJson(), s.toJson());
    expect(back.marks, s.marks);
    Map<String, Object?> j() => jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>;
    expect(MeditationSummary.fromJson(j()..['kind'] = 'night'), isNull);
    expect(MeditationSummary.fromJson(j()..['version'] = 2), isNull);
    expect(MeditationSummary.fromJson(j()..['settledS'] = 900), isNull, reason: 'more settled than run');
    expect(MeditationSummary.fromJson(j()..['calm'] = [0.5, 3]), isNull);
    expect(MeditationSummary.fromJson(j()..['bells'] = -1), isNull);
    expect(MeditationSummary.fromJson(j()..['restless'] = {'jaw': 1}), isNull);
    expect(MeditationSummary.fromJson('not a map'), isNull);
  });

  test('comparison: no range before 4 sessions, then within / above / below the last 14', () {
    final now = summaryOf(start: DateTime(2026, 11, 20), settledS: 420);
    expect(compareWithEarlier(now, [summaryOf()]).line, startsWith('Session 2.'));
    final earlier = [for (var d = 1; d <= 5; d++) summaryOf(start: DateTime(2026, 11, 10 + d), settledS: 200.0 + 20 * d)];
    final c = compareWithEarlier(now, earlier);
    expect(c.line, contains('70 %'));
    expect(c.line, contains('above the range of your last 5 sessions (37-50 %)'));
    expect(c.line, contains('A trend needs about 8 sessions'));
    expect(compareWithEarlier(summaryOf(start: DateTime(2026, 11, 20), settledS: 260), earlier).line, contains('within'));
  });

  test('a whole session: calibration, sound, bells, report, files that replay exactly', () async {
    final dir = Directory.systemTemp.createTempSync('meditation');
    addTearDown(() => dir.deleteSync(recursive: true));
    final band = DemoBand(DemoSignal(7)), sound = SilentSound();
    final c = MeditationController(
      finder: Finder([band]),
      sound: () => sound,
      store: MeditationStore(dir),
      timing: fast,
    );
    final stages = <Stage>[];
    c.addListener(() {
      if (stages.isEmpty || stages.last != c.stage) stages.add(c.stage);
    });
    await c.start(const Duration(minutes: 2));
    await until(c, () => c.stage == Stage.report);
    expect(stages, containsAllInOrder([Stage.connecting, Stage.contact, Stage.calibrating, Stage.running, Stage.ending, Stage.report]));
    expect(c.contact, {'O1': 4e5, 'O2': 6e5, 'T3': 1.2e6, 'T4': null}, reason: 'infinite resistance = no contact');
    expect(sound.started && sound.stopped, isTrue);
    expect(sound.cues, 4, reason: 'close your eyes, sound begins, the silent minutes begin, session over');
    expect(sound.bedOn, isFalse);
    final r = c.report!;
    expect(r.complete, isTrue);
    expect(r.runS, closeTo(120, 0.1));
    expect(r.bells, sound.bells);
    expect(r.bells, greaterThan(0));
    expect(r.iafHz, 10);
    expect(band.calls, containsAllInOrder(['startResist', 'stopResist', 'startSignal', 'stopSignal', 'disconnect']));

    final saved = MeditationStore(dir).list();
    expect(saved.single.toJson(), r.toJson());
    final log = jsonDecode(File('${dir.path}/${r.logFile}').readAsStringSync()) as Map<String, Object?>;
    final again = replaySession(log);
    expect(jsonEncode(again.log.lines), jsonEncode(log['lines']), reason: 'the phone session replays line for line');
    expect((log['info']! as List).any((i) => (i as Map).containsKey('sound')), isTrue);
    expect(c.comparison, startsWith('Session 1.'));
    c.dispose();
  });

  test('a clock correction mid-session is not a hole in the signal: arrivals are timed on a monotonic clock', () async {
    var wall = DateTime(2026, 11, 19, 21);
    final band = DemoBand(DemoSignal(7)), sound = SilentSound();
    final c = MeditationController(
      finder: Finder([band]),
      sound: () => sound,
      timing: fast,
      silentBlock: Duration.zero,
      clock: () => wall,
      monotonic: () => Duration.zero,
    );
    await c.start(const Duration(minutes: 1));
    await until(c, () => c.stage == Stage.running);
    wall = wall.add(const Duration(seconds: 30)); // the phone's clock corrected half a minute ahead
    await until(c, () => c.stage == Stage.report);
    final gaps = [for (final l in c.session!.log.lines) if (l['type'] == 'gap') l];
    expect(gaps, isEmpty, reason: 'the signal never stopped');
    c.dispose();
  });

  test('Stop saves before the slow steps: a sound that never finishes fading cannot lose the session', () async {
    final dir = Directory.systemTemp.createTempSync('meditation');
    addTearDown(() => dir.deleteSync(recursive: true));
    final band = DemoBand(DemoSignal(7), perTick: 25), sound = _StuckSound();
    final c = MeditationController(finder: Finder([band]), sound: () => sound, store: MeditationStore(dir), timing: fast);
    await c.start(const Duration(minutes: 20));
    await until(c, () => c.runSeconds > 30);
    unawaited(c.stop());
    await until(c, () => MeditationStore(dir).list().isNotEmpty, max: const Duration(seconds: 5));
    final s = MeditationStore(dir).list().single;
    expect(s.complete, isFalse);
    expect(s.runS, greaterThan(30));
    expect(File('${dir.path}/${s.logFile}').existsSync(), isTrue);
    expect(c.stage, Stage.ending, reason: 'the sound is still fading; the session is already kept');
  });

  test('a session is kept as it goes: a checkpoint every minute, then the final files (a killed app keeps it)', () async {
    final dir = Directory.systemTemp.createTempSync('meditation');
    addTearDown(() => dir.deleteSync(recursive: true));
    var mono = Duration.zero;
    final band = DemoBand(DemoSignal(7), perTick: 25), sound = SilentSound();
    final c = MeditationController(
      finder: Finder([band]),
      sound: () => sound,
      store: MeditationStore(dir),
      timing: fast,
      monotonic: () => mono,
    );
    await c.start(const Duration(minutes: 20));
    await until(c, () => c.runSeconds > 30);
    expect(MeditationStore(dir).list(), isEmpty, reason: 'not a minute yet');
    mono += const Duration(seconds: 61);
    await until(c, () => MeditationStore(dir).list().isNotEmpty, max: const Duration(seconds: 5));
    final cp = MeditationStore(dir).list().single;
    expect((cp.complete, cp.end), (false, 'running'), reason: 'a checkpoint says the session had not ended');
    final cpLog = jsonDecode(File('${dir.path}/${cp.logFile}').readAsStringSync()) as Map<String, Object?>;
    expect(replaySession(cpLog).log.lines, isNotEmpty, reason: 'the checkpoint\'s log replays');
    await c.stop();
    final fin = MeditationStore(dir).list().single;
    expect((fin.end, fin.start), (null, cp.start), reason: 'the final files replace the checkpoint');
    expect(fin.runS, greaterThan(cp.runS));
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    c.dispose();
  });

  group('clock limits', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('meditation'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a headband that goes silent for 5 minutes ends the session, kept with what there was', () async {
      var mono = Duration.zero;
      final band = DemoBand(DemoSignal(7), perTick: 25), sound = SilentSound();
      final c = MeditationController(
        finder: Finder([band]),
        sound: () => sound,
        store: MeditationStore(dir),
        timing: fast,
        monotonic: () => mono,
      );
      await c.start(const Duration(minutes: 20));
      await until(c, () => c.runSeconds > 30);
      band.goOutOfRange(); // the battery dies: no signal, reconnect tries find nothing
      mono += const Duration(minutes: 4);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.stage, Stage.running, reason: '4 minutes without signal: still waiting');
      mono += const Duration(minutes: 1, seconds: 1);
      await until(c, () => c.stage == Stage.report, max: const Duration(seconds: 5));
      expect(c.report!.end, MeditationSummary.endNoSignal);
      expect(c.report!.complete, isFalse);
      expect(MeditationStore(dir).list().single.end, MeditationSummary.endNoSignal);
      expect(sound.stopped, isTrue);
      c.dispose();
    });

    test('a session that never reaches its length ends at length + silent minutes + 20 min from Start', () async {
      var mono = Duration.zero;
      final band = DemoBand(DemoSignal(7), perTick: 25), sound = SilentSound();
      final c = MeditationController(
        finder: Finder([band]),
        sound: () => sound,
        store: MeditationStore(dir),
        timing: fast,
        monotonic: () => mono,
      );
      await c.start(const Duration(minutes: 20));
      await until(c, () => c.runSeconds > 30);
      mono += const Duration(minutes: 41);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.stage, Stage.running);
      mono += const Duration(minutes: 1, seconds: 1); // 20 + 2 + 20 minutes
      await until(c, () => c.stage == Stage.report, max: const Duration(seconds: 5));
      expect(c.report!.end, MeditationSummary.endClock);
      c.dispose();
    });

    test('a calibration that never gets its clean seconds ends after 10 minutes and says why', () async {
      var mono = Duration.zero;
      final band = DemoBand(DemoSignal(7), perTick: 1), sound = SilentSound(); // slow: still calibrating
      final c = MeditationController(
        finder: Finder([band]),
        sound: () => sound,
        store: MeditationStore(dir),
        timing: fast,
        monotonic: () => mono,
      );
      await c.start(const Duration(minutes: 5));
      expect(c.stage, Stage.calibrating);
      mono += const Duration(minutes: 10, seconds: 1);
      await until(c, () => c.stage == Stage.setup, max: const Duration(seconds: 5));
      expect(c.message, contains('calibration'));
      expect(MeditationStore(dir).list(), isEmpty, reason: 'nothing to report');
      expect(band.calls.last, 'disconnect');
      c.dispose();
    });
  });

  test('the silent minutes: the sound stops after the length, the headband goes on, the block has its number', () async {
    final dir = Directory.systemTemp.createTempSync('meditation');
    addTearDown(() => dir.deleteSync(recursive: true));
    final band = DemoBand(DemoSignal(7)), sound = SilentSound();
    final c = MeditationController(finder: Finder([band]), sound: () => sound, store: MeditationStore(dir), timing: fast);
    expect(c.silentBlock, silentBlockLength);
    await c.start(const Duration(minutes: 1));
    await until(c, () => c.inSilentBlock);
    final glides = sound.glides, bells = sound.bells;
    expect(sound.bedOn, isFalse, reason: 'the bed fades out at the cue');
    expect(c.stage, Stage.running);
    expect(c.runSeconds, closeTo(60, 0.1));
    await until(c, () => c.silentSeconds > 30);
    expect(c.silentSecondsLeft, inInclusiveRange(1, 90));
    await until(c, () => c.stage == Stage.report);
    expect(sound.glides, glides, reason: 'nothing is played in the silent minutes');
    expect(sound.bells, bells);
    final r = c.report!;
    expect(r.complete, isTrue);
    expect(r.runS, closeTo(60, 0.1), reason: 'the length counts the time with sound only');
    expect(r.silent!.plannedS, 120);
    expect(r.silent!.seconds, closeTo(120, 0.1));
    expect(r.silent!.alpha, isNotNull);
    expect(r.silent!.muscleShare, greaterThan(0), reason: 'the demo clenches every 45 s');
    final log = jsonDecode(File('${dir.path}/${r.logFile}').readAsStringSync()) as Map<String, Object?>;
    final marker = (log['info']! as List).cast<Map<String, Object?>>().firstWhere((i) => i.containsKey('silentBlock'));
    final fromN = (marker['silentBlock']! as Map<String, Object?>)['fromN']! as int;
    expect(fromN, (90 + 60) * 250, reason: 'after 90 s of calibration and 60 s with sound');
    expect(controlStream(log, SessionKind.meditation), hasLength(600), reason: 'a replay plays only the time with sound');
    expect(jsonEncode(replaySession(log).log.lines), jsonEncode(log['lines']), reason: 'the core ran on: it replays');
    c.dispose();
  });

  test('Stop in the silent minutes keeps the session whole and the block as far as it got', () async {
    final band = DemoBand(DemoSignal(7));
    final c = MeditationController(finder: Finder([band]), sound: SilentSound.new, timing: fast);
    await c.start(const Duration(minutes: 1));
    await until(c, () => c.silentSeconds > 20);
    await c.stop();
    await until(c, () => c.stage == Stage.report);
    expect(c.report!.complete, isTrue, reason: 'the time with sound was reached');
    expect(c.report!.silent!.seconds, inInclusiveRange(20, 60));
    expect(c.report!.silent!.alpha, isNull, reason: 'under a minute of clean signal: no number');
    c.dispose();
  });

  test('a session stopped before its silent minutes has none; the learning line says how many count', () async {
    final band = DemoBand(DemoSignal(7));
    final c = MeditationController(finder: Finder([band]), sound: SilentSound.new, timing: fast);
    await c.start(const Duration(minutes: 1));
    await until(c, () => c.runSeconds > 20);
    await c.stop();
    await until(c, () => c.stage == Stage.report);
    expect(c.report!.complete, isFalse);
    expect(c.report!.silent, isNull);
    expect(c.learning!.verdict, Verdict.notYet);
    expect(c.learning!.lines.first, startsWith('Not enough sessions yet: 0 of 8'));
    c.dispose();
  });

  test('drift-off in a session: lights off at the close-eyes cue, alpha fades, probably asleep within 4 min', () async {
    final demo = DemoSignal(11)
      ..blinks = false
      ..jawBursts = false
      ..wanders = false;
    final band = DemoBand(demo);
    final fade = Timer.periodic(const Duration(milliseconds: 1), (_) => demo.alphaGain = demo.t > 150 ? 0.1 : 1);
    addTearDown(fade.cancel);
    final c = MeditationController(finder: Finder([band]), sound: SilentSound.new, timing: fast);
    await c.start(const Duration(minutes: 6));
    await until(c, () => c.stage == Stage.report, max: const Duration(seconds: 60));
    final d = c.drift!;
    expect(d.lightsOff, inInclusiveRange(29, 31), reason: 'the close-eyes cue comes after 30 s eyes open');
    expect(d.baselineAlpha, greaterThan(50));
    expect(d.onset, inInclusiveRange(150, 185));
    expect(d.asleepAt! - d.onset!, 179);
    final r = c.report!;
    expect(r.asleepS, isNotNull);
    expect(r.asleepS! + 90, closeTo(d.asleepAt! + 1, 3), reason: 'run seconds start after the 90 s calibration');
    expect(r.drifting, greaterThanOrEqualTo(1));
    expect(c.seen!.epochs.where((e) => e.quality == EpochQuality.good).length, greaterThan(10));
    final info = c.session!.log.info.firstWhere((i) => i.containsKey('detectors'))['detectors']! as Map<String, Object?>;
    expect((info['drift']! as Map<String, Object?>)['onsetS'], d.onset);
    c.dispose();
  });

  test('a drop mid-session: a gap in the log, a direct reconnect, the session still ends with its report', () async {
    final demo = DemoSignal(3), first = DemoBand(demo), second = DemoBand(demo, label: 'B');
    final c = MeditationController(
      finder: Finder([first], direct: [second]),
      sound: SilentSound.new,
      timing: fast,
    );
    await c.start(const Duration(minutes: 1));
    await until(c, () => c.stage == Stage.running && c.runSeconds > 20);
    first.goOutOfRange();
    await until(c, () => c.stage == Stage.report);
    expect(first.calls, isNot(contains('disconnect')), reason: 'no SDK call on a headband out of range');
    expect(second.calls, containsAllInOrder(['startSignal', 'stopSignal', 'disconnect']));
    expect(c.leftLost, isTrue);
    expect(c.report!.complete, isTrue);
    c.dispose();
  });

  test('a drop: the reconnect waits, the direct tries, every third a scan, and the log lines (DECISIONS 76)', () async {
    final demo = DemoSignal(3), first = DemoBand(demo), second = DemoBand(demo, label: 'B');
    final finder = TimedFinder(first, second);
    const waits = [Duration(milliseconds: 40), Duration(milliseconds: 80), Duration(milliseconds: 120)];
    final c = MeditationController(
      finder: finder,
      sound: SilentSound.new,
      timing: const MeditationTiming(
        contactFor: Duration(milliseconds: 5),
        settle: Duration.zero,
        tick: Duration(milliseconds: 20),
        reconnectWaits: waits,
        endRingOut: Duration.zero,
      ),
    );
    await c.start(const Duration(minutes: 1));
    await until(c, () => c.stage == Stage.running && c.runSeconds > 5);
    final dropAt = finder.clock.elapsedMilliseconds;
    first.goOutOfRange();
    await until(c, () => c.stage == Stage.report);
    expect(finder.calls.map((e) => e.$1), ['direct', 'direct', 'scan', 'direct'], reason: 'every third try is a scan');
    var before = dropAt;
    for (var i = 0; i < 4; i++) {
      final wait = waits[i < 3 ? i : 2].inMilliseconds, at = finder.calls[i].$2;
      expect(at - before, greaterThanOrEqualTo(wait - 5), reason: 'try ${i + 1} waits ${wait}ms (the last wait repeats)');
      expect(at - before, lessThan(wait + 500), reason: 'try ${i + 1} is not delayed');
      before = at;
    }
    expect(first.calls, isNot(contains('disconnect')));
    final events = c.session!.log.info.map((i) => i['event']).whereType<String>().toList();
    expect(events.where((e) => e == 'drop'), hasLength(1));
    expect(events.where((e) => e == 'reconnect try'), hasLength(4));
    expect(events.where((e) => e == 'reconnected'), hasLength(1));
    final tries = c.session!.log.info.where((i) => i['event'] == 'reconnect try').toList();
    expect([for (final t in tries) (t['try'], t['scan'], t['ok'])], [(1, false, false), (2, false, false), (3, true, false), (4, false, true)]);
    c.dispose();
  });

  test('the reconnect rules are the shared link\'s: the timing maps one to one, and the controller has no copy', () {
    const t = MeditationTiming(), l = LinkTiming();
    expect(
      [t.link.scanFor, t.link.connectTimeout, t.link.sdkTimeout, t.link.contactFor, t.link.settle, t.link.restartStreamAfter, t.link.rescanFor],
      [l.scanFor, l.connectTimeout, l.sdkTimeout, l.contactFor, l.settle, l.restartStreamAfter, l.rescanFor],
      reason: 'the defaults are the link\'s',
    );
    expect(t.link.reconnectWaits, l.reconnectWaits);
    const custom = MeditationTiming(contactFor: Duration(milliseconds: 7), reconnectWaits: [Duration(milliseconds: 9)]);
    expect([custom.link.contactFor, custom.link.reconnectWaits], [const Duration(milliseconds: 7), const [Duration(milliseconds: 9)]]);
    final source = File('lib/meditation/controller.dart').readAsStringSync();
    expect(source, contains('BandLink('));
    for (final own in ['connectDirect', 'rangeChanges', 'startResist', 'stopSignal', 'disconnectAndDispose']) {
      expect(source, isNot(contains(own)), reason: 'no own copy of the headband rules ($own)');
    }
  });

  test('a stream that never starts is restarted once after restartStreamAfter, then the session goes on', () async {
    final band = DemoBand(DemoSignal(3), silentStarts: 1);
    final c = MeditationController(
      finder: Finder([band]),
      sound: SilentSound.new,
      timing: const MeditationTiming(
        contactFor: Duration(milliseconds: 5),
        settle: Duration.zero,
        tick: Duration(milliseconds: 20),
        restartStreamAfter: Duration(milliseconds: 150),
        endRingOut: Duration.zero,
      ),
    );
    await c.start(const Duration(minutes: 1));
    await until(c, () => band.sent > 500, max: const Duration(seconds: 10)); // nothing arrives until the restart
    expect(band.calls.where((e) => e == 'stopSignal'), hasLength(1));
    expect(c.session!.log.info.where((i) => i['event'] == 'stream restarted'), hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(band.calls.where((e) => e == 'startSignal'), hasLength(2), reason: 'restarted once only');
    await c.stop();
    c.dispose();
  });

  test('a skip in the packet numbers is a gap; stopping before calibration ends saves nothing', () async {
    final dir = Directory.systemTemp.createTempSync('meditation');
    addTearDown(() => dir.deleteSync(recursive: true));
    final band = DemoBand(DemoSignal(5), perTick: 25, skipAt: 2500);
    final c = MeditationController(finder: Finder([band]), sound: SilentSound.new, store: MeditationStore(dir), timing: fast);
    await c.start(const Duration(minutes: 5));
    await until(c, () => c.stage == Stage.calibrating && band.sent > 3000);
    final gaps = c.session!.log.lines.where((l) => l['type'] == 'gap').toList();
    expect(gaps.length, 1);
    expect(gaps.single['n'], 2500, reason: 'the gap lands at the sample after the hole');
    await c.stop();
    expect(c.stage, Stage.setup);
    expect(c.message, contains('nothing was saved'));
    expect(MeditationStore(dir).list(), isEmpty);
    expect(band.calls, contains('disconnect'));
    c.dispose();
  });

  test('no headband found: a plain failure', () async {
    final c = MeditationController(finder: Finder([null]), sound: SilentSound.new, timing: fast);
    await c.start(const Duration(minutes: 5));
    expect(c.stage, Stage.failed);
    expect(c.message, contains('not found'));
    c.dispose();
  });
}

/// A sound whose fade never ends (a stuck audio thread).
class _StuckSound extends SilentSound {
  @override
  Future<void> stop() => Completer<void>().future;
}
