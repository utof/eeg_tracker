// The Record tab's words for the last recording: a night only when it had a sleep stretch (DECISIONS 1137).
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/ui/home_tabs.dart';
import 'package:eeg_tracker/ui/night_screen.dart';
import 'package:eeg_tracker/ui/night_strip.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _line(String kind, {bool removed = false}) => {
  'span': 'r-1',
  'kind': kind,
  'source': 'owner_button',
  'start': '2026-11-26T14:41:00+03:00',
  'end': '2026-11-26T14:42:00+03:00',
  if (removed) 'removed': true,
};

String _sentence(NightState last) =>
    describeNight(status: null, running: false, nowMs: 0, quietMs: 0, last: last).sentence;

void main() {
  group('did the last recording have a sleep stretch', () {
    test('a Record recording with no sleep marked: no', () {
      expect(lastWasNight(const NightState(samples: 1000, sleepKit: false)), isFalse);
      expect(lastWasNight(NightState(samples: 1000, sleepKit: false, spans: [_line('work')])), isFalse);
    });

    test('a sleep or nap stretch, also one that ended before Stop: yes', () {
      expect(lastWasNight(NightState(samples: 1000, sleepKit: false, spans: [_line('sleep')])), isTrue);
      expect(lastWasNight(NightState(samples: 1000, sleepKit: false, spans: [_line('work'), _line('nap')])), isTrue);
      expect(lastWasNight(const NightState(samples: 1000)), isTrue, reason: 'Start the night, state from an older build');
    });

    test('a sleep stretch taken away ("Not sleep") is no sleep', () {
      expect(lastWasNight(NightState(samples: 1000, sleepKit: false, spans: [_line('sleep', removed: true)])), isFalse);
    });
  });

  test('the status sentence', () {
    expect(_sentence(const NightState(samples: 1000, sleepKit: false)), 'Last recording is saved. Put the headband on to start a new one.');
    expect(_sentence(NightState(samples: 1000, sleepKit: false, spans: [_line('sleep')])), startsWith('Last night is saved'));
  });

  group('the readouts and the hour grid', () {
    final rows = stripRows(startMs: slotMs, endMs: 3 * slotMs, slots: const {1: 100}, live: false);
    Widget host({required bool night}) => MaterialApp(
      theme: nightTheme(),
      home: NightView(
        tab: HomeTab.night,
        model: NightViewModel(
          title: 'Ready',
          sentence: '',
          tone: Tone.calm,
          running: false,
          minutes: 1,
          coverage: 0.02,
          lastWasNight: night,
          stripTitle: night ? 'Last night' : 'Last recording',
          rows: rows,
        ),
        onStart: () {},
        onStop: () {},
        onFix: (_) {},
      ),
    );

    testWidgets('no sleep: plain "recorded", no share of a night, no "night" anywhere', (tester) async {
      tester.view.physicalSize = const Size(1080, 6000); // tall: the hour grid is built too
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(night: false));
      expect(find.text('recorded'), findsOneWidget);
      expect(find.text('recorded last night'), findsNothing);
      expect(find.text('of the night saved'), findsNothing);
      expect(find.textContaining('ast night'), findsNothing);
      expect(find.text('Last recording'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with sleep: the night wording stays', (tester) async {
      await tester.pumpWidget(host(night: true));
      expect(find.text('recorded last night'), findsOneWidget);
      expect(find.text('of the night saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
