// The device choice "Headband: BrainBit / DIY board (test)" (lib/headband/diy/settings.dart, lib/headband/finder.dart):
// off by default; its file and its names checked; while it is on, every session's finder refuses in plain words
// (they read BrainBit's O1 O2 T3 T4) and only the night recorder's service records the board; the board's nights
// leave the phone with Export data in their own folder.
import 'dart:io';

import 'package:eeg_tracker/export/store.dart';
import 'package:eeg_tracker/headband/diy/board.dart';
import 'package:eeg_tracker/headband/diy/settings.dart';
import 'package:eeg_tracker/headband/finder.dart';
import 'package:eeg_tracker/headband/own/own_headband.dart' show OwnFinder;
import 'package:eeg_tracker/headband/own/settings.dart';
import 'package:eeg_tracker/morning/controller.dart';
import 'package:eeg_tracker/recorder/brainbit.dart' show SdkFinder;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/recorder_service.dart' show notificationText;
import 'package:eeg_tracker/recorder/status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory files;

  setUp(() => files = Directory.systemTemp.createTempSync('diy_switch'));
  tearDown(() => files.deleteSync(recursive: true));

  String rec() => '${files.path}/recordings';

  group('the setting', () {
    test('off by default, the laptop\'s default names; a missing or damaged file is the default', () {
      final store = DiyBoardStore(diyBoardDirFor(rec()));
      expect(store.dir.path, '${files.path}/diy-board');
      expect(store.load().useDiy, isFalse);
      expect(store.load().names, ['O1', 'O2', 'Fz', 'Fp1']);
      store.dir.createSync(recursive: true);
      store.file.writeAsStringSync('{not json');
      expect(store.load().useDiy, isFalse);
      store.file.writeAsStringSync('{"useDiy": true, "names": ["O1", "O1", "x", "y"]}');
      expect(store.load().useDiy, isTrue);
      expect(store.load().names, defaultDiyNames); // unusable names fall back, the choice stays
    });

    test('saved and read back, through a temporary file', () {
      final store = DiyBoardStore(diyBoardDirFor(rec()));
      store.save(const DiyBoardSettings(useDiy: true, names: ['A1', 'A2', 'Cz', 'Pz']));
      final back = DiyBoardStore(diyBoardDirFor(rec())).load();
      expect([back.useDiy, back.names], [true, ['A1', 'A2', 'Cz', 'Pz']]);
      expect(File('${store.file.path}.tmp').existsSync(), isFalse);
    });

    test('names: four, different, letters and digits; parsed from what a person types', () {
      expect(parseDiyNames(' O1, O2 Fz,,Fp1 '), ['O1', 'O2', 'Fz', 'Fp1']);
      expect(diyNamesProblem(['O1', 'O2', 'Fz', 'Fp1']), isNull);
      expect(diyNamesProblem(['O1', 'O2', 'Fz']), contains('Give 4, 6 or 8 names'));
      expect(diyNamesProblem(['O1', 'O2', 'Fz', 'Fp1', 'Cz']), contains('Give 4, 6 or 8 names'));
      expect(diyNamesProblem(parseDiyNames('O1 O2 F z Fp1')), contains('Give 4, 6 or 8 names')); // "F z" is two names
      expect(diyNamesProblem(['Fz', 'Cz', 'Pz', 'O1', 'O2', 'T7']), isNull); // the 6-channel chip
      expect(diyNamesProblem(['Fz', 'Cz', 'Pz', 'O1', 'O2', 'T7', 'T8', 'Oz']), isNull); // the 8-channel chip
      expect(diyNamesProblem([for (var i = 1; i <= 9; i++) 'C$i']), contains('Give 4, 6 or 8 names'));
      expect(diyNamesProblem(['O1', 'O2', 'F z', 'Fp1']), contains('not: F z'));
      expect(diyNamesProblem(['O1', 'O2', 'Fz/1', 'Fp1']), contains('not: Fz/1'));
      expect(diyNamesProblem(['O1', 'O2', 'O1', 'Fp1']), contains('its own name'));
      expect(diyNamesProblem(['O1', 'O2', 'Fz', 'A' * 17]), isNotNull);
    });

    test('the board\'s nights have their own folder beside the BrainBit\'s', () {
      expect(diyRecordingsDirFor(rec()).path, '${files.path}/recordings-diy');
    });
  });

  group('the finder', () {
    test('BrainBit\'s SDK by default; our own connection when its switch is on; a refusal for sessions with the board', () {
      expect(BrainBitFinder.choose(const OwnBleSettings(), null, null), isA<SdkFinder>());
      expect(BrainBitFinder.choose(const OwnBleSettings(useOwn: true), null, null), isA<OwnFinder>());
      expect(
        BrainBitFinder.chooseFor(const OwnBleSettings(useOwn: true), null, null, const DiyBoardSettings(useDiy: true)),
        isA<DiyRefusal>(),
      );
      expect(BrainBitFinder.chooseFor(const OwnBleSettings(), null, null, const DiyBoardSettings()), isA<SdkFinder>());
    });

    test('a session asks for the headband while the board is chosen: a plain refusal, no scan', () async {
      final f = BrainBitFinder(pick: () async => const DiyRefusal());
      await expectLater(
        f.find(const Duration(seconds: 1)),
        throwsA(isA<NotForDiyBoard>().having((e) => '$e', 'text', allOf(contains('DIY board (test) is chosen'), contains('O1 O2 T3 T4'), contains('Headband connection')))),
      );
      await expectLater(f.connectDirect(const BandId(name: 'x', address: 'y')), throwsA(isA<NotForDiyBoard>()));
      expect(f.usesDiy, isFalse); // the refusal is not the board
      f.dispose(anyLost: false);
    });

    test('the morning check-in refuses the board in words', () async {
      final c = MorningController(finder: const DiyRefusal());
      await c.start();
      expect(c.stage, MorningStage.failed);
      expect(c.message, startsWith('Could not start: The DIY board (test) is chosen as the headband.'));
      c.dispose();
    });

    test('the night\'s finder: the board\'s own; disposing it stops the listener', () async {
      final diy = DiyFinder(port: 0);
      final f = BrainBitFinder(pick: () async => diy);
      expect(await f.find(const Duration(milliseconds: 30)), isNull); // listened, nothing came
      expect(f.usesDiy, isTrue);
      f.dispose(anyLost: true);
    });
  });

  test('the notification says it is the DIY board and not EEG', () {
    const rec = RecorderStatus(phase: Phase.recording, nightSamples: 250 * 60 * 12);
    expect(notificationText(rec, null, true), 'Recording the DIY board · 12 min · not EEG');
    expect(notificationText(const RecorderStatus(phase: Phase.searching), null, true), 'Listening for the DIY board');
    expect(notificationText(rec), 'Recording · 12 min'); // the BrainBit's words unchanged
  });

  test('Export data takes the board\'s nights and its setting, in their own folders', () {
    for (final p in ['recordings/2026-11-19-231200.f32', 'recordings-diy/2026-11-20-001500.f32',
        'recordings-diy/2026-11-20-001500.log', 'diy-board/settings.json']) {
      File('${files.path}/$p')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    expect([for (final f in storedFiles(files)) f.path], [
      'diy-board/settings.json',
      'recordings-diy/2026-11-20-001500.f32',
      'recordings-diy/2026-11-20-001500.log',
      'recordings/2026-11-19-231200.f32',
    ]);
  });
}
