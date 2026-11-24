// Nothing the owner typed reaches the usage log, and no experiment's name (DECISIONS 757). A tap's label is the words
// under the tapped control; words the owner typed (a tag, an experiment's line, a note, the board's channel names) are
// wrapped in `OwnText` where they are shown, and the label skips them. Every test here shows a made-up secret inside a
// control and reads the label the tap would get (`tapTarget`, the same call the usage log makes).
import 'dart:io';

import 'package:eeg_tracker/archive/bands.dart';
import 'package:eeg_tracker/archive/items.dart';
import 'package:eeg_tracker/archive/tags.dart';
import 'package:eeg_tracker/experiments/experiment.dart';
import 'package:eeg_tracker/experiments/store.dart';
import 'package:eeg_tracker/signal/layout.dart';
import 'package:eeg_tracker/signal/head3d.dart';
import 'package:eeg_tracker/signal/live_signal.dart';
import 'package:eeg_tracker/signal/signal_feed.dart';
import 'package:eeg_tracker/try_these/cards.dart';
import 'package:eeg_tracker/try_these/progress.dart';
import 'package:eeg_tracker/logs/own_text.dart';
import 'package:eeg_tracker/logs/usage_watch.dart';
import 'package:eeg_tracker/ui/archive_sheets.dart';
import 'package:eeg_tracker/ui/archive_view.dart';
import 'package:eeg_tracker/ui/experiments_view.dart';
import 'package:eeg_tracker/ui/recording_view.dart';
import 'package:eeg_tracker/ui/signal_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/try_these_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

const String secret = 'zebra-secret';

/// What the usage log would say for a tap at the middle of [finder].
TapTarget? labelAt(WidgetTester tester, Finder finder) => tapTarget(tester.getCenter(finder.first), tester.view.viewId);

Future<void> show(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: Scaffold(body: SingleChildScrollView(child: w))));
  await tester.pump();
}

void noSecret(TapTarget? t) {
  expect(t, isNotNull);
  expect('${t!.label}|${t.id}|${t.control}', isNot(contains(secret)));
}

DateTime _t(int h, int m) => DateTime(2026, 11, 18, h, m);

ArchiveItem _taggedNight() => ArchiveItem(
  id: '2026-11-18-231200',
  kind: ArchiveKind.night,
  start: _t(9, 0),
  end: _t(17, 0),
  started: byHand(ArchiveKind.night),
  tags: TagsFile(id: 'x', tags: [ManualTag(start: _t(10, 0), end: _t(11, 0), label: secret, made: _t(12, 0))]),
);

void main() {
  setUpAll(loadFonts);

  group('the marker', () {
    testWidgets('a row\'s own words are the label; the marked words are skipped', (tester) async {
      await show(
        tester,
        ListTile(title: const OwnText(child: Text(secret)), subtitle: const Text('Open it'), onTap: () {}),
      );
      final t = labelAt(tester, find.byType(ListTile));
      expect(t!.label, 'Open it');
      noSecret(t);
    });

    testWidgets('a control with only marked words has no label, and keeps its kind and key', (tester) async {
      await show(
        tester,
        ListTile(key: const ValueKey('row'), title: const OwnText(child: Text(secret)), onTap: () {}),
      );
      final t = labelAt(tester, find.byType(ListTile));
      expect(t!.label, isNull);
      expect(t.control, 'ListTile');
      expect(t.id, 'row');
    });

    testWidgets('a bare switch is named by the unmarked words of its row', (tester) async {
      await show(
        tester,
        Row(
          children: [
            const OwnText(child: Text(secret)),
            const Text('Remind me'),
            Switch(value: false, onChanged: (_) {}),
          ],
        ),
      );
      final t = labelAt(tester, find.byType(Switch));
      expect(t!.label, 'Remind me');
    });

    testWidgets('a tooltip inside the marker is not the label', (tester) async {
      await show(
        tester,
        OwnText(child: IconButton(onPressed: () {}, tooltip: 'Play $secret', icon: const Icon(Icons.play_arrow))),
      );
      final t = labelAt(tester, find.byType(IconButton));
      noSecret(t);
      expect(t!.control, 'IconButton');
    });

    testWidgets('an ordinary tooltip is still the label', (tester) async {
      await show(tester, IconButton(onPressed: () {}, tooltip: 'Settings', icon: const Icon(Icons.settings)));
      expect(labelAt(tester, find.byType(IconButton))!.label, 'Settings');
    });
  });

  group('where the owner\'s words are shown inside a control', () {
    testWidgets('a lane\'s bands: the tag\'s word is not in the row\'s label', (tester) async {
      final tag = ManualTag(start: _t(10, 0), end: _t(11, 0), label: secret, made: _t(12, 0));
      final band = Band(Lane.tags, tag.start, tag.end, tag.label, source: 'Your tag.', tone: BandTone.yours, tag: tag);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: Builder(
            builder: (c) => TextButton(onPressed: () => showLaneSheet(c, Lane.tags, [band]), child: const Text('open')),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining(secret), findsOneWidget);
      noSecret(labelAt(tester, find.textContaining(secret)));
    });

    testWidgets('a recording\'s tags: the tag\'s word is not in the row\'s label', (tester) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: RecordingView(model: RecordingViewModel(item: _taggedNight()), onTag: (_) {}, onAddTag: () {}),
        ),
      );
      await tester.pump();
      expect(find.text(secret), findsOneWidget);
      final t = labelAt(tester, find.text(secret));
      noSecret(t);
      expect(t!.control, isNot('nothing'));
    });

    testWidgets('the archive\'s row: the tags line is not in the label', (tester) async {
      await show(tester, ArchiveRow(item: _taggedNight(), onTap: () {}));
      expect(find.textContaining(secret), findsOneWidget);
      noSecret(labelAt(tester, find.textContaining(secret)));
    });

    testWidgets('an earlier experiment\'s row: its line is not in the label', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('private_exp');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final store = ExperimentStore(Directory('${tmp.path}/experiments'));
      final made = DateTime(2026, 11, 19, 14, 30);
      store.create(
        preset: 'custom',
        doText: 'Cold shower $secret',
        dontText: 'As usual',
        outcome: outcomeById('asleep')!,
        weeks: 4,
        now: made,
      );
      final state = store.all(DateTime(2026, 12, 25)).single;
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: ExperimentView(page: null, earlier: [state], onOpen: (_) {}, onNew: () {}),
        ),
      );
      await tester.pump();
      expect(find.textContaining(secret), findsOneWidget);
      noSecret(labelAt(tester, find.textContaining(secret)));
    });
    testWidgets('a "Try these" card: the owner\'s note is not in the header\'s label', (tester) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final page = buildTryPage(tryCards, {'nap': const CardProgress(note: 'Not yet: $secret')});
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: TryTheseView(
            page: page,
            expanded: null,
            showFinished: false,
            onToggle: (_) {},
            onOpen: (_) {},
            onDone: (_) {},
            onSkip: (_) {},
            onReopen: (_) {},
            onNote: (_, _) {},
            onShowFinished: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining(secret), findsOneWidget);
      noSecret(labelAt(tester, find.textContaining(secret)));
    });

    testWidgets('an electrode row of the Signal page: a site named by the owner is not in the label', (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final m = diyBoardMontage(const ['O1', secret, 'Fz', 'Fp1']);
      final model = SignalViewModel(stage: SignalStage.live, kind: FeedKind.own, montage: m, measuresContact: false, diy: true, dataAge: 0);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: SignalView(
            model: model,
            signal: LiveSignal(names: m.names),
            frames: ValueNotifier<int>(0),
            pose: ValueNotifier(HeadPose.initial),
            initialPart: SignalPart.head,
            onAction: (_) {},
            onPositions: () {},
            onInfo: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.dragUntilVisible(find.text(secret), find.byType(ListView).first, const Offset(0, -250));
      await tester.pump();
      final t = labelAt(tester, find.text(secret));
      noSecret(t);
      expect(t!.control, isNot('nothing'));
      // a 10-10 name is the same word for everybody, and stays
      expect(labelAt(tester, find.text('Fz'))!.label, contains('Fz'));
    });
  });

  test('a session\'s name in the usage log and the app log is a fixed word, never built from what the owner typed', () {
    // `session:<title>` (Activity, the battery samples, the usage log) and "session held: <title>" (the app log) take
    // the title of a KeepSpec: each must be a plain string or the built-in sound preset's name
    final titles = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r'KeepSpec\(\s*title:\s*([^,]+),').allMatches(f.readAsStringSync())) {
        titles.add(m.group(1)!.trim());
      }
    }
    expect(titles.length, greaterThanOrEqualTo(7));
    for (final t in titles) {
      expect(RegExp(r"^'[^'$]*'$").hasMatch(t) || t == 'plan.preset.name', isTrue, reason: 'KeepSpec title: $t');
    }
  });
}
