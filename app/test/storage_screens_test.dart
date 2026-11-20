// Renders the Storage page (storage_view.dart; DECISIONS 690-699) in its states at the owner's phone width (393 dp),
// with real fonts, writes PNGs to build/screens/storage_*.png for a human look (the first viewport and the whole
// column), and fails on any layout overflow (also at 130 % text). The sizes are made up for the pictures.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/storage/clear.dart';
import 'package:eeg_tracker/ui/storage_screen.dart';
import 'package:eeg_tracker/ui/storage_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final StorageUsage _usage = StorageUsage(
  bytes: const {
    'nights.raw': 2140000000,
    'nights.reports': 6200000,
    'work.raw': 610000000,
    'work.summaries': 900000,
    'meditation.sessions': 1200000,
    'sound.sessions': 400000,
    'dream.audio': 88000000,
    'dream.text': 300000,
    'dream.sessions': 2100000,
    'checkins.raw': 41000000,
    'checkins.results': 700000,
    'logs.recorder': 9300000,
    'cache.all': 31000000,
    'other.all': 4800000,
  },
  files: const {},
  clearable: const {'nights.raw': 1210000000, 'work.raw': 610000000, 'dream.audio': 60000000, 'logs.recorder': 8000000, 'cache.all': 31000000},
  phoneOnly: const {'nights.raw': 930000000, 'dream.audio': 28000000, 'checkins.raw': 41000000},
  phoneOnlyCount: const {'nights.raw': 5, 'dream.audio': 7, 'checkins.raw': 12},
  why: const {'nights.raw': 'not checked on the laptop yet'},
  onLaptop: 14300000000,
);

const ({int total, int free}) _space = (total: 128000000000, free: 41200000000);

final Map<String, StorageViewModel> states = {
  'overview': StorageViewModel(usage: _usage, space: _space, paired: true, laptop: 'desk'),
  'selected': StorageViewModel(
    usage: _usage,
    space: _space,
    paired: true,
    laptop: 'desk',
    expanded: const {'nights', 'dream'},
    selected: const {'nights.raw', 'dream.audio'},
    danger: const {'checkins.raw'},
  ),
  'unpaired': StorageViewModel(usage: _usage, space: _space, busy: 'A night records: clearing waits until Stop.'),
  'loading': const StorageViewModel(),
};

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Widget _app(Widget child, double scale, GlobalKey key) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: nightTheme(),
      home: RepaintBoundary(key: key, child: child),
    ),
  ),
);

StorageView _view(StorageViewModel m) => StorageView(
  model: m,
  onSelect: (_, _) {},
  onExpand: (_) {},
  onKeep: (_, _) {},
  onClear: () {},
  onDanger: (_, _) {},
  onDangerDelete: () {},
  onSegment: (_) {},
);

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    final suffix = scale == 1.0 ? '' : '_text130';
    for (final e in states.entries) {
      for (final full in [false, true]) {
        testWidgets('storage ${e.key}${full ? ' (whole column)' : ''} at ${(scale * 100).round()} % text', (tester) async {
          tester.view.physicalSize = Size(1080, full ? 2.75 * 3600 : 2400);
          tester.view.devicePixelRatio = 2.75;
          addTearDown(tester.view.reset);
          final key = GlobalKey();
          await tester.pumpWidget(_app(_view(e.value), scale, key));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          await _shot(tester, key, 'storage_${e.key}${full ? '_full' : ''}$suffix');
        });
      }
    }
  }

  // The real page reads the folder in a background isolate: what it sends there must be plain data, not the page
  // (a closure made inside the page's own methods carried the page with it, the send failed and the page showed 0 MB;
  // the emulator, integration 17).
  testWidgets('the real page reads the folder off the screen\'s thread and shows its bytes', (tester) async {
    final root = Directory.systemTemp.createTempSync('storage_screen');
    addTearDown(() => root.deleteSync(recursive: true));
    final files = Directory('${root.path}/files')..createSync();
    File('${files.path}/nights/2026-11-18.report.json')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(2000000, 32));
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: StorageScreen(
          filesDir: files.path,
          paired: false,
          busy: () async => null,
          space: () async => (total: 64000000000, free: 30000000000),
        ),
      ),
    );
    StorageUsage? usage() => tester.widget<StorageView>(find.byType(StorageView)).model.usage;
    for (var i = 0; i < 100 && usage() == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(usage(), isNotNull);
    expect(usage()!.bytes['nights.reports'], 2000000);
  });
}
