// A work session end to end on a synthetic headband with a clock of its own (DECISIONS 440-449): calibration,
// the level, a drowsy hint with its chime and lock-screen words, a break, Stop and the saved file.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/session_keeper.dart';
import 'package:eeg_tracker/sound/work_sound.dart';
import 'package:eeg_tracker/work/breaks.dart';
import 'package:eeg_tracker/work/controller.dart';
import 'package:eeg_tracker/work/drowsiness.dart';
import 'package:eeg_tracker/work/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fast_band.dart' show OneFinder, until;

enum Mode { awake, drowsy, eyesClosed, off }

/// O1/O2: 10 Hz alpha; blinks every 4 s and sideways eye movements every 5 s while awake; none while drowsy; the
/// rails when off. Each batch is one second of its own clock.
class WorkBand implements Headband {
  WorkBand({required this.start});
  final double start;
  double clockS = 0;
  Mode mode = Mode.awake;
  int _i = 0, _pack = 0, _seed = 7;

  /// Small broadband noise (about 2 µV), so the muscle detector has a rest level.
  double _noise() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return (_seed / 0x7fffffff - 0.5) * 7;
  }
  Timer? _timer;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();

  DateTime now() => DateTime.fromMicrosecondsSinceEpoch(((start + clockS) * 1e6).round());

  List<Sample> _batch() {
    final out = <Sample>[];
    for (var k = 0; k < 250; k++, _i++) {
      final t = _i / 250;
      if (mode == Mode.off) {
        out.add((pack: _pack++ % 2048, o1: 0.4, o2: 0.4, t3: 0.4, t4: 0.4));
        continue;
      }
      final amp = switch (mode) {
        Mode.awake => 10.0,
        Mode.drowsy => 16.0,
        Mode.eyesClosed => 40.0,
        Mode.off => 0.0,
      };
      final alpha = amp * math.sin(2 * math.pi * 10 * t);
      final slow = 3 * math.sin(2 * math.pi * 3 * t);
      var blink = 0.0, eye = 0.0;
      if (mode == Mode.awake) {
        final bt = t % 4 - 2;
        blink = -120 * math.exp(-bt * bt / (2 * 0.04 * 0.04));
        final et = t % 5;
        final dir = (t ~/ 5).isEven ? 1 : -1;
        double ramp(double x) => x <= 0 ? 0 : x >= 1 ? 1 : 0.5 - 0.5 * math.cos(math.pi * x);
        eye = dir * 60 * (et < 2.5 ? ramp(et / 0.08) : 1 - ramp((et - 2.5) / 0.08));
      }
      out.add((
        pack: _pack++ % 2048,
        o1: (alpha + blink + slow + _noise()) * 1e-6,
        o2: (alpha * 0.9 + blink - slow + _noise()) * 1e-6,
        t3: (blink + eye + slow + _noise()) * 1e-6,
        t4: (blink - eye - slow + _noise()) * 1e-6,
      ));
    }
    return out;
  }

  @override
  String get name => 'BrainBit W';
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
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!_signal.hasListener) return;
      final b = _batch();
      clockS += 1;
      _signal.add(b);
    });
  }

  @override
  Future<void> stopSignal() async => _timer?.cancel();
  @override
  Future<void> startResist() async => Timer(const Duration(milliseconds: 1), () => _resist.add({'O1': 4e5, 'O2': 6e5, 'T3': 1.2e6, 'T4': 1.5e6}));
  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async => _timer?.cancel();
}

const fastLink = LinkTiming(scanFor: Duration(milliseconds: 50), contactFor: Duration(milliseconds: 5), settle: Duration.zero);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('work-ctl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  WorkController make(WorkBand band, {SilentWorkSound? sound, FakeSessionKeeper? keeper}) => WorkController(
    finder: OneFinder(band),
    sound: sound,
    keeper: keeper,
    store: WorkStore(Directory('${tmp.path}/work-sessions')),
    timing: const WorkTiming(link: fastLink, tick: Duration(milliseconds: 4), noDataAfter: Duration(seconds: 3)),
    clock: band.now,
  );

  test('calibrates on your first minutes, reads alert, then drowsy; the drowsy hint chimes and shows on the lock screen', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final sound = SilentWorkSound(), keeper = FakeSessionKeeper();
    final c = make(band, sound: sound, keeper: keeper);
    await c.start();
    expect(keeper.held, isTrue);
    expect(keeper.spec!.headband, isTrue);
    expect(c.stage, WorkStage.calibrating);
    await until(() => c.stage == WorkStage.running);
    expect(band.clockS, inInclusiveRange(240, 260), reason: '1 minute settling + 3 minutes of baseline');
    await until(() => c.level == DrowsyLevel.alert);
    band.mode = Mode.drowsy;
    await until(() => c.hint != null);
    expect(c.hint!.reason, HintReason.drowsy);
    expect(c.level, isNot(DrowsyLevel.alert));
    expect(sound.played, contains('chime'));
    expect(keeper.spec!.text, startsWith('You seem to be getting drowsy'));
    c.takeBreak();
    expect(c.onBreak, isTrue);
    expect(c.hint, isNull);
    final at = band.clockS;
    band.mode = Mode.awake;
    await until(() => band.clockS > at + 6 * 60);
    c.back();
    await until(() => band.clockS > at + 12 * 60);
    expect(c.afterBreak, startsWith('After your break: drowsiness went down'));
    await c.stop();
    expect(c.stage, WorkStage.done);
    expect(keeper.held, isFalse);
    final saved = WorkStore(Directory('${tmp.path}/work-sessions')).list().single;
    expect(saved.hints, 1);
    expect(saved.breaks, 1);
    expect(saved.drowsyMin, greaterThan(2));
    expect(c.last!['epochs'], isNotEmpty);
    c.dispose();
  });

  test('the headband off for 5 minutes is a break; the file is written while the session runs', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final c = make(band);
    await c.start();
    await until(() => c.stage == WorkStage.running);
    band.mode = Mode.off;
    await until(() => c.onBreak);
    expect(c.planner!.breaks.single.source, BreakSource.headbandOff);
    expect(c.worn, isFalse);
    band.mode = Mode.awake;
    await until(() => !c.onBreak);
    final files = Directory('${tmp.path}/work-sessions').listSync().whereType<File>().where((f) => f.path.endsWith('.work.json'));
    expect(files, isNotEmpty, reason: 'saved every 5 minutes');
    await c.stop();
    c.dispose();
  });

  test('an unanswered hint goes away when the headband comes off for a break', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final c = make(band);
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    band.mode = Mode.drowsy;
    await until(() => c.hint != null);
    band.mode = Mode.off;
    await until(() => c.onBreak);
    expect(c.hint, isNull);
    expect(c.planner!.hints.single.answer, isNull, reason: 'not answered; the break itself marks it taken later');
    await c.stop();
    expect(c.planner!.hints.single.taken, isTrue);
    c.dispose();
  });

  test('the eyes-closed minute comes first with its two cues and sets the closed-eyes alpha', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000)..mode = Mode.eyesClosed;
    final sound = SilentWorkSound();
    final c = make(band, sound: sound);
    await c.start(eyesClosedMinute: true);
    expect(c.stage, WorkStage.eyesClosed);
    expect(sound.played, ['close']);
    await until(() => c.stage == WorkStage.calibrating);
    band.mode = Mode.awake;
    expect(sound.played, ['close', 'open']);
    expect(c.closedAlpha, greaterThan(100));
    expect(c.drowsiness!.closedAlpha, c.closedAlpha);
    await c.stop();
    c.dispose();
  });

  test('no headband: it says so; Stop while connecting goes back to the start', () async {
    final c = WorkController(finder: _NoFinder(), timing: const WorkTiming(link: fastLink));
    await c.start();
    expect(c.stage, WorkStage.failed);
    expect(c.message, startsWith('Headband not found'));
    c.again();
    final slow = WorkController(finder: _NoFinder(delay: const Duration(milliseconds: 200)), timing: const WorkTiming(link: fastLink));
    final started = slow.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await slow.stop();
    expect(slow.stage, WorkStage.setup);
    await started;
    expect(slow.stage, WorkStage.setup);
  });

  test('words: the hint lines and the after-break line', () {
    final h = WorkHint(at: DateTime(2026), reason: HintReason.stretch, activeMin: 75.4, thresholdMin: 60, level: DrowsyLevel.alert);
    expect(hintTitle(h), "You've been at it for 1 h 15 min. A few minutes away from the screen?");
    final b = WorkBreak(start: DateTime(2026), source: BreakSource.tapped, before: 1.1, beforeLevel: DrowsyLevel.drowsy)
      ..end = DateTime(2026).add(const Duration(minutes: 8))
      ..after = 0.2
      ..afterLevel = DrowsyLevel.alert;
    expect(afterBreakWords(b), 'After your break: drowsiness went down (drowsy before, alert after).');
  });
}

class _NoFinder implements HeadbandFinder {
  _NoFinder({this.delay = Duration.zero});
  final Duration delay;
  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    await Future<void>.delayed(delay);
    return null;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('none');
}
