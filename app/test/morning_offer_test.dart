// The morning check-in offer (DECISIONS 1110): the pure rule, each condition on and off with its edges, and the one
// line above the Record tab's buttons (shown, its two buttons, hidden when the rule says no).
import 'package:eeg_tracker/morning/offer.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/ui/home_tabs.dart';
import 'package:eeg_tracker/ui/morning_offer_line.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Span _span(
  String id, {
  String kind = 'sleep',
  required DateTime start,
  DateTime? end,
  String endedBy = 'owner',
  bool removed = false,
}) => Span(id: id, kind: kind, start: start, end: end, endedBy: end == null ? null : endedBy, source: 'owner_button', removed: removed);

final DateTime _wake = DateTime(2026, 11, 26, 7, 12);
final DateTime _bed = DateTime(2026, 11, 25, 23, 30);
final DateTime _now = DateTime(2026, 11, 26, 7, 20);

Span _sleep({DateTime? start, DateTime? end, String kind = 'sleep', String endedBy = 'owner'}) =>
    _span('r-1', kind: kind, start: start ?? _bed, end: end ?? _wake, endedBy: endedBy);

MorningOffer? _offer(
  List<Span> spans, {
  DateTime? now,
  DateTime? data,
  DateTime? lastCheckIn,
  String? dismissed,
}) => morningOffer(
  spans: spans,
  now: now ?? _now,
  lastDataAt: data ?? (now ?? _now).subtract(const Duration(seconds: 5)),
  lastCheckIn: lastCheckIn,
  dismissedSpanId: dismissed,
);

void main() {
  group('the rule', () {
    test('a long sleep the owner ended, data arriving: the offer with the wake time', () {
      final o = _offer([_sleep()]);
      expect(o, isNotNull);
      expect(o!.spanId, 'r-1');
      expect(o.line, 'Slept until 07:12. Morning check-in now? About 6 minutes.');
    });

    test('3 hours or more of sleep: 2 h 59 min no, 3 h yes', () {
      expect(_offer([_sleep(start: _wake.subtract(const Duration(hours: 2, minutes: 59)))]), isNull);
      expect(_offer([_sleep(start: _wake.subtract(const Duration(hours: 3)))]), isNotNull);
    });

    test('a nap, or a sleep the app or the 60-minute rule ended, gets no offer', () {
      expect(_offer([_sleep(kind: 'nap')]), isNull);
      for (final by in ['headband_off', 'recording_stopped', 'other_activity', 'left_open', 'undone', 'activity']) {
        expect(_offer([_sleep(endedBy: by)]), isNull, reason: by);
      }
    });

    test('ended between 04:00 and 13:00: both edges in, a minute outside out', () {
      for (final (h, m, on) in [(3, 59, false), (4, 0, true), (13, 0, true), (13, 1, false)]) {
        final end = DateTime(2026, 11, 26, h, m);
        final now = end.add(const Duration(minutes: 5));
        expect(_offer([_sleep(start: end.subtract(const Duration(hours: 8)), end: end)], now: now) != null, on, reason: '$h:$m');
      }
    });

    test('at most 2 hours after the end', () {
      expect(_offer([_sleep()], now: _wake.add(const Duration(hours: 2))), isNotNull);
      expect(_offer([_sleep()], now: _wake.add(const Duration(hours: 2, seconds: 1))), isNull);
    });

    test('data in the last 2 minutes: 2:00 yes, 2:01 no, none at all no', () {
      expect(_offer([_sleep()], data: _now.subtract(const Duration(minutes: 2))), isNotNull);
      expect(_offer([_sleep()], data: _now.subtract(const Duration(minutes: 2, seconds: 1))), isNull);
      expect(
        morningOffer(spans: [_sleep()], now: _now, lastDataAt: null, lastCheckIn: null, dismissedSpanId: null),
        isNull,
      );
    });

    test('no check-in since the sleep ended: one before it does not count, one after it does', () {
      expect(_offer([_sleep()], lastCheckIn: _wake.subtract(const Duration(minutes: 1))), isNotNull);
      expect(_offer([_sleep()], lastCheckIn: _wake), isNull);
      expect(_offer([_sleep()], lastCheckIn: _wake.add(const Duration(minutes: 3))), isNull);
    });

    test('a check_in span of the recording after the sleep: no offer; one before it does not count', () {
      final after = _span('r-2', kind: 'check_in', start: _wake.add(const Duration(minutes: 1)), end: _wake.add(const Duration(minutes: 8)));
      final before = _span('r-0', kind: 'check_in', start: _bed.subtract(const Duration(hours: 5)), end: _bed.subtract(const Duration(hours: 4)));
      expect(_offer([_sleep(), after]), isNull);
      expect(_offer([before, _sleep()]), isNotNull);
    });

    test('something else marked open now: no offer', () {
      expect(_offer([_sleep(), _span('r-2', kind: 'work', start: _wake.add(const Duration(minutes: 2)))]), isNull);
      expect(_offer([_sleep(), _span('r-2', kind: 'work', start: _wake.add(const Duration(minutes: 2)), end: _wake.add(const Duration(minutes: 4)), endedBy: 'owner')]), isNotNull);
    });

    test('Not now for this sleep stretch hides it; another stretch is offered again', () {
      expect(_offer([_sleep()], dismissed: 'r-1'), isNull);
      expect(_offer([_sleep()], dismissed: 'r-9'), isNotNull);
    });

    test('a removed sleep span is no sleep; the newest sleep stretch is the one that counts', () {
      expect(_offer([_span('r-1', start: _bed, end: _wake, endedBy: 'owner', removed: true)]), isNull);
      final later = _span('r-2', start: _wake.add(const Duration(minutes: 20)), end: _wake.add(const Duration(minutes: 30)), endedBy: 'owner');
      expect(_offer([_sleep(), later], now: _wake.add(const Duration(minutes: 40))), isNull);
    });

    test('no spans: nothing', () {
      expect(_offer(const []), isNull);
    });
  });

  group('the line', () {
    final offer = MorningOffer(spanId: 'r-1', sleptUntil: _wake);
    Widget host(Widget? ask) => MaterialApp(
      theme: nightTheme(),
      home: NightView(
        tab: HomeTab.night,
        model: const NightViewModel(title: 'Recording', sentence: '', tone: Tone.live, running: true, spansLine: 'Recording since 23:30'),
        onStart: () {},
        onStop: () {},
        onFix: (_) {},
        morningAsk: ask,
      ),
    );

    testWidgets('shown above the buttons, the two buttons call back', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75; // 393 dp wide
      addTearDown(tester.view.reset);
      final calls = <String>[];
      await tester.pumpWidget(host(MorningOfferLine(offer: offer, onCheckIn: () => calls.add('in'), onNotNow: () => calls.add('later'))));
      expect(find.text('Slept until 07:12. Morning check-in now? About 6 minutes.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Check in'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Not now'), findsOneWidget);
      expect(tester.getRect(find.text('Check in')).bottom, lessThan(tester.getRect(find.text('Stop')).top));
      await tester.tap(find.text('Check in'));
      await tester.tap(find.text('Not now'));
      expect(calls, ['in', 'later']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 393 dp with large text', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: host(MorningOfferLine(offer: offer, onCheckIn: () {}, onNotNow: () {})),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('hidden when there is no offer', (tester) async {
      await tester.pumpWidget(host(null));
      expect(find.textContaining('Morning check-in now?'), findsNothing);
      expect(find.text('Not now'), findsNothing);
    });
  });
}
