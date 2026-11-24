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

  setUp(() => files = Directory.systemTemp.createTempSync('confirm-screens'));
  tearDown(() => files.deleteSync(recursive: true));

  Future<void> show(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: nightTheme(), home: child));
  }

  Widget host({FakePhone? phone, Object? changed}) => Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ConfirmCardHost(
          filesPath: files.path,
          phone: phone,
          changed: changed,
          clock: () => now,
          gather: (p) async => ConfirmQuestions(Directory(p)).gather(collect: (_) => const []),
        ),
      ],
    ),
  );

  Future<void> settle(WidgetTester t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
  }

  testWidgets('the batch asks each question with Yes, No and Not sure, and draws nothing without questions', (t) async {
    final got = <(String, Answer)>[];
    final qs = [ConfirmQuestion(nap, questionOf(nap, now), 'long'), ConfirmQuestion(walk, questionOf(walk, now), 'long')];
    await show(t, Scaffold(body: ConfirmBatch(questions: qs, onAnswer: (q, a) => got.add((q.id, a)))));
    expect(find.text('Did you nap 15:59-17:49?'), findsOneWidget);
    expect(find.text('Did you walk 19:08-21:14?'), findsOneWidget);
    expect(find.text('Yes'), findsNWidgets(2));
    expect(find.text('No'), findsNWidgets(2));
    expect(find.text('Not sure'), findsNWidgets(2));
    await t.tap(find.text('No').last);
    await t.tap(find.text('Not sure').first);
    expect(got, [(walk.id, Answer.no), (nap.id, Answer.skip)]);
    expect(t.takeException(), isNull);
    // the buttons are big enough to hit: 48 dp high
    expect(t.getSize(find.widgetWithText(OutlinedButton, 'Yes').first).height, greaterThanOrEqualTo(48));

    await show(t, Scaffold(body: ConfirmCard(questions: const [], onAnswer: (_, _) {})));
    expect(find.text('Quick check'), findsNothing);
  });

  testWidgets('the card shows the whole batch; a tap saves the answer and offers Undo', (t) async {
    ConfirmQuestions(files).register([nap, walk]);
    final phone = FakePhone();
    await show(t, host(phone: phone));
    await settle(t);
    expect(find.text('Quick check'), findsOneWidget);
    expect(find.text('Did you nap 15:59-17:49?'), findsOneWidget);
    expect(find.text('Did you walk 19:08-21:14?'), findsOneWidget);
    expect(find.byTooltip('Why the app asks'), findsOneWidget);

    await t.tap(find.text('Yes').first);
    await settle(t);
    expect(find.text('Saved: Yes'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget, reason: 'the other question still has its buttons');
    var state = ConfirmStore(files).read();
    expect(state.answers[nap.id]!.answer, Answer.yes);
    expect(state.answered(walk.id), isFalse);
    expect(phone.answeredIds, [nap.id]);

    await t.tap(find.text('Undo'));
    await settle(t);
    expect(find.text('Saved: Yes'), findsNothing);
    expect(find.text('Yes'), findsNWidgets(2));
    expect(ConfirmStore(files).read().answered(nap.id), isFalse);

    await t.tap(find.text('No').last);
    await t.tap(find.text('Not sure').first);
    await settle(t);
    state = ConfirmStore(files).read();
    expect((state.answers[walk.id]!.answer, state.answers[nap.id]!.answer), (Answer.no, Answer.skip));
    expect(find.text('Saved: No'), findsOneWidget);
    expect(find.text('Saved: Not sure'), findsOneWidget);
    expect(find.text('Add a few words'), findsOneWidget, reason: 'words go with a Yes or a No, not with Not sure');
    expect(t.takeException(), isNull);
  });

  testWidgets('a few words of your own are kept beside the answer', (t) async {
    ConfirmQuestions(files).register([walk]);
    await show(t, host());
    await settle(t);
    await t.tap(find.text('No'));
    await settle(t);
    await t.tap(find.text('Add a few words'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'sat on the bus');
    await t.tap(find.text('Save'));
    await settle(t);
    expect(find.text('Saved: No. "sat on the bus"'), findsOneWidget);
    expect(ConfirmStore(files).read().answers[walk.id]!.note, 'sat on the bus');
    expect(ConfirmStore(files).labelsFile.readAsStringSync(), contains('No: sat on the bus'));
  });

  testWidgets('answered questions are gone the next time the card loads; with none left there is no card', (t) async {
    ConfirmQuestions(files).register([nap, walk]);
    await show(t, host(changed: 1));
    await settle(t);
    await t.tap(find.text('Yes').first);
    await settle(t);
    await show(t, host(changed: 2)); // a recording stopped, a report appeared
    await settle(t);
    expect(find.text('Did you nap 15:59-17:49?'), findsNothing);
    expect(find.text('Did you walk 19:08-21:14?'), findsOneWidget);
    await t.tap(find.text('Yes'));
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
    await show(t, ConfirmSettingsScreen(filesPath: files.path, phone: FakePhone()));
    await settle(t);
    expect(find.text('Quick checks'), findsOneWidget);
    expect(find.text('Ask me'), findsOneWidget);
    expect(find.text('From 22:00'), findsOneWidget);
    expect(find.text('To 08:00'), findsOneWidget);
    await t.tap(find.text('5'));
    await settle(t);
    expect(ConfirmStore(files).settings().perBatch, 5);
    await t.tap(find.text('1'));
    await settle(t);
    expect(ConfirmStore(files).settings().perDay, 1);
    await t.tap(find.byType(Switch));
    await settle(t);
    expect(ConfirmStore(files).settings().on, isFalse);
    expect(find.text('Off: nothing is asked'), findsOneWidget);
    expect(t.takeException(), isNull);
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
