// What the study reminders page shows (DECISIONS rows 400-401): the times, the waking hours they keep to, the
// last 14 days and whether the reminders arrive.
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sharp/store.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/study/page.dart';
import 'package:eeg_tracker/study/schedule.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _now = DateTime(2026, 11, 28, 16, 20);

/// A recorded night from [start] to [wake] (made up).
SleepReport night(DateTime start, DateTime wake) => SleepReport({
  'night_of': dayKey(start),
  'scored': true,
  'data_start': isoLocal(start),
  'data_end': isoLocal(wake),
  'total': {'asleep_min': 420.0, 'recorded_min': 450.0, 'missing_min': 0, 'stray_sleep_min': 0},
  'periods': [
    {
      'start': isoLocal(start),
      'end': isoLocal(wake),
      'asleep_min': 420.0,
      'light_min': 300.0,
      'deep_min': 60.0,
      'dream_min': 60.0,
      'awake_min': 30.0,
      'wake_ups': 1,
      'missing_min': 0,
    },
  ],
});

/// Five nights ending on the mornings of the 23rd to the 27th, to bed at 23:10 and up at 07:05.
List<SleepReport> fiveNights() => [
  for (var d = 22; d <= 26; d++) night(DateTime(2026, 11, d, 23, 10), DateTime(2026, 11, d + 1, 7, 5)),
];

StudyPageModel page({
  StudySettings? saved,
  SharpSettings? sharp,
  List<StudyAnswer> answers = const [],
  List<PromptEvent> events = const [],
  List<SleepReport>? reports,
}) => buildStudyPage(
  saved: saved,
  sharp: sharp,
  answers: answers,
  events: events,
  reports: reports ?? fiveNights(),
  now: _now,
);

PromptEvent ev(DateTime planned, PromptEventKind k) => PromptEvent(planned: planned, at: planned, event: k);

void main() {
  test('your sleep sets the times: 21:30 and 08:00, kept inside the suggested waking hours (08:00 to 22:00)', () {
    final m = page();
    expect((m.times.evening, m.times.morning), (21 * 60 + 30, 8 * 60));
    expect(m.times.eveningAuto && m.times.morningAuto, isTrue);
    expect(m.window, (8 * 60, 22 * 60));
    expect(m.windowFromSharp, isFalse);
    expect(m.on, isFalse);
    expect(studyStatus(m), 'Off. Nothing is asked until you switch it on.');
    expect(studyStatus(page(saved: const StudySettings(on: true))), 'On: evening 21:30, morning 08:00.');
    expect(studyStatus(page(saved: const StudySettings(on: false))), contains('your answers so far are kept'));
  });

  test('no recorded nights: 21:00 and 08:30, no waking hours to keep to', () {
    final m = page(reports: const []);
    expect((m.times.evening, m.times.morning), (21 * 60, 8 * 60 + 30));
    expect(m.window, (0, 1439));
  });

  test('a saved sharp-hours window is the quiet hours', () {
    final m = page(
      sharp: const SharpSettings(on: false, perDay: 4, fromMin: 9 * 60, untilMin: 21 * 60, seed: 'x'),
    );
    expect(m.windowFromSharp, isTrue);
    expect(m.window, (9 * 60, 21 * 60));
    expect(m.times.evening, 21 * 60, reason: '21:30 moved to the end of the waking hours');
    expect(m.times.morning, 9 * 60, reason: '08:00 moved to their start');
  });

  test('the last 14 days: evenings answered and studied, the mornings by word; today apart', () {
    final m = page(
      answers: [
        StudyAnswer.evening(at: DateTime(2026, 11, 26, 21), studied: true),
        StudyAnswer.evening(at: DateTime(2026, 11, 27, 21), studied: false),
        StudyAnswer.morning(at: DateTime(2026, 11, 27, 8), recall: Recall.well),
        StudyAnswer.morning(at: DateTime(2026, 11, 28, 8), recall: Recall.little),
        StudyAnswer.evening(at: DateTime(2026, 11, 28, 10), studied: true),
        StudyAnswer.evening(at: DateTime(2026, 11, 1, 21), studied: true), // older than 14 days
      ],
    );
    expect((m.evenings, m.studied), (3, 2));
    expect(m.recalls, {Recall.little: 1, Recall.some: 0, Recall.well: 1});
    expect(m.recallCount, 2);
    expect(m.today.length, 2);
    expect(m.morningToday!.recall, Recall.little);
    expect(m.eveningToday!.studied, isTrue);
  });

  test('do the reminders arrive: the first event of each planned one in the last 7 days', () {
    final a = DateTime(2026, 11, 27, 21, 30), b = DateTime(2026, 11, 28, 8), c = DateTime(2026, 11, 26, 21, 30);
    final old = DateTime(2026, 11, 10, 21, 30);
    final r = reachOfStudy([
      ev(a, PromptEventKind.shown),
      ev(a, PromptEventKind.snoozed),
      ev(a, PromptEventKind.shown),
      ev(b, PromptEventKind.skipped),
      ev(c, PromptEventKind.late),
      ev(old, PromptEventKind.shown),
    ], _now);
    expect((r.shown, r.skipped, r.late, r.arrived), (1, 1, 1, 3));
  });
}
