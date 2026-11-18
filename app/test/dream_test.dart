// The dream catcher without a phone: the round rules, the end of a spoken answer, the session file, and whole
// sessions through the controller with a fake headband that streams a synthetic eyes-closed signal fast (its alpha
// fades and comes back on cue), a fake microphone and a silent sound.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/dream/audio.dart';
import 'package:eeg_tracker/dream/controller.dart';
import 'package:eeg_tracker/dream/rounds.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/dream/voice.dart';
import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sound/synth.dart' show wav16;
import 'package:flutter_test/flutter_test.dart';

/// Streams an eyes-closed synthetic signal (no blinks, no jaw) far faster than real time: [perTick] samples every
/// millisecond. [gain] sets the alpha's size at each second of signal (1 = the baseline's, 0.3 = faded).
class DriftBand implements Headband {
  DriftBand(this.gain, {this.perTick = 250});

  double Function(double t) gain;
  final int perTick;
  final DemoSignal demo = DemoSignal(5)
    ..eyes = 'closed'
    ..blinks = false
    ..jawBursts = false;
  int pack = 0;
  bool paused = false;
  Timer? _timer;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();
  final List<String> calls = [];

  @override
  String get name => 'BrainBit D';
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
      if (!_signal.hasListener || paused) return;
      demo.alphaGain = gain(demo.t);
      final batch = <Sample>[];
      for (final r in demo.next(perTick)) {
        batch.add((pack: pack % 2048, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6));
        pack++;
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

class OneFinder implements HeadbandFinder {
  OneFinder(this.band);
  final Headband? band;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    if (band != null) onFound?.call(band!.name, -60);
    return band;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('out of range');
}

/// Writes a one-second 16 kHz WAV at start and plays back [script] as the level, one reading a millisecond.
class FakeMic implements Mic {
  FakeMic(this.script);
  List<double> script;
  final List<String> started = [];
  int stops = 0;
  bool allow = true;
  StreamController<double> _levels = StreamController<double>.broadcast();
  Timer? _timer;

  @override
  Future<bool> allowed({bool ask = true}) async => allow;

  @override
  Future<void> start(String path) async {
    if (!allow) throw StateError('no microphone permission');
    started.add(path);
    File(path).writeAsBytesSync(wav16([Float32List(16000)], sampleRate: 16000));
    _levels = StreamController<double>.broadcast();
    var i = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      _levels.add(i < script.length ? script[i] : -60);
      i++;
    });
  }

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<void> stop() async {
    stops++;
    _timer?.cancel();
  }

  @override
  Future<void> dispose() async => _timer?.cancel();
}

/// The room at -60 dBFS, 2 s of voice at -30, then quiet: over after 3 s of silence (5.3 s in all).
final List<double> spoken = [-60, -60, -60, for (var i = 0; i < 20; i++) -30, for (var i = 0; i < 60; i++) -60];

const fast = DreamTiming(
  link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
  tick: Duration(milliseconds: 20),
  tapWindow: Duration(milliseconds: 100),
  wakeRingOut: Duration.zero,
);

Future<void> until(DreamController c, bool Function() done, {Duration max = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(max);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('stuck in ${c.stage} (${c.message}) at ${c.seconds.round()} s');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

DreamSession sessionWith(DateTime start, List<(double, DreamCause)> rounds) => DreamSession(
  start: start,
  plannedRounds: 4,
  ending: DreamEnding.wake,
  prompts: const {'theme': 'own', 'question': 'tone'},
  recording: fileStem(start),
  firstTimerS: 700,
  baselineS: 61,
  rounds: [
    for (final (i, (atS, cause)) in rounds.indexed)
      DreamRound(
        n: i + 1,
        atS: atS,
        at: start.add(Duration(seconds: atS.round())),
        cause: cause,
        state: 'drowsy',
        answerFile: '${fileStem(start)}-r${i + 1}.wav',
        answerS: 12.4,
        voiceS: 8.1,
        end: AnswerEnd.silence,
        drifting: i.isEven ? true : null,
        endS: atS + 40,
        note: i == 0 ? 'a tree with ladders' : '',
      ),
  ],
  endS: 1800,
  endWhy: DreamEnd.rounds,
  drift: const {'onsetS': 400, 'epochs': 'bbaadd'},
);

void main() {
  group('round plan', () {
    RoundPlan plan({int rounds = 4, int timer = 700, double u = 0}) =>
        RoundPlan(rounds: rounds, firstTimerS: timer, random: () => u);

    test('round 1 asks when the detector says drowsy, or at its timer', () {
      final p = plan();
      expect(p.due(100, null), isNull);
      expect(p.due(100, DriftState.awake), isNull);
      expect(p.due(240, DriftState.drowsy), DreamCause.drowsy);
      expect(plan().due(699, DriftState.awake), isNull);
      expect(plan().due(700, DriftState.awake), DreamCause.timer);
      expect(plan().due(700, null), DreamCause.timer, reason: 'the timer works without a baseline');
    });

    test('a later round needs alpha back, then faded again, at least 2 minutes after the last ended', () {
      final p = plan()
        ..start()
        ..finish(300);
      expect(p.due(301, DriftState.drowsy), isNull, reason: 'under way, then just ended');
      p.epoch(270, DriftState.awake); // started before the round ended: does not count
      expect(p.due(430, DriftState.drowsy), isNull);
      p.epoch(330, DriftState.awake);
      expect(p.awakeSince, isTrue);
      expect(p.due(410, DriftState.drowsy), isNull, reason: 'under 2 minutes');
      expect(p.due(420, DriftState.awake), isNull);
      expect(p.due(420, DriftState.drowsy), DreamCause.drowsy);
      expect(p.due(420, DriftState.asleep), DreamCause.drowsy);
    });

    test('a later round\'s timer falls 4 to 7 minutes after the last round ended', () {
      final early = plan(u: 0)
        ..start()
        ..finish(300);
      expect(early.timerS, 300 + 240);
      expect(early.due(539, DriftState.drowsy), isNull, reason: 'alpha never came back');
      expect(early.due(540, DriftState.drowsy), DreamCause.timer);
      final late = plan(u: 1)
        ..start()
        ..finish(300);
      expect(late.timerS, 300 + 420);
      expect(() => (plan(u: 1.5)..start()).finish(10), throwsStateError);
    });

    test('no round while one is under way, after the last one, or 45 minutes after lights off', () {
      final p = plan(rounds: 3)..start();
      expect(p.due(800, DriftState.drowsy), isNull);
      expect(p.over(800), isFalse);
      p.finish(800);
      for (var i = 0; i < 2; i++) {
        p
          ..start()
          ..finish(900.0 + i);
      }
      expect(p.done, 3);
      expect(p.over(902), isTrue);
      expect(p.due(2000, DriftState.drowsy), isNull);
      final capped = plan();
      expect(capped.due(DreamRule.capS - 1.0, DriftState.drowsy), DreamCause.drowsy);
      expect(capped.due(DreamRule.capS.toDouble(), DriftState.drowsy), isNull);
      expect(capped.over(DreamRule.capS.toDouble()), isTrue);
      capped.start();
      expect(capped.over(DreamRule.capS + 10.0), isFalse, reason: 'a round under way finishes');
    });
  });

  group('voice gate', () {
    AnswerEnd? run(VoiceGate g, List<double> levels) {
      for (final l in levels) {
        final e = g.add(l);
        if (e != null) return e;
      }
      return null;
    }

    test('3 s of silence after the voice ends the answer', () {
      final g = VoiceGate();
      expect(run(g, spoken), AnswerEnd.silence);
      expect(g.seconds, closeTo(5.3, 1e-9));
      expect(g.voiceSeconds, closeTo(2.0, 1e-9));
      expect(g.floor, -60);
    });

    test('no voice in 10 s: no answer; a voice that never stops: 30 s', () {
      final quiet = VoiceGate();
      expect(run(quiet, List.filled(200, -58)), AnswerEnd.noVoice);
      expect(quiet.seconds, closeTo(10, 1e-9));
      expect(quiet.heard, isFalse);
      final talker = VoiceGate();
      expect(run(talker, [-60, -60, -60, ...List.filled(400, -20)]), AnswerEnd.cap);
      expect(talker.seconds, closeTo(30, 1e-9));
    });

    test('a pause under 3 s does not end it; digital silence counts as a quiet room, not as -inf', () {
      final g = VoiceGate();
      final levels = [
        double.negativeInfinity, double.nan, -160.0, // the room: -70 at most
        ...List.filled(5, -55.0), // a breath: not 10 dB over the room
        ...List.filled(10, -40.0), ...List.filled(25, -70.0), ...List.filled(10, -40.0), ...List.filled(30, -70.0),
      ];
      expect(run(g, levels), AnswerEnd.silence);
      expect(g.floor, VoiceRule.quietestDb);
      expect(g.voiceSeconds, closeTo(2.5, 1e-9), reason: 'the -55 breath is voice too: 15 dB over a silent room');
      expect(g.seconds, closeTo(8.3, 1e-9));
    });

    test('a room that gets quieter lowers the line', () {
      final g = VoiceGate();
      run(g, [-40, -40, -40, -55, -55]);
      expect(g.floor, -55);
      expect(g.add(-44), isNull);
      expect(g.heard, isTrue);
    });
  });

  group('session file', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dream'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a session survives the file; damaged and foreign files are skipped; newest first', () {
      final store = DreamStore(Directory('${tmp.path}/dream-catcher'));
      final a = sessionWith(DateTime(2026, 11, 17, 23, 5), [(312, DreamCause.drowsy), (790.5, DreamCause.timer)]);
      final b = sessionWith(DateTime(2026, 11, 18, 23, 40), [(150, DreamCause.timer)]);
      store
        ..save(a)
        ..save(b);
      File('${store.dir.path}/broken.dream.json').writeAsStringSync('{"version": 1, "start": ');
      File('${store.dir.path}/other.dream.json').writeAsStringSync(jsonEncode({...a.toJson(), 'version': 2}));
      File('${store.dir.path}/bad-round.dream.json').writeAsStringSync(
        jsonEncode({
          ...a.toJson(),
          'start': '2026-11-16T22:00:00.000',
          'rounds': [
            {...a.rounds.first.toJson(), 'answerFile': '../../recordings/x.wav'},
          ],
        }),
      );
      final listed = store.list();
      expect([for (final s in listed) s.start], [b.start, a.start]);
      final back = listed[1];
      expect(jsonEncode(back.toJson()), jsonEncode(a.toJson()));
      expect(back.rounds.first.note, 'a tree with ladders');
      expect(back.rounds[1].drifting, isNull);
      expect(back.answers, 2);
      expect(earlierLatenciesMin(listed), [312 / 60], reason: 'only rounds the detector asked count');
      expect(store.dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('a WAV\'s length from its header; prompts count only with sound in them', () {
      final store = DreamStore(Directory('${tmp.path}/dream-catcher'));
      expect(store.promptPath(PromptKind.theme), isNull);
      store.promptsDir.createSync(recursive: true);
      store.promptFile(PromptKind.theme).writeAsBytesSync(wav16([Float32List(48000 * 3)]));
      store.promptFile(PromptKind.question).writeAsBytesSync(wav16([Float32List(1600)], sampleRate: 16000));
      expect(wavSeconds(store.promptFile(PromptKind.theme)), closeTo(3, 1e-9));
      expect(store.promptPath(PromptKind.theme), store.promptFile(PromptKind.theme).path);
      expect(store.promptPath(PromptKind.question), isNull, reason: '0.1 s is a slip of the finger');
      // a recorder stopped hard leaves the data size unset: the file's own length counts
      final raw = wav16([Float32List(16000)], sampleRate: 16000);
      ByteData.sublistView(raw).setUint32(40, 0, Endian.little);
      final f = File('${tmp.path}/hard.wav')..writeAsBytesSync(raw);
      expect(wavSeconds(f), closeTo(1, 1e-9));
      expect(wavSeconds(File('${tmp.path}/none.wav')), isNull);
      expect(wavSeconds(File('${tmp.path}/text.wav')..writeAsStringSync('hello')), isNull);
    });
  });

  group('sessions through the controller', () {
    late Directory tmp;
    late DreamStore store;
    late Directory recordings;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dream');
      recordings = Directory('${tmp.path}/recordings');
      store = DreamStore(dreamDirFor(recordings.path));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    DreamController controller(DriftBand? band, FakeMic mic, SilentDreamSound sound, {double u = 0.5, Future<String?> Function()? night, DateTime Function()? clock}) =>
        DreamController(
          finder: OneFinder(band),
          sound: () => sound,
          mic: mic,
          store: store,
          recordingsDir: recordings,
          startNight: night,
          timing: fast,
          random: () => u,
          clock: clock,
        );

    test('alpha fades, comes back and fades again: three rounds asked by the detector, answers kept', () async {
      late DreamController c;
      // faded from 150 s; after each round alpha comes back for 90 s, then fades again
      final band = DriftBand((t) {
        final end = c.plan?.lastEnd;
        if (end == null) return t < 150 ? 1 : 0.3;
        return t < end + 90 ? 1 : 0.3;
      });
      final mic = FakeMic(spoken), sound = SilentDreamSound();
      c = controller(band, mic, sound);
      var taps = 0;
      c.addListener(() {
        if (c.stage == DreamStage.checking && c.roundNow != null && taps < c.roundNow!) {
          taps = c.roundNow!;
          c.drifting(taps != 2);
        }
      });
      await c.start(rounds: 3);
      expect(c.stage, isIn([DreamStage.baseline, DreamStage.drifting]));
      await until(c, () => c.stage == DreamStage.done);
      final s = c.last!;
      expect(s.endWhy, DreamEnd.rounds);
      expect([for (final r in s.rounds) r.cause], List.filled(3, DreamCause.drowsy));
      // round 1: drowsy is known a minute after the fade
      expect(s.rounds.first.atS, inInclusiveRange(200, 245));
      for (var i = 1; i < 3; i++) {
        expect(s.rounds[i].atS, greaterThanOrEqualTo(s.rounds[i - 1].endS + DreamRule.gapS));
        expect(s.rounds[i].atS, lessThan(s.rounds[i - 1].endS + DreamRule.againWindowMin[0] * 60));
      }
      expect([for (final r in s.rounds) r.drifting], [true, false, true]);
      expect([for (final r in s.rounds) r.end], List.filled(3, AnswerEnd.silence));
      expect(s.rounds.every((r) => (r.answerS - 1).abs() < 1e-9 && (r.voiceS - 2).abs() < 1e-9), isTrue);
      for (final r in s.rounds) {
        expect(File('${store.dir.path}/${r.answerFile}').existsSync(), isTrue);
      }
      expect(s.rounds.first.answerFile, '${s.stem}-r1.wav');
      // the theme as you drift off, then question and theme each round; the last round wakes you instead
      expect(sound.played, [
        'theme:tone',
        for (var i = 0; i < 3; i++) ...['question:tone', if (i < 2) 'theme:tone'],
      ]);
      expect(sound.wakes, 1);
      expect(sound.stopped, isTrue);
      expect(band.calls.last, 'disconnect');
      expect(s.baselineS, inInclusiveRange(59, 70));
      expect(s.drift['epochs'], startsWith('ba'), reason: 'the baseline is complete at the end of the second epoch');
      expect((s.drift['epochs']! as String).contains('d'), isTrue);
      expect(s.prompts, {'theme': 'tone', 'question': 'tone'});
      expect(s.night, isNull);
      // saved, and the EEG is a normal recording of this night with the rounds as markers
      expect(store.list().single.toJson(), s.toJson());
      final f32 = File('${recordings.path}/${s.recording}.f32');
      expect(f32.lengthSync() ~/ recordBytes, closeTo(c.seen!.n, 2 * 250));
      final markers = [
        for (final l in File('${recordings.path}/${s.recording}.markers.jsonl').readAsLinesSync()) jsonDecode(l) as Map,
      ];
      expect(markers.first['text'], startsWith('dream catcher: lights off'));
      expect(markers.where((m) => '${m['text']}'.contains('question (alpha faded')).length, 3);
      expect(markers.last['text'], 'dream catcher: end (rounds done)');
      expect(markers.every((m) => m['i'] is int && m['t'] is double), isTrue);
      expect(nightsIn(recordings).single.recordings.single.path, f32.path);
      c.dispose();
    });

    test('alpha never fades: the timers ask, from your own usual drift-off time', () async {
      // three earlier sessions whose first round the detector asked after 2, 3 and 4 minutes
      for (final (i, m) in [2.0, 3.0, 4.0].indexed) {
        store.save(sessionWith(DateTime(2026, 11, 10 + i, 23), [(m * 60, DreamCause.drowsy)]));
      }
      final band = DriftBand((_) => 1), mic = FakeMic(spoken), sound = SilentDreamSound();
      final c = controller(band, mic, sound, u: 0);
      await c.start(rounds: 3);
      expect(c.plan!.firstTimerS, 150, reason: 'the middle half of 2-4 min, u = 0');
      await until(c, () => c.stage == DreamStage.done);
      final s = c.last!;
      expect([for (final r in s.rounds) r.cause], List.filled(3, DreamCause.timer));
      expect(s.rounds.first.atS, closeTo(150, 1.5));
      for (var i = 1; i < 3; i++) {
        expect(s.rounds[i].atS - s.rounds[i - 1].endS, closeTo(240, 1.5), reason: '4 min after the last ended');
      }
      expect([for (final r in s.rounds) r.drifting], List.filled(3, null), reason: 'nobody tapped');
      expect(store.list().length, 4);
      c.dispose();
    });

    test('Stop while answering keeps the answer so far and ends without the wake tone', () async {
      final band = DriftBand((_) => 1), mic = FakeMic([-60, -60, -60, ...List.filled(5000, -30)]);
      final sound = SilentDreamSound();
      final c = controller(band, mic, sound, u: 0);
      store.save(sessionWith(DateTime(2026, 11, 1, 23), [(60, DreamCause.drowsy)]));
      store.save(sessionWith(DateTime(2026, 11, 2, 23), [(60, DreamCause.drowsy)]));
      store.save(sessionWith(DateTime(2026, 11, 3, 23), [(60, DreamCause.drowsy)]));
      await c.start(rounds: 4);
      await until(c, () => c.stage == DreamStage.answering);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await c.stop();
      final s = c.last!;
      expect(c.stage, DreamStage.done);
      expect(s.endWhy, DreamEnd.stopped);
      expect(s.rounds.single.end, AnswerEnd.stopped);
      expect(s.rounds.single.answerFile, isNotNull);
      expect(s.rounds.single.voiceS, greaterThan(0));
      expect(sound.wakes, 0);
      expect(mic.stops, 1);
      expect(band.calls, contains('disconnect'));
      c.dispose();
    });

    test('the sleep ending: the night recording starts once the headband is free', () async {
      final band = DriftBand((_) => 1), mic = FakeMic(spoken), sound = SilentDreamSound();
      List<String>? callsAtNight;
      final c = controller(band, mic, sound, u: 0, night: () async {
        callsAtNight = List.of(band.calls);
        return null;
      });
      for (final d in [4, 5, 6]) {
        store.save(sessionWith(DateTime(2026, 11, d, 23), [(30, DreamCause.drowsy)]));
      }
      await c.start(rounds: 3, ending: DreamEnding.sleep);
      await until(c, () => c.stage == DreamStage.done);
      final s = c.last!;
      expect(s.rounds.length, 3);
      expect(sound.wakes, 0);
      expect(sound.played.last, 'theme:tone', reason: '"drift off again" after the last round too');
      expect(callsAtNight!.last, 'disconnect');
      expect(s.night, 'started');
      c.dispose();
    });

    test('45 minutes after lights off the session ends even with the headband silent', () async {
      var shift = Duration.zero;
      final band = DriftBand((_) => 1), mic = FakeMic(spoken), sound = SilentDreamSound();
      final c = controller(band, mic, sound, u: 1, clock: () => DateTime.now().add(shift));
      await c.start(rounds: 4);
      await until(c, () => c.seconds > 30);
      band.paused = true;
      shift = const Duration(minutes: 46);
      await until(c, () => c.stage == DreamStage.done);
      expect(c.last!.endWhy, DreamEnd.cap);
      expect(c.last!.rounds, isEmpty);
      expect(c.last!.endS, greaterThanOrEqualTo(DreamRule.capS));
      expect(sound.wakes, 1, reason: 'the wake tone ends a session that ran out of time');
      c.dispose();
    });

    test('your own prompts play when recorded; no headband: a plain failure', () async {
      store.promptsDir.createSync(recursive: true);
      store.promptFile(PromptKind.theme).writeAsBytesSync(wav16([Float32List(48000)]));
      final sound = SilentDreamSound();
      final c = controller(DriftBand((_) => 1), FakeMic(spoken), sound, u: 0);
      await c.start(rounds: 3);
      await c.stop();
      expect(sound.played.first, 'theme:own');
      expect(c.last!.prompts, {'theme': 'own', 'question': 'tone'});
      final none = controller(null, FakeMic(spoken), SilentDreamSound());
      await none.start();
      expect(none.stage, DreamStage.failed);
      expect(none.message, contains('not found'));
      c.dispose();
      none.dispose();
    });
  });
}
