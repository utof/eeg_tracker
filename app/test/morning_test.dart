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
import 'package:eeg_tracker/sound/check_in_sound.dart';
import 'package:flutter_test/flutter_test.dart';

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
          (pack: pack++ % 2048, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6),
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
    await until(c, () => c.grades['O1']!.word != 'not touching');
    expect(c.grades['T4']!.word, 'not touching'); // no contact reading: as the laptop page says it
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
    expect(saved.reactionMs, 312);
    expect(saved.caffeineCups, 2);
    expect(saved.caffeineLate, isTrue);
    expect(saved.iafHz, back['iaf_hz']);
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
    await until(c, () => c.grades['O1']!.word != 'not touching');
    c.begin();
    expect(c.stage, MorningStage.closed);
    await c.stop();
  });
}
