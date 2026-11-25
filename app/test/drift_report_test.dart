// When you fell asleep after lights off, in the sleep report (lib/sleep/drift.dart, DECISIONS 180-184): which marker
// is lights off, how it lands on the night's 30 s epochs, the sleep model's onset, the report's `drift_off`, the
// running check toward "4 of 5 nights within 5 minutes", and the night pass that runs the detector from lights off.
// The hand-worked cases are the same as analysis/tests/test_night_drift.py's (the Python reference).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart' show EpochQuality;
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/sleep/drift.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 'W', n1 = 'N1', n2 = 'N2', gap = 'gap';
List<String> rep(String s, int n) => List.filled(n, s);

/// A run of synthetic eyes-closed signal written as the recorder writes it: one `.idx` row per second. Alpha has
/// its full size until [fadeAtS], then a quarter of it (drifting off).
File writeDriftRun(Directory dir, double t0, int seconds, {required int fadeAtS}) {
  final demo = DemoSignal(5)
    ..eyes = 'closed'
    ..blinks = false
    ..jawBursts = false;
  final rec = ByteData(seconds * 250 * recordBytes);
  for (var s = 0; s < seconds; s++) {
    demo.alphaGain = s < fadeAtS ? 1 : 0.25;
    final rows = demo.next(250);
    for (var j = 0; j < 250; j++) {
      final o = (s * 250 + j) * recordBytes;
      rec.setUint32(o, (s * 250 + j) % 2048, Endian.little);
      for (var c = 0; c < 4; c++) {
        rec.setFloat32(o + 4 + 4 * c, rows[j][c] * 1e-6, Endian.little);
      }
    }
  }
  final stem = fileStem(DateTime.fromMillisecondsSinceEpoch((t0 * 1000).round()));
  final f = File('${dir.path}/$stem.f32')..writeAsBytesSync(rec.buffer.asUint8List());
  final idx = ByteData(seconds * indexBytes);
  for (var k = 0; k < seconds; k++) {
    idx
      ..setFloat64(k * indexBytes, t0 + k + 1, Endian.little)
      ..setUint64(k * indexBytes + 8, k * 250, Endian.little);
  }
  File('${dir.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
  return f;
}

void addMarker(File f32, double t, String text) =>
    File(f32.path.replaceFirst(RegExp(r'\.f32$'), '.markers.jsonl')).writeAsStringSync(
      '${jsonEncode({'t': t, 'i': 0, 'text': text})}\n',
      mode: FileMode.append,
    );

Map<String, dynamic> roundTrip(Map<String, Object?> m) => jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('drift_report_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('lights off, as night_drift.py', () {
    test('which marker texts mean lights off', () {
      expect(lightsOffFrom('lights off'), LightsOffFrom.button);
      expect(lightsOffFrom('dream catcher: lights off; rounds 4, ending wake, round 1 timer 812 s'), LightsOffFrom.dreamCatcher);
      expect(lightsOffFrom('sound: quiet minute (eyes closed)'), LightsOffFrom.sound);
      expect(lightsOffFrom('sound: quiet minute (eyes open)'), isNull);
      expect(lightsOffFrom('drift-off: drowsy'), isNull);
      expect(lightsOffFrom('morning:start'), isNull);
      expect(lightsOffFrom('Lights off'), isNull, reason: 'only the app\'s own texts');
    });

    test('the latest lights-off marker of the night, by its time, whichever file holds it', () {
      final a = File('${dir.path}/2026-11-18-230000.f32')..writeAsBytesSync([0]);
      final b = File('${dir.path}/2026-11-18-233000.f32')..writeAsBytesSync([0]);
      addMarker(a, 1000, 'dream catcher: lights off; rounds 3');
      addMarker(a, 1500, 'lights off');
      addMarker(a, 1600, 'drift-off: drowsy');
      addMarker(b, 1200, 'sound: quiet minute (eyes closed)');
      File('${dir.path}/2026-11-18-233000.markers.jsonl').writeAsStringSync('not json\n{"text": "lights off"}\n', mode: FileMode.append);
      final lo = lightsOffIn([a, b])!;
      expect((lo.t, lo.from), (1500.0, LightsOffFrom.button));
      expect(lightsOffIn([b])!.from, LightsOffFrom.sound);
      expect(lightsOffIn([File('${dir.path}/2026-11-18-235959.f32')]), isNull, reason: 'no markers file');
    });

    test('lights off lands on the next 30 s epoch of the night, never before its first sample', () {
      const start = 1795468320;
      expect(lightsOffSecond(start + 31.2, start), 60);
      expect(lightsOffSecond(start + 30.0, start), 30);
      expect(lightsOffSecond(start + 0.0, start), 0);
      expect(lightsOffSecond(start - 400.0, start), 0, reason: 'tapped while the headband was still being found');
    });

    test('the sleep model\'s onset: the first of 10 epochs in a row not scored awake, missing ones skipped', () {
      final stages = [...rep(w, 3), ...rep(n1, 9), w, ...rep(n2, 4), ...rep(gap, 3), ...rep(n2, 7), ...rep(w, 2)];
      expect(modelOnset(stages, 0), 13, reason: '9 then a wake epoch; the run from 13 jumps the gap');
      expect(modelOnset(stages, 14), 14);
      expect(modelOnset(stages, 16), isNull, reason: 'only 8 sleep epochs from 16 on');
      expect(modelOnset(rep(n2, 10), 0), 0);
      expect(modelOnset(rep(n2, 9), 0), isNull);
      expect(modelOnset(rep(n2, 12), 40), isNull, reason: 'lights off after the last epoch');
    });
  });

  group('the report\'s drift_off', () {
    final start = DateTime(2026, 11, 18, 23, 10);
    // lights off at 23:40 (epoch 60); the model: awake until epoch 96, then sleep (onset 18 min after lights off)
    final stages = [...rep(w, 96), ...rep(n2, 60)];

    Map<String, dynamic> report(DriftSeen s) => roundTrip(driftReport(s, stages, start));

    test('both found sleep 0.5 min apart: they agree and the night counts', () {
      const s = DriftSeen(
        lightsOffS: 1800,
        from: LightsOffFrom.button,
        tapped: 1795468320 + 1790.4,
        baselineS: 1889,
        drowsyS: 2909,
        onsetS: 2850,
        knownS: 3029,
        epochs: 'bbaaaaaaaadds',
      );
      final j = report(s);
      expect(j['version'], driftVersion);
      expect(j['validated'], false);
      expect(j['lights_off'], isoLocal(start.add(const Duration(seconds: 1800))));
      expect(j['lights_off_s'], 1800);
      expect(j['source'], 'button');
      expect(j['tapped'], isoLocal(DateTime.fromMicrosecondsSinceEpoch(((1795468320 + 1790.4) * 1e6).round())));
      expect((j['baseline_s'], j['drowsy_s'], j['onset_s'], j['known_s']), (1889, 2909, 2850, 3029));
      expect(j['model_onset_s'], 2880);
      expect((j['onset_min'], j['model_onset_min'], j['diff_min']), (17.5, 18.0, -0.5));
      expect((j['agree'], j['counted']), (true, true));
      expect(j['epochs'], 'bbaaaaaaaadds');
      expect(j['onset'], isoLocal(start.add(const Duration(seconds: 2850))));
      expect(j['model_onset'], isoLocal(start.add(const Duration(seconds: 2880))));
    });

    test('5 minutes apart still agree; 5.5 do not', () {
      DriftSeen at(int onset) => DriftSeen(lightsOffS: 1800, from: LightsOffFrom.button, onsetS: onset);
      expect(report(at(2880 + 300))['agree'], true);
      expect(report(at(2880 - 300))['agree'], true);
      expect(report(at(2880 + 330))['agree'], false);
      expect(report(at(2880 + 330))['diff_min'], 5.5);
    });

    test('only one of them found sleep: they disagree; neither: not counted', () {
      final missed = report(const DriftSeen(lightsOffS: 1800, from: LightsOffFrom.button));
      expect((missed['onset_min'], missed['model_onset_min'], missed['diff_min']), (null, 18.0, null));
      expect((missed['agree'], missed['counted']), (false, true));
      final awake = roundTrip(driftReport(
        const DriftSeen(lightsOffS: 1800, from: LightsOffFrom.dreamCatcher, onsetS: 2850),
        rep(w, 156),
        start,
      ));
      expect((awake['model_onset_min'], awake['agree'], awake['counted']), (null, false, true));
      final neither = roundTrip(driftReport(const DriftSeen(lightsOffS: 1800, from: LightsOffFrom.sound), rep(w, 156), start));
      expect((neither['agree'], neither['counted']), (null, false));
    });

    test('lights off never given (the night\'s start): shown, not counted', () {
      final j = report(const DriftSeen(lightsOffS: 0, from: LightsOffFrom.nightStart, onsetS: 2880));
      expect((j['source'], j['tapped'], j['onset_min'], j['model_onset_min']), ('night start', null, 48.0, 48.0));
      expect((j['agree'], j['counted']), (true, false));
    });

    test('read back from the report', () {
      final json = roundTrip(driftReport(
        const DriftSeen(lightsOffS: 1800, from: LightsOffFrom.button, tapped: 1795470110.4, onsetS: 2850),
        stages,
        start,
      ));
      final d = DriftResult.read(json)!;
      expect(d.lightsOff, start.add(const Duration(minutes: 30)));
      expect(d.from, LightsOffFrom.button);
      expect((d.onsetMin, d.modelOnsetMin, d.diffMin, d.agree, d.counted), (17.5, 18.0, -0.5, true, true));
      expect(DriftResult.read(null), isNull);
      expect(DriftResult.read({'lights_off': 'garbage'}), isNull);
    });
  });

  group('the check: 4 of 5 nights within 5 minutes', () {
    SleepReport night(String nightOf, {bool? agree, String from = 'button', bool hasDrift = true}) => SleepReport({
      'night_of': nightOf,
      if (hasDrift)
        'drift_off': {
          'lights_off': '${nightOf}T23:30:00+03:00',
          'source': from,
          'agree': agree,
          'counted': from != 'night start' && agree != null,
        },
    });

    test('counts the newest 5 counted nights; trusted at 4 of them', () {
      final none = driftCheck(const []);
      expect((none.agree, none.nights, none.trusted), (0, 0, false));
      final reports = [
        night('2026-11-25', agree: true),
        night('2026-11-24', agree: null), // no sleep found by either: not counted
        night('2026-11-23', agree: false, from: 'night start'), // Lights off not given: not counted
        night('2026-11-22', agree: true),
        night('2026-11-21', hasDrift: false), // scored before the detector was in the report
        night('2026-11-20', agree: false),
        night('2026-11-19', agree: true),
      ];
      final c = driftCheck(reports);
      expect((c.agree, c.nights, c.decided, c.trusted), (3, 4, false, false));
      final more = driftCheck([night('2026-11-26', agree: true), ...reports]);
      expect((more.agree, more.nights, more.decided, more.trusted), (4, 5, true, true));
      final later = driftCheck([night('2026-11-27', agree: false), night('2026-11-26', agree: true), ...reports]);
      expect((later.agree, later.nights, later.trusted), (3, 5, false), reason: 'the 19th dropped out of the newest 5');
    });
  });

  group('the night pass runs the detector from lights off', () {
    const t0 = 1795468320.0; // a whole second
    test('a Lights off marker: the detector counts from the next epoch and finds the fade', () {
      // lights off at 65.3 s: epoch 90 s; full alpha (the baseline) until 240 s, then a quarter of it
      final f = writeDriftRun(dir, t0, 480, fadeAtS: 240);
      addMarker(f, t0 + 65.3, 'lights off');
      final seen = seeNight([f])!;
      final d = seen.drift!;
      expect(seen.driftError, isNull);
      expect((d.lightsOffS, d.from, d.tapped), (90, LightsOffFrom.button, t0 + 65.3));
      expect(d.baselineS, 149, reason: '60 clean seconds from 90');
      expect(d.onsetS, 240);
      expect(d.knownS, 419, reason: 'the end of the sixth faded epoch');
      expect(d.drowsyS, 299);
      expect(d.epochs, 'baaaaaddddsss');
      expect(d.epochs.substring(5, 11), 'adddds');
    });

    test('no marker: the night\'s first sample is lights off', () {
      final f = writeDriftRun(dir, t0, 330, fadeAtS: 120);
      final d = seeNight([f])!.drift!;
      expect((d.lightsOffS, d.from, d.tapped), (0, LightsOffFrom.nightStart, null));
      expect((d.baselineS, d.onsetS, d.knownS), (59, 120, 299));
    });

    test('the report gets drift_off from the pass, and a null with the reason when the pass failed', () {
      Map<String, dynamic> build({NightSeen? seen, String? error}) => roundTrip(buildReport(
        nightOf: '2026-11-18',
        built: DateTime(2026, 11, 19, 7),
        scoringSeconds: 40,
        start: DateTime(2026, 11, 18, 23),
        lengthSeconds: 156 * 30.0,
        inputs: const {'a.f32': 1000},
        model: phoneModelId,
        stages: [...rep(w, 96), ...rep(n2, 60)],
        seen: seen,
        extrasError: error,
      ));
      const drift = DriftSeen(lightsOffS: 1800, from: LightsOffFrom.button, onsetS: 2850);
      final ok = build(seen: NightSeen(quality: List.filled(156, EpochQuality.good), bursts: const [], moves: const [], drift: drift));
      expect((ok['drift_off'] as Map)['onset_min'], 17.5);
      expect(ok['drift_off_error'], isNull);
      expect(ok['version'], 2, reason: 'additive: the version stays');
      final failed = build(error: 'out of memory');
      expect(failed.containsKey('drift_off'), isTrue);
      expect((failed['drift_off'], failed['drift_off_error']), (null, 'out of memory'));
      final noDrift = build(
        seen: NightSeen(quality: List.filled(156, EpochQuality.good), bursts: const [], moves: const [], driftError: 'bad marker'),
      );
      expect((noDrift['drift_off'], noDrift['drift_off_error']), (null, 'bad marker'));
      expect(noDrift['extras'], isNotNull, reason: 'the extras do not depend on the detector');
    });

    test('a report written before drift_off existed is kept; it counts as from an older scorer (row 580)', () {
      final rep2 = SleepReport({
        'version': reportVersion,
        'night_of': '2026-11-18',
        'inputs': [
          {'file': 'a.f32', 'bytes': 1000},
        ],
      });
      expect(isStale(const {'a.f32': 1000}, rep2), isFalse);
      expect(scoredByOlder(rep2, model: phoneModelId), isTrue);
      final now = SleepReport({...rep2.json, 'drift_off': null, 'rem_check': null, 'walking': null});
      expect(isStale(const {'a.f32': 1000}, now), isFalse);
      expect(scoredByOlder(now, model: phoneModelId), isFalse);
    });
  });
}
