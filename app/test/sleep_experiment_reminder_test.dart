// The optional evening reminder of a sleep experiment (DECISIONS 1085): off until switched on from the experiment's
// page, one a day at most, only for an evening that is still unanswered, in the phone's one list of reminders
// (the sharp-hours questions and the study reminders, DECISIONS 401), which rings none while a recording runs.
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/sharp/prompts.dart';
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sleep_experiments/kinds.dart';
import 'package:eeg_tracker/sleep_experiments/reminder.dart';
import 'package:eeg_tracker/sleep_experiments/store.dart';
import 'package:eeg_tracker/study/arm.dart';
import 'package:eeg_tracker/study/schedule.dart';
import 'package:eeg_tracker/study/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sharp_prompts_test.dart' show FakeSharpPhone;
import 'sleep_experiments_test.dart' show logOf;

final caffeine = kindById('caffeine_late')!, workout = kindById('workout_late')!;

({DateTime start, DateTime end}) _night(int day, int bedH, int bedM) =>
    (start: DateTime(2026, 11, day, bedH, bedM), end: DateTime(2026, 11, day + 1, 7, 30));

void main() {
  group('when it rings', () {
    test('22:15 without recorded nights; else 45 to 59 minutes before your usual bedtime, on a quarter hour', () {
      expect(reminderMinute(const [], (0, 1439)), 22 * 60 + 15);
      expect(reminderMinute([_night(1, 23, 40), _night(2, 23, 40)], (0, 1439)), 22 * 60 + 15, reason: 'under 3 nights');
      final late = [_night(1, 23, 40), _night(2, 23, 50), _night(3, 23, 30)];
      expect(reminderMinute(late, (0, 1439)), 22 * 60 + 45); // 23:40 - 45 min = 22:55, down to 22:45
      // bedtime after midnight
      final owl = [DateTime(2026, 11, 2, 1, 10), DateTime(2026, 11, 3, 1, 10), DateTime(2026, 11, 4, 1, 10)];
      expect(reminderMinute([for (final t in owl) (start: t, end: t.add(const Duration(hours: 8)))], (0, 1439)), 15);
    });
    test('never outside the waking hours: moved to their nearest end', () {
      final late = [_night(1, 23, 40), _night(2, 23, 50), _night(3, 23, 30)];
      expect(reminderMinute(late, (600, 1320)), 1320);
      expect(reminderMinute(const [], (600, 1320)), 1320);
      expect(reminderMinute(const [], (600, 1380)), 22 * 60 + 15);
    });
  });

  group('which evenings', () {
    const at = 22 * 60 + 15;
    final now = DateTime(2026, 11, 10, 18);
    ExperimentLog on(ExperimentKind k, Map<String, DayLog> days, {String? salt, String? ended}) {
      final e = logOf(k, days, salt: salt, ended: ended);
      return ExperimentLog(e.plan, e.days, e.ended, remind: true);
    }

    test('off unless switched on; none without an experiment or after it ended', () {
      expect(logOf(caffeine, const {}).remind, isFalse);
      expect(upcomingExperimentReminders(now, logOf(caffeine, const {}), at), isEmpty);
      expect(upcomingExperimentReminders(now, null, at), isEmpty);
      expect(upcomingExperimentReminders(now, on(caffeine, const {}, ended: '2026-11-09'), at), isEmpty);
    });
    test('one each evening, today first, for the next 14 days', () {
      final p = upcomingExperimentReminders(now, on(caffeine, const {}), at);
      expect(p.first.at, DateTime(2026, 11, 10, 22, 15));
      expect(p.every((x) => x.kind == PromptKind.sleepExperiment && !x.test), isTrue);
      expect(p.length, 15);
      expect({for (final x in p) x.at.hour * 60 + x.at.minute}, {at});
      expect({for (final x in p) DateTime(x.at.year, x.at.month, x.at.day)}.length, 15, reason: 'one a day');
    });
    test('tonight already answered: tonight\'s is dropped; a time that has passed is not rung late', () {
      final said = on(caffeine, {'2026-11-10': const DayLog(answer: Answer.without)});
      expect(upcomingExperimentReminders(now, said, at).first.at, DateTime(2026, 11, 11, 22, 15));
      expect(upcomingExperimentReminders(DateTime(2026, 11, 10, 22, 30), on(caffeine, const {}), at).first.at, DateTime(2026, 11, 11, 22, 15));
    });
    test('a reminder time after midnight belongs to the evening before', () {
      final p = upcomingExperimentReminders(DateTime(2026, 11, 10, 23, 50), on(caffeine, const {}), 15);
      expect(p.first.at, DateTime(2026, 11, 11, 0, 15));
      final said = on(caffeine, {'2026-11-10': const DayLog(answer: Answer.withIt)});
      expect(upcomingExperimentReminders(DateTime(2026, 11, 10, 23, 50), said, 15).first.at, DateTime(2026, 11, 12, 0, 15));
    });
    test('the app picks the nights: only an evening whose pick was drawn has a question to remind of', () {
      expect(upcomingExperimentReminders(now, on(workout, const {}, salt: 's'), at), isEmpty);
      final drawn = on(workout, {'2026-11-10': const DayLog(pick: true, pickIndex: 0)}, salt: 's');
      expect([for (final p in upcomingExperimentReminders(now, drawn, at)) p.at], [DateTime(2026, 11, 10, 22, 15)]);
    });
    test('not before the experiment\'s first evening', () {
      final e = logOf(caffeine, const {}, start: '2026-11-12');
      final p = upcomingExperimentReminders(now, ExperimentLog(e.plan, e.days, e.ended, remind: true), at);
      expect(p.first.at, DateTime(2026, 11, 12, 22, 15));
    });
  });

  group('on disk and in the phone\'s one list', () {
    late Directory tmp;
    late String rec;
    late SleepExperimentStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sleepexpremind');
      rec = '${tmp.path}/recordings';
      store = SleepExperimentStore(sleepExperimentsDirFor(rec));
    });
    tearDown(() => tmp.deleteSync(recursive: true));
    final now = DateTime(2026, 11, 10, 18);

    test('the switch is a line of the experiment\'s log: off at first, the last line wins', () {
      final id = store.create(kind: caffeine, picked: false, now: DateTime(2026, 11, 9, 12)).plan.id;
      expect(store.read(id)!.remind, isFalse);
      expect(store.setReminder(id, true, now), isTrue);
      expect(store.read(id)!.remind, isTrue);
      expect(File('${store.dir.path}/$id/log.jsonl').readAsLinesSync().last, contains('"event":"reminder"'));
      store.setReminder(id, false, now);
      expect(store.read(id)!.remind, isFalse);
      store.end(id, now);
      expect(store.setReminder(id, true, now), isFalse, reason: 'ended');
    });

    test('nothing switched on: the phone gets an empty list, as before', () async {
      store.create(kind: caffeine, picked: false, now: DateTime(2026, 11, 9, 12));
      final phone = FakeSharpPhone();
      await rearmPrompts(rec, phone, now);
      expect(phone.armed.single, isEmpty);
    });

    test('switched on: its evenings are in the list beside the study reminders, oldest first; answering drops tonight\'s', () async {
      final id = store.create(kind: caffeine, picked: false, now: DateTime(2026, 11, 9, 12), random: math.Random(1)).plan.id;
      store.setReminder(id, true, now);
      StudyStore(studyDirFor(rec)).saveSettings(const StudySettings(on: true));
      final phone = FakeSharpPhone();
      await rearmPrompts(rec, phone, now);
      final p = phone.armed.single;
      final mine = p.where((x) => x.kind == PromptKind.sleepExperiment).toList();
      expect(mine.first.at, DateTime(2026, 11, 10, 22, 15));
      expect(mine.length, 15);
      expect(p.where((x) => x.kind.isStudy).length, 14 * 2 + 1);
      for (var i = 1; i < p.length; i++) {
        expect(p[i].at.isBefore(p[i - 1].at), isFalse);
      }
      store.answer(id, '2026-11-10', Answer.neither, now);
      await rearmPrompts(rec, phone, now);
      expect(phone.armed.last.where((x) => x.kind == PromptKind.sleepExperiment).first.at, DateTime(2026, 11, 11, 22, 15));
    });

    test('a tap on the reminder opens the experiment; it is neither a study reminder nor a sharp question', () {
      final l = SharpLaunch.fromMap({'planned': 1763640000000, 'kind': 'sleep_experiment'})!;
      expect(l.kind, PromptKind.sleepExperiment);
      expect(PromptKind.sleepExperiment.isStudy, isFalse);
      expect(PromptKind.sleepExperiment.wire, 'sleep_experiment');
    });
  });
}
