// The confirmation questions' card, batch and settings page (lib/ui/confirm_view.dart, confirm_screen.dart; DECISIONS
// 860-869), on a phone-sized screen with the files in a temporary folder.
import 'dart:io';

import 'package:eeg_tracker/confirm/questions.dart';
import 'package:eeg_tracker/ui/confirm_screen.dart';
import 'package:eeg_tracker/ui/confirm_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_labels/shared_labels.dart';

import 'confirm_test.dart' show FakePhone, est;

void main() {
  late Directory files;
  final now = DateTime(2026, 11, 20, 21, 40);
  final nap = est(Labels.nap, DateTime(2026, 11, 20, 15, 59), 110, confidence: 0.9);
  final walk = est(Labels.walking, DateTime(2026, 11, 20, 19, 8), 126, confidence: 0.9);
  // a nap whose card is a blind one by the draw (1 in 5, by id)
  final hidden = est(Labels.nap, DateTime(2026, 11, 20, 16, 14), 40, confidence: 0.6);

  setUp(() => files = Directory.systemTemp.createTempSync('confirm-screens'));
  tearDown(() => files.deleteSync(recursive: true));

  Future<void> show(WidgetTester t, Widget child, {double height = 2340}) async {
    t.view.physicalSize = Size(1080, height);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: nightTheme(), home: child));
  }

  Widget host({FakePhone? phone, Object? changed, DateTime? at}) => Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ConfirmCardHost(
          filesPath: files.path,
          phone: phone,
          changed: changed,
          clock: () => at ?? now,
          gather: (p) async => ConfirmQuestions(Directory(p)).gather(collect: (_) => const []),
        ),
      ],
    ),
  );

  Future<void> settle(WidgetTester t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
  }

  test('the cards of these tests show the guess, and the blind one does not (drawn by id, the same every run)', () {
    expect((blindByDraw(nap.id), blindByDraw(walk.id), blindByDraw(hidden.id)), (false, false, true));
  });

  testWidgets('the batch asks each question with buttons that name the thing, and draws nothing without questions', (t) async {
    final got = <(String, Answer)>[];
    final qs = [ConfirmQuestion(nap, questionOf(nap, now), 'long'), ConfirmQuestion(walk, questionOf(walk, now), 'long')];
    await show(t, Scaffold(body: ConfirmBatch(questions: qs, onAnswer: (q, a) => got.add((q.id, a)))));
    expect(find.text('15:59-17:49. The headband thinks you napped. Did you?'), findsOneWidget);
    expect(find.text('19:08-21:14. The headband thinks you walked. Did you?'), findsOneWidget);
    expect(find.text('I napped'), findsOneWidget);
    expect(find.text('I was awake'), findsOneWidget);
    expect(find.text('I walked'), findsOneWidget);
    expect(find.text('Not sure'), findsNWidgets(2));
    await t.tap(find.text('I did not walk'));
    await t.tap(find.text('Not sure').first);
    expect(got, [(walk.id, Answer.no), (nap.id, Answer.skip)]);
    expect(t.takeException(), isNull);
    // the buttons are big enough to hit: 48 dp high
    expect(t.getSize(find.widgetWithText(OutlinedButton, 'I napped')).height, greaterThanOrEqualTo(48));

    await show(t, Scaffold(body: ConfirmCard(questions: const [], onAnswer: (_, _) {})));
    expect(find.text('Quick check'), findsNothing);
  });

  testWidgets('the card shows the whole batch; a tap saves the answer and offers Undo', (t) async {
    ConfirmQuestions(files).register([nap, walk]);
    final phone = FakePhone();
    await show(t, host(phone: phone));
    await settle(t);
    expect(find.text('Quick check'), findsOneWidget);
    expect(find.text('15:59-17:49. The headband thinks you napped. Did you?'), findsOneWidget);
    expect(find.text('19:08-21:14. The headband thinks you walked. Did you?'), findsOneWidget);
    expect(find.byTooltip('Why the app asks'), findsOneWidget);

    await t.tap(find.text('I napped'));
    await settle(t);
    expect(find.text('Saved: I napped'), findsOneWidget);
    expect(find.text('I walked'), findsOneWidget, reason: 'the other question still has its buttons');
    var state = ConfirmStore(files).read();
    expect(state.answers[nap.id]!.answer, Answer.yes);
    expect((state.answers[nap.id]!.card, state.answers[nap.id]!.timesConfirmed, state.answers[nap.id]!.seconds), (CardKind.normal, false, 0.0));
    expect(state.answered(walk.id), isFalse);
    expect(phone.answeredIds, [nap.id]);

    await t.tap(find.text('Undo'));
    await settle(t);
    expect(find.text('Saved: I napped'), findsNothing);
    expect(find.text('I napped'), findsOneWidget);
    expect(ConfirmStore(files).read().answered(nap.id), isFalse);

    await t.tap(find.text('I did not walk'));
    await t.tap(find.text('Not sure').first);
    await settle(t);
    state = ConfirmStore(files).read();
    expect((state.answers[walk.id]!.answer, state.answers[nap.id]!.answer), (Answer.no, Answer.skip));
    expect(find.text('Saved: I did not walk'), findsOneWidget);
    expect(find.text('Saved: Not sure'), findsOneWidget);
    expect(find.text('Add a few words'), findsOneWidget, reason: 'words go with a Yes or a No, not with Not sure');
    expect(t.takeException(), isNull);
  });

  testWidgets('"Yes, but the times are off": the strip, both ends moved, saved as your times', (t) async {
    ConfirmQuestions(files).register([walk]);
    await show(t, host());
    await settle(t);
    await t.tap(find.text('Yes, but the times are off'));
    await t.pumpAndSettle();
    expect(find.text('Start 19:08'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('times-start-later')));
    await t.tap(find.byKey(const ValueKey('times-end-earlier')));
    await t.tap(find.byKey(const ValueKey('times-end-earlier')));
    await t.pump();
    await t.tap(find.text('Save these times'));
    await settle(t);
    expect(find.text('Saved: I walked, 19:13-21:04'), findsOneWidget);
    final a = ConfirmStore(files).read().answers[walk.id]!;
    expect((a.answer, a.timesConfirmed, a.start, a.end), (Answer.yes, true, DateTime(2026, 11, 20, 19, 13), DateTime(2026, 11, 20, 21, 4)));
    final label = ConfirmStore(files).labelsFile.readAsLinesSync().last.split('\t');
    expect((label[1], label[2], label.last), ('2026-11-20T19:13:00+03:00', '2026-11-20T21:04:00+03:00', '1'));
    await t.tap(find.text('Undo'));
    await settle(t);
    expect(ConfirmStore(files).read().answered(walk.id), isFalse);
  });

  testWidgets('a stretch from yesterday: only "did it happen", the times are not asked about', (t) async {
    ConfirmQuestions(files).register([walk]);
    await show(t, host(at: DateTime(2026, 11, 21, 9)));
    await settle(t);
    expect(find.text('Yesterday, about 19:00 to 21:00. The headband thinks you walked. Did you?'), findsOneWidget);
    expect(find.text('Yes, but the times are off'), findsNothing);
    await t.tap(find.text('I walked'));
    await settle(t);
    expect(ConfirmStore(files).read().answers[walk.id]!.timesConfirmed, isFalse);
  });

  testWidgets('a blind card: no guess on screen, a chip stores what you said, the guess is kept for later', (t) async {
    ConfirmQuestions(files).register([hidden, walk]);
    await show(t, host());
    await settle(t);
    expect(find.text('What were you doing 16:14-16:54?'), findsOneWidget);
    expect(find.textContaining('napped'), findsNothing, reason: 'the guess (a nap) is not shown');
    expect(find.text('I walked'), findsOneWidget, reason: 'the other card shows its guess as usual');
    await t.tap(find.text('Working'));
    await settle(t);
    expect(find.text('Saved: Working'), findsOneWidget);
    var a = ConfirmStore(files).read().answers[hidden.id]!;
    expect((a.answer, a.card, a.said, a.guess, a.guessConfidence, a.agrees(hidden.label)), (Answer.said, CardKind.blind, Labels.working, 'nap', 0.6, false));
    final table = ConfirmStore(files).estimatesTable.readAsLinesSync().firstWhere((l) => l.startsWith(hidden.id)).split('\t');
    final row = Map.fromIterables(estimateColumns, table);
    expect((row['label'], row['answer'], row['card'], row['said'], row['agrees']), ('nap', 'said', 'blind', 'working', '0'));

    // words of your own
    await t.tap(find.text('Undo'));
    await settle(t);
    await t.tap(find.text('Something else'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'reading on the sofa');
    await t.tap(find.text('Save'));
    await settle(t);
    expect(find.text('Saved: reading on the sofa'), findsOneWidget);
    a = ConfirmStore(files).read().answers[hidden.id]!;
    expect((a.said, a.words), (null, 'reading on the sofa'));
    // words that name a label are that label: "sleeping" agrees with a nap
    await t.tap(find.text('Undo'));
    await settle(t);
    await t.tap(find.text('Something else'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Sleeping');
    await t.tap(find.text('Save'));
    await settle(t);
    a = ConfirmStore(files).read().answers[hidden.id]!;
    expect((a.said, a.agrees(hidden.label)), (Labels.asleep, true));
  });

  testWidgets('Not sure on a card is stored and the question does not come back', (t) async {
    ConfirmQuestions(files).register([walk]);
    await show(t, host(changed: 1));
    await settle(t);
    await t.tap(find.text('Not sure'));
    await settle(t);
    expect(ConfirmStore(files).answersFile.readAsStringSync(), contains('"answer":"not_sure"'));
    await show(t, host(changed: 2));
    await settle(t);
    expect(find.text('Quick check'), findsNothing);
    expect(ConfirmStore(files).labelsFile.readAsLinesSync(), hasLength(1));
  });

  testWidgets('a few words of your own are kept beside the answer', (t) async {
    ConfirmQuestions(files).register([walk]);
    await show(t, host());
    await settle(t);
    await t.tap(find.text('I did not walk'));
    await settle(t);
    await t.tap(find.text('Add a few words'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'sat on the bus');
    await t.tap(find.text('Save'));
    await settle(t);
    expect(find.text('Saved: I did not walk. "sat on the bus"'), findsOneWidget);
    expect(ConfirmStore(files).read().answers[walk.id]!.note, 'sat on the bus');
    expect(ConfirmStore(files).labelsFile.readAsStringSync(), contains('No: sat on the bus'));
  });

  testWidgets('answered questions are gone the next time the card loads; with none left there is no card', (t) async {
    ConfirmQuestions(files).register([nap, walk]);
    await show(t, host(changed: 1));
    await settle(t);
    await t.tap(find.text('I napped'));
    await settle(t);
    await show(t, host(changed: 2)); // a recording stopped, a report appeared
    await settle(t);
    expect(find.textContaining('you napped'), findsNothing);
    expect(find.text('19:08-21:14. The headband thinks you walked. Did you?'), findsOneWidget);
    await t.tap(find.text('I walked'));
    await settle(t);
    await show(t, host(changed: 3));
    await settle(t);
    expect(find.text('Quick check'), findsNothing);
  });

  testWidgets('switched off: no card', (t) async {
    ConfirmQuestions(files).register([nap]);
    ConfirmStore(files).saveSettings(const ConfirmSettings(on: false));
    await show(t, host());
    await settle(t);
    expect(find.text('Quick check'), findsNothing);
  });

  testWidgets('the settings page: the switch, how many, and the quiet hours', (t) async {
    await show(t, ConfirmSettingsScreen(filesPath: files.path, phone: FakePhone()), height: 4400); // the whole page at once
    await settle(t);
    expect(find.text('Quick checks'), findsOneWidget);
    expect(find.text('Ask me'), findsOneWidget);
    expect(find.text('From 22:00'), findsOneWidget);
    expect(find.text('To 08:00'), findsOneWidget);
    expect(find.text('5'), findsNothing, reason: 'at most 4 cards');
    expect(find.text('6'), findsNothing, reason: 'at most 2 notifications a day');
    await t.tap(find.text('3'));
    await settle(t);
    expect(ConfirmStore(files).settings().perBatch, 3);
    await t.tap(find.text('1'));
    await settle(t);
    expect(ConfirmStore(files).settings().perDay, 1);
    expect(find.text('Follow my sleep'), findsOneWidget);
    expect(find.textContaining('Needs 3 recorded nights first'), findsOneWidget);
    await t.tap(find.byType(Switch).last);
    await settle(t);
    expect(ConfirmStore(files).settings().quietFromSleep, isFalse);
    expect(find.text('Always these hours:'), findsOneWidget);
    await t.tap(find.byType(Switch).first);
    await settle(t);
    expect(ConfirmStore(files).settings().on, isFalse);
    expect(find.text('Off: nothing is asked'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the settings view says which quiet hours your sleep gives', (t) async {
    await show(t, ConfirmSettingsView(settings: const ConfirmSettings(), onChanged: (_) {}, quietNow: (startMin: 92, endMin: 571, nights: 9)));
    expect(find.text('Now quiet 01:32 to 09:31, from your last 9 nights'), findsOneWidget);
    expect(find.text('From 22:00'), findsNothing, reason: 'the fixed hours are not in force');
  });

  testWidgets('the settings view says when the phone blocks the notifications', (t) async {
    var opened = 0;
    await show(
      t,
      ConfirmSettingsView(settings: const ConfirmSettings(), onChanged: (_) {}, notificationsOn: false, onNotificationSettings: () => opened++),
    );
    expect(find.textContaining('only the card in the app asks'), findsOneWidget);
    await t.tap(find.text('Notification settings'));
    expect(opened, 1);
  });
}
