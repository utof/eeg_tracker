// Hands-free controls in the app (DECISIONS 240-249): the switch and calibration files, the per-session helper with
// its sleep gate and tone, and the sessions acting on gestures: sound for states pauses and resumes its sound and
// marks moments, from a fake headband that makes the gestures on its synthetic signal.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/detectors/gestures.dart';
import 'package:eeg_tracker/dream/audio.dart';
import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/dream/controller.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/export/store.dart' show isExported;
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/handsfree/calibration_controller.dart';
import 'package:eeg_tracker/handsfree/live.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/nap/audio.dart';
import 'package:eeg_tracker/nap/controller.dart';
import 'package:eeg_tracker/handsfree/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/live_drift.dart';
import 'package:eeg_tracker/sound/check_in_sound.dart';
import 'package:eeg_tracker/sound/feedback_sound.dart';
import 'package:eeg_tracker/sound/gesture_tone.dart';
import 'package:eeg_tracker/sound/state_sound.dart';
import 'package:eeg_tracker/states/controller.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/training/control.dart' show SessionKind;
import 'package:flutter_test/flutter_test.dart';

import 'dream_test.dart' show FakeMic, OneFinder, spoken;

const fs = 250;

/// A gesture drawn on the synthetic signal at [atS] seconds of signal.
sealed class Drawn {
  const Drawn(this.atS);
  final double atS;
}

/// Two 0.4 s clenches 0.6 s apart (40 µV of noise on T3 and T4).
class DrawnClench extends Drawn {
  const DrawnClench(super.atS);
}

/// One way (+[uv] in T3-T4), the other way 0.7 s later, back to the middle 0.7 s after that.
class DrawnGlance extends Drawn {
  const DrawnGlance(super.atS, {this.uv = 140});
  final double uv;
}

/// The demo signal (eyes closed, no blinks or jaw bursts) with gestures drawn on it; 1 s of signal a millisecond.
class GestureBand implements Headband {
  GestureBand(this.drawn, {this.eyes});
  final List<Drawn> drawn;

  /// 'open' or 'closed' at a second of signal (closed throughout by default).
  final String Function(double t)? eyes;
  final DemoSignal demo = DemoSignal(3)
    ..eyes = 'closed'
    ..blinks = false
    ..jawBursts = false;
  final math.Random _r = math.Random(5);
  int pack = 0;
  Timer? _timer;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();

  @override
  String get name => 'BrainBit G';
  @override
  String get address => 'AA:CC';
  @override
  String get serial => '2';
  @override
  int? get rssi => -60;
  @override
  BandId get id => const BandId(name: 'BrainBit', address: 'AA:CC', family: 'leBrainBitBlack');
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  double _g() => (_r.nextDouble() + _r.nextDouble() + _r.nextDouble() - 1.5) * 2;

  List<double> _row() {
    final t = demo.t;
    demo.eyes = eyes?.call(t) ?? 'closed';
    final row = demo.next(1).single;
    for (final d in drawn) {
      final s = t - d.atS;
      switch (d) {
        case DrawnClench():
          if ((s >= 0 && s < 0.4) || (s >= 1.0 && s < 1.4)) {
            final a = 40 * _g();
            row[2] += a;
            row[3] += 40 * _g();
          }
        case DrawnGlance(:final uv):
          double step(double at) => 0.5 * (1 + _tanh((s - at) / 0.02));
          final v = uv * (step(0) - 2 * step(0.7) + step(1.4));
          row[2] += v / 2;
          row[3] -= v / 2;
      }
    }
    return row;
  }

  static double _tanh(double v) => v > 20 ? 1 : (v < -20 ? -1 : (math.exp(2 * v) - 1) / (math.exp(2 * v) + 1));

  @override
  Future<void> startSignal() async {
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!_signal.hasListener) return;
      final batch = <Sample>[];
      for (var i = 0; i < 250; i++) {
        final r = _row();
        batch.add((pack: pack % 2048, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6));
        pack++;
      }
      _signal.add(batch);
    });
  }

  @override
  Future<void> stopSignal() async => _timer?.cancel();
  @override
  Future<void> startResist() async {
    Timer(const Duration(milliseconds: 1), () => _resist.add({'O1': 4e5, 'O2': 6e5, 'T3': 5e5, 'T4': 5e5}));
  }

  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async => _timer?.cancel();
}

/// Calibrated settings as a session gets them (left = + in T3-T4).
const calibrated = GestureSettings(clenchX: 15, glanceUv: 80, leftSign: 1);

const fast = StatesTiming(
  link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
  tick: Duration(milliseconds: 20),
);

Future<void> until(bool Function() done, String what, {Duration max = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(max);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('stuck waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// One JSON line's text field.
String _text(String line, [String key = 'text']) => (jsonDecode(line) as Map<String, Object?>)[key]! as String;

/// Rows of the demo signal with [drawn] gestures, through detectors with a hands-free helper.
List<GestureKind> heardOn(List<Drawn> drawn, double seconds, {bool Function()? asleep, HandsFree Function(void Function(GestureKind))? make}) {
  final band = GestureBand(drawn), heard = <GestureKind>[];
  final d = Detectors();
  final h = make?.call(heard.add) ?? HandsFree(calibrated, onGesture: heard.add, asleep: asleep);
  h.attach(d);
  for (var i = 0; i < seconds * fs; i++) {
    d.push(band._row());
  }
  return heard;
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('handsfree'));
  tearDown(() => root.deleteSync(recursive: true));

  group('the switch and the calibration', () {
    final cal = CalibrationRecord(
      made: DateTime(2026, 11, 19, 21, 5),
      settings: calibrated,
      tries: const [TryResult(GestureKind.clench, 33, 31.5, 0, 'ok'), TryResult(GestureKind.glance, 57, null, 0, 'none')],
      clenchSeen: 3,
      glanceSeen: 2,
      leftKnown: true,
      others: 0,
      recording: '2026-11-19-210300',
    );

    test('off and not calibrated until set; on only counts with a usable calibration', () {
      final s = HandsFreeStore(root);
      expect(s.load().on, isFalse);
      expect(s.load().calibration, isNull);
      s.setOn(true, DateTime(2026, 11, 19, 21));
      expect(s.load().on, isTrue);
      expect(s.load().active, isNull, reason: 'on, but nothing calibrated');
      s.saveCalibration(cal);
      final back = s.load().calibration!;
      expect([back.made, back.settings.clenchX, back.settings.leftSign, back.clenchSeen, back.recording], [cal.made, 15.0, 1, 3, cal.recording]);
      expect([for (final t in back.tries) [t.kind, t.cue, t.level, t.why]], [
        [GestureKind.clench, 33, 31.5, 'ok'],
        [GestureKind.glance, 57, null, 'none'],
      ]);
      expect(s.load().active!.clenchX, 15);
      s.setOn(false, DateTime(2026, 11, 19, 22));
      expect(s.load().active, isNull);
      final events = [for (final l in File('${root.path}/hands-free/events.jsonl').readAsLinesSync()) _text(l, 'event')];
      expect(events, ['switched on', 'calibrated: double clench 3 of 3 (on), look left then right 2 of 3 (on)', 'switched off']);
    });

    test('a damaged file reads as off and not calibrated; no temporary file is left', () {
      final s = HandsFreeStore(root)..saveCalibration(cal);
      File('${root.path}/hands-free/settings.json').writeAsStringSync('{"on": tru');
      File('${root.path}/hands-free/calibration.json').writeAsStringSync('{"made": "x"}');
      expect([s.load().on, s.load().calibration], [false, null]);
      expect(Directory('${root.path}/hands-free').listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('Export data takes the folder', () {
      for (final f in ['settings.json', 'calibration.json', 'events.jsonl']) {
        expect(isExported('hands-free/$f'), isTrue, reason: f);
      }
    });
  });

  group('the session helper', () {
    test('a gesture plays the tone and reaches the session; asleep, it is dropped and counted', () {
      final tone = SilentGestureTone();
      var asleep = false;
      late HandsFree h;
      final heard = heardOn([const DrawnClench(40), const DrawnGlance(50), const DrawnClench(60)], 66, make: (on) {
        return h = HandsFree(calibrated, onGesture: (k) {
          on(k);
          asleep = true; // the drift-off detector says asleep from the first gesture on
        }, tone: tone, asleep: () => asleep);
      });
      expect(heard, [GestureKind.clench]);
      expect(tone.played, [GestureKind.clench]);
      expect([h.heard, h.ignoredAsleep], [1, 2]);
      expect(h.summary()['ignoredAsleep'], 2);
    });

    test('calibrated settings decide: a glance the wrong way, or with glances off, is not heard', () {
      final drawn = [const DrawnGlance(40, uv: -140)];
      expect(heardOn(drawn, 46), isEmpty);
      expect(
        heardOn([const DrawnGlance(40)], 46, make: (on) => HandsFree(const GestureSettings(glanceOn: false), onGesture: on)),
        isEmpty,
      );
    });

    test('the morning check-in never sees gestures: its code does not use them', () {
      for (final f in Directory('lib/morning').listSync().whereType<File>()) {
        final src = f.readAsStringSync();
        expect(src.contains('handsfree') || src.contains('gestures.dart') || src.contains('DetectorTap'), isFalse, reason: f.path);
      }
    });
  });

  group('sound for states', () {
    test('a double clench pauses the sound and the next resumes it; a glance marks a moment', () async {
      final band = GestureBand([const DrawnClench(75), const DrawnGlance(85), const DrawnClench(95)]);
      final sound = SilentStateSound(), tone = SilentGestureTone();
      final recordings = Directory('${root.path}/recordings')..createSync();
      final store = SoundStore(soundStatesDirFor(recordings.path));
      final c = StatesController(finder: OneFinder(band), sound: () => sound, store: store, timing: fast, gestureTone: () => tone)
        ..handsFree = calibrated;
      await c.start(SoundPlan.of(SoundState.relax, minutes: 5));
      await until(() => c.stage == SoundStage.playing, 'the sound');
      await until(() => sound.pauses.length >= 2, 'two pauses');
      expect(sound.pauses, [true, false]);
      expect(c.paused, isFalse);
      expect(tone.played, [GestureKind.clench, GestureKind.glance, GestureKind.clench]);
      await c.stop();
      final events = [for (final e in store.list().single.events) e.text];
      expect(events.where((e) => e.startsWith('hands-free')), [
        'hands-free: sound paused (double clench)',
        'hands-free: moment (look left then right)',
        'hands-free: sound back (double clench)',
        'hands-free: 3 gestures acted on, 0 ignored while probably asleep',
      ]);
      c.dispose();
    });

    test('with the switch off nothing listens', () async {
      final band = GestureBand([const DrawnClench(75)]);
      final sound = SilentStateSound(), tone = SilentGestureTone();
      final c = StatesController(finder: OneFinder(band), sound: () => sound, timing: fast, gestureTone: () => tone);
      await c.start(SoundPlan.of(SoundState.relax, minutes: 5));
      await until(() => c.seconds > 85, '85 s');
      await c.stop();
      expect([sound.pauses, tone.played], [isEmpty, isEmpty]);
      c.dispose();
    });
  });

  group('meditation', () {
    const medFast = MeditationTiming(
      contactFor: Duration(milliseconds: 5),
      settle: Duration.zero,
      tick: Duration(milliseconds: 20),
      reconnectWaits: [Duration(milliseconds: 5)],
      endRingOut: Duration.zero,
    );
    String eyes(double t) => t < 30 ? 'open' : 'closed';

    Future<(MeditationController, SilentSound, List<String>)> session(SessionKind kind, List<Drawn> drawn) async {
      final band = GestureBand(drawn, eyes: eyes), sound = SilentSound(), events = <String>[];
      final c = MeditationController(finder: OneFinder(band), sound: () => sound, timing: medFast, gestureTone: SilentGestureTone.new)
        ..handsFree = calibrated;
      var bedOff = false;
      c.addListener(() {
        if (c.paused != bedOff) {
          bedOff = c.paused;
          events.add('paused ${c.paused}, bed ${sound.bedOn}, bells ${sound.bells}');
        }
      });
      await c.start(const Duration(minutes: 2), kind: kind);
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (c.stage != Stage.report && c.stage != Stage.rating && c.stage != Stage.setup) {
        if (DateTime.now().isAfter(end)) fail('stuck in ${c.stage}');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return (c, sound, events);
    }

    List<String> noted(MeditationController c) => [
      for (final i in c.session!.log.info)
        if (i['event'] case final String e when e.startsWith('hands-free')) e,
    ];

    test('a double clench pauses the bed and the bells, the next brings them back; a glance is a moment', () async {
      final (c, sound, events) = await session(SessionKind.meditation, const [DrawnClench(120), DrawnGlance(140), DrawnClench(160)]);
      expect(noted(c), ['hands-free: sound paused (double clench)', 'hands-free: moment (look left then right)', 'hands-free: sound back (double clench)']);
      expect(events.first, startsWith('paused true, bed false'));
      expect(events.last, startsWith('paused false, bed true'));
      final info = c.session!.log.info.firstWhere((i) => i.containsKey('handsFree'))['handsFree']! as Map;
      expect(info['heard'], 3);
      c.dispose();
    });

    test('alpha-theta: a double clench only marks a moment', () async {
      final (c, sound, _) = await session(SessionKind.alphaTheta, const [DrawnClench(120)]);
      expect(noted(c), ['hands-free: moment (double clench)']);
      expect(c.paused, isFalse);
      c.dispose();
    });
  });

  group('dream catcher', () {
    test('"were you drifting?": a double clench answers Drifting, a look left then right Awake', () async {
      final band = GestureBand([]);
      final recordings = Directory('${root.path}/recordings');
      final store = DreamStore(dreamDirFor(recordings.path)), tone = SilentGestureTone();
      final c = DreamController(
        finder: OneFinder(band),
        sound: SilentDreamSound.new,
        mic: FakeMic(spoken),
        store: store,
        recordingsDir: recordings,
        timing: const DreamTiming(
          link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
          tick: Duration(milliseconds: 20),
          tapWindow: Duration(seconds: 5),
          wakeRingOut: Duration.zero,
        ),
        random: () => 0,
        gestureTone: () => tone,
      )..handsFree = calibrated;
      var asked = 0;
      c.addListener(() {
        if (c.stage == DreamStage.checking && asked < c.roundsDone + 1) {
          asked = c.roundsDone + 1;
          final t = band.demo.t + 0.5;
          band.drawn.add(asked == 1 ? DrawnClench(t) : DrawnGlance(t));
        }
      });
      await c.start(rounds: 2);
      await until(() => c.stage == DreamStage.done, 'the end', max: const Duration(seconds: 60));
      expect([for (final r in c.last!.rounds) r.drifting], [true, false]);
      expect(tone.played, [GestureKind.clench, GestureKind.glance]);
      final marks = [
        for (final l in File('${recordings.path}/${c.last!.recording}.markers.jsonl').readAsLinesSync())
          if (_text(l).startsWith('hands-free')) _text(l),
      ];
      expect(marks, [
        'hands-free: drifting (double clench)',
        'hands-free: awake (look left then right)',
        'hands-free: 2 gestures acted on, 0 ignored while probably asleep',
      ]);
      c.dispose();
    });
  });

  group('nap coach', () {
    test('a gesture marks a moment in the nap\'s recording', () async {
      final band = GestureBand([const DrawnClench(100), const DrawnGlance(110)]);
      final recordings = Directory('${root.path}/recordings');
      final c = NapController(
        finder: OneFinder(band),
        sound: SilentNapSound.new,
        recordingsDir: recordings,
        timing: const NapTiming(
          link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
          tick: Duration(milliseconds: 20),
        ),
        gestureTone: SilentGestureTone.new,
      )..handsFree = calibrated;
      await c.start(lengthMin: 20);
      List<String> marks() {
        final f = recordings.listSync().whereType<File>().where((f) => f.path.endsWith('.markers.jsonl')).firstOrNull;
        return [for (final l in f?.readAsLinesSync() ?? const <String>[]) _text(l)];
      }

      await until(() => c.seconds > 120, '120 s');
      await c.stop();
      expect(marks().where((m) => m.startsWith('hands-free')), [
        'hands-free: moment (double clench)',
        'hands-free: moment (look left then right)',
        'hands-free: 2 gestures acted on, 0 ignored while probably asleep',
      ]);
      c.dispose();
    });
  });

  group('the night recording', () {
    /// The night recorder's live detector fed GestureBand batches of 125 samples, arriving as they would.
    (LiveDrift, List<String>) night(GestureSettings? settings, List<Drawn> drawn, double seconds) {
      final band = GestureBand(drawn), live = LiveDrift(handsFree: settings), events = <String>[];
      final start = DateTime(2026, 11, 19, 23).millisecondsSinceEpoch;
      for (var sent = 0; sent < seconds * fs; sent += 125) {
        final rows = [
          for (var i = 0; i < 125; i++)
            () {
              final r = band._row();
              return (pack: (sent + i) % 2048, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6);
            }(),
        ];
        live.add(DateTime.fromMillisecondsSinceEpoch(start + (sent + 125) * 4), rows);
        events.addAll(live.takeEvents());
      }
      return (live, events);
    }

    test('a double clench is a moment marker; a glance is not (dream sleep is full of them)', () {
      final (live, events) = night(calibrated, [const DrawnClench(100), const DrawnGlance(120)], 130);
      expect(events.where((e) => e.startsWith('hands-free')), [handsFreeMoment]);
      expect([live.hands!.heard, live.hands!.ignoredAsleep], [1, 0]);
    });

    test('switch off, or no usable double clench: nothing listens', () {
      expect(night(null, [const DrawnClench(100)], 110).$1.hands, isNull);
      expect(night(const GestureSettings(clenchOn: false), [const DrawnClench(100)], 110).$1.hands, isNull);
    });

    test('the recorder reads the switch and the calibration from the app\'s folder, never throwing', () {
      expect(nightGestures(root), isNull);
      final s = HandsFreeStore(root)..setOn(true, DateTime(2026, 11, 19, 22));
      expect(nightGestures(root), isNull, reason: 'not calibrated');
      CalibrationRecord cal(GestureSettings g) => CalibrationRecord(
        made: DateTime(2026, 11, 19, 21),
        settings: g,
        tries: const [],
        clenchSeen: g.clenchOn ? 3 : 0,
        glanceSeen: 3,
        leftKnown: true,
        others: 0,
      );
      s.saveCalibration(cal(calibrated));
      expect(nightGestures(root)!.clenchX, 15);
      s.saveCalibration(cal(const GestureSettings(clenchOn: false)));
      expect(nightGestures(root), isNull, reason: 'only the glance works');
      expect(nightGestures(Directory('${root.path}/missing')), isNull);
    });
  });

  group('calibration', () {
    const calFast = CalTiming(
      link: LinkTiming(contactFor: Duration(milliseconds: 5), settle: Duration.zero, reconnectWaits: [Duration(milliseconds: 5)]),
      tick: Duration(milliseconds: 20),
    );

    test('six cued tries: the levels are tuned, each try is judged, and it is saved with its EEG', () async {
      final band = GestureBand([
        for (final at in [32, 40, 48]) DrawnClench(at + 0.8),
        for (final at in [56, 64, 72]) DrawnGlance(at + 0.6),
      ]);
      final sound = SilentCheckInSound(), store = HandsFreeStore(root);
      final c = CalibrationController(finder: OneFinder(band), sound: () => sound, store: store, timing: calFast);
      final cued = <int>[];
      var lanes = false;
      c.addListener(() {
        final t = c.tryNow;
        if (t != null && (cued.isEmpty || cued.last != t)) cued.add(t);
        if (c.stage == CalStage.trying && c.jaw.length == 100 && c.jaw.any((v) => v > c.clenchLine)) lanes = true;
      });
      expect(c.clenchLine, GestureRule.clenchX, reason: 'the planning line before any calibration');
      await c.start();
      await until(() => c.stage == CalStage.result, 'the result');
      expect(cued, [0, 1, 2, 3, 4, 5]);
      expect(sound.played, ['close', 'close', 'close', 'open', 'open', 'open', 'end']);
      expect(lanes, isTrue, reason: 'the jaw lane showed a clench over the line');
      final r = c.result!;
      expect([r.clenchSeen, r.glanceSeen, r.leftKnown, r.others], [3, 3, true, 0]);
      expect([for (final t in r.tries) t.why], List.filled(6, 'ok'));
      expect(r.settings.clenchX, greaterThan(GestureRule.clenchX));
      expect(c.clenchLine, r.settings.clenchX);
      final saved = store.load().calibration!;
      expect([saved.clenchSeen, saved.settings.leftSign], [3, 1]);
      final eeg = Directory('${root.path}/hands-free/recordings').listSync().map((f) => f.uri.pathSegments.last).toList();
      expect(eeg.where((n) => n.startsWith(saved.recording!)).map((n) => n.split('.').skip(1).join('.')).toSet(),
          containsAll(['f32', 'log', 'markers.jsonl']));
      c.dispose();
    });

    test('stopped half way: nothing is saved and no EEG is left', () async {
      final band = GestureBand([]);
      final store = HandsFreeStore(root);
      final c = CalibrationController(finder: OneFinder(band), sound: SilentCheckInSound.new, store: store, timing: calFast);
      await c.start();
      await until(() => c.seconds > 20, '20 s');
      expect(c.stillLeft, lessThan(12));
      await c.stop();
      expect(c.stage, CalStage.setup);
      expect(store.load().calibration, isNull);
      final eeg = Directory('${root.path}/hands-free/recordings');
      expect(eeg.existsSync() ? eeg.listSync() : const [], isEmpty);
      c.dispose();
    });

    test('no headband: a plain failure', () async {
      final c = CalibrationController(finder: OneFinder(null), sound: SilentCheckInSound.new, timing: calFast);
      await c.start();
      expect(c.stage, CalStage.failed);
      expect(c.message, contains('not found'));
      c.dispose();
    });
  });
}
