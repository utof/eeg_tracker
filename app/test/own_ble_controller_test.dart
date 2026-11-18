// The "Headband connection" page's logic (lib/headband/own/controller.dart) on the fake headband: the probe run
// from the page, what it saves, and the rule that our own connection is only offered after a passed probe, or
// with "try anyway".
import 'dart:io';

import 'package:eeg_tracker/export/store.dart' show storedFiles;
import 'package:eeg_tracker/headband/own/controller.dart';
import 'package:eeg_tracker/headband/own/protocol.dart';
import 'package:eeg_tracker/headband/own/settings.dart';
import 'package:eeg_tracker/sound/check_in_sound.dart';
import 'package:flutter_test/flutter_test.dart';

import 'own_ble/fake_head.dart';
import 'own_ble/fake_headband.dart';

class CountingSound implements CheckInSound {
  CountingSound({this.broken = false});
  final bool broken;
  final played = <String>[];
  bool started = false, stopped = false;

  @override
  Future<void> start() async {
    if (broken) throw StateError('no audio');
    started = true;
  }

  @override
  void close() => played.add('close');
  @override
  void open() => played.add('open');
  @override
  void end() => played.add('end');
  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  late Directory files;
  late OwnBleStore store;
  late Directory recordings;

  setUp(() {
    files = Directory.systemTemp.createTempSync('own_ble_page');
    recordings = Directory('${files.path}/recordings')..createSync();
    store = OwnBleStore(ownBleDirFor(recordings.path));
  });
  tearDown(() => files.deleteSync(recursive: true));

  OwnBleController page(Head head, {CountingSound? sound, Future<String?> Function()? before}) {
    final c = OwnBleController(
      store: store,
      recordings: recordings,
      transport: () => head.hb,
      sound: sound == null ? null : () => sound,
      before: before,
      timeScale: 1 / speed,
      probeClock: head.clock,
    )..load();
    // The probe's steps move the fake head; the page's own listener is the controller's.
    c.addListener(() {
      final s = c.step;
      if (s != null && (head.steps.isEmpty || !identical(head.steps.last, s))) head.onStep(s);
      if (c.stage == OwnStage.waitingReady) c.ready();
    });
    return c;
  }

  test('BrainBit\'s SDK is the default, and our own connection is not offered before a passed probe', () {
    final c = page(Head());
    expect(c.settings.useOwn, isFalse);
    expect(c.setUseOwn(true), isFalse);
    expect(c.message, contains('Run the probe first'));
    expect(store.load().useOwn, isFalse);
    expect(c.setSignalResist(true), isFalse);

    expect(c.setUseOwn(true, anyway: true), isTrue, reason: 'the explicit "try anyway"');
    expect(store.load().useOwn, isTrue);
    expect(store.load().triedAnyway, isTrue);
    expect(c.setUseOwn(false), isTrue);
    expect(store.load().useOwn, isFalse);
    expect(store.load().triedAnyway, isFalse);
  });

  test('"try anyway" starts from the headband the SDK recorded with', () {
    File('${recordings.path}/2026-11-18-010000.log').writeAsStringSync(
      '2026-11-18T01:00:00.000 connected BB Black AA:BB:CC:33:44:55 serial X battery 40% signal -80 dBm\n',
    );
    final c = page(Head());
    c.setUseOwn(true, anyway: true);
    expect(store.load().address, 'AA:BB:CC:33:44:55');
  });

  test('a full probe from the page: steps and tones, a pass, and only then the switch', () async {
    final head = Head(), sound = CountingSound();
    final c = page(head, sound: sound);
    final stages = <OwnStage>[];
    c.addListener(() {
      if (stages.isEmpty || stages.last != c.stage) stages.add(c.stage);
    });
    final r = (await c.runProbe())!;
    expect(r.verdict.passed, isTrue, reason: r.text);
    expect(stages, [OwnStage.connecting, OwnStage.waitingReady, OwnStage.running, OwnStage.idle]);
    expect(sound.started && sound.stopped, isTrue);
    expect(sound.played.where((p) => p == 'close'), hasLength(1), reason: 'one low tone: close your eyes');
    expect(sound.played.where((p) => p == 'open'), hasLength(1), reason: 'one rising pair: open them');
    expect(sound.played.where((p) => p == 'end').length, greaterThanOrEqualTo(10), reason: 'a tone at each lift');
    expect(c.busy, isFalse);
    expect(c.lines.where((l) => l.$1 == false), isEmpty);
    expect(c.lines.any((l) => l.$2.contains('Channel order as assumed')), isTrue);

    final saved = store.load();
    expect(saved.useOwn, isFalse, reason: 'a pass offers the switch; it does not flip it');
    expect(saved.probePassed, isTrue);
    expect(saved.probe!.command5, isTrue);
    expect(saved.probe!.folder, 'own-ble/probe/${r.stamp}');
    expect(saved.address, fakeAddress);
    expect(saved.name, 'BB Black');
    expect(saved.layout, isNull);
    expect(File('${files.path}/${saved.probe!.folder}/summary.txt').existsSync(), isTrue);
    // Export data takes everything in the app's folder: the probe's result and the settings leave with it.
    final leaving = [for (final f in storedFiles(files)) f.path];
    expect(leaving, [
      for (final n in ['decoded.csv', 'gatt.txt', 'probe.log', 'raw.txt', 'summary.json', 'summary.txt'])
        'own-ble/probe/${r.stamp}/$n',
      'own-ble/settings.json',
    ]);

    expect(c.setUseOwn(true), isTrue);
    expect(store.load().useOwn, isTrue);
    expect(store.load().triedAnyway, isFalse);
    expect(c.setSignalResist(true), isTrue);
    expect(store.load().signalResist, isTrue);
    c.setUseOwn(false);
    expect(store.load().signalResist, isFalse, reason: 'contact all night belongs to our own connection');

    // A page opened later shows the same result.
    final later = page(Head());
    expect(later.settings.probePassed, isTrue);
    expect(later.lines.length, c.lines.length);
    expect(later.lines.first, c.lines.first);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the probe on the desk: saved, but no pass, so the switch still needs "try anyway"', () async {
    final head = Head();
    final c = page(head)..setWorn(false);
    final r = (await c.runProbe())!;
    expect(r.verdict.passed, isFalse);
    expect(store.load().probePassed, isFalse);
    expect(store.load().probe!.worn, isFalse);
    expect(c.setUseOwn(true), isFalse);
    expect(head.steps.any((s) => s.name == 'ready'), isFalse);
  });

  test('another channel order found by the lifts is kept for our connection', () async {
    store.save(OwnBleSettings(layout: Layout(order: ['T3', 'T4', 'O1', 'O2'], resistOrder: ['T3', 'T4', 'O1', 'O2'])));
    final c = page(Head());
    final r = (await c.runProbe())!;
    expect(r.verdict.passed, isTrue);
    expect(store.load().layout!.order, ['O2', 'T3', 'T4', 'O1']);
    expect(store.load().layout!.resistOrder, ['O2', 'T3', 'T4', 'O1']);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a headband that asks for pairing: the page turns "Pair first" on; the next run keeps it', () async {
    final head = Head(needsPairing: true);
    final c = page(head)..setWorn(false);
    await c.runProbe();
    expect(c.needsPairing, isTrue);
    expect(c.pairFirst, isTrue);
    expect(store.load().pair, isFalse, reason: 'not kept until a run with pairing worked');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final r = (await c.runProbe())!;
    expect(r.summary['error'], isNull);
    expect(c.needsPairing, isFalse);
    expect(store.load().pair, isTrue);
  });

  test('not started while a night records, or without the Bluetooth permission', () async {
    final head = Head();
    final c = page(head, before: () async => 'A night is recording. Stop it first: the headband keeps one connection.');
    expect(await c.runProbe(), isNull);
    expect(c.message, contains('A night is recording'));
    expect(head.hb.connects, 0);
    expect(store.load().probe, isNull);
  });

  test('no audio, a stop in the middle, a failed probe after a pass: each is said and saved honestly', () async {
    final head = Head();
    final c = page(head, sound: CountingSound(broken: true))..setWorn(false);
    final running = c.runProbe();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.stage, OwnStage.running);
    expect(c.fraction, inInclusiveRange(0.01, 0.99));
    c.stopProbe();
    final r = (await running)!;
    expect(r.summary['error'], contains('stopped by you'));
    expect(store.load().probePassed, isFalse);
    expect(c.stage, OwnStage.idle);

    // Our connection was on by an earlier pass; a later failed probe leaves the switch but drops the pass.
    store.save(
      store.load().copyWith(
        useOwn: true,
        probe: const ProbeNote(at: '2026-11-19-081500', passed: true, worn: true, command5: true, folder: 'own-ble/probe/x'),
      ),
    );
    head.hb.awayUntil = DateTime.now().add(const Duration(hours: 1));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await c.runProbe();
    expect(store.load().useOwn, isTrue);
    expect(store.load().probePassed, isFalse);
    expect(c.lines.first.$2, contains('It stopped early'));
  });
}
