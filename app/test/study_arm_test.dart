// The phone is given one list: the sharp-hours questions and the study reminders together (DECISIONS row 401), so
// arming one never wipes the other.
import 'dart:io';

import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sharp/store.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/study/arm.dart';
import 'package:eeg_tracker/study/schedule.dart';
import 'package:eeg_tracker/study/store.dart';
import 'package:eeg_tracker/wearer/check.dart' show answerSomeoneElse;
import 'package:flutter_test/flutter_test.dart';

import 'sharp_prompts_test.dart' show FakeSharpPhone;
import 'study_page_test.dart' show night;

void main() {
  late Directory tmp;
  late String recordings;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('arm');
    recordings = '${tmp.path}/recordings';
  });
  tearDown(() => tmp.deleteSync(recursive: true));
  final now = DateTime(2026, 11, 20, 15);
  const sharpOn = SharpSettings(on: true, perDay: 4, fromMin: 600, untilMin: 1320, seed: 'x');

  test('nothing saved, or both off: an empty list (it cancels)', () async {
    final phone = FakeSharpPhone();
    await rearmPrompts(recordings, phone, now);
    SharpStore(sharpDirFor(recordings)).saveSettings(sharpOn.copyWith(on: false));
    StudyStore(studyDirFor(recordings)).saveSettings(const StudySettings(on: false));
    await rearmPrompts(recordings, phone, now);
    expect(phone.armed, [isEmpty, isEmpty]);
  });

  test('study only: the evening and morning of the next 14 days, at 21:00 and 08:30 without recorded nights', () async {
    final phone = FakeSharpPhone();
    StudyStore(studyDirFor(recordings)).saveSettings(const StudySettings(on: true));
    await rearmPrompts(recordings, phone, now);
    final p = phone.armed.single;
    expect(p.every((x) => x.kind.isStudy), isTrue);
    expect(p.first.at, DateTime(2026, 11, 20, 21));
    expect(p.first.kind, PromptKind.studyEvening);
    expect(p[1].at, DateTime(2026, 11, 21, 8, 30));
    expect(p[1].kind, PromptKind.studyMorning);
    expect(p.length, 14 * 2 + 1);
  });

  test('sharp hours and study together: one list, oldest first, each moment its own kind', () async {
    final phone = FakeSharpPhone();
    SharpStore(sharpDirFor(recordings)).saveSettings(sharpOn);
    StudyStore(studyDirFor(recordings)).saveSettings(const StudySettings(on: true, eveningMin: 1230, morningMin: 540));
    await rearmPrompts(recordings, phone, now);
    final p = phone.armed.single;
    expect(p.length, greaterThan(upcomingPrompts(now, sharpOn).length));
    for (var i = 1; i < p.length; i++) {
      expect(p[i].at.isBefore(p[i - 1].at), isFalse);
    }
    expect(p.where((x) => x.kind == PromptKind.sharp).length, upcomingPrompts(now, sharpOn).length);
    expect(p.where((x) => x.kind == PromptKind.studyEvening).first.at, DateTime(2026, 11, 20, 20, 30));
    expect(p.where((x) => x.kind == PromptKind.studyMorning).first.at, DateTime(2026, 11, 21, 9));
  });

  test(
    'the sharp window is the quiet hours: a study time set by hand is used as it is, automatic ones keep inside',
    () {
      final p = plannedPrompts(
        now: now,
        sharp: sharpOn.copyWith(untilMin: 20 * 60), // awake until 20:00
        study: const StudySettings(on: true),
      );
      expect(
        p.where((x) => x.kind == PromptKind.studyEvening).first.at,
        DateTime(2026, 11, 20, 20),
        reason: '21:00 moved to the end of the waking hours',
      );
    },
  );

  test('an answered evening is not asked again, and "no" drops the next morning', () async {
    final phone = FakeSharpPhone();
    final store = StudyStore(studyDirFor(recordings))
      ..saveSettings(const StudySettings(on: true, eveningMin: 1230, morningMin: 540));
    store.addAnswer(StudyAnswer.evening(at: DateTime(2026, 11, 20, 14), studied: false));
    await rearmPrompts(recordings, phone, now);
    final p = phone.armed.single;
    expect(
      p.first.at,
      DateTime(2026, 11, 21, 20, 30),
      reason: 'today\'s evening is answered, tomorrow\'s morning has nothing to recall',
    );
    expect(p.first.kind, PromptKind.studyEvening);
  });

  test('nights someone else wore do not set the times (DECISIONS 377): two own nights are too few', () async {
    // three late nights tagged "someone else" and two of the owner's: only the owner's count, and two are under the
    // three a usual bedtime needs, so the reminders keep 21:00 and 08:30
    final nights = NightReportStore(nightsDirFor(recordings));
    for (var d = 15; d <= 19; d++) {
      final own = d >= 18;
      final start = own ? DateTime(2026, 11, d, 23, 10) : DateTime(2026, 11, d + 1, 2, 40);
      nights.write({
        ...night(start, start.add(const Duration(hours: 8))).json,
        'night_of': '2026-11-$d',
        if (!own) 'wearer': {'answer': answerSomeoneElse},
      });
    }
    expect(nights.all(), hasLength(5));
    final phone = FakeSharpPhone();
    StudyStore(studyDirFor(recordings)).saveSettings(const StudySettings(on: true));
    await rearmPrompts(recordings, phone, now);
    final p = phone.armed.single;
    expect(p.first.at, DateTime(2026, 11, 20, 21));
    expect(p[1].at, DateTime(2026, 11, 21, 8, 30));
  });

  test('readOwnDayNumbers: sharp hours and recall together', () {
    SharpStore(sharpDirFor(recordings)).addRating(SharpRating(at: DateTime(2026, 11, 20, 10), sharp: 4));
    StudyStore(studyDirFor(recordings))
        .addAnswer(StudyAnswer.morning(at: DateTime(2026, 11, 21, 8), recall: Recall.well));
    final n = readOwnDayNumbers(recordings);
    expect(n['sharp'], {'2026-11-20': 4.0});
    expect(n['recall'], {'2026-11-21': 3.0});
    expect(n['dayrt'], isEmpty);
  });
}
