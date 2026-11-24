// The main screen's bottom bar (DECISIONS 597): every entry of the one-page night screen is on some tab, between
// nights and during one; Start night is on the first tab, which the app opens on; system Back on another tab returns to
// Night; the bar has five destinations. Shots at 393 dp with 100 and 130 % text in build/screens/tabs_*.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/ui/home_tabs.dart';
import 'package:eeg_tracker/ui/morning_section.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

void _no() {}

NightViewModel _model({required bool running}) => NightViewModel(
  title: running ? 'Recording' : 'Ready',
  sentence: running ? 'All is well. You can put the phone down.' : 'Last night is saved. Put the headband on to start a new one.',
  tone: running ? Tone.live : Tone.calm,
  running: running,
  minutes: 192,
  dataAgeSeconds: running ? 1 : null,
  coverage: running ? null : 0.97,
  battery: running ? 80 : null,
  rssi: running ? -64 : null,
  contactOhms: const {'O1': 8e5, 'O2': 9e5, 'T3': 1.8e6, 'T4': null},
  nightsOnPhone: 3,
  exportLine: running ? null : (text: 'Last export yesterday; 3 new files since.', warn: false),
  sleep: running ? null : const SleepSummary(nightOf: '2026-11-19', scored: true, asleepMin: 412, periods: 2),
  dreamLine: 'Last session: 3 answers, Tue 18 Nov 23:10.',
  napLine: 'Last nap: 30 min.',
  lucidLine: 'On: practise before you sleep.',
  share: (on: true, text: 'Shared on Wi-Fi at 192.168.1.23 until 08:00.', warn: false, address: '192.168.1.23'),
  alarmLine: running ? 'Alarm 07:00-07:30.' : 'Smart alarm off.',
  alarmAction: running ? 'Alarm off' : 'Set alarm',
  lightsOffLine: running ? 'Tap Lights off as you close your eyes to sleep.' : null,
);

NightView _page(NightViewModel m, HomeTab? tab) => NightView(
  model: m,
  tab: tab,
  onStart: _no,
  onStop: _no,
  onFix: (_) {},
  onExport: _no,
  onExportData: _no,
  onShare: (_) {},
  onShareDetails: _no,
  onMeditate: _no,
  onDream: _no,
  onNap: _no,
  onLucid: _no,
  onSound: _no,
  onWork: _no,
  onSleepReport: _no,
  onRetrySleep: _no,
  morning: const MorningSection(doneAt: null, onCheckIn: _no, onTrends: _no),
  onLightsOff: _no,
  onSettings: _no,
  onAlarm: _no,
  onAwake: _no,
  onLicences: _no,
);

Widget _tabs(NightViewModel m, {GlobalKey<HomeTabsState>? key}) => HomeTabs(
  key: key,
  page: (context, tab) => switch (tab) {
    HomeTab.signal => const Scaffold(body: Center(child: Text('the Signal page'))),
    HomeTab.trends => const Scaffold(body: Center(child: Text('the Trends page'))),
    _ => _page(m, tab),
  },
);

/// Every text on screen (buttons' labels too), on a page tall enough to build every section.
Set<String> _texts(WidgetTester tester) => {
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    if (t.data != null) t.data! else if (t.textSpan != null) t.textSpan!.toPlainText(),
};

Future<void> _pump(WidgetTester tester, Widget w, {double height = 6000, double scale = 1}) async {
  tester.view.physicalSize = Size(1080, 1080 / 393 * height);
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: w),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(loadFonts);

  test('the sections split at the marks; null keeps them all', () {
    const a = Text('a'), b = Text('b'), c = Text('c');
    final all = <Widget>[a, const TabStart(HomeTab.more), b, const TabStart(HomeTab.sessions), c];
    expect(sectionsFor(HomeTab.night, all), [a]);
    expect(sectionsFor(HomeTab.more, all), [b]);
    expect(sectionsFor(HomeTab.sessions, all), [c]);
    expect(sectionsFor(HomeTab.signal, all), isEmpty);
    expect(sectionsFor(null, all), [a, b, c]);
  });

  for (final running in [false, true]) {
    final when = running ? 'during a night' : 'between nights';
    testWidgets('every entry of the one-page screen is on some tab, $when', (tester) async {
      final m = _model(running: running);
      await _pump(tester, _page(m, null));
      final whole = _texts(tester);
      final key = GlobalKey<HomeTabsState>();
      await _pump(tester, _tabs(m, key: key));
      final seen = <String>{};
      final where = <HomeTab, Set<String>>{};
      for (final t in HomeTab.values) {
        key.currentState!.go(t);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        where[t] = _texts(tester);
        seen.addAll(where[t]!);
      }
      expect(whole.difference(seen), isEmpty, reason: 'on no tab');
      // the night's controls are on the first tab
      if (running) {
        expect(where[HomeTab.night], containsAll(['Lights off', 'Stop', 'Recording', 'Headband']));
        expect(where[HomeTab.sessions], contains('Sound'));
        expect(where[HomeTab.sessions]!.any((s) => s.startsWith('The headband is busy with the night')), isTrue);
        expect(where[HomeTab.more]!.any((s) => s.contains('Shared on Wi-Fi')), isTrue);
      } else {
        expect(where[HomeTab.night], containsAll(['Sleep', 'Sleep report', 'Morning check-in', 'Try these', 'Phone']));
        expect(where[HomeTab.sessions], containsAll(['Meditate', 'Dream catcher', 'Nap coach', 'Lucid dreams', 'Work session', 'Sound']));
        expect(where[HomeTab.more], containsAll(['Export data', 'Export a night', 'Settings', 'Licences']));
        expect(where[HomeTab.night], isNot(contains('Meditate')));
        expect(where[HomeTab.sessions], isNot(contains('Sleep')));
      }
      expect(where[HomeTab.signal], contains('the Signal page'));
      expect(where[HomeTab.trends], contains('the Trends page'));
    });
  }

  testWidgets('the app opens on Night with Start night pinned; the bar has five tabs; Back returns to Night', (tester) async {
    final key = GlobalKey<HomeTabsState>();
    await _pump(tester, _tabs(_model(running: false), key: key), height: 873);
    expect(key.currentState!.tab, HomeTab.night);
    expect(find.ancestor(of: find.text('Sleep'), matching: find.bySubtype<FilledButton>()), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    for (final t in HomeTab.values) {
      expect(find.text(t.label), findsWidgets);
    }
    await tester.tap(find.text('Sessions'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(key.currentState!.tab, HomeTab.sessions);
    expect(find.ancestor(of: find.text('Sleep'), matching: find.bySubtype<FilledButton>()), findsNothing); // pinned only on Night
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));
    expect(key.currentState!.tab, HomeTab.night);
    expect(find.ancestor(of: find.text('Sleep'), matching: find.bySubtype<FilledButton>()), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });

  for (final scale in [1.0, 1.3]) {
    for (final (tab, running) in [(HomeTab.night, false), (HomeTab.night, true), (HomeTab.sessions, false), (HomeTab.more, false)]) {
      testWidgets('tabs ${tab.name}${running ? ' recording' : ''} at 393 dp and ${(scale * 100).round()} % text', (tester) async {
        final key = GlobalKey<HomeTabsState>();
        final shot = GlobalKey();
        await _pump(tester, RepaintBoundary(key: shot, child: _tabs(_model(running: running), key: key)), height: 873, scale: scale);
        key.currentState!.go(tab);
        await tester.pump(const Duration(seconds: 1)); // the bar's pill has moved
        expect(tester.takeException(), isNull);
        final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/screens/tabs_${tab.name}${running ? '_recording' : ''}_393dp_text${(scale * 100).round()}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }
}
