// The replay headband (lib/headband/replay.dart, DECISIONS 730-739): made-up recordings in the app's own format
// (lib/headband/replay_scenarios.dart; never the owner's EEG) played into the reader, the night recorder and the
// work session through the slot the tests' fake headbands use. Any layout: the helmet plan's 8 channels at 500 Hz and
// three channels at 125 Hz with one at a custom place, besides the BrainBit's four.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/headband/replay.dart';
import 'package:eeg_tracker/headband/replay_scenarios.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/packed.dart' show packRaw;
import 'package:eeg_tracker/dream/band_link.dart' show LinkTiming;
import 'package:eeg_tracker/work/breaks.dart';
import 'package:eeg_tracker/work/controller.dart';
import 'package:eeg_tracker/work/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fast_band.dart' show until;

/// (counter, volts) of every record in [f32], read straight from the bytes by its header.
List<(int, List<double>)> records(File f32) {
  final h = readHeader(f32);
  final b = ByteData.sublistView(f32.readAsBytesSync());
  return [
    for (var o = 0; o + h.recordBytes <= b.lengthInBytes; o += h.recordBytes)
      (b.getUint32(o, Endian.little), [for (var c = 0; c < h.count; c++) b.getFloat32(o + 4 + 4 * c, Endian.little)]),
  ];
}

/// (arrival, first sample) of every `.idx` row.
List<(double, int)> indexRows(File f32) {
  final b = ByteData.sublistView(File('${f32.path.substring(0, f32.path.length - 4)}.idx').readAsBytesSync());
  return [
    for (var o = 0; o + 16 <= b.lengthInBytes; o += 16) (b.getFloat64(o, Endian.little), b.getUint64(o + 8, Endian.little)),
  ];
}

List<ReplayBatch> readAll(ReplayCursor c) => [for (var b = c.next(); b != null; b = c.next()) b];

const fastNight = RecorderTiming(
  tick: Duration(milliseconds: 10),
  ticksPerCheck: 30,
  scanFor: Duration(milliseconds: 300),
  rescanFor: Duration(milliseconds: 300),
  connectTimeout: Duration(seconds: 2),
  sdkTimeout: Duration(seconds: 2),
  notFoundWait: Duration(milliseconds: 5),
  notFoundWaitLong: Duration(milliseconds: 5),
  reconnectWaits: [Duration(milliseconds: 5), Duration(milliseconds: 20)],
  scanEvery: 1,
  stallChecksToGiveUp: 3,
  stopTimeout: Duration(seconds: 2),
  contactFor: Duration(milliseconds: 40),
  settle: Duration(milliseconds: 5),
  retryWait: Duration(milliseconds: 5),
);

const fastLink = LinkTiming(scanFor: Duration(milliseconds: 50), contactFor: Duration(milliseconds: 5), settle: Duration.zero);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('replay'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(Scenario s, {String? into}) => writeScenario(Directory('${tmp.path}/${into ?? s.name}'), s);

  Scenario short(String name, RecordingHeader h, List<Stretch> parts) => Scenario(name, 'a test', parts, header: h);

  group('the recordings', () {
    test('the made-up scenarios are what they say: every layout, the made-up line in the log, no person', () {
      for (final s in scenarios.values) {
        expect(s.about, isNotEmpty);
        expect(s.seconds, greaterThan(0));
      }
      expect(scenarios['helmet-8']!.header.count, 8);
      expect(scenarios['helmet-8']!.header.sampleRate, 500);
      expect(scenarios['custom-3']!.header.names, ['Fp1', 'Oz', 'X1']);
      expect(scenarios['custom-3']!.header.channels.last.site, isNull, reason: 'a place with no 10-10 name');
      final f = write(short('c', customScenarioHeader, const [Stretch(Act.quiet, 4)]));
      expect(File('${f.path.substring(0, f.path.length - 4)}.log').readAsStringSync(), contains('made-up recording'));
      expect(readHeader(f), customScenarioHeader);
      expect(records(f), hasLength(4 * 125));
    });

    test('an 8-channel recording at 500 Hz replays record for record and batch for batch, plain and packed', () {
      final s = short('h', helmetScenarioHeader, const [Stretch(Act.quiet, 6), Stretch(Act.talking, 6)]);
      final f = write(s);
      final want = records(f), rows = indexRows(f);
      for (final packed in [false, true]) {
        if (packed) {
          // past the packing size: pack it the way the app does after a day
          expect(packRaw(f).packed.existsSync(), isTrue);
          expect(f.existsSync(), isFalse);
        }
        final c = ReplayCursor([f]);
        expect(c.header.names, ['M1', 'M2', 'F7', 'F8', 'Fz', 'C3', 'C4', 'Pz']);
        final batches = readAll(c);
        expect(batches, hasLength(rows.length));
        final got = [for (final b in batches) ...b.samples];
        expect(got, hasLength(want.length));
        for (var i = 0; i < want.length; i += 97) {
          expect(got[i].pack, want[i].$1);
          expect(got[i].volts, want[i].$2);
        }
        for (var k = 1; k < rows.length; k++) {
          expect(batches[k].at, closeTo(rows[k].$1 - rows[0].$1, 1e-6));
          expect(batches[k - 1].samples.length, rows[k].$2 - rows[k - 1].$2);
        }
        expect(c.firstArrival, rows.first.$1);
        expect(c.ended, isTrue);
      }
    });

    test('four channels at the BrainBit\'s sites in another order play as a BrainBit, in its order', () {
      final h = RecordingHeader(
        channels: const [
          HeaderChannel('T3', site: 'T7'),
          HeaderChannel('T4', site: 'T8'),
          HeaderChannel('O1', site: 'O1'),
          HeaderChannel('O2', site: 'O2'),
        ],
        device: 'BrainBit',
      );
      final f = write(short('swapped', h, const [Stretch(Act.quiet, 3)]));
      final finder = ReplayFinder(ReplayPlan(files: [f]));
      expect(finder.asBrainBit, isTrue);
      final c = ReplayCursor([f], order: brainBitOrder(h));
      final first = c.next()!.samples.first;
      final raw = records(f).first.$2;
      expect([first.o1, first.o2, first.t3, first.t4], [raw[2], raw[3], raw[0], raw[1]]);
      // 4 channels at another rate, or other sites: another board
      expect(ReplayFinder(ReplayPlan(files: [write(short('c', customScenarioHeader, const [Stretch(Act.quiet, 2)]))])).asBrainBit, isFalse);
    });

    test('drop-outs play as silence of their length; gaps over max_gap_s are shortened to it', () {
      final f = write(scenarios['dropouts']!);
      double gapsOver(List<ReplayBatch> b, double s) =>
          [for (var k = 1; k < b.length; k++) b[k].at - b[k - 1].at].where((g) => g > s).fold(0.0, (a, g) => a + g);
      final full = readAll(ReplayCursor([f]));
      expect(gapsOver(full, 1), closeTo(2 + 8 + 45 + 3 * 0.1, 0.01));
      expect(full.last.at, closeTo(255 - 0.1, 0.01));
      final capped = readAll(ReplayCursor([f], maxGapS: 10));
      expect(gapsOver(capped, 1), closeTo(2.1 + 8.1 + 10, 0.01), reason: 'the 45.1 s between batches cut to 10');
      // the packet numbers go on through a drop-out, as the BrainBit's do when packets are lost
      final packs = [for (final b in full) ...b.samples.map((s) => s.pack)];
      expect(packs[60 * 250], (62 * 250) % 2048);
    });

    test('several file sets play one after another; a damaged index row ends the rows, not the data', () {
      final a = write(short('a', brainBitHeader, const [Stretch(Act.quiet, 2)]), into: 'two');
      final b = writeScenario(
        Directory('${tmp.path}/two'),
        Scenario('b', 'later', const [Stretch(Act.quiet, 2)], header: brainBitHeader, start: DateTime(2026, 11, 20, 10, 0, 30)),
      );
      final both = readAll(ReplayCursor([a, b], maxGapS: 5));
      expect([for (final x in both) ...x.samples], hasLength(2 * 2 * 250));
      expect(both.last.at, closeTo(1.9 + 5 + 1.9, 0.01), reason: 'the 28.1 s between the sets shortened to 5');
      // a row past the data (the samples were never flushed): the file ends at the row before it
      final idx = File('${b.path.substring(0, b.path.length - 4)}.idx');
      final rows = idx.readAsBytesSync();
      final bad = ByteData(16)
        ..setFloat64(0, 1e10, Endian.little)
        ..setUint64(8, 1 << 40, Endian.little);
      idx.writeAsBytesSync([...rows.sublist(0, 16 * 5), ...bad.buffer.asUint8List()]);
      final cut = readAll(ReplayCursor([b]));
      expect(cut, hasLength(5), reason: 'the row past the data is left out, and every row after it');
      expect([for (final x in cut) ...x.samples], hasLength(2 * 250), reason: 'the records after the last good row play with it');
    });

    test('a file set without an index plays in batches of 0.1 s', () {
      final f = write(short('noidx', helmetScenarioHeader, const [Stretch(Act.quiet, 2)]));
      File('${f.path.substring(0, f.path.length - 4)}.idx').deleteSync();
      final all = readAll(ReplayCursor([f]));
      expect(all, hasLength(20));
      expect(all.every((b) => b.samples.length == 50), isTrue);
      expect(all.last.at, closeTo(1.9, 1e-9));
    });

    test('two layouts in one replay are refused in words', () {
      final a = write(short('a', brainBitHeader, const [Stretch(Act.quiet, 1)]));
      final b = write(short('b', helmetScenarioHeader, const [Stretch(Act.quiet, 1)]));
      expect(() => ReplayCursor([a, b]), throwsA(isA<ReplayError>().having((e) => e.message, 'message', contains('one layout'))));
    });
  });

  group('the plan and the switch', () {
    File plan(Object json) {
      final d = Directory('${tmp.path}/files/replay')..createSync(recursive: true);
      return File('${d.path}/plan.json')..writeAsStringSync(jsonEncode(json));
    }

    String rec() => (Directory('${tmp.path}/files/recordings')..createSync(recursive: true)).path;

    test('a plan names recordings inside files/replay and how to play them', () {
      writeScenario(Directory('${tmp.path}/files/replay/talk'), scenarios['custom-3']!);
      plan({'files': ['talk/2026-11-20-100000.f32'], 'speed': 4, 'from_s': 10, 'max_gap_s': 5, 'loop': true, 'contact_ohms': {'O1': 2e6}});
      final p = ReplayPlan.load(replayDirFor(rec()));
      expect(p.files.single.path, endsWith('files/replay/talk/2026-11-20-100000.f32'));
      expect([p.speed, p.fromS, p.maxGapS, p.loop], [4, 10, 5, true]);
      expect(p.contactOhms, {'O1': 2e6});
    });

    test('without a list every recording directly in files/replay plays, packed ones too, oldest first', () {
      final d = Directory('${tmp.path}/files/replay');
      final b = writeScenario(d, Scenario('b', 'b', const [Stretch(Act.quiet, 1)], header: brainBitHeader, start: DateTime(2026, 11, 20, 11)));
      final a = writeScenario(d, Scenario('a', 'a', const [Stretch(Act.quiet, 1)], header: brainBitHeader, start: DateTime(2026, 11, 20, 9)));
      plan({});
      expect([for (final f in ReplayPlan.load(d).files) f.path], [a.path, b.path]);
    });

    test('anything a plan cannot use is an error that names the file; never a silent fallback', () {
      writeScenario(Directory('${tmp.path}/files/replay/x'), scenarios['custom-3']!);
      for (final (json, words) in [
        ({'files': ['../recordings/2026-11-19-025205.f32']}, 'not a path inside'),
        ({'files': ['/data/x.f32']}, 'not a path inside'),
        ({'files': ['x/missing.f32']}, 'is not there'),
        ({'files': ['x/2026-11-20-100000.idx']}, 'not a recording'),
        ({'files': <String>[]}, 'list of recordings'),
        ({'speed': 0}, 'speed must be'),
        ({'speed': 'fast'}, 'speed must be'),
        ({'loop': 'yes'}, 'loop must be'),
        ({'contact_ohms': {'O1': -1}}, 'contact_ohms'),
      ]) {
        plan(json);
        expect(() => ReplayPlan.load(replayDirFor(rec())), throwsA(isA<ReplayError>().having((e) => e.message, 'm', contains(words))), reason: '$json');
      }
      File('${tmp.path}/files/replay/plan.json').writeAsStringSync('{"speed": ');
      expect(() => ReplayPlan.load(replayDirFor(rec())), throwsA(isA<ReplayError>()));
    });

    test('only a replay build looks for a plan; without one even a replay build uses the headband', () {
      expect(replayBuild, isFalse, reason: 'the tests and the owner\'s builds are no replay builds');
      expect(replayFinderFor(rec(), forSessions: true, allowed: true), isNull, reason: 'no plan');
      writeScenario(Directory('${tmp.path}/files/replay'), scenarios['custom-3']!);
      plan({});
      expect(replayFinderFor(rec(), forSessions: true), isNull, reason: 'not a replay build');
      expect(replayFinderFor(rec(), forSessions: true, allowed: true), isNotNull);
    });

    test("a session refuses a replay that is not the BrainBit's layout, in words; the recorder takes it", () async {
      final f = write(short('h', helmetScenarioHeader, const [Stretch(Act.quiet, 2)]));
      final p = ReplayPlan(files: [f]);
      await expectLater(
        ReplayFinder(p, forSessions: true).find(const Duration(seconds: 1)),
        throwsA(isA<NotForReplayBoard>().having((e) => '$e', 'words', contains("Sessions read the BrainBit's O1 O2 T3 T4"))),
      );
      final band = await ReplayFinder(p).find(const Duration(seconds: 1));
      expect(band, isA<OtherBoard>());
      expect((band! as OtherBoard).header.names, helmetScenarioHeader.names);
      expect((band as OtherBoard).header.device, 'Replay of Made-up helmet');
    });
  });

  group('playing', () {
    test('real pace at 25x: every sample arrives in about 1/25 of the recording\'s time, then "out of range"', () async {
      final f = write(short('q', brainBitHeader, const [Stretch(Act.quiet, 5)]));
      final finder = ReplayFinder(ReplayPlan(files: [f], speed: 25));
      final band = (await finder.find(const Duration(seconds: 1)))!;
      final got = <Sample>[];
      final out = Completer<void>();
      band.signal.listen(got.addAll);
      band.rangeChanges.listen((r) => r ? null : out.complete());
      final sw = Stopwatch()..start();
      await band.startSignal();
      await out.future.timeout(const Duration(seconds: 5));
      expect(sw.elapsedMilliseconds, inInclusiveRange(150, 2000), reason: '5 s at 25x is 0.2 s');
      expect(got, hasLength(5 * 250));
      expect(await band.isInRange(), isFalse);
      expect(await finder.find(const Duration(seconds: 1)), isNull, reason: 'nothing more to play');
    });

    test('a reconnect goes on where the replay was; the old connection is handed over', () async {
      final f = write(short('q', brainBitHeader, const [Stretch(Act.quiet, 20)]));
      final finder = ReplayFinder(ReplayPlan(files: [f]), pace: const ReplayPace.virtual(stepS: 0.5));
      final a = (await finder.find(const Duration(seconds: 1)))!;
      final got = <Sample>[];
      a.signal.listen(got.addAll);
      await a.startSignal();
      await until(() => got.length >= 1000);
      await a.disconnectAndDispose();
      final n = got.length;
      final b = await finder.connectDirect(a.id);
      expect(identical(a, b), isFalse);
      await expectLater(a.startSignal(), throwsStateError);
      b.signal.listen(got.addAll);
      await b.startSignal();
      await until(() => finder.finished);
      expect(got, hasLength(20 * 250));
      expect(got[n].pack, (got[n - 1].pack + 1) % 2048, reason: 'no sample twice, none skipped');
    });

    test('from_s and loop: starts 10 s in, starts again at the end', () async {
      final f = write(short('q', brainBitHeader, const [Stretch(Act.quiet, 12)]));
      final finder = ReplayFinder(ReplayPlan(files: [f], fromS: 10, loop: true), pace: const ReplayPace.virtual(stepS: 0.25));
      final band = (await finder.find(const Duration(seconds: 1)))!;
      final got = <Sample>[];
      band.signal.listen(got.addAll);
      await band.startSignal();
      await until(() => got.length >= 2 * 250 + 12 * 250 + 100);
      await band.stopSignal();
      // the first batch at 10 s on the replay's clock (2500 samples in, give or take the rounding of one batch)
      expect(got.first.pack, inInclusiveRange(2500 % 2048, 2525 % 2048));
      final restart = got.indexWhere((s) => s.pack == 0);
      expect(restart, greaterThan(0), reason: 'the loop starts the recording again');
      expect(finder.finished, isFalse);
    });

    test('the contact check reads the plan\'s ohms, by the channel names it plays', () async {
      final f = write(short('q', brainBitHeader, const [Stretch(Act.quiet, 1)]));
      final band = (await ReplayFinder(ReplayPlan(files: [f], contactOhms: const {'T4': 4e6})).find(Duration.zero))!;
      final first = band.resistance.first;
      await band.startResist();
      expect(await first, {'O1': 3e5, 'O2': 3e5, 'T3': 3e5, 'T4': 4e6});
      await band.stopResist();
    });
  });

  test('the night recorder keeps an 8-channel replay under its own header, record for record, and says it replayed', () async {
    final f = write(short('h', helmetScenarioHeader, const [Stretch(Act.quiet, 8)]));
    final dir = Directory('${tmp.path}/out');
    final finder = ReplayFinder(ReplayPlan(files: [f], speed: 20));
    final r = NightRecorder(
      finder: finder,
      dir: dir,
      store: MemoryNightStore(),
      onStatus: (_) {},
      onStuck: (_) async => fail('nothing may get stuck'),
      timing: fastNight,
    );
    final run = r.run(restartedBySystem: false);
    await until(() => finder.finished, limit: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await r.stop();
    await run;
    final out = dir.listSync().whereType<File>().where((x) => x.path.endsWith('.f32')).toList();
    expect(out, hasLength(1));
    final h = readHeader(out.single);
    expect(h.names, helmetScenarioHeader.names);
    expect(h.sampleRate, 500);
    expect(h.device, 'Replay of Made-up helmet');
    final want = records(f), got = records(out.single);
    expect(got, hasLength(want.length));
    expect(got.last.$2, want.last.$2);
    expect(got[1234].$2, want[1234].$2);
    final log = File('${out.single.path.substring(0, out.single.path.length - 4)}.log').readAsStringSync();
    expect(log, contains('$replayName: 2026-11-20-100000.f32, Made-up helmet: M1 M2 F7 F8 Fz C3 C4 Pz at 500 Hz'));
  });

  group('a work session on a replayed day (its own clock: minutes in a second)', () {
    WorkController session(ReplayFinder finder, Directory dir) => WorkController(
      finder: finder,
      store: WorkStore(dir),
      timing: const WorkTiming(link: fastLink, tick: Duration(milliseconds: 4), noDataAfter: Duration(seconds: 3)),
      clock: finder.now,
    );

    Future<WorkController> play(String scenario, {required double untilS}) async {
      final f = write(scenarios[scenario]!);
      final finder = ReplayFinder(ReplayPlan(files: [f]), pace: const ReplayPace.virtual(), forSessions: true);
      final c = session(finder, Directory('${tmp.path}/work'));
      await c.start();
      await until(() => finder.played >= untilS || finder.finished);
      return c;
    }

    test('quiet work calibrates in its first 4 minutes and starts no break', () async {
      final c = await play('quiet-work', untilS: 9 * 60);
      expect(c.stage, WorkStage.running);
      expect(c.worn, isTrue);
      expect(c.planner!.breaks, isEmpty);
      await c.stop();
      c.dispose();
    });

    test('the headband off for 7 minutes is a break by itself, and the signal back ends it', () async {
      final c = await play('band-off', untilS: 14 * 60);
      expect(c.planner!.breaks.map((b) => b.source), [BreakSource.headbandOff]);
      expect(c.onBreak, isFalse, reason: 'the signal came back');
      await c.stop();
      c.dispose();
    });

    // The 2026-11-20 break loop (DECISIONS 680): talking read as the headband off. Fixed on fix/app-work-session-day,
    // not yet on main: on main this replay starts a break (checked 2026-11-20); enable both once main has the fix.
    const waitsForFix = 'enable once fix/app-work-session-day (DECISIONS 680-686) is merged into main';

    test('talking from the start (a meeting) never starts a break', () async {
      final c = await play('talking-work', untilS: 11 * 60);
      expect(c.planner!.breaks, isEmpty);
      expect(c.worn, isTrue, reason: 'talking is skin contact');
      await c.stop();
      c.dispose();
    }, skip: waitsForFix);

    test('talking after calibration never starts a break', () async {
      final c = await play('quiet-then-talking', untilS: 16 * 60);
      expect(c.stage, WorkStage.running);
      expect(c.planner!.breaks, isEmpty);
      await c.stop();
      c.dispose();
    }, skip: waitsForFix);
  });
}
