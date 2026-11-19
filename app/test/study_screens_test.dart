// Renders the study reminders page, its one-tap question and the Settings row in their states at the owner's phone
// width (393 dp) with real fonts, writes build/screens/study_*.png for a human look, and fails on any layout overflow
// (also at 130 % text). Then the flows on a fake app folder with a fake phone: switch on, log, delete (DECISIONS rows
// 400-401).
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/sharp/prompts.dart';
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sharp/store.dart';
import 'package:eeg_tracker/study/page.dart';
import 'package:eeg_tracker/study/schedule.dart';
import 'package:eeg_tracker/study/store.dart';
import 'package:eeg_tracker/ui/hands_free_view.dart';
import 'package:eeg_tracker/ui/study_screen.dart';
import 'package:eeg_tracker/ui/study_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;
import 'sharp_prompts_test.dart' show FakeSharpPhone;
import 'study_page_test.dart' show fiveNights;

final DateTime _now = DateTime(2026, 11, 28, 16, 20);

StudySettings _on({int? evening, int? morning}) => StudySettings(
  on: true,
  eveningMin: evening,
  morningMin: morning,
  firstOn: DateTime(2026, 11, 1),
  changed: DateTime(2026, 11, 1),
);

/// Prompt events of the last week: every reminder shown, one skipped.
List<PromptEvent> _events() => [
  for (var d = 1; d <= 6; d++) ...[
    PromptEvent(
      planned: DateTime(2026, 11, 28 - d, 21, 30),
      at: DateTime(2026, 11, 28 - d, 21, 30),
      event: PromptEventKind.shown,
    ),
    PromptEvent(
      planned: DateTime(2026, 11, 28 - d, 8),
      at: DateTime(2026, 11, 28 - d, 8),
      event: d == 3 ? PromptEventKind.skipped : PromptEventKind.shown,
      reason: d == 3 ? 'night recording' : null,
    ),
  ],
];

StudyPageModel _model({
  StudySettings? saved,
  bool answers = false,
  bool nights = true,
  bool notifications = true,
  SharpSettings? sharp,
}) => buildStudyPage(
  saved: saved,
  sharp: sharp,
  answers: answers
      ? [
          for (var d = 1; d <= 9; d++) ...[
            StudyAnswer.evening(at: DateTime(2026, 11, 28 - d, 21, 40), studied: d != 4),
            if (d != 4) StudyAnswer.morning(at: DateTime(2026, 11, 29 - d, 8, 5), recall: Recall.values[d % 3]),
          ],
          StudyAnswer.morning(
            at: DateTime(2026, 11, 28, 8, 12),
            recall: Recall.some,
            prompt: DateTime(2026, 11, 28, 8),
          ),
        ]
      : const [],
  events: saved == null ? const [] : _events(),
  reports: nights ? fiveNights() : const [],
  now: _now,
  notificationsOn: notifications,
  xiaomi: true,
);

void _no() {}

Widget _page(StudyPageModel m) => StudyView(
  model: m,
  onToggle: (_) {},
  onEvening: _no,
  onMorning: _no,
  onAutoEvening: _no,
  onAutoMorning: _no,
  onLogEvening: _no,
  onLogMorning: _no,
  onInfo: _no,
  onNotifications: _no,
  onPhoneSettings: (_) {},
  onDelete: _no,
);

final _eveningLaunch = SharpLaunch(
  planned: DateTime(2026, 11, 28, 21, 30),
  shown: DateTime(2026, 11, 28, 21, 31),
  kind: PromptKind.studyEvening,
);
final _morningLaunch = SharpLaunch(
  planned: DateTime(2026, 11, 28, 8),
  shown: DateTime(2026, 11, 28, 8, 1),
  kind: PromptKind.studyMorning,
);

final Map<String, Widget Function()> pages = {
  'page_new': () => _page(_model(nights: false)),
  'page_on': () => _page(_model(saved: _on(), answers: true)),
  'page_manual_notifications_off': () => _page(
    _model(
      saved: _on(evening: 20 * 60 + 15, morning: 9 * 60),
      answers: true,
      notifications: false,
    ),
  ),
  'settings_row': () => SettingsView(
    model: const SettingsViewModel(),
    onToggle: (_) {},
    onCalibrate: _no,
    onInfo: _no,
    studyOn: true,
    onStudy: _no,
  ),
};

final Map<String, Widget Function()> questions = {
  'ask_evening': () => StudyLogView(
    kind: PromptKind.studyEvening,
    stage: StudyStage.ask,
    asked: _eveningLaunch.shown,
    onStudied: (_) {},
    onNotYet: _no,
  ),
  'ask_evening_page': () =>
      StudyLogView(kind: PromptKind.studyEvening, stage: StudyStage.ask, onStudied: (_) {}, onNotYet: _no),
  'ask_morning': () => StudyLogView(
    kind: PromptKind.studyMorning,
    stage: StudyStage.ask,
    asked: _morningLaunch.shown,
    onRecall: (_) {},
    onNotYet: _no,
  ),
  'saved_yes': () => StudyLogView(
    kind: PromptKind.studyEvening,
    stage: StudyStage.saved,
    saved: StudyAnswer.evening(at: DateTime(2026, 11, 28, 21, 40), studied: true),
    onDone: _no,
  ),
  'saved_no': () => StudyLogView(
    kind: PromptKind.studyEvening,
    stage: StudyStage.saved,
    saved: StudyAnswer.evening(at: DateTime(2026, 11, 28, 21, 40), studied: false),
    onDone: _no,
  ),
  'saved_recall': () => StudyLogView(
    kind: PromptKind.studyMorning,
    stage: StudyStage.saved,
    saved: StudyAnswer.morning(at: DateTime(2026, 11, 28, 8, 5), recall: Recall.little),
    onDone: _no,
  ),
};

/// Pushes [w] over a stub page (as the app opens it, so the app bar has its Back arrow), checks for overflow and
/// writes build/screens/[name].png; [height] in dp (873 = the owner's first screen; more = the whole page).
Future<void> _shoot(WidgetTester tester, Widget w, String name, double scale, {double height = 873}) async {
  tester.view.physicalSize = Size(1080, height * 1080 / 393); // the owner's Xiaomi 11T: 393 dp wide
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view)
          .copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(
        navigatorKey: nav,
        debugShowCheckedModeBanner: false,
        theme: nightTheme(),
        home: const Scaffold(),
      ),
    ),
  );
  unawaited(
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => RepaintBoundary(key: key, child: w),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1080 / 393);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name${scale == 1.0 ? '' : '_text130'}.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    final pct = (scale * 100).round();
    for (final e in pages.entries) {
      testWidgets('study ${e.key} at $pct % text, first screen and full length', (tester) async {
        await _shoot(tester, e.value(), 'study_${e.key}', scale);
        await _shoot(tester, e.value(), 'study_${e.key}_full', scale, height: scale == 1.0 ? 2000 : 2800);
      });
    }
    for (final e in questions.entries) {
      testWidgets('study ${e.key} at $pct % text', (tester) async {
        await _shoot(tester, e.value(), 'study_${e.key}', scale);
      });
    }
  }

  group('the words', () {
    test('status, where the times come from, and the last 14 days', () {
      expect(studyStatus(_model(nights: false)), 'Off. Nothing is asked until you switch it on.');
      expect(studyStatus(_model(saved: _on())), 'On: evening 21:30, morning 08:00.');
      final m = _model(saved: _on(), answers: true);
      expect(timeNote(m, evening: true), 'From your sleep: about 1½ hours before your usual bedtime.');
      expect(timeNote(m, evening: false), 'From your sleep: 45 minutes after you usually wake.');
      expect(timeNote(_model(saved: _on(evening: 1215), answers: true), evening: true), 'Set by you.');
      expect(
        timeNote(_model(nights: false), evening: false),
        'Until 3 nights are recorded: 08:30, then it follows your sleep.',
      );
      final moved = _model(
        saved: _on(),
        sharp: const SharpSettings(on: false, perDay: 4, fromMin: 9 * 60, untilMin: 21 * 60, seed: 'x'),
      );
      expect(timeNote(moved, evening: true), endsWith('Moved to keep inside your waking hours, 09:00 to 21:00.'));
      expect(historyWords(_model()), 'Nothing logged yet.');
      expect(
        historyWords(m),
        'Studied on 8 of 9 evenings you answered. Recall the next morning: well 3, some 3, a little 3.',
      );
    });

    test('delivery: what arrived in the last 7 days', () {
      expect(
        studyReachWords(_model(saved: _on())),
        'Last 7 days: 12 reminders arrived. 1 came during a recording or a session and was skipped.',
      );
      expect(studyReachWords(_model(saved: const StudySettings(on: false))), isNull);
    });

    test('answers in words', () {
      expect(answerWords(StudyAnswer.evening(at: _now, studied: true)), 'Studied tonight: yes');
      expect(answerWords(StudyAnswer.morning(at: _now, recall: Recall.little)), 'Recalled: a little');
    });
  });

  group('the flows on a fake app folder', () {
    late Directory tmp;
    late String rec;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('study-ui');
      rec = '${tmp.path}/files/recordings';
      Directory(rec).createSync(recursive: true);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    // the page's work (files, the permission request, the fake phone, a reload) takes a few turns of the real clock
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 2; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('switch on: settings saved, both reminders handed to the phone; off hands it nothing', (tester) async {
      final phone = FakeSharpPhone();
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: StudyScreen(recordingsDir: rec, phone: phone, now: () => _now),
        ),
      );
      await settle(tester);
      expect(find.text('Off. Nothing is asked until you switch it on.'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await settle(tester);
      final store = StudyStore(studyDirFor(rec));
      final s = store.settings()!;
      expect(s.on, isTrue);
      expect(s.firstOn, _now);
      expect(s.eveningMin, isNull);
      final armed = phone.armed.last;
      expect(armed.first.kind, PromptKind.studyEvening);
      expect(armed.first.at, DateTime(2026, 11, 28, 21));
      expect(armed.map((p) => p.kind).toSet(), {PromptKind.studyEvening, PromptKind.studyMorning});
      expect(find.text('On: evening 21:00, morning 08:30.'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await settle(tester);
      expect(store.settings()!.on, isFalse);
      expect(phone.armed.last, isEmpty);
      expect(File('${store.dir.path}/events.jsonl').readAsLinesSync(), hasLength(2));
    });

    testWidgets('an evening reminder\'s tap: "yes" is saved with its prompt, and the evening is not asked twice', (
      tester,
    ) async {
      final phone = FakeSharpPhone();
      StudyStore(studyDirFor(rec)).saveSettings(_on());
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: StudyLogScreen(
            kind: PromptKind.studyEvening,
            launch: _eveningLaunch,
            recordingsDir: rec,
            phone: phone,
            now: () => DateTime(2026, 11, 28, 21, 40),
          ),
        ),
      );
      await tester.tap(find.text('Yes'));
      await settle(tester);
      final a = StudyStore(studyDirFor(rec)).answers().single;
      expect((a.isEvening, a.studied), (true, true));
      expect(a.prompt, _eveningLaunch.planned);
      expect(a.shown, _eveningLaunch.shown);
      expect(find.text('Saved: you studied tonight.'), findsOneWidget);
      expect(
        phone.armed.last.first.at,
        DateTime(2026, 11, 29, 8, 30),
        reason: 'tonight is answered: the next one is tomorrow morning',
      );
    });

    testWidgets('"no" drops tomorrow morning\'s reminder', (tester) async {
      final phone = FakeSharpPhone();
      StudyStore(studyDirFor(rec)).saveSettings(_on());
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: StudyLogScreen(
            kind: PromptKind.studyEvening,
            recordingsDir: rec,
            phone: phone,
            now: () => DateTime(2026, 11, 28, 21, 40),
          ),
        ),
      );
      await tester.tap(find.text('No'));
      await settle(tester);
      expect(StudyStore(studyDirFor(rec)).answers().single.studied, isFalse);
      expect(phone.armed.last.first, isA<PlannedPrompt>().having((p) => p.at, 'at', DateTime(2026, 11, 29, 21)));
      expect(find.textContaining('morning reminder is skipped'), findsOneWidget);
    });

    testWidgets('a morning reminder\'s tap: recall is saved; from the page it has no prompt', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: StudyLogScreen(
            kind: PromptKind.studyMorning,
            launch: _morningLaunch,
            recordingsDir: rec,
            phone: FakeSharpPhone(),
            now: () => DateTime(2026, 11, 28, 8, 5),
          ),
        ),
      );
      await tester.tap(find.text('Some'));
      await settle(tester);
      final a = StudyStore(studyDirFor(rec)).answers().single;
      expect(a.recall, Recall.some);
      expect(a.prompt, _morningLaunch.planned);
      expect(find.text('Saved: some.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: StudyLogScreen(
            kind: PromptKind.studyMorning,
            recordingsDir: rec,
            phone: FakeSharpPhone(),
            now: () => DateTime(2026, 11, 28, 9),
          ),
        ),
      );
      await tester.tap(find.text('A little'));
      await settle(tester);
      final all = StudyStore(studyDirFor(rec)).answers();
      expect(all.length, 2);
      expect(all.last.prompt, isNull);
      expect(all.last.recall, Recall.little);
    });

    testWidgets('"Not yet" saves nothing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: StudyLogScreen(
            kind: PromptKind.studyEvening,
            recordingsDir: rec,
            phone: FakeSharpPhone(),
            now: () => _now,
          ),
        ),
      );
      await tester.tap(find.text('Not yet'));
      await settle(tester);
      expect(StudyStore(studyDirFor(rec)).answers(), isEmpty);
    });

    testWidgets('delete asks once, removes the study files and leaves the sharp-hours questions armed', (tester) async {
      final phone = FakeSharpPhone();
      SharpStore(sharpDirFor(rec))
          .saveSettings(const SharpSettings(on: true, perDay: 4, fromMin: 600, untilMin: 1320, seed: 'x'));
      final store = StudyStore(studyDirFor(rec))
        ..saveSettings(_on())
        ..addAnswer(StudyAnswer.morning(at: _now, recall: Recall.well));
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: StudyScreen(recordingsDir: rec, phone: phone, now: () => _now),
        ),
      );
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Delete my study data'), 300);
      await tester.tap(find.text('Delete my study data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(store.dir.existsSync(), isFalse);
      expect(phone.armed.last, isNotEmpty);
      expect(phone.armed.last.every((p) => p.kind == PromptKind.sharp), isTrue);
    });
  });
}
