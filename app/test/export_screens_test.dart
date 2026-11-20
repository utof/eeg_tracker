// Renders the Export data page in its states at a phone's size with real fonts, writes build/screens/export_*.png
// for a human look, and fails on any layout overflow (also at 130 % text). The words of each state are checked
// without a phone (describeExport).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/export/exporter.dart';
import 'package:eeg_tracker/ui/export_view.dart';
import 'package:eeg_tracker/ui/meditation_view.dart' show MarkShape;
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/share_sheet.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';

import 'screens_test.dart' show loadFonts;

final _now = DateTime(2026, 11, 22, 9, 30);
const _gb = 3104000000;

ExportViewModel _m({
  String? folder = 'Download/EEG',
  bool usable = true,
  int pendingFiles = 37,
  int pendingBytes = 210400000,
  DateTime? last,
  ExportProgress? progress,
  ExportOutcome? outcome,
  bool stopping = false,
  String? blocked,
}) => ExportViewModel(
  now: _now,
  folderLabel: folder,
  folderUsable: usable,
  phoneFiles: 412,
  phoneBytes: _gb,
  pendingFiles: pendingFiles,
  pendingBytes: pendingBytes,
  lastComplete: last,
  progress: progress,
  outcome: outcome,
  stopping: stopping,
  blocked: blocked,
);

ExportOutcome _out(int files, int bytes, {bool complete = true, String? error}) =>
    (files: files, bytes: bytes, complete: complete, error: error, notExported: const [], at: _now);

final Map<String, ExportViewModel> _states = {
  'export_first': _m(folder: null, pendingFiles: 412, pendingBytes: _gb),
  'export_never': _m(pendingFiles: 412, pendingBytes: _gb),
  'export_due': _m(last: DateTime(2026, 11, 18, 8, 10)),
  'export_up_to_date': _m(last: DateTime(2026, 11, 22, 8), pendingFiles: 0, pendingBytes: 0),
  'export_copying': _m(
    last: DateTime(2026, 11, 18, 8, 10),
    progress: const ExportProgress(12, 37, 80300000, 210400000, 'recordings/2026-11-21-232410.f32'),
  ),
  'export_done': _m(last: _now, pendingFiles: 0, pendingBytes: 0, outcome: _out(37, 210400000)),
  'export_failed': _m(
    last: DateTime(2026, 11, 18, 8, 10),
    pendingFiles: 25,
    pendingBytes: 130100000,
    outcome: _out(12, 80300000, complete: false, error: 'the folder is gone: pick it again'),
  ),
  'export_lost': _m(usable: false, last: DateTime(2026, 11, 18, 8, 10)),
  'export_blocked': _m(
    last: DateTime(2026, 11, 18, 8, 10),
    blocked: 'A night is recording. Stop it first: nothing is exported while it records.',
  ),
};

Future<void> _shoot(WidgetTester tester, Widget w, String name, {double scale = 1, double height = 980}) async {
  tester.view.physicalSize = Size(1210, height * 2.75); // about a Xiaomi 12T: 440 x 980 dp
  tester.view.devicePixelRatio = 2.75;
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
    final image = await boundary.toImage(pixelRatio: height > 980 ? 2.0 : 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  group('the words of each state', () {
    test('before the first pick: no folder, the button picks one', () {
      final s = describeExport(_states['export_first']!);
      expect(s.title, 'No folder yet');
      expect(s.sentence, contains('Download/EEG'));
    });

    test('3 days with new files: due, amber, and it says what is only on the phone', () {
      final s = describeExport(_states['export_due']!);
      expect(s.title, 'Export due');
      expect(s.color, Night.caution);
      expect(s.mark, MarkShape.ringedDot);
      expect(s.sentence, 'Last export 4 days ago: 37 new files (210 MB) are only on this phone.');
    });

    test('done, stopped by the folder, lost permission, a night recording', () {
      expect(describeExport(_states['export_done']!).sentence,
          '37 files (210 MB) copied into Download/EEG/eeg-export, with the list of every file (manifest.json) for '
          'the laptop to check.');
      final failed = describeExport(_states['export_failed']!);
      expect(failed.title, 'Export stopped');
      expect(failed.color, Night.problem);
      expect(failed.sentence, contains('12 files copied are kept and listed'));
      expect(describeExport(_states['export_lost']!).title, 'Folder lost');
      expect(describeExport(_states['export_blocked']!).title, 'Not now');
      expect(describeExport(_states['export_up_to_date']!).title, 'Up to date');
      expect(describeExport(_states['export_never']!).title, 'Never exported');
    });

    test('the strip counts what reached the folder, copying included', () {
      expect(_states['export_copying']!.exportedBytes, _gb - 210400000 + 80300000);
      expect(_states['export_first']!.exportedBytes, 0);
    });
  });

  for (final scale in [1.0, 1.3]) {
    for (final e in _states.entries) {
      testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
        await _shoot(
          tester,
          ExportView(model: e.value, onPick: () {}, onExportNew: () {}, onExportAll: () {}, onStop: () {}),
          '${e.key}${scale == 1.0 ? '' : '_text130'}',
          scale: scale,
        );
      });
    }
  }

  testWidgets('export_copying_full: the whole page', (tester) async {
    await _shoot(tester, ExportView(model: _states['export_copying']!), 'export_copying_full', height: 1700);
  });

  // Share on Wi-Fi (DECISIONS rows 220-229): the row in Your data in its states, and the sheet.
  const shareOff = (on: false, text: 'Lets your laptop watch the signal and copy the files over your home Wi-Fi.', warn: false, address: null);
  const shareOn = (
    on: true,
    text: 'On at 192.168.1.23:8765 until 10:05. Keep this app open while the laptop copies.',
    warn: false,
    address: '192.168.1.23:8765',
  );
  const shareNoWifi = (
    on: true,
    text: 'On, but no Wi-Fi address found. Join your home Wi-Fi, or use a USB cable: see Address and code.',
    warn: true,
    address: null,
  );
  for (final scale in [1.0, 1.3]) {
    final tag = scale == 1.0 ? '' : '_text130';
    for (final (name, line) in [('off', shareOff), ('on', shareOn), ('no_wifi', shareNoWifi)]) {
      testWidgets('night_share_$name at ${(scale * 100).round()} % text', (tester) async {
        final model = NightViewModel(
          title: 'Ready',
          sentence: 'Last night is saved. Put the headband on to start a new one.',
          tone: Tone.calm,
          running: false,
          nightsOnPhone: 3,
          exportLine: (text: 'Last export yesterday; 3 new files (2.4\u00a0MB) since.', warn: false),
          share: line,
        );
        await _shoot(
          tester,
          NightView(model: model, onStart: () {}, onStop: () {}, onFix: (_) {}, onExport: () {}, onExportData: () {}, onShare: (_) {}, onShareDetails: () {}),
          'night_share_$name${tag}_full',
          scale: scale,
          height: 2100,
        );
        expect(find.text('Share on Wi-Fi'), findsOneWidget);
        expect(find.text('Address and code'), line.on ? findsOneWidget : findsNothing);
        expect(tester.widget<Switch>(find.byType(Switch)).value, line.on);
      });
    }

    testWidgets('night_share_recording at ${(scale * 100).round()} % text: during a night only the switch is in Your data', (tester) async {
      const model = NightViewModel(
        title: 'Recording',
        sentence: 'All is well. You can put the phone down.',
        tone: Tone.live,
        running: true,
        minutes: 12,
        dataAgeSeconds: 0,
        share: (on: true, text: 'On at 192.168.1.23:8765 until 10:05.', warn: false, address: '192.168.1.23:8765'),
      );
      await _shoot(
        tester,
        NightView(model: model, onStart: () {}, onStop: () {}, onFix: (_) {}, onShare: (_) {}, onShareDetails: () {}),
        'night_share_recording${tag}_full',
        scale: scale,
        height: 1500,
      );
      expect(find.text('Your data'), findsOneWidget);
      expect(find.text('Export data'), findsNothing);
    });

    for (final (name, address, night) in [('night', '192.168.1.23', true), ('app', '192.168.1.23', false), ('no_wifi', null, true)]) {
      testWidgets('share_sheet_$name at ${(scale * 100).round()} % text', (tester) async {
        final model = ShareSheetModel(address: address, port: 8765, token: 'kq7m2xwp9dfh', until: DateTime(2026, 11, 23, 10, 5), night: night);
        await _shoot(
          tester,
          Scaffold(backgroundColor: Night.surfaceHigh, body: ShareSheet(model: model, onNewToken: () {})),
          'share_sheet_$name$tag',
          scale: scale,
          height: 1500, // the whole sheet, with "nothing is lost" (DECISIONS 614), at 130 % text too
        );
        expect(find.text('kq7m2xwp9dfh'), findsOneWidget);
        expect(find.text(address == null ? 'not found' : '192.168.1.23:8765'), findsOneWidget);
        expect(find.byType(QrBox), address == null ? findsNothing : findsOneWidget);
        // no address known: the cable way, with commands that work after it (DECISIONS row 563)
        expect(find.text('adb forward tcp:8765 tcp:8765'), address == null ? findsOneWidget : findsNothing);
        expect(find.textContaining('A USB cable works without it'), address == null ? findsOneWidget : findsNothing);
        expect(find.textContaining('scripts/pull_phone.py http://${address ?? '127.0.0.1'}:8765 --token kq7m2xwp9dfh'), findsOneWidget);
        // between nights a notification keeps the app answering in the background (DECISIONS row 589)
        expect(find.textContaining('"Sharing on Wi-Fi" notification'), name == 'app' ? findsOneWidget : findsNothing);
        // the laptop losing the phone loses nothing (the owner's night of 2026-11-20, DECISIONS 614)
        expect(find.textContaining('If the laptop cannot reach the phone, nothing is lost'), findsOneWidget);
      });
    }
  }

  test('the QR code holds the address and the code, with a quiet margin', () {
    final image = QrImage(QrCode(payload: QrPayload.fromString(shareUrl('192.168.1.23', 8765, 'kq7m2xwp9dfh'))));
    expect(image.moduleCount, lessThanOrEqualTo(37)); // 208 dp / (37 + 8) = 4 dp a module at the least
  });

  for (final warn in [true, false]) {
    testWidgets('night_your_data${warn ? '_due' : ''}: the night screen\'s section, whole', (tester) async {
      final model = NightViewModel(
        title: 'Ready',
        sentence: 'Last night is saved. Put the headband on to start a new one.',
        tone: Tone.calm,
        running: false,
        nightsOnPhone: 3,
        exportLine: warn
            ? (text: 'Last export 4 days ago: 37 new files (210\u00a0MB) are only on this phone.', warn: true)
            : (text: 'Last export yesterday; 3 new files (2.4\u00a0MB) since.', warn: false),
      );
      await _shoot(
        tester,
        NightView(model: model, onStart: () {}, onStop: () {}, onFix: (_) {}, onExport: () {}, onExportData: () {}),
        'night_your_data${warn ? '_due' : ''}_full',
        height: 1900,
      );
    });
  }
}
