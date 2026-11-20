// A work session end to end on a synthetic headband with a clock of its own (DECISIONS 440-449): calibration,
// the level, a drowsy hint with its chime and lock-screen words, a break, Stop and the saved file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
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

enum Mode { awake, drowsy, eyesClosed, off, stall }

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
      final amp = switch (mode) {
        Mode.awake => 10.0,
        Mode.drowsy => 16.0,
        Mode.eyesClosed => 40.0,
        Mode.off || Mode.stall => 0.0,
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
      out.add(Sample.four(
        pack: _pack++ % 2048,
        o1: (alpha + blink + slow + _noise()) * 1e-6,
        o2: (alpha * 0.9 + blink - slow + _noise()) * 1e-6,
        t3: (blink + eye + slow + _noise()) * 1e-6,
        t4: t4lost ? 0.4 : (blink - eye - slow + _noise()) * 1e-6,
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
    void Function(Map<String, Object?>? state)? onShare,
  }) => WorkController(
    finder: OneFinder(band),
    sound: sound,
    keeper: keeper,
    inCall: inCall,
    mediaVolume: mediaVolume,
    onShare: onShare,
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

  test("the summary for the laptop tray (DECISIONS 671): calibrating, the level and signal, a hint, a break, none after Stop", () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final sent = <Map<String, Object?>?>[];
    final c = make(band, onShare: sent.add);
    await c.start();
    expect(sent.last, containsPair('kind', 'work'));
    expect(sent.last, containsPair('stage', 'calibrating'));
    expect(sent.last!['since'], endsWith('Z'), reason: 'UTC, so the laptop reads the right hour');
    expect(DateTime.parse(sent.last!['since']! as String), c.startedAt!.toUtc());
    await until(() => c.level == DrowsyLevel.alert);
    expect(sent.last, containsPair('stage', 'running'));
    expect(sent.last, containsPair('level', 'alert'));
    expect(sent.last, containsPair('signal', 'good'));
    expect(sent.last, containsPair('on_break', false));
    expect(sent.last!['hint'], isNull);
    // the newest data as of the last send, which is at most 5 s (shareEvery) and a tick old
    expect((sent.last!['data_at']! as num) * 1e6, closeTo(band.now().microsecondsSinceEpoch, 7e6));
    // between changes it goes out every 5 s of the session's clock, not every tick
    final n = sent.length, at = band.clockS;
    await until(() => band.clockS > at + 20);
    expect(sent.length - n, inInclusiveRange(2, 6));
    band.mode = Mode.drowsy;
    await until(() => c.hint != null);
    expect(sent.last!['hint'], containsPair('reason', 'drowsy'));
    expect(sent.last, containsPair('level', isNot('alert')));
    c.takeBreak();
    expect(sent.last, containsPair('on_break', true));
    expect(sent.last!['hint'], isNull);
    band.mode = Mode.off;
    await until(() => c.signal == WorkSignal.off || c.signal == WorkSignal.lost);
    await until(() => sent.last!['signal'] == 'off' || sent.last!['signal'] == 'lost');
    await c.stop();
    expect(sent.last, isNull);
    final after = sent.length;
    c.dispose();
    expect(sent.length, after, reason: 'nothing more once it said none');
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

  test('a hint during a call: its words show at once, its chime waits until the call is over (DECISIONS 495)', () async {
    final band = WorkBand(start: DateTime(2026, 11, 19, 10).millisecondsSinceEpoch / 1000);
    final sound = SilentWorkSound(), keeper = FakeSessionKeeper();
    var call = true, asked = 0;
    final c = make(band, sound: sound, keeper: keeper, inCall: () async {
      asked++;
      return call;
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
    final c = make(band, sound: sound, inCall: () async => call);
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
