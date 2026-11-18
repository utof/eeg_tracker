// Renders the night screen in its main states at a phone's size with real fonts, writes PNGs to
// build/screens/ for a human look, and fails on any layout overflow (also at 130 % font size).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/phone.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/ui/night_strip.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/phone_checks.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return; // text renders as boxes; layout is still checked
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> f(String name) async => ByteData.sublistView(File('$dir/$name').readAsBytesSync());
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Light']) {
    roboto.addFont(f('Roboto-$w.ttf'));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(f('MaterialIcons-Regular.otf'))).load();
}

final _night = DateTime(2026, 11, 18, 23, 12);
final _now = DateTime(2026, 11, 19, 2, 44);

List<StripRow> _rows({required DateTime end, required bool live}) {
  final slots = <int, int>{};
  for (var t = _night; t.isBefore(end); t = t.add(const Duration(seconds: 30))) {
    final gap = t.isAfter(DateTime(2026, 11, 19, 1, 3)) && t.isBefore(DateTime(2026, 11, 19, 1, 9));
    if (!gap) {
      slots.update(t.millisecondsSinceEpoch ~/ slotMs, (v) => v + 30 * sampleRateHz, ifAbsent: () => 30 * sampleRateHz);
    }
  }
  return stripRows(startMs: _night.millisecondsSinceEpoch, endMs: end.millisecondsSinceEpoch, slots: slots, live: live);
}

const _xiaomi = PhoneCheck(
  'Xiaomi: turn on Autostart, set Battery saver to No restrictions, and lock the app in Recents. '
  'Android cannot tell the app whether this is done.',
  [
    ('Autostart', FixAction.xiaomiAutostart),
    ('Battery saver', FixAction.xiaomiBatterySaver),
    ('Done', FixAction.xiaomiDone),
  ],
  serious: false,
);

final Map<String, NightViewModel> states = {
  'recording': NightViewModel(
    title: 'Recording',
    sentence: 'All is well. You can put the phone down.',
    tone: Tone.live,
    running: true,
    minutes: 206.4,
    dataAgeSeconds: 1,
    rows: _rows(end: _now, live: true),
    battery: 78,
    rssi: -64,
    contactOhms: const {'O1': 4.2e5, 'O2': 6.1e5, 'T3': 1.8e6, 'T4': 3.4e6},
    checks: phoneChecks(
      phone: const PhoneSnapshot({'sdkInt': 34, 'ignoringBatteryOptimizations': true, 'bluetoothOn': true}),
      nearbyAllowed: true,
      xiaomiDone: true,
    ),
    filesPath: 'Android/media/io.github.utof.eeg_tracker/recordings',
  ),
  'no_data': NightViewModel(
    title: 'No data',
    sentence: 'No data for 52 s. The recorder will reconnect.',
    tone: Tone.problem,
    running: true,
    minutes: 206.4,
    dataAgeSeconds: 52,
    rows: _rows(end: _now, live: true),
    battery: 77,
    rssi: -88,
    contactOhms: const {'O1': 4.2e5, 'O2': 6.1e5, 'T3': 1.8e6, 'T4': 3.4e6},
    checks: const [_xiaomi],
  ),
  'first_run': NightViewModel(
    title: 'Ready',
    sentence: 'Put the headband on and switch it on, then start the night.',
    tone: Tone.calm,
    running: false,
    checks: phoneChecks(
      phone: const PhoneSnapshot({
        'sdkInt': 34,
        'bluetoothOn': false,
        'notificationsEnabled': false,
        'hyperOs': 'OS1.0',
      }),
      nearbyAllowed: false,
      xiaomiDone: false,
    ),
  ),
  'morning': NightViewModel(
    title: 'Ready',
    sentence: 'Last night is saved. Put the headband on to start a new one.',
    tone: Tone.calm,
    running: false,
    minutes: 431.2,
    coverage: nightCoverage(_rows(end: DateTime(2026, 11, 19, 6, 23), live: false)),
    stripTitle: 'Last night',
    rows: _rows(end: DateTime(2026, 11, 19, 6, 23), live: false),
    contactOhms: const {'O1': 4.2e5, 'O2': 6.1e5, 'T3': 1.8e6, 'T4': 3.4e6},
    checks: const [],
    filesPath: 'Android/media/io.github.utof.eeg_tracker/recordings',
  ),
};

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1210, 2695); // about a Xiaomi 12T: 440 x 980 dp
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightTheme(),
              home: RepaintBoundary(
                key: key,
                child: NightView(model: e.value, onStart: () {}, onStop: () {}, onFix: (_) {}),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.75);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('build/screens/${e.key}${scale == 1.0 ? '' : '_text130'}.png')..createSync(recursive: true);
          out.writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }
}
