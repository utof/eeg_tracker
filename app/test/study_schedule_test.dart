// Evening study, morning review: the reminders' schedule (DECISIONS rows 400-401). Pure: the times from the phone's
// sleep reports, the quiet hours, and which reminders are still worth ringing.
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/study/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Night = ({DateTime start, DateTime end});

/// [n] nights from [d0], each asleep at [bed] and awake at [wake] (minutes after midnight; bed after midnight when
/// smaller than wake).
List<Night> nights(int bed, int wake, {int n = 5, int d0 = 10}) => [
  for (var i = 0; i < n; i++)
    (
      start: DateTime(
        2026,
        11,
        d0 + i,
        bed ~/ 60,
        bed % 60,
      ).add(bed < 12 * 60 ? const Duration(days: 1) : Duration.zero),
      end: DateTime(2026, 11, d0 + i + 1, wake ~/ 60, wake % 60),
    ),
];

int hm(int h, int m) => h * 60 + m;

/// What the sleep gives, as [studyTimes] takes it.
({int evening, int morning}) sug(int evening, int morning) => (evening: evening, morning: morning);

void main() {
  group('the times from your sleep', () {
    test('evening: 90 minutes before your usual bedtime, down to the quarter hour', () {
      expect(suggestTimes(nights(hm(23, 10), hm(7, 5))).evening, hm(21, 30));
      expect(suggestTimes(nights(hm(23, 30), hm(7, 5))).evening, hm(22, 0));
    });

    test('morning: 45 minutes after your usual wake-up, up to the quarter hour', () {
      expect(suggestTimes(nights(hm(23, 10), hm(7, 5))).morning, hm(8, 0));
      expect(suggestTimes(nights(hm(23, 10), hm(7, 15))).morning, hm(8, 0));
      expect(suggestTimes(nights(hm(23, 10), hm(7, 16))).morning, hm(8, 15));
    });

    test('a bedtime after midnight still gives an evening before it', () {
      final t = suggestTimes(nights(hm(0, 40), hm(8, 30)));
      expect(t.evening, hm(23, 0));
      expect(t.morning, hm(9, 15));
    });

    test('always 1 to 2 hours before bed and 30 to 60 minutes after waking', () {
      for (var bed = 0; bed < 1440; bed += 7) {
        final t = suggestTimes(nights(bed, hm(7, 0), n: 3));
        final before = (bed - t.evening + 1440) % 1440;
        expect(before, inInclusiveRange(90, 104), reason: 'bed $bed');
      }
      for (var wake = 0; wake < 1440; wake += 7) {
        final t = suggestTimes(nights(hm(23, 0), wake, n: 3));
        final after = (t.morning - wake + 1440) % 1440;
        expect(after, inInclusiveRange(45, 59), reason: 'wake $wake');
      }
    });

    test('under 3 recorded nights: 21:00 and 08:30', () {
      final t = suggestTimes(nights(hm(23, 10), hm(7, 5), n: 2));
      expect((t.evening, t.morning), (hm(21, 0), hm(8, 30)));
      expect(suggestTimes(const []).evening, hm(21, 0));
    });
  });

  group('quiet hours', () {
    const window = (600, 1320); // 10:00 to 22:00

    test('automatic times are kept inside the waking hours', () {
      final s = StudySettings(on: true);
      final t = studyTimes(s, sug(hm(21, 0), hm(8, 30)), window);
      expect(t.evening, hm(21, 0));
      expect(t.morning, hm(10, 0), reason: 'a morning reminder before the waking hours moves to their start');
      final late = studyTimes(s, sug(hm(22, 45), hm(11, 0)), window);
      expect(late.evening, hm(22, 0), reason: 'an evening one after them moves to their end');
      expect(late.morning, hm(11, 0));
    });

    test('times you set are used as they are', () {
      final s = StudySettings(on: true, eveningMin: hm(20, 15), morningMin: hm(9, 0));
      final t = studyTimes(s, sug(hm(21, 0), hm(8, 30)), window);
      expect((t.evening, t.morning), (hm(20, 15), hm(9, 0)));
      expect(t.eveningAuto, isFalse);
      expect(studyTimes(StudySettings(on: true), sug(hm(21, 0), hm(11, 0)), window).eveningAuto, isTrue);
    });

    test('a time is inside the waking hours, also across midnight', () {
      expect(timeInWindow(hm(10, 0), 600, 1320), isTrue);
      expect(timeInWindow(hm(22, 0), 600, 1320), isTrue);
      expect(timeInWindow(hm(22, 1), 600, 1320), isFalse);
      expect(timeInWindow(hm(9, 59), 600, 1320), isFalse);
      expect(timeInWindow(hm(0, 30), hm(14, 0), hm(2, 0)), isTrue);
      expect(timeInWindow(hm(12, 0), hm(14, 0), hm(2, 0)), isFalse);
    });
  });

  group('which reminders are still ahead', () {
    final now = DateTime(2026, 11, 20, 12);
    const times = (evening: 1290, morning: 480, eveningAuto: true, morningAuto: true); // 21:30, 08:00
    final on = StudySettings(on: true);

    List<(DateTime, PromptKind)> ahead(StudySettings s, List<StudyAnswer> answers, {int days = 3}) => [
      for (final p in upcomingStudy(now, s, times, answers, days: days)) (p.at, p.kind),
    ];

    test('off: nothing', () {
      expect(upcomingStudy(now, StudySettings(on: false), times, const []), isEmpty);
    });

    test('on: an evening and a morning every day, oldest first, only those after now', () {
      final a = ahead(on, const [], days: 1);
      expect(a, [
        (DateTime(2026, 11, 20, 21, 30), PromptKind.studyEvening),
        (DateTime(2026, 11, 21, 8), PromptKind.studyMorning),
        (DateTime(2026, 11, 21, 21, 30), PromptKind.studyEvening),
      ]);
    });

    test('the morning of today still rings when it is ahead; one already past does not', () {
      expect(ahead(on, const [], days: 0).first, (DateTime(2026, 11, 20, 21, 30), PromptKind.studyEvening));
      final early = DateTime(2026, 11, 20, 7);
      final p = upcomingStudy(early, on, times, const [], days: 0);
      expect(p.first.at, DateTime(2026, 11, 20, 8));
      expect(p.first.kind, PromptKind.studyMorning);
    });

    test('an evening already answered today is not asked again', () {
      final a = ahead(on, [StudyAnswer.evening(at: DateTime(2026, 11, 20, 11), studied: true)], days: 1);
      expect(a.first, (DateTime(2026, 11, 21, 8), PromptKind.studyMorning));
    });

    test('"no" last evening: no morning question about it', () {
      final a = ahead(on, [StudyAnswer.evening(at: DateTime(2026, 11, 19, 22), studied: false)], days: 1);
      expect(a.where((x) => x.$2 == PromptKind.studyMorning && x.$1.day == 21).length, 1);
      final no = ahead(on, [StudyAnswer.evening(at: DateTime(2026, 11, 20, 12), studied: false)], days: 2);
      expect(
        no.map((x) => x.$1),
        isNot(contains(DateTime(2026, 11, 21, 8))),
        reason: 'said no for the evening of the 20th',
      );
      expect(no.map((x) => x.$1), contains(DateTime(2026, 11, 22, 8)));
    });

    test('a "no" at 01:00 counts for the evening before it (the day runs 04:00 to 04:00)', () {
      final n = DateTime(2026, 11, 21, 0, 30);
      final a = upcomingStudy(n, on, times, [
        StudyAnswer.evening(at: DateTime(2026, 11, 21, 0, 10), studied: false),
      ], days: 1);
      expect(a.map((p) => p.at), isNot(contains(DateTime(2026, 11, 21, 8))));
    });

    test('a morning already answered is not asked again', () {
      final early = DateTime(2026, 11, 21, 7, 30);
      final a = upcomingStudy(early, on, times, [
        StudyAnswer.morning(at: DateTime(2026, 11, 21, 7), recall: Recall.some),
      ], days: 0);
      expect(a.where((p) => p.kind == PromptKind.studyMorning), isEmpty);
    });

    test('times after midnight belong to the next calendar date of their 04:00 day', () {
      const late = (evening: 1500, morning: 600, eveningAuto: false, morningAuto: false);
      final p = upcomingStudy(now, on, late, const [], days: 0);
      expect(p.first.at, DateTime(2026, 11, 21, 1, 0));
    });
  });

  group('the settings file', () {
    test('round trip; anything else is refused', () {
      final s = StudySettings(
        on: true,
        eveningMin: hm(20, 0),
        firstOn: DateTime(2026, 11, 20, 9),
        changed: DateTime(2026, 11, 20, 9),
      );
      final back = StudySettings.fromJson(s.toJson())!;
      expect(back.on, isTrue);
      expect(back.eveningMin, hm(20, 0));
      expect(back.morningMin, isNull);
      expect(back.firstOn, DateTime(2026, 11, 20, 9));
      expect(StudySettings.fromJson({'version': 2, 'on': true}), isNull);
      expect(StudySettings.fromJson({'version': 1, 'on': 'yes'}), isNull);
      expect(StudySettings.fromJson({'version': 1, 'on': true, 'evening': '25:00'}), isNull);
      expect(StudySettings.fromJson(null), isNull);
    });
  });
}
