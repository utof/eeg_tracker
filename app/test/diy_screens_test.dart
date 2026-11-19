// The DIY board on the phone's pages (DECISIONS rows 360-369): the Headband connection page with the device choice
// and the board's section, and the night screen while a DIY night records and between nights. Rendered at the
// owner's 393 dp at 100 and 130 % text with real fonts, written to build/screens/diy_*.png for a human look; any
// layout overflow fails. The words of each state are checked without a phone.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/headband/diy/settings.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/ui/diy_board_view.dart';
import 'package:eeg_tracker/ui/night_screen.dart' show describeNight;
import 'package:eeg_tracker/ui/night_strip.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/own_ble_view.dart';
import 'package:eeg_tracker/ui/phone_checks.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/phone.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

const _board = BoardLive(
  names: ['O1', 'O2', 'Fz', 'Fp1'],
  mode: 'test',
  modeText: "test signal: the chip's own square wave, not EEG",
  notEeg: true,
  levelsUv: [3749.98, 3749.98, 3749.98, 3749.98],
  link: 'UDP port 9000 on every IPv4 interface (Wi-Fi route)',
  sender: '192.168.1.50',
  lost: 3,
  boardMissed: 1,
);

final Map<String, OwnBleViewModel> _pages = {
  'diy_page_brainbit': const OwnBleViewModel(diy: DiyPageModel(address: '192.168.1.23')),
  'diy_page_on': const OwnBleViewModel(diy: DiyPageModel(useDiy: true, address: '192.168.1.23')),
  'diy_page_no_wifi': const OwnBleViewModel(diy: DiyPageModel(useDiy: true, names: ['A1', 'A2', 'Cz', 'Pz'])),
  'diy_page_blocked': const OwnBleViewModel(
    blocked: 'A night is recording. Stop it first: the headband keeps one connection.',
    diy: DiyPageModel(useDiy: true, address: '192.168.1.23'),
  ),
};

NightViewModel _night(String name) {
  final now = DateTime(2026, 11, 20, 0, 40).millisecondsSinceEpoch;
  final start = DateTime(2026, 11, 19, 23, 50).millisecondsSinceEpoch;
  RecorderStatus st(Phase p, {String note = '', BoardLive? board, int samples = 0}) =>
      RecorderStatus(phase: p, note: note, board: board, nightSamples: samples, lastDataMs: now - 500, nightStartMs: start);
  final recording = st(Phase.recording, board: _board, samples: 250 * 60 * 50);
  final listening = st(Phase.searching, note: 'headband not found; is it on and charged?');
  final s = switch (name) {
    'diy_night_recording' => recording,
    'diy_night_listening' => listening,
    _ => null,
  };
  final running = s != null;
  final d = describeNight(status: s, running: running, nowMs: now, quietMs: 0, diy: (address: '192.168.1.23'));
  return NightViewModel(
    title: d.title,
    sentence: d.sentence,
    tone: d.tone,
    running: running,
    minutes: s?.minutesRecorded,
    dataAgeSeconds: running ? 0 : null,
    rows: running ? stripRows(startMs: start, endMs: now, slots: {now ~/ slotMs: 250 * 60 * 20}, live: true) : const [],
    board: s?.board,
    diyNames: defaultDiyNames,
    checks: phoneChecks(phone: const PhoneSnapshot({'bluetoothOn': false}), nearbyAllowed: false, xiaomiDone: true, bluetooth: false),
  );
}

Future<void> _shoot(WidgetTester tester, Widget w, String name, {required double scale}) async {
  tester.view.physicalSize = const Size(1080, 1080 / 393 * 1900); // the owner's 393 dp, tall enough for the page
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: w)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/${name}_393dp_text${(scale * 100).round()}.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  group('the words', () {
    final now = DateTime(2026, 11, 20, 0, 40).millisecondsSinceEpoch;
    const at = (address: '192.168.1.23');

    test('ready: start the board, answer its prompts, where it sends', () {
      final d = describeNight(status: null, running: false, nowMs: now, quietMs: 0, diy: at);
      expect(d.title, 'Ready');
      expect(d.sentence, 'Start the board and answer its prompts, then start the night. It sends to 192.168.1.23 over Wi-Fi.');
    });

    test('listening, nothing yet; the board\'s own trouble in its own words', () {
      var d = describeNight(
        status: const RecorderStatus(phase: Phase.searching, note: 'headband not found; is it on and charged?'),
        running: true,
        nowMs: now,
        quietMs: 0,
        diy: at,
      );
      expect([d.title, d.tone], ['Listening', Tone.caution]);
      expect(d.sentence, contains('sending to 192.168.1.23, and past its prompts'));
      d = describeNight(
        status: const RecorderStatus(phase: Phase.searching, note: 'could not connect: The board sends 8 channels; ...'),
        running: true,
        nowMs: now,
        quietMs: 0,
        diy: at,
      );
      expect(d.sentence, 'The board sends 8 channels; ...');
    });

    test('recording: says what the chip records and that it is not EEG', () {
      final d = describeNight(
        status: RecorderStatus(phase: Phase.recording, lastDataMs: now, board: _board),
        running: true,
        nowMs: now,
        quietMs: 0,
        diy: at,
      );
      expect([d.title, d.sentence, d.tone], ['Recording', "Recording the board's test signal. It is not EEG.", Tone.live]);
      final quiet = describeNight(
        status: RecorderStatus(phase: Phase.recording, lastDataMs: now - 12000, board: _board),
        running: true,
        nowMs: now,
        quietMs: 0,
        diy: at,
      );
      expect(quiet.sentence, 'No frames for 12 s. Is the board still sending?');
    });

    test('the BrainBit\'s words are unchanged without the board', () {
      final d = describeNight(status: null, running: false, nowMs: now, quietMs: 0);
      expect(d.sentence, 'Put the headband on and switch it on, then start the night.');
    });

    test('phone checks: no Bluetooth or Nearby rows for the board', () {
      const off = PhoneSnapshot({'bluetoothOn': false});
      expect(phoneChecks(phone: off, nearbyAllowed: false, xiaomiDone: true).map((c) => c.text),
          containsAll(['Bluetooth is off.', 'Nearby devices is not allowed, so the app cannot find the headband.']));
      expect(phoneChecks(phone: off, nearbyAllowed: false, xiaomiDone: true, bluetooth: false).map((c) => c.text),
          isNot(contains('Bluetooth is off.')));
    });

    test('the page: the board chosen is a test, in caution amber with its words', () {
      final s = describeOwnBle(_pages['diy_page_on']!);
      expect(s.title, 'DIY board (test)');
      expect(s.color, Night.caution);
      expect(describeOwnBle(_pages['diy_page_blocked']!).title, 'Not now');
      expect(describeOwnBle(_pages['diy_page_brainbit']!).title, "BrainBit's connection");
    });
  });

  for (final scale in [1.0, 1.3]) {
    for (final e in _pages.entries) {
      testWidgets('${e.key} at 393 dp and ${(scale * 100).round()} % text', (tester) async {
        await _shoot(tester, OwnBleView(model: e.value, onDevice: (_) {}, onNames: (_) {}), e.key, scale: scale);
        if (e.value.diyOn) {
          expect(find.text('Safety'), findsOneWidget);
          expect(find.textContaining('This app only listens.'), findsOneWidget);
          expect(find.textContaining('Nothing in this app makes the board safe'), findsOneWidget);
          expect(find.text('Run the probe'), findsNothing); // no probe for the board
        } else {
          expect(find.text('DIY board (test)'), findsOneWidget); // the choice is offered
          expect(find.text('Run the probe'), findsOneWidget);
        }
      });
    }
    for (final name in ['diy_night_recording', 'diy_night_listening', 'diy_night_ready']) {
      testWidgets('$name at 393 dp and ${(scale * 100).round()} % text', (tester) async {
        await _shoot(
          tester,
          NightView(model: _night(name), onStart: () {}, onStop: () {}, onFix: (_) {}, onLightsOff: () {}),
          name,
          scale: scale,
        );
        if (name == 'diy_night_recording') {
          expect(find.text('Test signal, not EEG'), findsOneWidget);
          expect(find.text('Fp1'), findsOneWidget);
          expect(find.textContaining('192.168.1.50'), findsOneWidget);
        }
        if (name == 'diy_night_ready') {
          expect(find.textContaining('No sleep report for the DIY board'), findsOneWidget);
          expect(find.text('DIY board (test). Not connected.'), findsOneWidget);
          expect(find.text('Bluetooth is off.'), findsNothing);
          expect(find.text('Headband: DIY board (test), over Wi-Fi.'), findsOneWidget);
        }
      });
    }
  }

  testWidgets('channel names: a wrong list is refused in words; a good one is saved', (tester) async {
    List<String>? saved;
    tester.view.physicalSize = const Size(1080, 1080 / 393 * 1900);
    tester.view.devicePixelRatio = 1080 / 393;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: OwnBleView(model: _pages['diy_page_on']!, onNames: (n) => saved = n),
      ),
    );
    final field = find.byType(TextField);
    await tester.enterText(field, 'O1, O2, O1, Fp1');
    await tester.pump(); // Save is enabled once the field differs
    await tester.tap(find.text('Save names'));
    await tester.pump();
    expect(find.text('Each channel needs its own name.'), findsOneWidget);
    expect(saved, isNull);
    await tester.enterText(field, 'O1 O2 Cz Pz');
    await tester.pump();
    await tester.tap(find.text('Save names'));
    await tester.pump();
    expect(saved, ['O1', 'O2', 'Cz', 'Pz']);
  });
}
