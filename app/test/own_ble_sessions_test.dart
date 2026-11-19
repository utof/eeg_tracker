// A night and whole sessions through our own connection (lib/headband/own/) on the fake headband: the night
// recorder, a meditation, and the shared headband link of the dream catcher and the sound sessions, all through
// the same `Headband` interface they use with BrainBit's SDK. Also the switch and its settings file.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/headband/finder.dart';
import 'package:eeg_tracker/headband/own/own_headband.dart';
import 'package:eeg_tracker/headband/own/protocol.dart';
import 'package:eeg_tracker/headband/own/settings.dart';
import 'package:eeg_tracker/headband/own/universal_transport.dart' show blePackage;
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/recorder/brainbit.dart' show SdkFinder;
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/sound/feedback_sound.dart';
import 'package:flutter_test/flutter_test.dart';

import 'own_ble/fake_headband.dart';

const _ms = Duration(milliseconds: 1);

OwnTiming ownFast({Duration healFor = const Duration(seconds: 3), List<Duration>? backoffs}) => OwnTiming(
  callTimeout: _ms * 300,
  healFor: healFor,
  stall: _ms * 150,
  backoffs: backoffs ?? [_ms * 20, _ms * 40, _ms * 80],
  contactFor: _ms * 30,
  notesEvery: _ms * 50,
  contactNoteEvery: _ms * 100,
  poll: _ms * 10,
  stopWait: _ms * 500,
);

OwnFinder own(FakeHeadband hb, {OwnTiming? timing, OwnBleSettings? settings, void Function(String, String)? remember}) =>
    OwnFinder(
      transport: hb,
      settings: settings ?? const OwnBleSettings(address: fakeAddress, name: 'BB Black'),
      timing: timing ?? ownFast(),
      remember: remember,
    );

/// The recorder's rules at test speed. Its own no-data check comes every 300 ms, so a short drop is left to the
/// headband object to mend.
const night = RecorderTiming(
  tick: Duration(milliseconds: 10),
  ticksPerCheck: 30,
  scanFor: Duration(milliseconds: 100),
  contactFor: Duration(milliseconds: 40),
  settle: Duration(milliseconds: 5),
  retryWait: Duration(milliseconds: 5),
  sdkTimeout: Duration(seconds: 2),
  connectTimeout: Duration(seconds: 2),
  notFoundWait: Duration(milliseconds: 10),
  notFoundWaitLong: Duration(milliseconds: 10),
  stallChecksToGiveUp: 3,
  stopTimeout: Duration(seconds: 2),
  reconnectWaits: [Duration(milliseconds: 20), Duration(milliseconds: 40), Duration(milliseconds: 80)],
  scanEvery: 3,
  rescanFor: Duration(milliseconds: 50),
);

Future<void> waitFor(bool Function() done, {Duration max = const Duration(seconds: 8)}) async {
  final t0 = DateTime.now();
  while (!done()) {
    if (DateTime.now().difference(t0) > max) fail('timed out waiting');
    await Future<void>.delayed(_ms * 10);
  }
}

void main() {
  late Directory dir;
  late MemoryNightStore store;
  late List<RecorderStatus> statuses;
  late List<String> stuck;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('own_ble_night');
    store = MemoryNightStore();
    statuses = [];
    stuck = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  NightRecorder recorder(HeadbandFinder finder) => NightRecorder(
    finder: finder,
    dir: dir,
    store: store,
    onStatus: statuses.add,
    onStuck: (r) async => stuck.add(r),
    timing: night,
  );

  List<File> files(String ext) =>
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.$ext')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  List<({int pack, double o1})> records(File f) {
    final b = ByteData.sublistView(f.readAsBytesSync());
    return [
      for (var i = 0; i + recordBytes <= b.lengthInBytes; i += recordBytes)
        (pack: b.getUint32(i, Endian.little), o1: b.getFloat32(i + 4, Endian.little).toDouble()),
    ];
  }

  group('a night through our own connection', () {
    test('contact check, signal saved in the usual files, clean stop; no scan with a known address', () async {
      final hb = FakeHeadband(battery: 64);
      final r = recorder(own(hb));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => statuses.isNotEmpty && statuses.last.nightSamples > 500);
      await r.stop();
      await running;

      expect(hb.scans, 0);
      expect(hb.connects, 1);
      expect(hb.commands.take(4), [cmdIdle, cmdResist, cmdIdle, cmdSignal]); // contact first, then the signal
      expect(hb.commands.last, cmdIdle);
      expect(hb.link, isNull, reason: 'disconnected at the end');
      expect(stuck, isEmpty);
      final rec = records(files('f32').single);
      expect(rec.length, greaterThan(500));
      expect(rec.length, store.state.samples);
      for (var i = 0; i < 200; i++) {
        expect(rec[i].pack, i); // the headband's own sample counter
        expect(rec[i].o1, closeTo(hb.sent[i]['O1']!, 2 * fakeVoltsPerCount + 1e-11)); // float32 in the file
      }
      final log = files('log').single.readAsStringSync();
      expect(log, contains('connected BB Black $fakeAddress serial fake-serial battery 64% signal unknown (no scan)'));
      expect(log, contains('driver own Bluetooth LE (lib/headband/own, fake headband); service ${fakeUuid(1, '7')}'));
      expect(log, contains('layout wire order O2 T3 T4 O1, resistance order O2 T3 T4 O1, gain 6'));
      expect(log, contains('mode signal (command 3)'));
      expect(log, contains('contact ohms O1=150000 O2=220000 T3=400000 T4=180000'));
      expect(log, contains('recording started, 250 Hz'));
      expect(log, contains('missing 0 in 0 gaps, repeated 0'));
      expect(store.state.band!.address, fakeAddress);
      expect(store.state.contactOhms['T3'], 400000);
      expect(statuses.map((s) => s.phase), containsAllInOrder([Phase.searching, Phase.connecting, Phase.recording]));
    });

    test('a short drop is mended inside the same connection object: one file set, no restart', () async {
      final hb = FakeHeadband(dropAfter: _ms * 200, dropFor: _ms * 80, maxDrops: 1);
      final r = recorder(own(hb));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => hb.connects == 2 && hb.packets > 150);
      await Future<void>.delayed(_ms * 150);
      await r.stop();
      await running;

      expect(hb.drops, 1);
      expect(hb.scans, 0);
      expect(files('f32'), hasLength(1), reason: 'the night stays in one file set');
      final log = files('log').single.readAsStringSync();
      expect(log, contains('headband lost: link dropped; trying again in 0.02 s (try 1)'));
      expect(log, contains(RegExp(r'reconnected after \d+\.\d s away \(try \d+\), battery 87%; same files')));
      expect(log, isNot(contains('drop (')));
      expect(log, isNot(contains('headband out of range')));
      expect(log, contains('missing 0 in 0 gaps, repeated 0'), reason: 'the counter starting again is not a loss');
      expect(hb.commands.where((c) => c == cmdResist), hasLength(1), reason: 'contact is checked once a night');
      expect(r.abandoned, isEmpty);
      // The hole shows in the arrival times, as on the laptop: the samples before and after it are all there.
      final packs = [for (final x in records(files('f32').single)) x.pack];
      final restart = [for (var i = 1; i < packs.length; i++) if (packs[i] < packs[i - 1]) i];
      expect(restart, hasLength(1));
      expect(packs[restart.single], 0);
    });

    test('a long absence: the object gives up, the recorder reconnects by address and starts a new file set', () async {
      final hb = FakeHeadband(dropAfter: _ms * 200, dropFor: _ms * 700, maxDrops: 1);
      final r = recorder(own(hb, timing: ownFast(healFor: _ms * 150)));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => files('f32').length == 2 && files('f32').last.lengthSync() > 2000);
      await r.stop();
      await running;

      expect(hb.scans, lessThanOrEqualTo(3), reason: 'only every third try scans');
      final first = files('log').first.readAsStringSync(), second = files('log').last.readAsStringSync();
      expect(first, contains("handing over to the app's reconnect"));
      expect(first, contains('headband out of range; saving'));
      expect(first, contains('drop (out of range)'));
      expect(first, contains('reconnect try 1 (direct to $fakeAddress)'));
      expect(second, contains(RegExp(r'reconnected \((direct|scan), try \d+\) after a drop \(out of range\)')));
      expect(hb.commands.where((c) => c == cmdResist), hasLength(1), reason: 'no second contact check');
      expect(r.abandoned, hasLength(1));
      expect(hb.link, isNull);
      expect(stuck, isEmpty, reason: 'our connection never needs a process restart');
    });

    /// The recorder and the object at the phone's own ratios, 1 s = 10 ms: the recorder checks every 10 s and gives a
    /// run up after 40 s without data; the object mends for 30 s with its 1, 2, 5, 10, 20, 30 s pauses (DECISIONS 213).
    NightRecorder atPhoneRatios(FakeHeadband hb) => NightRecorder(
      finder: own(
        hb,
        timing: OwnTiming(
          callTimeout: _ms * 120,
          healFor: _ms * 300,
          stall: _ms * 50,
          backoffs: [_ms * 10, _ms * 20, _ms * 50, _ms * 100, _ms * 200, _ms * 300],
          contactFor: _ms * 60,
          notesEvery: _ms * 100,
          poll: _ms * 3,
          stopWait: _ms * 300,
        ),
      ),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (r) async => stuck.add(r),
      timing: const RecorderTiming(
        tick: Duration(milliseconds: 10),
        ticksPerCheck: 10,
        scanFor: Duration(milliseconds: 300),
        contactFor: Duration(milliseconds: 60),
        settle: Duration(milliseconds: 10),
        retryWait: Duration(milliseconds: 30),
        sdkTimeout: Duration(seconds: 2),
        connectTimeout: Duration(seconds: 2),
        notFoundWait: Duration(milliseconds: 100),
        notFoundWaitLong: Duration(milliseconds: 600),
        stopTimeout: Duration(seconds: 2),
        reconnectWaits: [Duration(milliseconds: 20), Duration(milliseconds: 50), Duration(milliseconds: 100)],
        rescanFor: Duration(milliseconds: 150),
      ),
    );

    test('at the phone\'s ratios a 15 s drop is left to the object: no stream restart undoes its mending', () async {
      final hb = FakeHeadband(dropAfter: _ms * 400, dropFor: _ms * 150, maxDrops: 1);
      final r = atPhoneRatios(hb);
      final running = r.run(restartedBySystem: false);
      await waitFor(() => hb.drops == 1 && hb.connects == 2 && hb.packets > 200);
      await Future<void>.delayed(_ms * 300);
      await r.stop();
      await running;
      final log = files('log').single.readAsStringSync();
      expect(log, isNot(contains('restarting stream')));
      expect(log, contains(RegExp(r'reconnected after \d+\.\d s away \(try [2-9]\)')), reason: 'its tries went on counting');
      expect(files('f32'), hasLength(1));
    });

    test('at the phone\'s ratios a 2 min drop: the object gives up after its 30 s and hands over', () async {
      final hb = FakeHeadband(dropAfter: _ms * 400, dropFor: _ms * 1200, maxDrops: 1);
      final r = atPhoneRatios(hb);
      final running = r.run(restartedBySystem: false);
      await waitFor(() => files('f32').length == 2 && files('f32').last.lengthSync() > 2000);
      await r.stop();
      await running;
      final first = files('log').first.readAsStringSync();
      expect(first, isNot(contains('restarting stream')));
      expect(first, contains("handing over to the app's reconnect"));
      expect(first, contains('drop (out of range)'));
      expect(r.abandoned, hasLength(1));
    });

    test('lost packets are counted, by the driver and by the night\'s packet line alike', () async {
      final hb = FakeHeadband(loseEvery: 7);
      final r = recorder(own(hb));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => statuses.isNotEmpty && statuses.last.nightSamples > 1500);
      await r.stop();
      await running;
      final log = files('log').single.readAsStringSync();
      final lost = RegExp(r'lost (\d+) samples in (\d+) gaps \(packet counter jumps\)').allMatches(log).toList();
      expect(lost, isNotEmpty);
      for (final m in lost) {
        expect(int.parse(m.group(1)!), 8 * int.parse(m.group(2)!));
      }
      final end = RegExp(r'end of night, packets: \d+ samples, missing (\d+) in (\d+) gaps, repeated 0, longest gap 8 samples')
          .firstMatch(log)!;
      expect(int.parse(end.group(1)!), 8 * int.parse(end.group(2)!));
      expect(int.parse(end.group(2)!), greaterThanOrEqualTo(20));
    });

    test('with command 5 contact is measured all night alongside the signal', () async {
      final hb = FakeHeadband();
      final r = recorder(
        own(hb, settings: const OwnBleSettings(address: fakeAddress, signalResist: true)),
      );
      final running = r.run(restartedBySystem: false);
      await waitFor(() => statuses.isNotEmpty && statuses.last.nightSamples > 1500);
      await r.stop();
      await running;
      final log = files('log').single.readAsStringSync();
      expect(log, contains('mode signal+resistance (command 5)'));
      expect('contact ohms O1=150000'.allMatches(log).length, greaterThanOrEqualTo(3), reason: 'the start check, then live');
      expect(hb.commands, contains(cmdSignalResist));
      expect(hb.commands, isNot(contains(cmdSignal)));
    });

    test('no known address: a scan by name finds the headband and it is remembered', () async {
      final hb = FakeHeadband();
      final remembered = <String>[];
      final r = recorder(own(hb, settings: const OwnBleSettings(), remember: (a, n) => remembered.add('$a $n')));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => statuses.isNotEmpty && statuses.last.nightSamples > 200);
      await r.stop();
      await running;
      expect(hb.scans, 1);
      expect(remembered, ['$fakeAddress BB Black']);
      expect(files('log').single.readAsStringSync(), contains('battery 87% signal -61 dBm'));
    });

    test('a saved address that does not answer falls back to the scan', () async {
      final hb = FakeHeadband(directFails: true);
      final r = recorder(own(hb));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => statuses.isNotEmpty && statuses.last.nightSamples > 200);
      await r.stop();
      await running;
      expect(hb.scans, 1);
      expect(hb.connects, 1);
    });

    test('Bluetooth off: said as "could not connect" with the reason, and it keeps trying', () async {
      final hb = FakeHeadband()..bluetoothOff = true;
      final r = recorder(own(hb, settings: const OwnBleSettings()));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => hb.scans >= 2);
      expect(statuses.any((s) => s.note == 'could not connect: scan failed: Bluetooth not enabled'), isTrue);
      await r.stop();
      await running;
      expect(files('f32'), isEmpty);
      expect(stuck, isEmpty);
    });

    test('headband switched off: keeps looking, writes no files, stops promptly', () async {
      final hb = FakeHeadband()..awayUntil = DateTime.now().add(const Duration(hours: 1));
      final r = recorder(own(hb));
      final running = r.run(restartedBySystem: false);
      await waitFor(() => hb.scans >= 2);
      await r.stop();
      await running;
      expect(files('f32'), isEmpty);
      expect(stuck, isEmpty);
    });
  });

  group('sessions through our own connection', () {
    /// The demo signal (eyes open 30 s, then closed) at about 250 times real time.
    FakeHeadband demoBand({Duration? dropAfter}) {
      final demo = DemoSignal(7);
      return FakeHeadband(
        interval: _ms,
        packetsPerTick: 30,
        dropAfter: dropAfter,
        dropFor: _ms * 60,
        maxDrops: 1,
        rows: (n) {
          demo.eyes = demo.t < 30 ? 'open' : 'closed';
          final r = demo.next(1).single;
          return {'O1': r[0] * 1e-6, 'O2': r[1] * 1e-6, 'T3': r[2] * 1e-6, 'T4': r[3] * 1e-6};
        },
      );
    }

    const fast = MeditationTiming(
      contactFor: Duration(milliseconds: 40),
      settle: Duration.zero,
      tick: Duration(milliseconds: 20),
      reconnectWaits: [Duration(milliseconds: 5)],
      endRingOut: Duration.zero,
    );

    test('a whole meditation: contact, calibration, the session, its report', () async {
      final hb = demoBand();
      final c = MeditationController(finder: own(hb), sound: SilentSound.new, timing: fast);
      await c.start(const Duration(minutes: 2));
      await waitFor(() => c.stage == Stage.report || c.stage == Stage.failed, max: const Duration(seconds: 30));
      expect(c.stage, Stage.report, reason: c.message);
      expect(c.contact, {'O1': 150000.0, 'O2': 220000.0, 'T3': 400000.0, 'T4': 180000.0});
      expect(c.report!.complete, isTrue);
      expect(c.report!.runS, closeTo(120, 0.1));
      expect(c.report!.iafHz, 10);
      expect(hb.commands.take(4), [cmdIdle, cmdResist, cmdIdle, cmdSignal]);
      expect(hb.commands.last, cmdIdle);
      expect(hb.link, isNull);
      expect(c.leftLost, isFalse);
      c.dispose();
    });

    test('a drop in the middle of a meditation is mended without the session noticing more than a hole', () async {
      final hb = demoBand(dropAfter: _ms * 120);
      // The first pause is a second, as on the phone: the hole is long enough to count as one (over 1 s).
      final c = MeditationController(
        finder: own(hb, timing: ownFast(backoffs: [_ms * 1100])),
        sound: SilentSound.new,
        timing: fast,
      );
      await c.start(const Duration(minutes: 3));
      await waitFor(() => c.stage == Stage.report || c.stage == Stage.failed, max: const Duration(seconds: 30));
      expect(c.stage, Stage.report, reason: c.message);
      expect(hb.drops, 1);
      expect(hb.connects, 2);
      expect(hb.scans, 0);
      expect(c.report!.complete, isTrue);
      expect(c.leftLost, isFalse, reason: 'the same headband object carried on');
      expect(c.session!.log.lines.where((l) => l['type'] == 'gap'), isNotEmpty, reason: 'the hole is in the log');
      c.dispose();
    });

    test('the shared headband link (dream catcher, sound sessions): contact, signal, a mended drop, release', () async {
      final hb = FakeHeadband(dropFor: _ms * 60);
      final batches = <int>[];
      final events = <String>[];
      final link = BandLink(
        finder: own(hb),
        timing: LinkTiming(contactFor: _ms * 40, settle: Duration.zero, reconnectWaits: [_ms * 5]),
        onBatch: (_, b) => batches.add(b.length),
        onEvent: (e, line) => events.add(line),
      );
      String? found;
      expect(await link.connect(onFound: (n) => found = n), isTrue);
      expect(found, isNull, reason: 'a known address needs no scan');
      expect(link.name, 'BB Black');
      expect(await link.contact(), {'O1': 150000.0, 'O2': 220000.0, 'T3': 400000.0, 'T4': 180000.0});
      await link.startSignal();
      await waitFor(() => batches.length > 30);
      hb.drop();
      final before = batches.length;
      await waitFor(() => hb.connects == 2 && batches.length > before + 30);
      expect(link.lost, isFalse, reason: 'mended inside the headband object');
      expect(events, isEmpty);
      expect(batches.every((n) => n == 8), isTrue);
      await link.close();
      expect(hb.link, isNull);
      expect(hb.commands.last, cmdIdle);
      expect(link.leftLost, isFalse);
    });

    test('the shared link when the headband stays away: it reconnects by address, as with the SDK', () async {
      final hb = FakeHeadband(dropFor: _ms * 400);
      final batches = <int>[];
      final events = <LinkEvent>[];
      final link = BandLink(
        finder: own(hb, timing: ownFast(healFor: _ms * 100)),
        timing: LinkTiming(contactFor: _ms * 40, settle: Duration.zero, reconnectWaits: [_ms * 30]),
        onBatch: (_, b) => batches.add(b.length),
        onEvent: (e, _) => events.add(e),
      );
      expect(await link.connect(), isTrue);
      await link.startSignal();
      await waitFor(() => batches.length > 20);
      hb.drop();
      await waitFor(() => events.contains(LinkEvent.reconnected));
      final before = batches.length;
      await waitFor(() => batches.length > before + 20);
      expect(events.first, LinkEvent.drop);
      expect(link.lost, isFalse);
      await link.close();
      expect(hb.link, isNull);
    });

    test('a contact check while the signal runs: same connection, the signal comes back by itself', () async {
      final hb = FakeHeadband();
      final band = (await own(hb).find(_ms * 100))! as OwnHeadband;
      var samples = 0;
      final ohms = <Map<String, double>>[];
      band.signal.listen((b) => samples += b.length);
      band.resistance.listen(ohms.add);
      await band.startSignal();
      await waitFor(() => samples > 200);
      await band.startResist();
      await waitFor(() => ohms.isNotEmpty);
      await band.stopResist();
      final before = samples;
      await waitFor(() => samples > before + 200);
      expect(hb.connects, 1);
      expect(hb.commands, containsAllInOrder([cmdSignal, cmdIdle, cmdResist, cmdIdle, cmdSignal]));
      expect(await band.isInRange(), isTrue);
      expect(await band.battery(), 87);
      await band.disconnectAndDispose();
      expect(hb.link, isNull);
    });
  });

  group('the switch', () {
    test('BrainBit\'s SDK is the default; our own connection only when the switch is on', () {
      expect(BrainBitFinder.choose(const OwnBleSettings(), null, null), isA<SdkFinder>());
      expect(BrainBitFinder.choose(const OwnBleSettings(address: fakeAddress), null, null), isA<SdkFinder>());
      expect(BrainBitFinder.choose(const OwnBleSettings(useOwn: true), null, null), isA<OwnFinder>());
    });

    test('the finder asks once and keeps its choice for the session', () async {
      final hb = FakeHeadband();
      var asked = 0;
      final f = BrainBitFinder(
        pick: () async {
          asked++;
          return own(hb);
        },
      );
      expect(f.usesOwn, isNull);
      final band = (await f.find(_ms * 100))!;
      expect(f.usesOwn, isTrue);
      await band.disconnectAndDispose();
      final again = await f.connectDirect(band.id);
      await again.disconnectAndDispose();
      expect(asked, 1);
      f.dispose(anyLost: false);
    });

    test('our own connection starts from the address in the newest recorder log when none is saved', () {
      final rec = Directory('${dir.path}/recordings')..createSync();
      File('${rec.path}/2026-11-17-230000.log').writeAsStringSync(
        '2026-11-17T23:00:00.000 connected BB Black AA:BB:CC:00:11:22 serial X battery 50% signal -70 dBm\n',
      );
      File('${rec.path}/2026-11-18-010000.log').writeAsStringSync(
        '2026-11-18T01:00:00.000 connected BB Black aa:bb:cc:33:44:55 serial X battery 40% signal -80 dBm\n'
        '2026-11-18T01:30:00.000 samples 100 (+100) battery 40%\n',
      );
      File('${rec.path}/2026-11-18-020000.log').writeAsStringSync('2026-11-18T02:00:00.000 contact ohms O1=1\n');
      expect(knownAddress(rec), 'AA:BB:CC:33:44:55');
      expect(knownAddress(Directory('${dir.path}/missing')), isNull);
      final f = ownFinderFor(const OwnBleSettings(useOwn: true), null, rec);
      expect(f.settings.address, 'AA:BB:CC:33:44:55');
      final saved = ownFinderFor(const OwnBleSettings(useOwn: true, address: fakeAddress), null, rec);
      expect(saved.settings.address, fakeAddress);
    });

    test('settings file: defaults, a round trip, a damaged file, the remembered headband', () {
      final s = OwnBleStore(Directory('${dir.path}/own-ble'));
      expect(s.load().useOwn, isFalse);
      expect(s.load().probePassed, isFalse);
      final full = OwnBleSettings(
        useOwn: true,
        triedAnyway: true,
        signalResist: true,
        pair: true,
        address: fakeAddress,
        name: 'BB Black',
        layout: Layout(order: ['T3', 'T4', 'O1', 'O2'], gain: 12),
        probe: const ProbeNote(
          at: '2026-11-19-081500',
          passed: true,
          worn: true,
          command5: true,
          folder: 'own-ble/probe/2026-11-19-081500',
          line: 'Passed.',
        ),
      );
      s.save(full);
      expect(jsonEncode(s.load().toJson()), jsonEncode(full.toJson()));
      expect(s.load().probePassed, isTrue);
      expect(File('${s.file.path}.tmp').existsSync(), isFalse);
      s.remember('AA:BB:CC:33:44:55', '');
      expect(s.load().address, 'AA:BB:CC:33:44:55');
      expect(s.load().name, 'BB Black');
      expect(s.load().useOwn, isTrue, reason: 'remembering changes nothing else');
      s.file.writeAsStringSync('{ not json');
      expect(s.load().useOwn, isFalse, reason: 'a damaged file means BrainBit\'s SDK');
      expect(ownBleDirFor('/data/files/recordings').path, '/data/files/own-ble');
    });

    test('remembering a headband never writes over settings it could not read', () {
      final s = OwnBleStore(Directory('${dir.path}/own-ble'));
      // Half a file (two writers at once): left as it is for the screen's next save, not replaced by the defaults.
      const half = '{"useOwn": true, "layout": {"or';
      s.dir.createSync(recursive: true);
      s.file.writeAsStringSync(half);
      s.remember('AA:BB:CC:33:44:55', 'BB Black');
      expect(s.file.readAsStringSync(), half);
      // A read that fails (here a link that points at itself): nothing is written either.
      s.file.deleteSync();
      Link(s.file.path).createSync(s.file.path);
      s.remember('AA:BB:CC:33:44:55', 'BB Black');
      expect(FileSystemEntity.isLinkSync(s.file.path), isTrue);
      // No file yet: remembering starts one.
      Link(s.file.path).deleteSync();
      s.remember(fakeAddress, 'BB Black');
      expect(s.load().address, fakeAddress);
      expect(s.load().useOwn, isFalse);
      expect(s.dir.listSync().map((e) => e.uri.pathSegments.last), ['settings.json'], reason: 'no temporary file left');
    });

    test('the package named in the log is the one pinned in pubspec.lock', () {
      final lock = File('pubspec.lock').readAsStringSync();
      final m = RegExp(r'  universal_ble:\n(?:    .*\n)*?    version: "([^"]+)"').firstMatch(lock)!;
      expect(blePackage, 'universal_ble ${m.group(1)}');
      expect(File('pubspec.yaml').readAsStringSync(), contains('universal_ble: ${m.group(1)}'));
    });
  });
}
