// "Was this you?" (DECISIONS 370-379) around its rules: the night pass keeps the minutes after Lights off, the report
// gets `wearer_signal`, a rebuilt report keeps the owner's answer, the files (switch, answers, log), the trends
// leaving out "someone else", and the words. The rules themselves: wearer_cross_check_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/export/store.dart' show storedFiles;
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/nights.dart' show nightsIn;
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/prep.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/ui/trends_screen.dart' show readTrendInputs;
import 'package:eeg_tracker/wearer/check.dart';
import 'package:eeg_tracker/wearer/wearer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'drift_report_test.dart' show addMarker, roundTrip, writeDriftRun;

const w = 'W', n2 = 'N2';
List<String> rep(String s, int n) => List.filled(n, s);

/// A night report as the scorer writes it, with a wearer signal ([iaf] null: none) and maybe an answer.
Map<String, dynamic> night(String nightOf, {double? iaf = 10.0, String? why, String? answer, double alpha = 30}) {
  final start = DateTime.parse('${nightOf}T23:00:00');
  final r = roundTrip(buildReport(
    nightOf: nightOf,
    built: start.add(const Duration(hours: 8)),
    scoringSeconds: 30,
    start: start,
    lengthSeconds: 40 * 30.0,
    inputs: {'${fileStem(start)}.f32': 1000},
    model: phoneModelId,
    stages: [...rep(w, 10), ...rep(n2, 30)],
  ));
  r['wearer_signal'] = {
    'version': 1,
    'from_s': 30,
    'epochs': 9,
    'clean_s': 260.0,
    'iaf_hz': iaf,
    'alpha_uv2': alpha,
    'slope': -1.5,
    'why': why,
  };
  if (answer != null) r['wearer'] = {'answer': answer, 'at': '${nightOf}T23:59:00+03:00'};
  return r;
}

/// A check-in result with its three numbers.
Map<String, Object?> checkIn(DateTime start, {double iaf = 9.8, double clean = 110}) => {
  'version': 'morning-v1',
  'start': start.toIso8601String(),
  'date': '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}',
  'channels': {
    'O1': {'clean_s_ec': clean},
    'O2': {'clean_s_ec': clean},
  },
  'back': {'iaf_hz': iaf, 'alpha_ec_uv2': 31.0, 'aperiodic_slope_ec': -1.5, 'ec_rise': 2.5, 'clean_share': 0.95},
  'ratings': {'kss': 4, 'mood': 3, 'tension': 2},
};

void main() {
  late Directory root, recordings;
  setUp(() {
    root = Directory.systemTemp.createTempSync('wearer');
    recordings = Directory('${root.path}/recordings')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('the night pass and the report', () {
    const t0 = 1795468320.0;

    test('with Lights off the pass keeps the back channels of the next 10 minutes; without it nothing', () {
      final f = writeDriftRun(recordings, t0, 900, fadeAtS: 800);
      expect(seeNight([f])!.wearer, isNull, reason: 'no marker: the night start is not Lights off');
      addMarker(f, t0 + 65.3, 'lights off');
      final win = seeNight([f])!.wearer!;
      expect(win.fromS, 90);
      expect(win.length, 600 * 250);
      expect(win.missing.any((m) => m), isFalse);
    });

    test('the report gets wearer_signal from the awake epochs after Lights off', () {
      final f = writeDriftRun(recordings, t0, 900, fadeAtS: 800);
      addMarker(f, t0 + 65.3, 'lights off');
      final seen = seeNight([f])!;
      Map<String, dynamic> build(List<String>? stages, NightSeen? s) => roundTrip(buildReport(
        nightOf: '2026-11-18',
        built: DateTime(2026, 11, 19, 7),
        scoringSeconds: 40,
        start: DateTime.fromMillisecondsSinceEpoch((t0 * 1000).round()),
        lengthSeconds: 900,
        inputs: const {'a.f32': 1000},
        model: phoneModelId,
        stages: stages,
        seen: s,
      ));
      final ws = build([...rep(w, 13), ...rep(n2, 17)], seen)['wearer_signal'] as Map<String, dynamic>;
      expect(ws['why'], isNull);
      expect((ws['from_s'], ws['epochs']), (90, 10), reason: 'epochs 3-12 awake, 13-22 not');
      expect(ws['clean_s'] as double, greaterThanOrEqualTo(minCleanS));
      expect(ws['iaf_hz'] as double, closeTo(10, 0.3), reason: "the demo signal's 10 Hz alpha");
      final (sig, _) = reportSignal(ws);
      expect(sig, isNotNull);
      final asleep = build([...rep(w, 4), ...rep(n2, 26)], seen)['wearer_signal'] as Map<String, dynamic>;
      expect((asleep['epochs'], asleep['why']), (1, whyClean));
      expect(build(null, seen)['wearer_signal'], isNull, reason: 'unscored');
      expect(build([...rep(w, 30)], null)['wearer_signal'], isNull, reason: 'no pass');
    });

    test('a night scored again keeps the owner\'s answer', () async {
      final store = NightReportStore(nightsDirFor(recordings.path));
      final f = writeDriftRun(recordings, t0, 400, fadeAtS: 300);
      addMarker(f, t0 + 5, 'lights off');
      final scorer = SleepScorer(
        recordingsDir: recordings,
        store: store,
        openRun: (run) async => _AllAwake(),
        prepare: (files) async => prepareNight(files),
        see: (files) async => seeNight(files),
      );
      final first = await scorer.score(scorer.due().single);
      answerWearer(recordings.path, kindNight, first.nightOf, answerSomeoneElse, DateTime(2026, 11, 19, 8));
      expect(store.read(first.nightOf)!.json['wearer'], containsPair('answer', answerSomeoneElse));
      expect(scorer.due(), isEmpty);
      final again = await scorer.score(nightsIn(recordings).single); // as after 10 minutes more of the night
      expect(again.json['wearer'], containsPair('answer', answerSomeoneElse));
      expect(store.read(first.nightOf)!.json['wearer'], containsPair('answer', answerSomeoneElse));
    });
  });

  group('the files', () {
    test('on unless switched off; a damaged settings file reads as on; every change is an event', () {
      final s = WearerStore(wearerDirFor(recordings.path));
      expect(s.on, isTrue);
      s.setOn(false, DateTime(2026, 11, 20, 9));
      expect(s.on, isFalse);
      File('${s.dir.path}/settings.json').writeAsStringSync('{oops');
      expect(s.on, isTrue);
      final events = File('${s.dir.path}/events.jsonl').readAsLinesSync().map(jsonDecode).toList();
      expect((events.single as Map)['event'], 'switched off');
    });

    test('an answer tags the night report or the check-in file, and taking it back clears it', () {
      final nights = NightReportStore(nightsDirFor(recordings.path))..write(night('2026-11-18'));
      final mornings = MorningStore(morningsDirFor(recordings.path));
      final start = DateTime(2026, 11, 19, 9, 12, 5);
      mornings.save(checkIn(start), start);
      answerWearer(recordings.path, kindNight, '2026-11-18', answerSomeoneElse, DateTime(2026, 11, 19, 9));
      answerWearer(recordings.path, kindCheckIn, fileStem(start), answerMe, DateTime(2026, 11, 19, 9, 20));
      expect(nights.read('2026-11-18')!.wearerAnswer, answerSomeoneElse);
      expect(mornings.list().single.wearerAnswer, answerMe);
      expect(mornings.list().single.json['back'], isNotNull, reason: 'the rest of the file is kept');
      answerWearer(recordings.path, kindNight, '2026-11-18', null, DateTime(2026, 11, 19, 9, 30));
      expect(nights.read('2026-11-18')!.wearerAnswer, isNull);
      final events = File('${wearerDirFor(recordings.path).path}/events.jsonl').readAsLinesSync();
      expect(events, hasLength(3));
      expect(jsonDecode(events.last), containsPair('event', 'answer'));
    });

    test('Export data takes the folder: the switch, the events and the log', () {
      final s = WearerStore(wearerDirFor(recordings.path))..setOn(true, DateTime(2026, 11, 20));
      NightReportStore(nightsDirFor(recordings.path)).write(night('2026-11-19'));
      refreshWearer(recordings.path, DateTime(2026, 11, 20, 8));
      final paths = [for (final f in storedFiles(root)) f.path];
      expect(paths, containsAll(['wearer/settings.json', 'wearer/events.jsonl', 'wearer/log.jsonl']));
      expect(s.dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('"someone else" leaves the trends; "it was me" and no answer stay', () {
      final nights = NightReportStore(nightsDirFor(recordings.path))
        ..write(night('2026-11-17'))
        ..write(night('2026-11-18', answer: answerSomeoneElse))
        ..write(night('2026-11-19', answer: answerMe));
      final mornings = MorningStore(morningsDirFor(recordings.path));
      final a = DateTime(2026, 11, 19, 9), b = DateTime(2026, 11, 20, 9);
      mornings
        ..save({...checkIn(a), 'wearer': {'answer': answerSomeoneElse}}, a)
        ..save(checkIn(b), b);
      expect(nights.all(), hasLength(3), reason: 'nothing is deleted');
      final inputs = readTrendInputs(recordings.path);
      expect(inputs.nights.map((r) => r.nightOf), ['2026-11-19', '2026-11-17']);
      expect(inputs.mornings.map((m) => m.start), [b]);
    });
  });

  group('the check over the app\'s files', () {
    test('silent while learning; nights and check-ins counted apart; the log gets each recording once', () {
      final nights = NightReportStore(nightsDirFor(recordings.path));
      for (var d = 1; d <= 3; d++) {
        nights.write(night('2026-11-0$d'));
      }
      nights.write(night('2026-11-04', iaf: null, why: whyLightsOff));
      final mornings = MorningStore(morningsDirFor(recordings.path));
      final s = DateTime(2026, 11, 2, 9);
      mornings.save(checkIn(s), s);
      final now = DateTime(2026, 11, 5, 10);
      final r = refreshWearer(recordings.path, now);
      expect(r.on, isTrue);
      expect(r.of(kindNight, '2026-11-03')!.state, WearerState.learning);
      expect(r.of(kindNight, '2026-11-03')!.have, 2);
      expect(r.of(kindNight, '2026-11-04')!.why, whyLightsOff);
      expect(r.learning(kindNight), (have: 3, days: 3));
      expect(r.learning(kindCheckIn), (have: 1, days: 1));
      final log = File('${wearerDirFor(recordings.path).path}/log.jsonl');
      expect(log.readAsLinesSync(), hasLength(5));
      refreshWearer(recordings.path, now.add(const Duration(hours: 1)));
      expect(log.readAsLinesSync(), hasLength(5), reason: 'judged once');
      final line = jsonDecode(log.readAsLinesSync().first) as Map;
      expect(line.keys, containsAll(['judged', 'kind', 'id', 'state', 'distance', 'answer']));
    });

    test('a night scored before the check existed is not part of it', () {
      final old = night('2026-11-01')..remove('wearer_signal');
      NightReportStore(nightsDirFor(recordings.path)).write(old);
      final r = refreshWearer(recordings.path, DateTime(2026, 11, 2));
      expect(r.of(kindNight, '2026-11-01'), isNull);
      expect(r.learning(kindNight), (have: 0, days: 0));
    });

    test('switched off: no verdicts and nothing written', () {
      NightReportStore(nightsDirFor(recordings.path)).write(night('2026-11-01'));
      WearerStore(wearerDirFor(recordings.path)).setOn(false, DateTime(2026, 11, 1));
      final r = refreshWearer(recordings.path, DateTime(2026, 11, 2));
      expect(r.on, isFalse);
      expect(r.of(kindNight, '2026-11-01'), isNull);
      expect(File('${wearerDirFor(recordings.path).path}/log.jsonl').existsSync(), isFalse);
    });

    test('a far night after ten on five days asks; the words never claim who it was', () {
      final nights = NightReportStore(nightsDirFor(recordings.path));
      for (var d = 1; d <= 10; d++) {
        nights.write(night('2026-11-${d.toString().padLeft(2, '0')}', iaf: 9.9 + 0.05 * (d % 3)));
      }
      nights.write(night('2026-11-11', iaf: 8.2, alpha: 90));
      final r = refreshWearer(recordings.path, DateTime(2026, 11, 12));
      final v = r.of(kindNight, '2026-11-11')!;
      expect(v.state, WearerState.notLikeYou);
      final line = wearerLine(r, kindNight, '2026-11-11')!;
      expect(line.question, isTrue);
      expect(line.text, "This doesn't look like your usual brain signal. Was it you?");
      expect(line.detail, contains('slower'));
      expect(line.detail, contains('8.2'));
      final all = [line.text, line.detail ?? '', line.note ?? ''].join(' ').toLowerCase();
      for (final banned in ['diagnos', 'identity', 'identified', 'stranger', 'intruder', 'not you']) {
        expect(all, isNot(contains(banned)));
      }
      final ok = wearerLine(r, kindNight, '2026-11-10')!;
      expect((ok.question, ok.text), (false, 'Learning what your brain looks like: 9 of 10 nights.'));
    });
  });

  group('the words', () {
    WearerResult result(WearerVerdict v, {String? answer, bool on = true, WearerSignal? signal}) => WearerResult(
      on: on,
      verdicts: {'${v.kind}:${v.id}': v},
      answers: {'${v.kind}:${v.id}': ?answer},
      signals: {'${v.kind}:${v.id}': ?signal},
    );
    const id = '2026-11-20-091205';

    test('learning, looks like you, not checked', () {
      final learn = result(const WearerVerdict(id: id, kind: kindCheckIn, state: WearerState.learning, have: 3, days: 2));
      expect(wearerLine(learn, kindCheckIn, id)!.text, 'Learning what your brain looks like: 3 of 10 check-ins.');
      final days = result(const WearerVerdict(id: id, kind: kindCheckIn, state: WearerState.learning, have: 12, days: 3));
      expect(wearerLine(days, kindCheckIn, id)!.text,
          'Learning what your brain looks like: 12 check-ins so far, on 3 of the 5 different days it needs.');
      final like = result(const WearerVerdict(id: id, kind: kindCheckIn, state: WearerState.likeYou, distance: 1.1));
      expect(wearerLine(like, kindCheckIn, id)!.text, 'Looks like your usual brain signal.');
      final not = result(const WearerVerdict(id: id, kind: kindNight, state: WearerState.unchecked, why: whyLightsOff));
      expect(wearerLine(not, kindNight, id)!.text, 'Not checked: Lights off was not tapped.');
      final peak = result(const WearerVerdict(id: id, kind: kindCheckIn, state: WearerState.unchecked, why: whyPeak));
      expect(wearerLine(peak, kindCheckIn, id)!.text, 'Not checked: no clear alpha rhythm with eyes closed.');
      for (final r in [learn, like, not, peak]) {
        final l = wearerLine(r, kindCheckIn, id) ?? wearerLine(r, kindNight, id)!;
        expect((l.question, l.canSaySomeoneElse, l.canUndo), (false, true, false));
      }
    });

    test('answered: someone else is left out, it was me counts; both can be taken back', () {
      const v = WearerVerdict(id: id, kind: kindCheckIn, state: WearerState.notLikeYou, distance: 3.4);
      final out = wearerLine(result(v, answer: answerSomeoneElse), kindCheckIn, id)!;
      expect(out.text, 'Someone else wore the headband: this check-in is left out of your trends, the unusual card '
          'and experiments.');
      expect((out.question, out.canSaySomeoneElse, out.canUndo), (false, false, true));
      final me = wearerLine(result(v, answer: answerMe), kindCheckIn, id)!;
      expect(me.text, 'You said this was you. It now counts toward what your brain looks like.');
      expect(me.canUndo, isTrue);
      final like = wearerLine(
        result(const WearerVerdict(id: id, kind: kindNight, state: WearerState.likeYou), answer: answerSomeoneElse),
        kindNight,
        id,
      )!;
      expect(like.text, contains('this night is left out'));
    });

    test('the biggest difference in plain words', () {
      WearerLine line(String biggest, double z, WearerSignal s) => wearerLine(
        result(
          WearerVerdict(
            id: id,
            kind: kindCheckIn,
            state: WearerState.notLikeYou,
            distance: 3,
            z: {'iaf': 0, 'alpha': 0, 'slope': 0, biggest: z},
            usual: const {'iaf': 9.8, 'alpha': 1.5, 'slope': -1.5},
            biggest: biggest,
          ),
          signal: s,
        ),
        kindCheckIn,
        id,
      )!;
      expect(line('iaf', 4, const {'iaf': 11.04, 'alpha': 1.5, 'slope': -1.5}).detail,
          'Its alpha rhythm was faster than yours usually is: 11.0\u00a0Hz, usually about 9.8.');
      expect(line('alpha', -4, const {'iaf': 9.8, 'alpha': 0.9, 'slope': -1.5}).detail,
          'Its alpha was weaker than yours usually is: 8\u00a0µV², usually about 32.');
      expect(line('slope', 4, const {'iaf': 9.8, 'alpha': 1.5, 'slope': -0.8}).detail,
          'Its background signal was flatter than yours usually is.');
      expect(line('slope', -4, const {'iaf': 9.8, 'alpha': 1.5, 'slope': -2.4}).detail,
          'Its background signal was steeper than yours usually is.');
    });

    test('switched off or not judged: no line', () {
      const v = WearerVerdict(id: id, kind: kindCheckIn, state: WearerState.likeYou);
      expect(wearerLine(result(v, on: false), kindCheckIn, id), isNull);
      expect(wearerLine(result(v), kindNight, id), isNull);
    });
  });
}

/// AnySleep stand-in: every epoch awake.
class _AllAwake implements StageRun {
  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) =>
      throw UnimplementedError('one piece');

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    final out = Float32List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      out[e * 5] = 3;
    }
    return out;
  }
}
