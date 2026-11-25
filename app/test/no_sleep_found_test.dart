// "No sleep found" (spec section 6, DECISIONS 886 and 987): a sleep stretch the app started by itself (the headband
// watcher's evening guess) gets a night's report only when its scoring finds 10 minutes or more asleep; under that it
// is listed as "no sleep found" and counts for nothing. A stretch you pressed always counts.
import 'dart:convert';

import 'package:eeg_tracker/sleep/model.dart' show phoneModelId;
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/trends/sleep_days.dart' show countsForSleepNumbers;
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scored report of 3 hours with [asleepMin] asleep in one stretch, from a span that came [from].
Map<String, dynamic> _rep(double asleepMin, String? from) {
  final start = DateTime(2026, 11, 22, 22, 10);
  final asleep = (asleepMin * 2).round();
  final stages = [for (var i = 0; i < 360; i++) i >= 40 && i < 40 + asleep ? 'N2' : 'W'];
  final j = (jsonDecode(
            jsonEncode(
              buildReport(
                nightOf: '2026-11-22',
                built: start.add(const Duration(hours: 4)),
                scoringSeconds: 30,
                start: start,
                lengthSeconds: 3 * 3600,
                inputs: const {'2026-11-22-221000.f32': 1000},
                model: phoneModelId,
                stages: stages,
                confidence: List.filled(stages.length, 0.8),
              ),
            ),
          )
          as Map)
      .cast<String, dynamic>();
  if (from != null) {
    j['span'] = {
      'recording': ['2026-11-22-221000'],
      'spans': ['2026-11-22-221000-1'],
      'kind': 'night',
      'from': from,
    };
  }
  return j;
}

void main() {
  test('an auto-started sleep with under 10 minutes asleep is marked; 10 minutes or a pressed one is not', () {
    expect(markNoSleepFound(_rep(6, 'auto'))['no_sleep_found'], isTrue);
    expect(markNoSleepFound(_rep(0, 'auto'))['no_sleep_found'], isTrue);
    expect(markNoSleepFound(_rep(6, 'migrated'))['no_sleep_found'], isTrue);
    expect(markNoSleepFound(_rep(10, 'auto')).containsKey('no_sleep_found'), isFalse);
    expect(markNoSleepFound(_rep(45, 'auto')).containsKey('no_sleep_found'), isFalse);
    expect(markNoSleepFound(_rep(0, 'pressed')).containsKey('no_sleep_found'), isFalse, reason: 'a night you pressed is worth seeing');
    expect(markNoSleepFound(_rep(0, 'confirmed')).containsKey('no_sleep_found'), isFalse);
    expect(markNoSleepFound(_rep(0, null)).containsKey('no_sleep_found'), isFalse, reason: 'an old report has no span');
    // a second scoring that finds sleep takes the mark away
    final again = _rep(45, 'auto')..['no_sleep_found'] = true;
    expect(markNoSleepFound(again).containsKey('no_sleep_found'), isFalse);
    expect(noSleepFoundBelowMin, 10);
  });

  test('a report marked so counts for no sleep number', () {
    final found = SleepReport(markNoSleepFound(_rep(45, 'auto')));
    final none = SleepReport(markNoSleepFound(_rep(6, 'auto')));
    expect(found.noSleepFound, isFalse);
    expect(none.noSleepFound, isTrue);
    expect(countsForSleepNumbers(found), isTrue);
    expect(countsForSleepNumbers(none), isFalse);
  });

  testWidgets('the Record tab says "No sleep found" for it, in plain words', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: NightView(
          model: const NightViewModel(
            title: 'Not recording',
            sentence: '',
            tone: Tone.calm,
            running: false,
            sleep: SleepSummary(nightOf: '2026-11-22', scored: true, asleepMin: 6, noSleepFound: true),
          ),
          onStart: () {},
          onStop: () {},
          onFix: (_) {},
        ),
      ),
    );
    expect(find.textContaining('No sleep found'), findsOneWidget);
    expect(find.textContaining('under 10 minutes'), findsOneWidget);
    expect(find.textContaining('asleep, night of'), findsNothing);
  });
}
