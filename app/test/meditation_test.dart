// The meditation mode without a phone: the tracker's counts on the demo signal, the summary file and its
// checks, the comparison wording, and whole sessions through the controller with a fake headband that streams
// the demo signal fast (calibration, sound cues and bells, report, saved files that replay exactly, a drop).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/feedback/session.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/store.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/sound/feedback_sound.dart';
import 'package:flutter_test/flutter_test.dart';

/// Streams the demo signal (in volts, as the SDK gives it) far faster than real time: [perTick] samples
/// every millisecond. Eyes open for the first 30 s (the calibration's instruction), then closed.
class DemoBand implements Headband {
  DemoBand(this.demo, {this.perTick = 250, this.label = 'A', this.skipAt});

  final DemoSignal demo;
  final int perTick;
  final String label;

  /// At this sample, the packet numbers jump by 100 (100 samples lost on the way).
  final int? skipAt;
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
    expect(sound.cues, 3, reason: 'close your eyes, sound begins, session over');
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
