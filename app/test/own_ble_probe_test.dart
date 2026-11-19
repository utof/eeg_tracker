// The phone's probe of our own connection (lib/headband/own/probe.dart) on the fake headband, at 40 times real
// time: the steps, the files it writes, and the plain verdict, for a headband that behaves as assumed and for ones
// that do not (another channel order, no command 5, pairing needed, switched off).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/headband/own/probe.dart';
import 'package:eeg_tracker/headband/own/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'own_ble/fake_head.dart';
import 'own_ble/fake_headband.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('own_ble_probe'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('headband on, behaving as assumed: every check passes and the files are written', () async {
    final head = Head();
    final r = await head.probe(dir).run();
    final v = r.verdict;
    expect(r.summary['error'], isNull);
    expect(v.passed, isTrue, reason: r.text);
    expect(v.worn, isTrue);
    expect(v.command5, isTrue);
    expect(v.needsPairing, isFalse);
    expect(v.layout, isNull, reason: 'the assumed order was right: nothing to change');
    expect(v.line, startsWith('Passed.'));
    final checks = (r.summary['verdict']! as Map).cast<String, bool?>();
    expect(checks, {
      'rate_250': true,
      'packet_108_bytes': true,
      'counter_counts_samples': true,
      'no_lost_samples': true,
      'alpha_on_assumed_back_slots': true,
      'order_matches_default': true,
      'resist_order_matches_default': true,
      'command2_stops_signal': true,
      'command4_gives_resistance': true,
      'command5_signal': true,
      'command5_resistance': true,
      'signal_restarts_after_resistance': true,
    });
    expect(r.summary['suggested_order'], 'O2,T3,T4,O1');
    expect(r.summary['suggested_resist_order'], 'O2,T3,T4,O1');
    expect(r.summary['direct_connect'], 'worked');
    expect(head.hb.scans, 0);
    expect(head.hb.commands, [cmdSignal, cmdIdle, cmdResist, cmdIdle, cmdSignalResist, cmdIdle, cmdSignal, cmdIdle]);
    expect(head.hb.link, isNull);

    // The steps the owner sees, in order, with their tones.
    final shown = [for (final s in head.steps) if (s.text != null) s.name];
    expect(shown.take(5), ['ready', 'signal', 'eyes_closed', 'eyes_open', 'rest']);
    expect(shown, containsAllInOrder(['lift_O1', 'lift_O2', 'lift_T3', 'lift_T4', 'resist', 'resist_lift_O1', 'resist_lift_T4', 'done']));
    expect(head.steps.firstWhere((s) => s.name == 'eyes_closed').cue, ProbeCue.closeEyes);
    expect(head.steps.firstWhere((s) => s.name == 'eyes_open').cue, ProbeCue.openEyes);
    expect(head.steps.firstWhere((s) => s.name == 'lift_T3').text, 'Lift the LEFT TEMPLE electrode off the skin now.');
    expect(head.steps.last.index, head.steps.last.total);

    // The result folder: app-private, one per run, everything the laptop needs.
    expect(r.dir.parent.path, dir.path);
    expect(r.note().folder, 'own-ble/probe/${r.stamp}');
    expect(r.note().passed, isTrue);
    final have = [for (final f in r.dir.listSync()) f.uri.pathSegments.last]..sort();
    expect(have, ['decoded.csv', 'gatt.txt', 'probe.log', 'raw.txt', 'summary.json', 'summary.txt']);
    final saved = jsonDecode(File('${r.dir.path}/summary.json').readAsStringSync()) as Map<String, Object?>;
    expect((saved['plain']! as Map)['passed'], isTrue);
    expect(saved['service'], fakeUuid(1, '7'));
    expect((saved['device']! as Map)['firmware'], '1.10.0');
    final text = File('${r.dir.path}/summary.txt').readAsStringSync();
    expect(text, contains('VERDICT: Passed.'));
    expect(text, contains('250 Hz: yes   108-byte packets: yes   counter counts samples (+8): yes'));
    expect(text, contains('command 5: signal yes, resistance yes   signal starts again after resistance: yes'));
    final gatt = File('${r.dir.path}/gatt.txt').readAsStringSync();
    expect(gatt, contains('service ${fakeUuid(1, '7')}'));
    expect(gatt, contains("char 00002a26-0000-1000-8000-00805f9b34fb [read] = 312e31302e30 '1.10.0'"));
    final raw = File('${r.dir.path}/raw.txt').readAsLinesSync();
    expect(raw.length, greaterThan(3000));
    expect(raw.first, matches(RegExp(r'^\d+\.\d{3} signal 7e400004 108 [0-9a-f]{216}$')));
    expect(raw.any((l) => l.contains(' resist 7e400005 20 ')), isTrue);
    final csv = File('${r.dir.path}/decoded.csv').readAsLinesSync();
    expect(csv.first, 't,step,counter,k,marker,slot0_O2,slot1_T3,slot2_T4,slot3_O1');
    expect(csv.length, greaterThan(20000));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('another channel order than assumed: the lifts find it and the verdict hands it over', () async {
    final head = Head();
    final assumed = Layout(order: ['T3', 'T4', 'O1', 'O2'], resistOrder: ['T3', 'T4', 'O1', 'O2']);
    final r = await head.probe(dir, layout: assumed).run();
    expect(r.summary['suggested_order'], 'O2,T3,T4,O1');
    expect((r.summary['verdict']! as Map)['order_matches_default'], isFalse);
    expect((r.summary['verdict']! as Map)['alpha_on_assumed_back_slots'], isFalse);
    expect(r.verdict.passed, isTrue, reason: 'the order is settled, only not as assumed');
    expect(r.verdict.layout!.order, ['O2', 'T3', 'T4', 'O1']);
    expect(r.verdict.layout!.resistOrder, ['O2', 'T3', 'T4', 'O1']);
    expect(r.verdict.lines.any((l) => l.$2.contains('The app will use what it found')), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('headband on the desk: the protocol steps only, so not a full pass', () async {
    final head = Head();
    final r = await head.probe(dir, worn: false).run();
    expect(r.summary['error'], isNull);
    expect(r.verdict.passed, isFalse);
    expect(r.verdict.worn, isFalse);
    expect(r.verdict.command5, isTrue);
    expect(r.verdict.line, contains('Run it once with the headband on'));
    expect(head.steps.where((s) => s.text != null).map((s) => s.name), ['done']);
    expect((r.summary['verdict']! as Map).containsKey('order_matches_default'), isFalse);
  });

  test('a headband without command 5: said plainly, the rest still counts', () async {
    final head = Head(ignoreCmd5: true);
    final r = await head.probe(dir, worn: false).run();
    expect(r.verdict.command5, isFalse);
    expect((r.summary['verdict']! as Map)['command5_signal'], isFalse);
    expect((r.summary['verdict']! as Map)['signal_restarts_after_resistance'], isTrue);
    expect(r.verdict.lines.any((l) => l.$1 == false && l.$2.contains('command 5) does not work')), isTrue);
  });

  test('a headband that needs pairing: the verdict says how; with pairing on it goes through', () async {
    final head = Head(needsPairing: true);
    final r = await head.probe(dir, worn: false).run();
    expect(r.verdict.needsPairing, isTrue);
    expect(r.verdict.passed, isFalse);
    expect(r.verdict.line, contains('Hold its button 4 seconds'));
    expect(File('${r.dir.path}/summary.txt').readAsStringSync(), contains('STOPPED EARLY: connect:'));
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // the next run gets its own folder (stamp)
    final again = await head.probe(dir, worn: false, pair: true).run();
    expect(again.summary['error'], isNull);
    expect(again.verdict.needsPairing, isFalse);
    expect(head.hb.paired, isTrue);
    expect(dir.listSync(), hasLength(2));
  });

  test('headband switched off: an early stop with its files, never an exception', () async {
    final head = Head()..hb.awayUntil = DateTime.now().add(const Duration(hours: 1));
    final r = await head.probe(dir).run();
    expect(r.summary['error'], contains('connect'));
    expect(r.verdict.passed, isFalse);
    expect(r.verdict.line, contains("BrainBit's SDK stays in use"));
    expect(File('${r.dir.path}/gatt.txt').readAsStringSync(), 'not connected\n');
    expect(File('${r.dir.path}/summary.json').existsSync(), isTrue);
  });

  test('a known address that does not answer: it scans by name and says so', () async {
    final head = Head()..hb.directFails = true;
    final r = await head.probe(dir, worn: false).run();
    expect(r.summary['error'], isNull);
    expect('${r.summary['direct_connect']}', startsWith('failed:'));
    expect(head.hb.scans, 1);
    expect(r.summary['rssi'], -61);
  });

  test('stopped by the owner: it ends at once and keeps what it has', () async {
    final head = Head();
    final p = head.probe(dir, worn: false);
    final running = p.run();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    p.cancel();
    final r = await running;
    expect(r.summary['error'], contains('stopped by you'));
    expect(head.hb.link, isNull);
    expect(head.hb.commands.last, cmdIdle);
  });

  test('the noise level is compared with a recording made through BrainBit\'s SDK', () async {
    final rec = Directory('${dir.path}/recordings')..createSync();
    final rng = math.Random(3);
    double gauss() {
      final u = 1 - rng.nextDouble(), v = rng.nextDouble();
      return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
    }

    void write(String stem, double sdUv, {String log = 'connected BB Black'}) {
      final b = ByteData(20 * 250 * 70);
      for (var i = 0; i < 250 * 70; i++) {
        b.setUint32(20 * i, i, Endian.little);
        for (var j = 0; j < 4; j++) {
          b.setFloat32(20 * i + 4 + 4 * j, sdUv * 1e-6 * gauss(), Endian.little);
        }
      }
      File('${rec.path}/$stem.f32').writeAsBytesSync(b.buffer.asUint8List());
      File('${rec.path}/$stem.log').writeAsStringSync('$log\n');
    }

    write('2026-11-17-230000', 4);
    write('2026-11-18-230000', 40, log: 'driver own Bluetooth LE (lib/headband/own)'); // ours: never the reference
    File('${rec.path}/2026-11-19-010000.f32').writeAsBytesSync(Uint8List(200)); // too short
    final ref = newestSdkRecording(rec)!;
    expect(ref.path, endsWith('2026-11-17-230000.f32'));
    expect(sdkReference(ref)['O1']!['diff_rms'], closeTo(4 * math.sqrt2, 0.4));
    final r = await Head().probe(Directory('${dir.path}/probe'), worn: false, sdkRef: ref).run();
    final ratio = ((r.summary['sdk_reference']! as Map)['ratio_diff_rms']! as Map).cast<String, num>();
    expect(ratio.keys, names);
    for (final x in ratio.values) {
      expect(x, closeTo(1, 0.25)); // the fake head has the same 4 µV noise
    }
    expect(r.verdict.lines.any((l) => l.$1 == true && l.$2.contains('the scale looks right')), isTrue);
    expect(newestSdkRecording(Directory('${dir.path}/none')), isNull);
  });

  test('analysis helpers give the laptop probe\'s numbers', () {
    List<double> sine(double amp, double hz) => [for (var k = 0; k < fs * 10; k++) amp * math.sin(2 * math.pi * hz * k / fs)];
    expect(bandPower(sine(20, 10)) / bandPower(sine(5, 10)), closeTo(16, 1e-6));
    expect(bandPower(sine(20, 25)), lessThan(0.01 * bandPower(sine(20, 10))));
    expect(bandPower([1, 2, 3]).isNaN, isTrue);
    final lifts = {
      'O1': <String, Object?>{'slot': 3},
      'O2': <String, Object?>{'slot': 0},
      'T3': <String, Object?>{'slot': 1},
      'T4': <String, Object?>{'slot': 2},
    };
    expect(orderFrom(lifts), 'O2,T3,T4,O1');
    expect(orderFrom({...lifts, 'T4': <String, Object?>{'slot': 1}}), isNull);
    final s = stats([1, 2, 3, 4, 5]);
    expect(s['mean'], 3);
    expect(s['sd'], closeTo(math.sqrt(2.5), 1e-12));
    expect(s['diff_rms'], 1);
    expect(stats([1]), {'n': 1});
  });
}
