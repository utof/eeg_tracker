// The Record tab's bar with activities (Record first step 4, DECISIONS 983-986): what is marked now, the activity
// buttons, End, Undo; and the app's question after an activity that started the recording.
import 'package:eeg_tracker/headband/connection.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/spans/activities.dart';
import 'package:eeg_tracker/ui/activity_stop.dart';
import 'package:eeg_tracker/ui/home_tabs.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoFinder implements HeadbandFinder {
  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async => null;
  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('none');
}

Widget _tab(NightViewModel m, {List<String>? opened, VoidCallback? onEnd, VoidCallback? onUndo, HomeTab tab = HomeTab.night}) => MaterialApp(
  theme: nightTheme(),
  home: NightView(
    tab: tab,
    model: m,
    onStart: () {},
    onRecord: () {},
    onSleepNow: () {},
    onStop: () {},
    onFix: (_) {},
    onNap: () => opened?.add('nap'),
    onWork: () => opened?.add('work'),
    onMeditate: () => opened?.add('meditate'),
    onSound: () => opened?.add('sound'),
    onDream: () => opened?.add('dream'),
    onEndActivity: onEnd,
    onUndo: onUndo,
  ),
);

const _idle = NightViewModel(title: 'Not recording', sentence: '', tone: Tone.calm, running: false);

NightViewModel _recording({String? activity, String? word, String? undo, bool sleeping = false}) => NightViewModel(
  title: 'Recording',
  sentence: '',
  tone: Tone.live,
  running: true,
  sleeping: sleeping,
  spansLine: 'Recording since 11:02',
  activityLine: activity,
  activityWord: word,
  undoLine: undo,
);

void main() {
  testWidgets('nothing recording: Record, Sleep, and the activities that also start recording', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_tab(_idle, opened: opened));
    expect(find.text('Record'), findsWidgets);
    expect(find.text('Sleep'), findsWidgets);
    expect(find.textContaining('each also starts recording'), findsOneWidget);
    for (final w in ['Nap', 'Work', 'Meditate']) {
      await tester.tap(find.widgetWithText(ActionChip, w));
    }
    expect(opened, ['nap', 'work', 'meditate']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording: the activities are offered on it; what is marked now has End', (tester) async {
    final opened = <String>[];
    var ended = 0;
    await tester.pumpWidget(_tab(_recording(), opened: opened));
    expect(find.textContaining('Mark on this recording'), findsOneWidget);
    expect(find.textContaining('Now:'), findsNothing);
    await tester.tap(find.widgetWithText(ActionChip, 'Work'));
    expect(opened, ['work']);

    await tester.pumpWidget(_tab(_recording(activity: 'Work since 14:05', word: 'Work'), onEnd: () => ended++));
    expect(find.text('Now: Work since 14:05'), findsOneWidget);
    await tester.tap(find.text('End Work'));
    expect(ended, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('after the 60-minute rule the bar offers Undo', (tester) async {
    var undone = 0;
    const line = 'Work ended at 14:05: the headband was off for an hour. Still going?';
    await tester.pumpWidget(_tab(_recording(undo: line), onUndo: () => undone++));
    expect(find.text(line), findsOneWidget);
    await tester.tap(find.text('Undo'));
    expect(undone, 1);
  });

  testWidgets('the Sessions tab during a recording has every session and no "busy" sentence', (tester) async {
    await tester.pumpWidget(_tab(_recording(sleeping: true), tab: HomeTab.sessions));
    expect(find.textContaining('Stop sleep on the Record tab first'), findsOneWidget);
    await tester.pumpWidget(_tab(_recording(), tab: HomeTab.sessions));
    expect(find.textContaining('is marked on that recording'), findsOneWidget);
    expect(find.textContaining('busy'), findsNothing);
    for (final w in ['Meditate', 'Dream catcher', 'Nap coach', 'Work session']) {
      // the section's button (its heading may have the same word)
      await tester.scrollUntilVisible(find.widgetWithText(OutlinedButton, w), 200, scrollable: find.byType(Scrollable).first);
      expect(find.widgetWithText(OutlinedButton, w), findsOneWidget, reason: w);
    }
  });

  testWidgets('the question after an activity that started the recording: Stop everything is the filled button', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Builder(
          builder: (c) => TextButton(onPressed: () async => answer = await showActivityStop(c, 'Work'), child: const Text('go')),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Work has ended'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Stop everything'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Keep recording'), findsOneWidget);
    await tester.tap(find.text('Keep recording'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('the asker shows the question when an activity leaves one, and gives the answer back', (tester) async {
    final owner = HeadbandConnection(makeFinder: _NoFinder.new);
    addTearDown(owner.dispose);
    var stopped = 0;
    final acts = Activities(owner: owner, send: (_) {}, serviceRuns: () async => false)..stopRecording = () async => stopped++;
    final nav = GlobalKey<NavigatorState>();
    final asker = ActivityStopAsker(acts, nav)..install();
    addTearDown(asker.dispose);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), navigatorKey: nav, home: const Scaffold(body: Text('a page'))));
    acts.ask.value = ActivityRun('meditate', startedRecording: true);
    await tester.pumpAndSettle();
    expect(find.text('Meditate has ended'), findsOneWidget);
    await tester.tap(find.text('Stop everything'));
    await tester.pumpAndSettle();
    expect(stopped, 1);
    expect(acts.ask.value, isNull);
    expect(find.text('Meditate has ended'), findsNothing);
  });

  // DECISIONS 1011: no answer means keep recording. Only the Stop everything button stops the recording.
  group('nobody answers "Stop everything / Keep recording"', () {
    late HeadbandConnection owner;
    late Activities acts;
    late GlobalKey<NavigatorState> nav;
    var stopped = 0;

    Future<ActivityStopAsker> app(WidgetTester tester, {bool withPage = true}) async {
      stopped = 0;
      owner = HeadbandConnection(makeFinder: _NoFinder.new);
      addTearDown(owner.dispose);
      acts = Activities(owner: owner, send: (_) {}, serviceRuns: () async => false)..stopRecording = () async => stopped++;
      nav = GlobalKey<NavigatorState>();
      final asker = ActivityStopAsker(acts, nav)..install();
      if (withPage) {
        await tester.pumpWidget(MaterialApp(theme: nightTheme(), navigatorKey: nav, home: const Scaffold(body: Text('a page'))));
      }
      return asker;
    }

    testWidgets('the sheet dismissed with Back: the recording goes on, the question is gone', (tester) async {
      final asker = await app(tester);
      addTearDown(asker.dispose);
      acts.ask.value = ActivityRun('nap', startedRecording: true); // a nap's wake ended it by its own timer
      await tester.pumpAndSettle();
      expect(find.text('Nap has ended'), findsOneWidget);
      await tester.binding.handlePopRoute(); // Android's Back
      await tester.pumpAndSettle();
      expect(find.text('Nap has ended'), findsNothing);
      expect(stopped, 0, reason: 'no answer must mean keep recording');
      expect(acts.ask.value, isNull);
    });

    testWidgets('a tap beside the sheet does not close it and stops nothing', (tester) async {
      final asker = await app(tester);
      addTearDown(asker.dispose);
      acts.ask.value = ActivityRun('work', startedRecording: true);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Work has ended'), findsOneWidget);
      expect(stopped, 0);
    });

    testWidgets('the question left unanswered for hours (the screen off), then the app closed: nothing is stopped', (tester) async {
      final asker = await app(tester);
      acts.ask.value = ActivityRun('meditate', startedRecording: true); // the meditation's own end
      await tester.pumpAndSettle();
      expect(find.text('Meditate has ended'), findsOneWidget);
      await tester.pump(const Duration(hours: 8));
      expect(stopped, 0);
      asker.dispose(); // the app's screen goes away; the recorder is a service of its own
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(hours: 1));
      expect(stopped, 0, reason: 'closing the app is not an answer');
    });

    testWidgets('no page to show the question on (the app is not on the screen): nothing is stopped', (tester) async {
      final asker = await app(tester, withPage: false);
      addTearDown(asker.dispose);
      acts.ask.value = ActivityRun('work', startedRecording: true);
      await tester.pump(const Duration(minutes: 30));
      expect(stopped, 0);
    });

    testWidgets('an answer that comes without a choice counts as Keep recording', (tester) async {
      final asker = await app(tester);
      addTearDown(asker.dispose);
      acts.ask.value = ActivityRun('work', startedRecording: true);
      await acts.answer(stopEverything: false);
      expect(stopped, 0);
      expect(acts.ask.value, isNull);
    });
  });
}
