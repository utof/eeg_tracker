// A work session end to end on a synthetic headband with a clock of its own (DECISIONS 440-449): calibration,
// the level, a drowsy hint with its chime and lock-screen words, a break, Stop and the saved file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/nights.dart' show forgetNightSets, nightsIn;
import 'package:eeg_tracker/session_keeper.dart';
import 'package:eeg_tracker/sound/audio_route.dart' show MediaVolume;
import 'package:eeg_tracker/sound/work_sound.dart';
import 'package:eeg_tracker/work/breaks.dart';
import 'package:eeg_tracker/work/controller.dart';
import 'package:eeg_tracker/work/drowsiness.dart';
import 'package:eeg_tracker/work/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fast_band.dart' show OneFinder, until;
import 'support/gates.dart';

enum Mode { awake, drowsy, eyesClosed, off, stall, talking, flat, wild }

/// O1/O2: 10 Hz alpha; blinks every 4 s and sideways eye movements every 5 s while awake; none while drowsy; the
/// rails when off. Talking: the awake signal with 9 of every 10 seconds of jaw movement (4 Hz, 160-300 µV on every
/// channel) and muscle (80 Hz at T3/T4), as in a call; flat: every channel still (an electrode on the desk); wild:
/// 2000 µV of mains on every channel (floating electrodes). Each batch is one second of its own clock.
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

  /// What mends a stall: 'restart' (the stream started again) or 'reconnect' (a new connection); null: nothing.
  String? healOn;

  /// T4 has lost contact: held at the rail.
  bool t4lost = false;
  bool _started = false;
  final List<String> calls = [];
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();

  DateTime now() => DateTime.fromMicrosecondsSinceEpoch(((start + clockS) * 1e6).round());

  List<Sample> _batch() {
    final out = <Sample>[];
    for (var k = 0; k < 250; k++, _i++) {
      final t = _i / 250;
      if (mode == Mode.off || mode == Mode.stall) {
        out.add(Sample.four(pack: _pack++ % 2048, o1: 0.4, o2: 0.4, t3: 0.4, t4: 0.4));
        continue;
      }
      if (mode == Mode.flat) {
        out.add(Sample.four(pack: _pack++ % 2048, o1: 0.012, o2: -0.008, t3: 0.02, t4: -0.015));
        continue;
      }
      if (mode == Mode.wild) {
        final hum = 2000 * math.sin(2 * math.pi * 50 * t);
        out.add(Sample.four(pack: _pack++ % 2048, o1: hum * 1e-6, o2: hum * 0.9e-6, t3: -hum * 1e-6, t4: hum * 1.1e-6));
        continue;
      }
      final amp = switch (mode) {
        Mode.awake || Mode.talking => 10.0,
        Mode.drowsy => 16.0,
        Mode.eyesClosed => 40.0,
        Mode.off || Mode.stall || Mode.flat || Mode.wild => 0.0,
      };
      final alpha = amp * math.sin(2 * math.pi * 10 * t);
      final slow = 3 * math.sin(2 * math.pi * 3 * t);
      var blink = 0.0, eye = 0.0, jaw = 0.0, emg = 0.0;
      if (mode == Mode.talking && t % 10 < 9) {
        jaw = math.sin(2 * math.pi * 4 * t);
        emg = 40 * math.sin(2 * math.pi * 80 * t);
      }
      if (mode == Mode.awake || mode == Mode.talking) {
        final bt = t % 4 - 2;
        blink = -120 * math.exp(-bt * bt / (2 * 0.04 * 0.04));
        final et = t % 5;
        final dir = (t ~/ 5).isEven ? 1 : -1;
        double ramp(double x) => x <= 0 ? 0 : x >= 1 ? 1 : 0.5 - 0.5 * math.cos(math.pi * x);
        eye = dir * 60 * (et < 2.5 ? ramp(et / 0.08) : 1 - ramp((et - 2.5) / 0.08));
      }
      out.add(Sample.four(
        pack: _pack++ % 2048,
        o1: (alpha + blink + slow + 160 * jaw + _noise()) * 1e-6,
        o2: (alpha * 0.9 + blink - slow + 170 * jaw + _noise()) * 1e-6,
        t3: (blink + eye + slow + 300 * jaw + emg + _noise()) * 1e-6,
        t4: t4lost ? 0.4 : (blink - eye - slow + 280 * jaw - emg + _noise()) * 1e-6,
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
    calls.add('startSignal');
    if (_started && mode == Mode.stall && healOn == 'restart') mode = Mode.awake;
    _started = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!_signal.hasListener) return;
      final b = _batch();
      clockS += 1;
      if (mode != Mode.stall) _signal.add(b); // a stall: the clock goes on, nothing arrives
    });
  }

  @override
  Future<void> stopSignal() async {
    calls.add('stopSignal');
    _timer?.cancel();
  }
  @override
  Future<void> startResist() async => Timer(const Duration(milliseconds: 1), () => _resist.add({'O1': 4e5, 'O2': 6e5, 'T3': 1.2e6, 'T4': 1.5e6}));
  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async {
    calls.add('disconnect');
    _timer?.cancel();
    if (mode == Mode.stall && healOn == 'reconnect') mode = Mode.awake;
  }
}

/// Finds [band] once, and reaches it again directly (a reconnect after a drop or a stall).
class _AgainFinder implements HeadbandFinder {
  _AgainFinder(this.band);
  final WorkBand band;
  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async => band;
  @override
  Future<Headband> connectDirect(BandId id) async => band;
}

const fastLink = LinkTiming(scanFor: Duration(milliseconds: 50), contactFor: Duration(milliseconds: 5), settle: Duration.zero);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('work-ctl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  WorkController make(
    WorkBand band, {
    SilentWorkSound? sound,
    FakeSessionKeeper? keeper,
    Future<bool?> Function()? inCall,
    Future<MediaVolume?> Function()? mediaVolume,
    bool Function()? laptopMeeting,
    bool raw = false,
  }) => WorkController(
    finder: OneFinder(band),
    sound: sound,
    keeper: keeper,
    inCall: inCall,
    mediaVolume: mediaVolume,
    laptopMeeting: laptopMeeting,
    recordingsDir: raw ? Directory('${tmp.path}/recordings') : null,
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

  test("every saved epoch carries its own time under `at`, and theta stays under `t`", () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final c = make(band);
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    await c.stop();
    final file = Directory('${tmp.path}/work-sessions').listSync().whereType<File>().single;
    final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final start = DateTime.parse(j['start'] as String), end = DateTime.parse(j['end'] as String);
    final epochs = (j['epochs'] as List).cast<Map<String, dynamic>>();
    expect(epochs.length, greaterThan(8));
    DateTime? before;
    for (final e in epochs) {
      final at = DateTime.tryParse('${e['at']}');
      expect(at, isNotNull, reason: 'the epoch ${e['s']} has no time: $e');
      expect(at!.isBefore(start) || at.isAfter(end), isFalse, reason: 'inside the session');
      if (before != null) expect(at.isAfter(before), isTrue);
      before = at;
      // the epoch's own start second sits where its time says (the band's clock is the session's clock)
      expect(at.difference(start).inSeconds, closeTo(e['s'] as num, 31));
      expect(e['t'], anyOf(isNull, isA<num>()), reason: 'theta, not a time');
    }
    c.dispose();
  });

  test("the last hour's strip fills from the epochs' own times", () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final c = make(band);
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    expect(c.lastHour().where((x) => x == WorkCell.alert), isNotEmpty);
    await c.stop();
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

  WorkController gated(HeadbandFinder finder, WorkBand band, SessionKeeper keeper) => WorkController(
    finder: finder,
    keeper: keeper,
    store: WorkStore(Directory('${tmp.path}/work-sessions')),
    timing: const WorkTiming(link: fastLink, tick: Duration(milliseconds: 4), noDataAfter: Duration(seconds: 3)),
    clock: band.now,
  );

  test('Stop, then Start again while the first search runs: the first search ending touches nothing (row 450)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final finder = GateFinder(), keeper = FakeSessionKeeper();
    final c = gated(finder, band, keeper);
    final first = c.start();
    await until(() => finder.finds.length == 1);
    await c.stop();
    final second = c.start();
    await until(() => finder.finds.length == 2);
    finder.finds[1].complete(band);
    await second;
    expect(c.stage, WorkStage.calibrating);
    finder.finds[0].complete(null); // the first search ends: "not found"
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.stage, isNot(WorkStage.failed), reason: c.message);
    expect(c.active, isTrue);
    expect(keeper.held, isTrue, reason: 'the new session keeps its service');
    await c.stop();
    expect(c.stage, WorkStage.done);
    c.dispose();
  });

  test('Stop while the stream is being started: the session stays stopped and lets the headband go (row 450)', () async {
    final inner = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000), band = SlowStart(inner);
    final keeper = FakeSessionKeeper();
    final c = gated(OneFinder(band), inner, keeper);
    final started = c.start();
    await until(() => band.asked);
    await c.stop();
    band.gate.complete();
    await started;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.stage, WorkStage.setup);
    expect(c.active, isFalse);
    expect(keeper.held, isFalse);
    expect(band.disconnected, isTrue);
    c.dispose();
  });

  test('Stop while the service is being held: the session stays stopped and lets the headband go (row 450)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final keeper = GateKeeper();
    final c = gated(OneFinder(band), band, keeper);
    final started = c.start();
    await until(() => keeper.holds.length == 1);
    await c.stop();
    keeper.holds[0].complete(true);
    await started;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.stage, WorkStage.setup);
    expect(c.active, isFalse);
    final at = band.clockS;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(band.clockS, at, reason: 'the stream was stopped');
    c.dispose();
  });

  test('the work session leaves other apps their sound: music or a podcast plays on (DECISIONS 468)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final keeper = FakeSessionKeeper();
    final c = make(band, keeper: keeper);
    await c.start();
    expect(keeper.spec!.focus, isFalse, reason: 'only a short chime plays, now and then');
    c.takeBreak(); // held again with other words
    expect(keeper.spec!.text, 'On a break');
    expect(keeper.spec!.focus, isFalse);
    await c.stop();
    c.dispose();
  });

  test('Stop writes the final file before letting go of the headband and the service', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final dir = Directory('${tmp.path}/work-sessions');
    Map<String, Object?>? atRelease;
    final keeper = _WatchKeeper(() {
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.work.json')).toList();
      atRelease = files.isEmpty ? null : jsonDecode(files.single.readAsStringSync()) as Map<String, Object?>;
    });
    final c = make(band, keeper: keeper);
    await c.start();
    await until(() => band.clockS > 90);
    await c.stop();
    expect(atRelease?['ended'], 'stopped', reason: 'a locked phone may freeze the app once the service is let go');
    expect(atRelease?['headband'], 'BrainBit W', reason: 'not blank: the headband was still held');
    expect(c.last!['headband'], 'BrainBit W');
    c.dispose();
  });

  test('a call that begins as a hint shows: its words show at once, its chime waits until the call is over (DECISIONS 495)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final sound = SilentWorkSound(), keeper = FakeSessionKeeper();
    var call = true, asked = 0;
    late final WorkController c;
    // the call rings the moment the hint comes (during a call no hint is decided at all, DECISIONS 685)
    c = make(band, sound: sound, keeper: keeper, inCall: () async {
      asked++;
      return call && c.hint != null;
    });
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    band.mode = Mode.drowsy;
    await until(() => c.hint != null);
    expect(keeper.spec!.text, startsWith('You seem to be getting drowsy'), reason: 'the lock-screen card at once');
    final at = band.clockS;
    await until(() => band.clockS > at + 30);
    expect(sound.played, isNot(contains('chime')), reason: 'not over a call');
    expect(asked, greaterThan(1), reason: 'checked again while the hint waits');
    expect(c.meeting, isTrue, reason: 'the call is a meeting');
    call = false;
    await until(() => sound.played.contains('chime'));
    expect(sound.played.where((p) => p == 'chime'), hasLength(1));
    await c.stop();
    final events = (c.last!['events'] as List).cast<Map<String, Object?>>();
    expect(events.map((e) => e['event']), contains('chime waited: a call'));
    c.dispose();
  });

  test('a hint answered during the call never chimes; with no call it chimes at once (DECISIONS 495)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final sound = SilentWorkSound();
    var call = true;
    late final WorkController c;
    c = make(band, sound: sound, inCall: () async => call && c.hint != null);
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    band.mode = Mode.drowsy;
    await until(() => c.hint != null);
    c.answer(HintAnswer.notNow);
    call = false;
    final at = band.clockS;
    await until(() => band.clockS > at + 30);
    expect(sound.played, isNot(contains('chime')), reason: 'the hint was answered meanwhile');
    await c.stop();
    c.dispose();

    final band2 = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final sound2 = SilentWorkSound();
    final c2 = make(band2, sound: sound2, inCall: () async => null); // the phone cannot say: not held back
    await c2.start();
    await until(() => c2.level == DrowsyLevel.alert);
    band2.mode = Mode.drowsy;
    await until(() => c2.hint != null);
    await until(() => sound2.played.contains('chime'));
    await c2.stop();
    c2.dispose();
  });

  test('a low media volume at Start gives a quiet line; loud enough or unknown says nothing (DECISIONS 496)', () async {
    Future<String?> noteFor(MediaVolume? v) async {
      final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
      final c = make(band, mediaVolume: () async => v);
      await c.start();
      await until(() => band.clockS > 20);
      final note = c.volumeNote;
      await c.stop();
      c.dispose();
      return note;
    }

    expect(
      await noteFor((volume: 2, max: 15)),
      'The media volume is low (2 of 15), so the break chime may not be heard. The hints also show on the lock screen.',
    );
    expect(
      await noteFor((volume: 0, max: 15)),
      'The media volume is off, so the break chime cannot be heard. The hints also show on the lock screen.',
    );
    expect(await noteFor((volume: 3, max: 15)), isNull, reason: '20 % of the range, as the check-in\'s soft tones');
    expect(await noteFor(null), isNull);
  });

  WorkController again(WorkBand band) => WorkController(
    finder: _AgainFinder(band),
    store: WorkStore(Directory('${tmp.path}/work-sessions')),
    timing: const WorkTiming(
      link: LinkTiming(scanFor: Duration(milliseconds: 50), contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
      tick: Duration(milliseconds: 4),
    ),
    clock: band.now,
  );

  List<String> eventsOf(WorkController c) => [for (final e in c.sessionJson(c.startedAt!.add(const Duration(hours: 1)))['events']! as List) '${(e as Map)['event']}'];

  test('a stream that stops with the headband in range is restarted, and the session goes on (review 2026-11-20, finding 1)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 20, 10).millisecondsSinceEpoch / 1000)..healOn = 'restart';
    final c = again(band);
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    band.mode = Mode.stall;
    await until(() => band.calls.where((x) => x == 'startSignal').length == 2);
    await until(() => c.signal == WorkSignal.good && c.worn);
    expect(eventsOf(c), contains(startsWith('no data for')), reason: 'the restart is in the file');
    expect(c.onBreak, isFalse, reason: 'seconds without data are not a break');
    await c.stop();
    c.dispose();
  });

  test('still nothing 40 s later: the headband is let go and reached again; no break all afternoon (finding 1)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 20, 10).millisecondsSinceEpoch / 1000)..healOn = 'reconnect';
    final c = again(band);
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    final at = band.clockS;
    band.mode = Mode.stall;
    await until(() => band.calls.contains('disconnect'));
    expect(c.signal, WorkSignal.lost);
    await until(() => band.clockS > at + 10 * 60);
    expect(eventsOf(c), containsAllInOrder([startsWith('no data for'), contains('reconnecting'), 'reconnected']));
    expect(c.onBreak, isFalse);
    expect(c.planner!.breaks, isEmpty, reason: 'under a minute without data');
    expect(c.signal, WorkSignal.good);
    expect(c.level, DrowsyLevel.alert);
    await c.stop();
    c.dispose();
  });

  test('one electrode losing contact pauses the eye readings instead of reading as drowsy (review 2026-11-20, finding 3)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 20, 10).millisecondsSinceEpoch / 1000);
    final c = make(band);
    await c.start();
    await until(() => c.level == DrowsyLevel.alert);
    final at = band.clockS;
    band.t4lost = true;
    await until(() => band.clockS > at + 12 * 60);
    expect(c.level, DrowsyLevel.alert, reason: 'window ${c.drowsiness!.window}');
    expect(c.hint, isNull);
    expect(c.signal, WorkSignal.noEyes, reason: 'the signal line says the eye readings are paused');
    final last = c.drowsiness!.epochs.last;
    expect(last.events, isNull);
    expect(last.still, isNull);
    band.t4lost = false;
    await until(() => band.clockS > at + 14 * 60);
    expect(c.signal, WorkSignal.good);
    await c.stop();
    c.dispose();
  });

  group('work review 2026-11-20', () {
    WorkBand bandAt10() => WorkBand(start: DateTime(2026, 11, 20, 10).millisecondsSinceEpoch / 1000);

    test('a forgotten Back: off and on again ends the break by itself; the card and the file say so (finding 2)', () async {
      final band = bandAt10();
      final keeper = FakeSessionKeeper();
      final c = make(band, keeper: keeper);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      c.takeBreak();
      expect(keeper.spec!.text, 'On a break');
      final at = band.clockS;
      band.mode = Mode.off;
      await until(() => band.clockS > at + 3 * 60);
      band.mode = Mode.awake;
      await until(() => !c.onBreak);
      expect(band.clockS - at, inInclusiveRange(4.5 * 60, 6 * 60), reason: '2 minutes worn after it came back');
      final b = c.planner!.breaks.single;
      expect(b.endSource, BreakEnd.auto);
      expect(eventsOf(c), contains(startsWith('break ended by itself')));
      expect(keeper.spec!.text, isNot('On a break'), reason: 'the card was held again');
      expect(keeper.spec!.button, isNull);
      expect(c.afterBreak, isNotNull);
      await c.stop();
      c.dispose();
    });

    test('Back on the lock-screen card while on a break (finding 2)', () async {
      final band = bandAt10();
      final keeper = FakeSessionKeeper();
      final c = make(band, keeper: keeper);
      await c.start();
      await until(() => c.stage == WorkStage.running);
      expect(keeper.spec!.button, isNull, reason: 'no break: only Stop');
      c.takeBreak();
      expect(keeper.spec!.button, 'Back');
      keeper.onButton!();
      expect(c.onBreak, isFalse);
      expect(c.planner!.breaks.single.endSource, BreakEnd.back);
      expect(keeper.spec!.button, isNull);
      keeper.onButton!(); // a late second tap: nothing
      expect(c.onBreak, isFalse);
      await c.stop();
      c.dispose();
    });

    test('the headband put down for a break keeps the level before it; the after line compares (finding 6)', () async {
      final band = bandAt10();
      final c = make(band);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      band.mode = Mode.off;
      await until(() => c.onBreak);
      final b = c.planner!.breaks.single;
      expect(b.source, BreakSource.headbandOff);
      expect(b.before, isNotNull);
      expect(b.beforeLevel, DrowsyLevel.alert);
      band.mode = Mode.awake;
      await until(() => !c.onBreak);
      await until(() => b.after != null);
      expect(c.afterBreak, startsWith('After your break: drowsiness about the same (alert before, alert after)'));
      await c.stop();
      c.dispose();
    });

    test('an unanswered hint goes after its 30 minutes, from the page and the card (finding 9)', () async {
      final band = bandAt10();
      final keeper = FakeSessionKeeper();
      final c = make(band, keeper: keeper);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      band.mode = Mode.drowsy;
      await until(() => c.hint != null);
      final h = c.hint!;
      band.mode = Mode.awake;
      await until(() => band.now().difference(h.at).inMinutes >= 29);
      expect(c.hint, same(h));
      await until(() => band.now().difference(h.at).inMinutes >= 31);
      expect(c.hint, isNull);
      expect(keeper.spec!.text, isNot(startsWith('You seem')));
      c.takeBreak();
      expect(h.answer, isNull, reason: 'a break long after is not its answer');
      await c.stop();
      c.dispose();
    });

    test("a jump of the phone's clock is not worn time (finding 8)", () async {
      final band = bandAt10();
      var offset = Duration.zero;
      final c = WorkController(
        finder: OneFinder(band),
        store: WorkStore(Directory('${tmp.path}/work-sessions')),
        timing: const WorkTiming(link: fastLink, tick: Duration(milliseconds: 4)),
        clock: () => band.now().add(offset),
        monotonic: () => Duration(microseconds: (band.clockS * 1e6).round()),
      );
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      final before = c.wornMin, at = band.clockS;
      offset = const Duration(hours: 2);
      await until(() => band.clockS > at + 20);
      expect(c.wornMin - before, lessThan(1));
      expect(c.hint, isNull);
      await c.stop();
      c.dispose();
    });

    test("the card's words follow the level, not only every 20 minutes (finding 13)", () async {
      final band = bandAt10();
      final keeper = FakeSessionKeeper();
      final c = make(band, keeper: keeper);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      expect(keeper.spec!.text, startsWith('Alert'));
      band.mode = Mode.drowsy;
      await until(() => c.level != DrowsyLevel.alert);
      expect(keeper.spec!.text, startsWith(levelWords[c.level]!));
      await c.stop();
      c.dispose();
    });

    test('the after-break line goes 30 minutes after the break (finding 15)', () async {
      final band = bandAt10();
      final c = make(band);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      c.takeBreak();
      final at = band.clockS;
      await until(() => band.clockS > at + 6 * 60);
      c.back();
      expect(c.afterBreak, startsWith('Back from your break'));
      await until(() => band.clockS > at + 30 * 60);
      expect(c.afterBreak, isNotNull);
      await until(() => band.clockS > at + 37 * 60);
      expect(c.afterBreak, isNull);
      await c.stop();
      c.dispose();
    });

    test('Start under 5 minutes after the last Stop carries its stretch; the earlier hint before a lunch Stop counts as followed (finding 7)', () async {
      final dir = Directory('${tmp.path}/work-sessions');
      final store = WorkStore(dir);
      final t0 = DateTime(2026, 11, 20, 10);
      Map<String, Object?> earlier(DateTime start, DateTime end, {required double stretch, DateTime? hintAt}) => {
        'version': workFormatVersion,
        'kind': 'work_session',
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'ended': 'stopped',
        'stretch_min': stretch,
        'hints': [
          if (hintAt != null) {'at': hintAt.toIso8601String(), 'reason': 'stretch', 'active_min': 60.0, 'threshold_min': 60.0, 'level': 'alert', 'taken': false},
        ],
        'breaks': [],
        'epochs': [],
      };
      // the morning: a hint at 08:50 not followed inside the session, stopped at 09:00 for an hour
      store.save(earlier(DateTime(2026, 11, 20, 7, 45), DateTime(2026, 11, 20, 9), stretch: 70, hintAt: DateTime(2026, 11, 20, 8, 50)));
      // the session before this one: ended 2 minutes before Start (a crash, a restart)
      store.save(earlier(DateTime(2026, 11, 20, 9, 30), t0.subtract(const Duration(minutes: 2)), stretch: 40));
      final band = WorkBand(start: t0.millisecondsSinceEpoch / 1000);
      final c = make(band);
      await c.start();
      expect(c.stretchMin, closeTo(40, 0.5));
      expect(c.planner!.thresholdMin(t0), 60, reason: 'the lunch Stop was the hint\'s break');
      expect(eventsOf(c), contains(startsWith('stretch carried over')));
      await c.stop();
      c.dispose();
    });
  });

  group('a working day (2026-11-20: talking in a call read as the headband off)', () {
    WorkBand bandAt10() => WorkBand(start: DateTime(2026, 11, 20, 10).millisecondsSinceEpoch / 1000);

    test('talking (jaw, muscle and movement on every channel) is worn but not readable: never a break', () async {
      final band = bandAt10();
      final keeper = FakeSessionKeeper();
      final c = make(band, keeper: keeper);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      final at = band.clockS, worn = c.wornMin;
      band.mode = Mode.talking;
      await until(() => band.clockS > at + 12 * 60);
      expect(c.planner!.breaks, isEmpty, reason: 'talking is not the headband off');
      expect(c.onBreak, isFalse);
      expect(c.worn, isTrue);
      expect(c.wornMin - worn, greaterThan(11), reason: 'a call is worn time');
      expect(c.signal, WorkSignal.noisy, reason: 'Talking / moving: reading paused');
      expect(c.level, DrowsyLevel.unknown, reason: 'no reading from talking');
      expect(keeper.spec!.text, isNot('On a break'));
      band.mode = Mode.awake;
      await until(() => c.level == DrowsyLevel.alert);
      expect(c.signal, WorkSignal.good);
      await c.stop();
      c.dispose();
    });

    for (final off in [Mode.off, Mode.flat, Mode.wild]) {
      test('the headband really off (${off.name}) is a break after 5 minutes', () async {
        final band = bandAt10();
        final c = make(band);
        await c.start();
        await until(() => c.stage == WorkStage.running);
        final at = band.clockS;
        band.mode = off;
        await until(() => band.clockS > at + 4 * 60);
        expect(c.onBreak, isFalse, reason: 'under 5 minutes only pauses the count');
        expect(c.worn, isFalse);
        expect(c.signal, WorkSignal.off);
        await until(() => c.onBreak);
        expect(band.clockS - at, inInclusiveRange(5 * 60, 6 * 60));
        expect(c.planner!.breaks.single.source, BreakSource.headbandOff);
        band.mode = Mode.awake;
        await until(() => !c.onBreak);
        await c.stop();
        c.dispose();
      });
    }

    test('calibrating while you talk: no break, it waits for quiet half minutes; quiet ones finish it', () async {
      final band = bandAt10()..mode = Mode.talking;
      final keeper = FakeSessionKeeper();
      final c = make(band, keeper: keeper);
      await c.start();
      await until(() => band.clockS > 10 * 60);
      expect(c.stage, WorkStage.calibrating);
      expect(c.onBreak, isFalse);
      expect(c.planner!.breaks, isEmpty);
      expect(c.worn, isTrue);
      expect(c.signal, WorkSignal.noisy);
      final at = band.clockS;
      band.mode = Mode.awake;
      await until(() => c.stage == WorkStage.running);
      expect(band.clockS - at, lessThan(4.5 * 60), reason: '6 quiet half minutes after the first minute');
      await c.stop();
      c.dispose();
    });

    test('Back after a tapped break while calibrating keeps what calibration gathered; the break is not learned from', () async {
      final band = bandAt10();
      final c = make(band);
      await c.start();
      await until(() => (c.drowsiness?.baselineLeft ?? 6) <= 3);
      final left = c.drowsiness!.baselineLeft;
      c.takeBreak();
      expect(c.onBreak, isTrue, reason: 'a tap starts a break, also while calibrating');
      final at = band.clockS;
      await until(() => band.clockS > at + 3 * 60);
      expect(c.drowsiness!.baselineLeft, left, reason: 'half minutes on a break are not the baseline');
      c.back();
      expect(c.stage, WorkStage.calibrating);
      final back = band.clockS;
      await until(() => c.stage == WorkStage.running);
      expect(band.clockS - back, lessThan((left + 2) * 30), reason: 'it goes on where it was: no new settling minute');
      await c.stop();
      c.dispose();
    });

    test('the headband off 5 minutes while calibrating: no break; calibration starts over once it is back', () async {
      final band = bandAt10();
      final c = make(band);
      await c.start();
      await until(() => (c.drowsiness?.baselineLeft ?? 6) <= 3);
      final at = band.clockS, worn = c.wornMin;
      band.mode = Mode.off;
      await until(() => band.clockS > at + 7 * 60);
      expect(c.onBreak, isFalse, reason: 'no break starts by itself while calibrating');
      expect(c.planner!.breaks, isEmpty);
      expect(c.wornMin - worn, lessThan(0.5), reason: 'off is not worn time');
      expect(c.signal, WorkSignal.off);
      final back = band.clockS;
      band.mode = Mode.awake;
      await until(() => eventsOf(c).any((e) => e.startsWith('calibration starts over')));
      expect(c.drowsiness!.baselineLeft, WorkRule.baselineEpochs);
      expect(c.drowsiness!.settleLeft, greaterThan(0), reason: 'a settling minute first');
      await until(() => c.stage == WorkStage.running);
      expect(band.clockS - back, inInclusiveRange(4 * 60, 5.5 * 60), reason: 'a settling minute and 3 minutes again');
      await c.stop();
      c.dispose();
    });

    test('a finished baseline stays after a long time off: Back never calibrates again', () async {
      final band = bandAt10();
      final c = make(band);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      final baseline = c.drowsiness!.baseline;
      band.mode = Mode.off;
      await until(() => c.onBreak);
      final at = band.clockS;
      await until(() => band.clockS > at + 20 * 60);
      band.mode = Mode.awake;
      await until(() => !c.onBreak);
      expect(c.stage, WorkStage.running);
      expect(identical(c.drowsiness!.baseline, baseline), isTrue);
      await until(() => c.level == DrowsyLevel.alert);
      await c.stop();
      c.dispose();
    });

    test('the raw EEG of the whole session is kept as a recording that is no night, and closed at Stop', () async {
      final band = bandAt10();
      final c = make(band, raw: true);
      await c.start();
      final stem = c.rawStem!;
      final dir = Directory('${tmp.path}/recordings');
      for (final ext in ['f32', 'idx', 'log', 'header.json']) {
        expect(File('${dir.path}/$stem.$ext').existsSync(), isTrue, reason: '$ext from the start, calibration included');
      }
      final h = readHeader(File('${dir.path}/$stem.f32'));
      expect(h.session, sessionWork);
      expect(h.isSleep, isFalse);
      expect(h.names, ['O1', 'O2', 'T3', 'T4']);
      await until(() => c.level == DrowsyLevel.alert);
      c.takeBreak();
      final at = band.clockS;
      await until(() => band.clockS > at + 60);
      c.back();
      await c.stop();
      final f32 = File('${dir.path}/$stem.f32');
      final n = f32.lengthSync() ~/ h.recordBytes;
      expect(f32.lengthSync() % h.recordBytes, 0);
      expect(n, closeTo(band.clockS * 250, 2 * 250), reason: 'every sample since the stream started');
      final idx = File('${dir.path}/$stem.idx').lengthSync();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(f32.lengthSync(), n * h.recordBytes, reason: 'closed: nothing more is written');
      expect(File('${dir.path}/$stem.idx').lengthSync(), idx);
      final log = File('${dir.path}/$stem.log').readAsLinesSync();
      expect(log.first, contains('work session (not a night'));
      expect(log.last, endsWith('stopped'));
      final marks = File('${dir.path}/$stem.markers.jsonl').readAsLinesSync().map((l) => (jsonDecode(l) as Map)['text']);
      expect(marks, containsAllInOrder(['work: calibrated', 'work: on a break (tapped)', 'work: back (tapped)']));
      expect(c.last!['raw'], stem);
      expect(c.rawNote, contains('MB) is kept with your recordings'));
      forgetNightSets();
      expect(nightsIn(dir), isEmpty, reason: 'a work session is not a night');
      c.dispose();
    });

    test('a call on the phone labels a meeting: no drowsiness verdict, no hint until it ends; then the hint comes', () async {
      final band = bandAt10();
      final keeper = FakeSessionKeeper();
      var call = false;
      final c = make(band, keeper: keeper, inCall: () async => call);
      await c.start();
      await until(() => c.level == DrowsyLevel.alert);
      call = true;
      await until(() => c.meeting);
      expect(c.meetingSource, 'phone call');
      expect(keeper.spec!.text, startsWith('In a meeting'));
      final at = band.clockS;
      band.mode = Mode.drowsy;
      await until(() => band.clockS > at + 10 * 60);
      expect(c.hint, isNull, reason: 'no hint during a call');
      expect(c.level, DrowsyLevel.unknown, reason: 'no verdict from a meeting');
      expect(c.onBreak, isFalse);
      call = false;
      await until(() => !c.meeting);
      await until(() => c.hint != null);
      expect(c.hint!.reason, HintReason.drowsy);
      await c.stop();
      final j = c.last!;
      final meetings = (j['meetings']! as List).cast<Map<String, Object?>>();
      expect(meetings.single['source'], 'phone call');
      expect(j['meeting_min'] as num, inInclusiveRange(9.5, 11.5));
      final epochs = (j['epochs']! as List).cast<Map<String, Object?>>();
      final inMeeting = epochs.where((e) => e['meeting'] == true).toList();
      expect(inMeeting.length, inInclusiveRange(18, 22));
      expect(inMeeting.every((e) => e['level'] == 'unknown' && e['index'] == null), isTrue);
      expect((j['minutes']! as Map)['meeting'] as num, inInclusiveRange(9, 11));
      expect(eventsOf(c), containsAllInOrder(['meeting started', 'meeting ended']));
      c.dispose();
    });

    test("the laptop's word that its session is in a meeting labels one too (POST /work meeting)", () async {
      final band = bandAt10()..mode = Mode.talking;
      var laptop = true;
      final c = make(band, laptopMeeting: () => laptop);
      await c.start();
      await until(() => band.clockS > 6 * 60);
      expect(c.meeting, isTrue);
      expect(c.meetingSource, 'laptop');
      expect(c.stage, WorkStage.calibrating);
      expect(c.calibrationWaits, isFalse, reason: 'in a meeting it says so instead');
      expect(c.onBreak, isFalse);
      laptop = false;
      band.mode = Mode.awake;
      await until(() => c.stage == WorkStage.running);
      await c.stop();
      final meetings = (c.last!['meetings']! as List).cast<Map<String, Object?>>();
      expect(meetings.single['source'], 'laptop');
      c.dispose();
    });

    test('calibration says it waits for a quiet minute while you talk, on the page and the card', () async {
      final band = bandAt10()..mode = Mode.talking;
      final keeper = FakeSessionKeeper();
      final c = make(band, keeper: keeper);
      await c.start();
      await until(() => band.clockS > 3 * 60);
      expect(c.calibrationWaits, isTrue);
      expect(keeper.spec!.text, 'Calibrating: waiting for a quiet minute');
      band.mode = Mode.awake;
      await until(() => !c.calibrationWaits && keeper.spec!.text == 'Calibrating');
      await c.stop();
      c.dispose();
    });
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
