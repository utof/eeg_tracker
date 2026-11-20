// The morning check-in on the phone with a fake headband: contact, eyes closed, eyes open, the questions, the
// numbers and the files (DECISIONS rows 120 and 125), and what happens on Stop and when the headband drops out.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/morning/controller.dart';
import 'package:eeg_tracker/morning/result.dart';
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/session_keeper.dart';
import 'package:eeg_tracker/sound/check_in_sound.dart';
import 'package:eeg_tracker/signal/quality.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gates.dart';

/// Streams the demo signal far faster than real time; the eyes follow the check-in's phase.
class EyesBand implements Headband {
  EyesBand(this.demo, this.eyes, {this.resists = true});
  final bool resists;
  final DemoSignal demo;
  final String Function() eyes;
  int pack = 0;
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
  String get name => 'BrainBit A';
  @override
  String get address => 'AA:BB';
  @override
  String get serial => '1';
  @override
  int? get rssi => -60;
  @override
  BandId get id => const BandId(name: 'BrainBit', address: 'AA:BB');
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  @override
  Future<void> startSignal() async {
    calls.add('startSignal');
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!_signal.hasListener) return;
      demo.eyes = eyes();
      _signal.add([
        for (final r in demo.next(250))
          Sample.four(pack: pack++ % 2048, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6),
      ]);
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
    if (!resists) return;
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

class OneFinder implements HeadbandFinder {
  OneFinder(this.band);
  final Headband? band;
  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async => band;
  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('no direct connections here');
}

const fast = MorningTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, phaseS: 40);

Future<void> until(MorningController c, bool Function() done, {Duration max = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(max);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('stuck in ${c.stage} (${c.message})');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

const answers = MorningAnswers(
  kss: 4,
  mood: 3,
  tension: 2,
  cups: 2,
  caffeineLate: true,
  caffeineToday: false,
  drinks: 0,
  reaction: {'median_ms': 312, 'taps': 14, 'lapses': 0, 'false_starts': 1, 'length_s': 60},
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('morning'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ({MorningController c, EyesBand band, SilentCheckInSound sound}) make({int seed = 1}) {
    late MorningController c;
    final band = EyesBand(DemoSignal(seed), () => c.stage == MorningStage.closed ? 'closed' : 'open');
    final sound = SilentCheckInSound();
    c = MorningController(finder: OneFinder(band), sound: () => sound, store: MorningStore(tmp), timing: fast);
    return (c: c, band: band, sound: sound);
  }

  test('a whole check-in: contact, the two phases, the questions, the numbers and the files', () async {
    final (:c, :band, :sound) = make();
    await c.start();
    expect(c.stage, MorningStage.contact);
    expect(c.contact['O1'], 4e5);
    expect(c.contact['T4'], isNull);
    await until(c, () => c.quality.electrodes.every((e) => e.fromSignal)); // the one judge has seen 4 s of signal
    expect(c.quality.gradeOf('O1'), isNot(Contact.none));
    expect(c.quality.electrodes.last.ohms, isNull); // T4: no contact reading
    c.begin();
    expect(c.stage, MorningStage.closed);
    await until(c, () => c.stage == MorningStage.questions);
    expect(sound.played, ['close', 'open', 'end']);
    expect(band.calls, contains('disconnect'));
    await c.save(answers);
    expect(c.stage, MorningStage.result, reason: c.message);
    final r = c.result!;
    expect(r['version'], morningVersion);
    expect(r['app'], 'phone');
    expect(r['ratings'], {'kss': 4, 'mood': 3, 'tension': 2});
    expect((r['habits']! as Map)['caffeine_cups'], 2);
    expect((r['reaction']! as Map)['median_ms'], 312);
    expect(r['phase_s'], {'eyes_closed': 40.0, 'eyes_open': 40.0});
    final back = (r['back']! as Map).cast<String, Object?>();
    expect(back['ec_rise'] as double, greaterThan(1.5)); // the demo's alpha rises with the eyes closed
    expect(back['iaf_hz'], isNotNull);
    expect((r['compared']! as List).first, containsPair('earlier', 0));

    // the files: the result under the eyes-closed start, the raw signal with the laptop page's markers
    final files = tmp.listSync().map((f) => f.path.split('/').last).toList()..sort();
    expect(files.where((f) => f.endsWith('.morning.json')), hasLength(1));
    final f32 = files.singleWhere((f) => f.endsWith('.f32'));
    final markers = File('${tmp.path}/${f32.replaceFirst('.f32', '.markers.jsonl')}').readAsLinesSync();
    expect([for (final l in markers) (jsonDecode(l) as Map)['text']], [
      'morning:start',
      'morning:eyes_closed:start',
      'morning:eyes_closed:end',
      'morning:eyes_open:start',
      'morning:eyes_open:end',
      'morning:ratings {"kss":4,"mood":3,"tension":2}',
      'morning:end',
    ]);
    // the raw file analysed again (as the laptop would after an export) gives the same numbers
    final again = readCheckInRecording(File('${tmp.path}/$f32'))!;
    expect(analyseCheckIn(again.phases).back, back);
    expect(again.ratings, {'kss': 4, 'mood': 3, 'tension': 2});

    // the store reads it back for the trends
    final saved = MorningStore(tmp).list().single;
    expect(saved.kss, 4);
    expect(saved.slept, isNull); // not tapped: no key in the result, no 6th marker field
    expect(saved.reactionMs, 312);
    expect(saved.caffeineCups, 2);
    expect(saved.caffeineLate, isTrue);
    expect(saved.iafHz, back['iaf_hz']);
  });

  test('"How did you sleep?" is kept with the check-in when tapped: result, markers, raw file and store', () async {
    final (:c, band: _, sound: _) = make();
    await c.start();
    c.begin();
    await until(c, () => c.stage == MorningStage.questions);
    await c.save(const MorningAnswers(
      kss: 4,
      mood: 3,
      tension: 2,
      sleep: 2,
      cups: 0,
      caffeineToday: false,
      drinks: 0,
    ));
    expect(c.result!['ratings'], {'kss': 4, 'mood': 3, 'tension': 2, 'sleep': 2});
    final f32 = tmp.listSync().map((f) => f.path.split('/').last).singleWhere((f) => f.endsWith('.f32'));
    final markers = File('${tmp.path}/${f32.replaceFirst('.f32', '.markers.jsonl')}').readAsLinesSync();
    expect([for (final l in markers) (jsonDecode(l) as Map)['text']], contains('morning:ratings {"kss":4,"mood":3,"tension":2,"sleep":2}'));
    expect(readCheckInRecording(File('${tmp.path}/$f32'))!.ratings, {'kss': 4, 'mood': 3, 'tension': 2, 'sleep': 2});
    expect(MorningStore(tmp).list().single.slept, 2);
    // the laptop's comparison rows are still its own three (morning_check.ROWS)
    expect([for (final r in c.result!['compared']! as List) (r as Map)['label']], isNot(contains(contains('sleep'))));
  });

  test('a second check-in is compared with the first', () async {
    for (final seed in [1, 2]) {
      final (:c, band: _, sound: _) = make(seed: seed);
      await c.start();
      c.begin();
      await until(c, () => c.stage == MorningStage.questions);
      await c.save(answers);
      expect(c.stage, MorningStage.result);
      if (seed == 2) expect((c.result!['compared']! as List).first, containsPair('earlier', 1));
    }
  });

  test('Stop in the middle keeps nothing', () async {
    final (:c, :band, sound: _) = make();
    await c.start();
    c.begin();
    await until(c, () => c.stage == MorningStage.open);
    await c.stop();
    expect(c.stage, MorningStage.intro);
    expect(c.message, contains('Nothing was kept'));
    expect(tmp.listSync(), isEmpty);
    expect(band.calls, contains('disconnect'));
  });

  test('a headband that drops out stops the check-in and is never called again', () async {
    final (:c, :band, sound: _) = make();
    await c.start();
    c.begin();
    await until(c, () => c.stage == MorningStage.closed);
    band.calls.clear();
    band.goOutOfRange();
    await until(c, () => c.stage == MorningStage.intro);
    expect(c.message, contains('dropped out'));
    expect(band.calls, isEmpty);
    expect(c.leftLost, isTrue);
    expect(tmp.listSync(), isEmpty);
  });

  test('after a drop, the next check-in in the same screen still lets its headband go (finding 8)', () async {
    late MorningController c;
    String eyes() => c.stage == MorningStage.closed ? 'closed' : 'open';
    final finder = GateFinder(), first = EyesBand(DemoSignal(1), eyes), second = EyesBand(DemoSignal(2), eyes);
    c = MorningController(finder: finder, store: MorningStore(tmp), timing: fast);
    var starting = c.start();
    await until(c, () => finder.finds.length == 1);
    finder.finds[0].complete(first);
    await starting;
    c.begin();
    first.goOutOfRange();
    await until(c, () => c.stage == MorningStage.intro);
    starting = c.start();
    await until(c, () => finder.finds.length == 2);
    finder.finds[1].complete(second);
    await starting;
    expect(c.stage, MorningStage.contact);
    await c.stop();
    expect(second.calls, containsAllInOrder(['startSignal', 'stopSignal', 'disconnect']));
    expect(first.calls, isNot(contains('disconnect')), reason: 'the lost one is never touched');
    expect(c.leftLost, isTrue, reason: 'the finder must still keep its scanner');
  });

  test('Stop, then Start again while the first search runs: a late headband is let go, not taken (finding 1)', () async {
    late MorningController c;
    String eyes() => c.stage == MorningStage.closed ? 'closed' : 'open';
    final finder = GateFinder(), late = EyesBand(DemoSignal(1), eyes), band = EyesBand(DemoSignal(2), eyes);
    c = MorningController(finder: finder, store: MorningStore(tmp), timing: fast);
    final first = c.start();
    await until(c, () => finder.finds.length == 1);
    await c.stop();
    final second = c.start();
    await until(c, () => finder.finds.length == 2);
    finder.finds[1].complete(band);
    await second;
    expect(c.stage, MorningStage.contact);
    finder.finds[0].complete(late); // the first search finds the headband too, late
    await first;
    expect((c.stage, c.message), (MorningStage.contact, ''));
    expect(late.calls, ['disconnect']);
    await c.stop();
    expect(band.calls, containsAllInOrder(['stopSignal', 'disconnect']));
  });

  test('Stop, then Start again while the first start waits for the service: the first start does not search', () async {
    late MorningController c;
    final finder = GateFinder(), keeper = GateKeeper();
    final band = EyesBand(DemoSignal(2), () => c.stage == MorningStage.closed ? 'closed' : 'open');
    c = MorningController(finder: finder, store: MorningStore(tmp), timing: fast, keeper: keeper);
    final first = c.start();
    await until(c, () => keeper.holds.length == 1);
    await c.stop();
    final second = c.start();
    await until(c, () => keeper.holds.length == 2);
    keeper.holds[0].complete(true); // the phone answers the first hold only now
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(finder.finds, isEmpty, reason: 'a second search beside the new start could take its headband');
    keeper.holds[1].complete(true);
    await until(c, () => finder.finds.length == 1);
    finder.finds[0].complete(band);
    await second;
    await first;
    expect((c.stage, c.message), (MorningStage.contact, ''));
    expect(finder.finds, hasLength(1));
    await c.stop();
    expect(band.calls, containsAllInOrder(['stopSignal', 'disconnect']));
  });

  test('Stop, then Start again: the first search finding nothing fails nothing (finding 1)', () async {
    late MorningController c;
    final finder = GateFinder(), band = EyesBand(DemoSignal(2), () => 'open');
    c = MorningController(finder: finder, store: MorningStore(tmp), timing: fast);
    final first = c.start();
    await until(c, () => finder.finds.length == 1);
    await c.stop();
    final second = c.start();
    await until(c, () => finder.finds.length == 2);
    finder.finds[1].complete(band);
    await second;
    finder.finds[0].complete(null);
    await first;
    expect(c.stage, MorningStage.contact, reason: c.message);
    await c.stop();
  });

  test('Stop while the stream is being started: the check-in stays stopped (finding 9)', () async {
    final inner = EyesBand(DemoSignal(1), () => 'open'), band = SlowStart(inner);
    final c = MorningController(finder: OneFinder(band), store: MorningStore(tmp), timing: fast);
    final started = c.start();
    await until(c, () => band.asked);
    await c.stop();
    band.gate.complete();
    await started;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.stage, MorningStage.intro);
    expect(c.active, isFalse);
    expect(inner.calls, contains('disconnect'));
  });

  test('the check-in holds the session service while it records; its Stop ends the check-in', () async {
    late MorningController c;
    final band = EyesBand(DemoSignal(1), () => c.stage == MorningStage.closed ? 'closed' : 'open');
    final keeper = FakeSessionKeeper();
    c = MorningController(finder: OneFinder(band), store: MorningStore(tmp), timing: fast, keeper: keeper);
    await c.start();
    expect(keeper.held, isTrue, reason: 'a locked phone must not freeze the recording part');
    expect((keeper.spec!.title, keeper.spec!.headband), ('Morning check-in', true));
    c.begin();
    await until(c, () => c.stage == MorningStage.questions);
    expect(keeper.log, ['hold', 'release'], reason: 'the questions need no service');
    c.again();
    final second = FakeSessionKeeper();
    c = MorningController(finder: OneFinder(EyesBand(DemoSignal(2), () => 'open')), store: MorningStore(tmp), timing: fast, keeper: second);
    await c.start();
    second.onStop!(); // Stop on the notification
    await until(c, () => c.stage == MorningStage.intro);
    expect(second.log, ['hold', 'release']);
    final none = FakeSessionKeeper();
    final failed = MorningController(finder: OneFinder(null), store: MorningStore(tmp), timing: fast, keeper: none);
    await failed.start();
    expect(failed.stage, MorningStage.failed);
    expect(none.log, ['hold', 'release']);
  });

  test('a call during the check-in stops it and keeps nothing; a short notification sound does not', () async {
    late MorningController c;
    final band = EyesBand(DemoSignal(1), () => c.stage == MorningStage.closed ? 'closed' : 'open');
    final keeper = FakeSessionKeeper();
    c = MorningController(
      finder: OneFinder(band),
      store: MorningStore(tmp),
      timing: const MorningTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, phaseS: 600),
      keeper: keeper,
    );
    await c.start();
    c.begin();
    keeper.onFocus!(FocusChange.duck);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.stage, MorningStage.closed, reason: 'a notification sound is not a call');
    keeper.onFocus!(FocusChange.paused);
    await until(c, () => c.stage == MorningStage.intro);
    expect(c.message, contains('call or another app'));
    expect(tmp.listSync(), isEmpty);
    expect(keeper.held, isFalse);
  });

  test('no headband: a plain failure', () async {
    final c = MorningController(finder: OneFinder(null), store: MorningStore(tmp), timing: fast);
    await c.start();
    expect(c.stage, MorningStage.failed);
    expect(c.message, contains('not found'));
  });

  test('no contact reading: the signal decides the words and the check-in can start', () async {
    late MorningController c;
    final band = EyesBand(DemoSignal(), () => c.stage == MorningStage.closed ? 'closed' : 'open', resists: false);
    c = MorningController(finder: OneFinder(band), store: MorningStore(tmp), timing: fast);
    await c.start();
    expect(c.contact, isEmpty);
    await until(c, () => c.quality.gradeOf('O1') != Contact.none);
    c.begin();
    expect(c.stage, MorningStage.closed);
    await c.stop();
  });
}
