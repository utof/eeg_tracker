// The confirmation questions (lib/confirm, DECISIONS 860-869): which estimates are asked about, that none is asked
// twice, what Yes, No and Not sure store, the labels file against the golden file the laptop's reader is checked with
// (analysis/tests/test_confirm.py), the notification's answers, and the detectors' estimates.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/archive/tags.dart';
import 'package:eeg_tracker/confirm/phone.dart';
import 'package:eeg_tracker/confirm/questions.dart';
import 'package:eeg_tracker/confirm/sources.dart';
import 'package:eeg_tracker/sleep/report.dart' hide isoLocal;
import 'package:eeg_tracker/walking/pass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_labels/shared_labels.dart';

class FakePhone implements ConfirmPhone {
  final List<(DateTime, List<String>, List<String>)> armed = [];
  final List<String> answeredIds = [];
  final List<List<Map<String, Object?>>> cards = [];

  @override
  Future<void> arm(DateTime at, List<String> ids, List<String> texts, {List<Map<String, Object?>> cards = const []}) async {
    armed.add((at, ids, texts));
    this.cards.add(cards);
  }

  @override
  Future<void> answered(String id) async => answeredIds.add(id);

  @override
  Future<bool> notificationsOn() async => true;

  @override
  Future<void> openChannelSettings() async {}

  @override
  set onOpen(void Function()? f) {}
}

Estimate est(
  Label label,
  DateTime start,
  int minutes, {
  double? confidence,
  String? recording = 'rec-a',
  String detector = 'd',
  String version = 'v1',
  YesMeans yesMeans = YesMeans.certain,
}) => Estimate(
  detector: detector,
  version: version,
  label: label,
  start: start,
  end: start.add(Duration(minutes: minutes)),
  recording: recording,
  confidence: confidence,
  yesMeans: yesMeans,
  made: start.add(Duration(minutes: minutes)),
);

void main() {
  late Directory files;
  final day = DateTime(2026, 11, 20);
  DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));
  var now = at(22);

  ConfirmQuestions make({ConfirmPhone? phone}) => ConfirmQuestions(files, phone: phone, clock: () => now);

  setUp(() {
    files = Directory.systemTemp.createTempSync('confirm-test');
    now = at(22);
  });
  tearDown(() => files.deleteSync(recursive: true));

  group('the question', () {
    test('is short, with the times in local time and a day word only when it is not today', () {
      final nap = est(Labels.nap, at(15, 59), 110);
      expect(questionOf(nap, at(18)), '15:59-17:49. The headband thinks you napped. Did you?');
      expect(questionOf(est(Labels.walking, at(19, 8), 126), at(22)), '19:08-21:14. The headband thinks you walked. Did you?');
      expect(questionOf(est(Labels.asleep, at(23, 41), 444), at(32)), '23:41-07:05. The headband thinks you slept. Did you?', reason: 'a night ended today');
      expect(questionOf(nap, at(32)), 'Yesterday 15:59-17:49. The headband thinks you napped. Did you?');
      expect(questionOf(nap, at(24 * 3 + 8)), 'Fri 20 Nov 15:59-17:49. The headband thinks you napped. Did you?');
    });

    test('an estimate keeps its id across detector versions and reads back from its line', () {
      final a = est(Labels.walking, at(19, 8), 126, confidence: 0.9);
      final b = est(Labels.walking, at(19, 8), 126, version: 'v2');
      expect(a.id, b.id);
      expect(a.id, matches(RegExp(r'^est:[0-9a-f]{16}$')));
      expect(est(Labels.walking, at(19, 9), 126).id, isNot(a.id));
      final back = Estimate.fromJson(jsonDecode(jsonEncode(a.toJson())))!;
      expect((back.id, back.confidence, back.label, back.start, back.end, back.recording), (a.id, 0.9, a.label, a.start, a.end, 'rec-a'));
      expect(Estimate.fromJson({...a.toJson(), 'label': 'juggling'}), isNull);
      expect(Estimate.fromJson({...a.toJson(), 'end': a.toJson()['start'], 'start': a.toJson()['end']}), isNull);
    });
  });

  group('the queue', () {
    test('with more waiting than a batch holds: the notification takes the newest and the least sure, the card keeps every one', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      final sure = est(Labels.walking, at(9), 20, confidence: 0.9);
      final unsure = est(Labels.walking, at(11), 20, confidence: 0.4);
      final long = est(Labels.walking, at(13), 150, confidence: 0.8);
      final rare = est(Labels.nap, at(16), 30, confidence: 0.9);
      q.register([sure, unsure, long, rare]);
      q.store.saveSettings(const ConfirmSettings(perBatch: 3));
      final got = q.pending();
      expect([for (final x in got) x.id], [sure.id, unsure.id, long.id, rare.id], reason: 'the older, sure walk stays on the card');
      expect(got.first.guessText, '09:00-09:20. The headband thinks you walked. Did you?');
      expect({for (final x in got) x.id: x.why}[unsure.id], 'unsure');
      expect(quickChecksWaiting.value, 4, reason: 'the Record tab\'s badge counts all of them');
      // the notification is planned for three; the fourth is not pushed
      await q.plan();
      expect(phone.armed.single.$2, [unsure.id, long.id, rare.id]);
      // nothing is closed unasked: no "not answered" line, and it is no label
      expect(q.close(), 0);
      final s = q.store.read();
      expect((s.unanswered.containsKey(sure.id), s.closed(sure.id)), (false, false));
      q.answer(unsure.id, Answer.yes);
      expect([for (final x in q.pending()) x.id], [sure.id, long.id, rare.id]);
      expect(quickChecksWaiting.value, 3);
      // it ages out by the usual rule: 48 hours after it ended
      now = at(9, 21 + 48 * 60);
      expect([for (final x in q.pending()) x.id], [long.id, rare.id]);
      expect(q.close(), 1, reason: 'now it is written down as too old, as before');
      expect(q.store.read().unanswered[sure.id]!.why, WhyNot.neverSeen);
    });

    test('a kind with few answers so far comes before one with many', () {
      final q = make();
      final walks = [for (var h = 8; h < 12; h++) est(Labels.walking, at(h), 20, confidence: 0.8)];
      final naps = [est(Labels.nap, at(13), 20, confidence: 0.8), est(Labels.nap, at(14), 20, confidence: 0.8)];
      q.register([...walks, ...naps]);
      q.answer(walks[0].id, Answer.yes);
      q.answer(walks[1].id, Answer.no);
      final state = q.store.read();
      expect(state.labelsOf(Labels.walking), 2);
      expect(valueOf(naps[0], state).value, greaterThan(valueOf(walks[2], state).value));
    });

    test('leaves out what is not over, what is too old, and everything when switched off', () {
      final q = make();
      final old = est(Labels.walking, at(-30), 30);
      final going = est(Labels.walking, at(21, 50), 30);
      final ok = est(Labels.walking, at(20), 30);
      q.register([old, going, ok]);
      expect([for (final x in q.pending()) x.id], [ok.id]);
      q.store.saveSettings(const ConfirmSettings(on: false));
      expect(q.pending(), isEmpty);
      expect(q.pendingFor('rec-a', at(-40), at(23)).map((x) => x.id), [old.id, ok.id], reason: 'a recording\'s own batch: any age, the switch does not matter');
    });

    test('never asks about a stretch you tagged in the Archive with that word', () {
      final q = make();
      final walk = est(Labels.walking, at(19, 8), 126);
      final nap = est(Labels.nap, at(15, 59), 110);
      q.register([walk, nap]);
      final tags = TagStore(files);
      tags.add('rec-a', ManualTag(start: at(19), end: at(21, 10), label: 'walk'));
      expect([for (final x in q.pending()) x.id], [nap.id]);
      tags.add('rec-a', ManualTag(start: at(9), end: at(18), label: 'work')); // another word: no say about a nap
      expect([for (final x in q.pending()) x.id], [nap.id]);
      tags.add('rec-b', ManualTag(start: at(16), end: at(17, 45), label: 'sleep')); // sleep and nap are one question
      expect(q.pending(), isEmpty);
    });
  });

  group('never twice', () {
    test('an answered estimate is not asked again, and neither is the same stretch found again', () {
      final q = make();
      final walk = est(Labels.walking, at(19, 8), 126);
      q.register([walk]);
      q.answer(walk.id, Answer.skip);
      expect(q.pending(), isEmpty, reason: 'Not sure is an answer');
      // a new detector version moves the ends a little: the same question
      final again = est(Labels.walking, at(19, 10), 120, version: 'v2');
      expect(q.register([again]), 1);
      expect(q.pending(), isEmpty);
      // the same stretch scored as something else is another question
      final other = est(Labels.asleep, at(19, 20), 30);
      q.register([other]);
      expect([for (final x in q.pending()) x.id], [other.id]);
    });

    test('registering the same estimate twice keeps one line, and two open estimates of one stretch ask once', () {
      final q = make();
      final a = est(Labels.nap, at(15, 59), 110);
      expect(q.register([a]), 1);
      expect(q.register([a]), 0);
      expect(q.store.estimatesFile.readAsLinesSync(), hasLength(1));
      final b = est(Labels.asleep, at(16, 5), 100, version: 'v2');
      q.register([b]);
      expect([for (final x in q.pending()) x.id], [b.id], reason: 'the newer estimate of the stretch');
    });

    test('an estimate goes out in one notification batch only; the card keeps it', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      q.store.saveSettings(const ConfirmSettings(quietStartMin: 23 * 60));
      final walk = est(Labels.walking, at(19, 8), 126);
      q.register([walk]);
      now = at(21, 20);
      await q.plan();
      expect(phone.armed.single.$1, at(21, 24), reason: '10 minutes after the walk ended');
      expect(phone.armed.single.$2, [walk.id]);
      expect(phone.armed.single.$3, ['19:08-21:14. The headband thinks you walked. Did you?']);
      await q.plan();
      expect(phone.armed, hasLength(1), reason: 'the same batch is not armed again');
      now = at(21, 30); // its moment passed: it went out
      await q.plan();
      expect(q.store.read().notified, {walk.id});
      expect(q.store.armed(), isNull);
      expect(phone.armed, hasLength(1));
      expect([for (final x in q.pending()) x.id], [walk.id]);
      // a new estimate makes a new batch without the old one, an hour after the last
      final nap = est(Labels.nap, at(20), 30);
      q.register([nap]);
      await q.plan();
      expect(phone.armed.last.$2, [nap.id]);
      expect(phone.armed.last.$1, at(22, 24));
    });
  });

  group('when', () {
    final walk = est(Labels.walking, at(19, 8), 126);
    ConfirmState state([List<DateTime> batches = const []]) =>
        ConfirmState(estimates: {walk.id: walk}, answers: {}, notified: {}, batches: batches);
    List<Pick> batch() => [Pick(walk, 1, 'long')];

    test('soon after the stretch, now when it is long over, never when off or with nothing to ask', () {
      const s = ConfirmSettings();
      expect(planTime(batch(), state(), s, at(21, 15)), at(21, 24));
      expect(planTime(batch(), state(), s, at(21, 40)), at(21, 40));
      expect(planTime(const [], state(), s, at(21, 40)), isNull);
      expect(planTime(batch(), state(), const ConfirmSettings(on: false), at(21, 40)), isNull);
    });

    test('not in the quiet hours: at their end, also across midnight', () {
      const s = ConfirmSettings(); // 22:00 to 08:00
      expect(planTime(batch(), state(), s, at(22, 5)), at(32));
      expect(planTime(batch(), state(), s, at(27)), at(32));
      expect(planTime(batch(), state(), s, at(21, 55)), at(21, 55));
      const day = ConfirmSettings(quietStartMin: 13 * 60, quietEndMin: 15 * 60);
      expect(planTime(batch(), state(), day, at(13, 30).add(const Duration(days: 1))), at(15).add(const Duration(days: 1)));
    });

    test('an hour between batches and at most so many a day', () {
      const s = ConfirmSettings(perDay: 2);
      expect(planTime(batch(), state([at(21)]), s, at(21, 30)), at(22).add(const Duration(hours: 10)), reason: '22:00 is quiet: the morning');
      expect(planTime(batch(), state([at(12)]), s, at(21, 30)), at(21, 30));
      expect(planTime(batch(), state([at(10), at(12)]), s, at(21, 30)), at(32), reason: 'two went out today: tomorrow, after the quiet hours');
    });
  });

  group('answers', () {
    test('Yes, No and Not sure are stored as lines; the first stands, undo takes it back', () {
      final q = make();
      final a = est(Labels.nap, at(15, 59), 110), b = est(Labels.walking, at(19, 8), 126), c = est(Labels.asleep, at(19, 20), 30);
      q.register([a, b, c]);
      now = at(22, 1);
      q.answer(a.id, Answer.yes);
      q.answer(b.id, Answer.no);
      q.answer(c.id, Answer.skip);
      q.answer(a.id, Answer.no); // already answered: nothing written
      final lines = [for (final l in q.store.answersFile.readAsLinesSync()) jsonDecode(l) as Map];
      expect(lines, [
        {'estimate_id': a.id, 'answer': 'yes', 'at': '2026-11-20T22:01:00+03:00', 'via': 'card', 'guess': 'nap', 'confidence': null, 'age_min': 252, 'times_confirmed': false},
        {'estimate_id': b.id, 'answer': 'no', 'at': '2026-11-20T22:01:00+03:00', 'via': 'card', 'guess': 'walking', 'confidence': null, 'age_min': 47},
        {'estimate_id': c.id, 'answer': 'not_sure', 'at': '2026-11-20T22:01:00+03:00', 'via': 'card', 'guess': 'asleep', 'confidence': null, 'age_min': 131},
      ]);
      var s = q.store.read();
      expect({for (final e in s.answers.entries) e.key: e.value.answer}, {a.id: Answer.yes, b.id: Answer.no, c.id: Answer.skip});
      q.undo(b.id);
      s = q.store.read();
      expect(s.answered(b.id), isFalse);
      expect([for (final x in q.pending()) x.id], [b.id], reason: 'asked again after undo');
      q.answer(b.id, Answer.yes);
      expect(q.store.read().answers[b.id]!.answer, Answer.yes);
    });

    test('Yes makes a label over the estimate, No a label that it was not so, Not sure none', () {
      final q = make();
      final a = est(Labels.asleep, at(1), 300, confidence: 0.8, yesMeans: YesMeans.likely, recording: '2026-11-20-010000');
      final b = est(Labels.walking, at(19, 8), 126, recording: null);
      final c = est(Labels.nap, at(15), 30);
      q.register([a, b, c]);
      q.answer(a.id, Answer.yes);
      q.answer(b.id, Answer.no);
      q.answer(c.id, Answer.skip);
      q.note(b.id, ' I was on the\tsofa ');
      final rows = [for (final l in q.store.labelsFile.readAsLinesSync()) l.split('\t')];
      expect(rows.first, labelColumns);
      expect(rows, hasLength(3));
      Map<String, String> row(int i) => Map.fromIterables(labelColumns, rows[i]);
      expect(row(1), {
        'label_id': 'confirm:${a.id.substring(4)}',
        'start': '2026-11-20T01:00:00+03:00',
        'end': '2026-11-20T06:00:00+03:00',
        'recording': '2026-11-20-010000',
        'kind': 'state',
        'label': 'asleep',
        'value': '',
        'unit': '',
        'source': 'owner_app_prompt',
        'confidence': 'likely',
        'created': '2026-11-20T22:00:00+03:00',
        'supersedes': '',
        'owner_words': 'Yes',
        'context': 'the app asked; d (v1) said asleep, confidence 0.80',
        'present': '1',
        'estimate_id': a.id,
        'times_confirmed': '0',
      });
      expect((row(2)['label'], row(2)['present'], row(2)['confidence'], row(2)['owner_words'], row(2)['recording']), (
        'walking',
        '0',
        'certain',
        'No: I was on the sofa',
        '',
      ));
    });

    test('the labels file is the golden file the laptop is checked against', () {
      final from = Directory('../packages/shared_labels/test/fixtures/confirm');
      Directory('${files.path}/confirm').createSync();
      for (final n in ['estimates.jsonl', 'answers.jsonl']) {
        File('${from.path}/$n').copySync('${files.path}/confirm/$n');
      }
      final state = ConfirmStore(files).read();
      expect(state.estimates, hasLength(15));
      expect(labelsTsv(state), File('${from.path}/labels.tsv').readAsStringSync());
      expect(estimatesTsv(state), File('${from.path}/estimates.tsv').readAsStringSync());
      expect(tsvCell('a "b"'), '"a ""b"""');
      expect(tsvCell('plain, with a comma'), 'plain, with a comma');
    });

    test('a question nobody answered is written down as that, once, and is not a label', () async {
      final q = make(phone: FakePhone());
      q.store.saveSettings(const ConfirmSettings(quietStartMin: 23 * 60));
      final pushed = est(Labels.walking, at(19, 8), 126), unseen = est(Labels.nap, at(21), 30);
      q.register([pushed]);
      now = at(21, 30);
      await q.plan(); // armed for 21:30
      now = at(21, 40);
      await q.plan(); // it went out
      q.register([unseen]);
      expect(q.store.read().notified, {pushed.id});
      now = at(48 + 21, 20);
      expect(q.close(), 1, reason: 'the walk ended 48 h and 6 minutes ago');
      now = at(48 + 21, 31);
      await q.plan();
      expect(q.close(), 0, reason: 'each once');
      final s = q.store.read();
      expect((s.unanswered[pushed.id]!.why, s.unanswered[unseen.id]!.why), (WhyNot.expired, WhyNot.neverSeen));
      expect((s.answered(pushed.id), s.closed(pushed.id), s.closed(unseen.id)), (false, true, true));
      expect(q.pending(), isEmpty);
      expect(q.store.labelsFile.readAsLinesSync(), hasLength(1), reason: 'silence is no label');
      final table = q.store.estimatesTable.readAsStringSync();
      expect(RegExp('not_answered').allMatches(table), hasLength(2));
      expect(table, isNot(contains('\tyes\t')));
    });

    test('the card\'s answer keeps what the card was; every answer reaches the hook with whose the times are', () {
      final got = <(String, Answer, bool)>[];
      ConfirmQuestions.onAnswered = (e, a) => got.add((e.id, a.answer, a.timesConfirmed));
      addTearDown(() => ConfirmQuestions.onAnswered = null);
      final q = make();
      final a = est(Labels.nap, at(15, 59), 110, confidence: 0.8), b = est(Labels.walking, at(19, 8), 126);
      q.register([a, b]);
      now = at(22, 0).add(const Duration(seconds: 3));
      q.answer(a.id, Answer.yes, card: CardKind.normal, shown: at(22));
      q.answer(b.id, Answer.yes, card: CardKind.normal, shown: at(22), start: at(19, 20), end: at(21));
      final s = q.store.read();
      expect((s.answers[a.id]!.card, s.answers[a.id]!.seconds, s.answers[a.id]!.ageMin, s.answers[a.id]!.guessConfidence), (CardKind.normal, 3.0, 251, 0.8));
      expect(got, [(a.id, Answer.yes, false), (b.id, Answer.yes, true)]);
      expect((s.answers[b.id]!.start, s.answers[b.id]!.end), (at(19, 20), at(21)));
    });

    test('a Yes calls the hook with the estimate and the answer as kept (record-first makes a sleep stretch of it)', () {
      final got = <(Estimate, Answered)>[];
      ConfirmQuestions.onYes = (e, a) => got.add((e, a));
      addTearDown(() => ConfirmQuestions.onYes = null);
      final q = make();
      final a = est(Labels.nap, at(15, 59), 110), b = est(Labels.walking, at(19, 8), 126), c = est(Labels.asleep, at(2), 60);
      q.register([a, b, c]);
      q.answer(a.id, Answer.yes);
      q.answer(b.id, Answer.no);
      q.answer(c.id, Answer.yes, start: at(2, 10), end: at(2, 50));
      expect([for (final x in got) (x.$1.id, x.$2.timesConfirmed, x.$2.start)], [(a.id, false, null), (c.id, true, at(2, 10))]);
    });
  });

  group('the notification', () {
    test('its buttons write the app\'s own answer lines, read when the app is next open', () async {
      final q = make(phone: FakePhone());
      final a = est(Labels.nap, at(15, 59), 110), b = est(Labels.walking, at(19, 8), 126);
      q.register([a, b]);
      // ConfirmPrompts.kt: JSONObject().put("estimate_id", id).put("answer", answer).put("at", iso).put("via", "notification")
      q.store.answersFile.writeAsStringSync(
        '{"estimate_id":"${a.id}","answer":"yes","at":"2026-11-20T21:30:12+03:00","via":"notification"}\n'
        '{"estimate_id":"${b.id}","answer":"skip","at":"2026-11-20T21:30:15+03:00","via":"notification"}\n'
        '{"estimate_id":"${b.id}","answ', // the app was killed mid-line
        mode: FileMode.append,
      );
      expect(q.pending(), isEmpty);
      await q.refresh(collect: (_) => const []);
      final rows = q.store.labelsFile.readAsLinesSync();
      expect(rows, hasLength(2));
      expect(rows[1], contains('owner_app_prompt'));
      expect(rows[1], contains('2026-11-20T21:30:12+03:00'));
      final s = q.store.read();
      expect((s.answers[a.id]!.via, s.answers[b.id]!.answer), ('notification', Answer.skip));
    });

    test('an answer in the app leaves the notification; the waiting batch loses it', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      final a = est(Labels.nap, at(20, 30), 60), b = est(Labels.walking, at(19, 8), 126);
      q.register([a, b]);
      now = at(21, 31);
      await q.plan();
      expect(phone.armed.single.$2, [b.id, a.id]);
      q.answer(b.id, Answer.yes);
      await pumpEventQueue();
      expect(phone.answeredIds, [b.id]);
      expect(phone.armed.last.$2, [a.id], reason: 'armed again without the answered one');
      q.answer(a.id, Answer.no);
      await pumpEventQueue();
      expect(phone.armed.last.$2, isEmpty, reason: 'nothing left: the alarm is cancelled');
      expect(q.store.armed(), isNull);
    });

    test('the batch\'s words are as read at its moment: a night asked about in the morning', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      q.register([est(Labels.walking, at(19, 8), 126)]);
      now = at(22, 30); // quiet: goes out at 08:00 tomorrow
      await q.plan();
      expect(phone.armed.single.$1, at(32));
      expect(phone.armed.single.$3, ['Yesterday, about 19:00 to 21:00. The headband thinks you walked. Did you?']);
    });
  });

  group('the asking rules through the door (DECISIONS 960-979)', () {
    // 16:14 draws a blind card (1 in 5, by id); 15:59 and 19:08 do not
    final hidden = est(Labels.nap, at(16, 14), 40, confidence: 0.6), walk = est(Labels.walking, at(19, 8), 126, confidence: 0.9);
    void lineOf(ConfirmQuestions q, Map<String, Object?> j) => q.store.asksFile.writeAsStringSync('${jsonEncode(j)}\n', mode: FileMode.append);

    test('1 card in 5 is blind on the card and in the notification; the stop sheet shows the guess', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      q.store.saveSettings(const ConfirmSettings(quietFromSleep: false, quietStartMin: 23 * 60));
      q.register([hidden, walk]);
      now = at(21, 30);
      final cards = q.pending();
      expect([for (final c in cards) (c.kind, c.text)], [
        (CardKind.blind, 'What were you doing 16:14-16:54?'),
        (CardKind.normal, '19:08-21:14. The headband thinks you walked. Did you?'),
      ]);
      expect(q.pendingFor('rec-a', at(0), at(22)).map((c) => c.kind), everyElement(CardKind.normal));
      await q.plan();
      expect(phone.armed.single.$3, ['What were you doing 16:14-16:54?', '19:08-21:14. The headband thinks you walked. Did you?']);
      expect(phone.cards.single, [
        {'card': 'blind', 'yes': '', 'no': '', 'guess': 'nap', 'confidence': 0.6, 'end_ms': at(16, 54).millisecondsSinceEpoch},
        {'card': 'normal', 'yes': 'I walked', 'no': 'I did not walk', 'guess': 'walking', 'confidence': 0.9, 'end_ms': at(21, 14).millisecondsSinceEpoch},
      ]);
      // the notification's own lines (ConfirmPrompts.kt) read like the card's
      q.store.answersFile.writeAsStringSync(
        '{"estimate_id":"${walk.id}","answer":"yes","at":"2026-11-20T21:40:03+03:00","via":"notification","card":"normal","guess":"walking","confidence":0.9,"shown":"2026-11-20T21:40:00+03:00","seconds":3.2,"age_min":26,"times_confirmed":false}\n'
        '{"estimate_id":"${hidden.id}","answer":"not_answered","why":"dismissed","at":"2026-11-20T21:41:00+03:00","via":"notification"}\n',
        mode: FileMode.append,
      );
      final s = q.store.read();
      expect((s.answers[walk.id]!.seconds, s.answers[walk.id]!.timesConfirmed, s.answers[walk.id]!.via), (3.2, false, 'notification'));
      expect((s.unanswered[hidden.id]!.why, s.closed(hidden.id)), (WhyNot.dismissed, false));
      expect([for (final c in q.pending()) c.id], [hidden.id], reason: 'swiped away: still on the card');
    });

    test('at most 2 pushed batches a day: the third is planned for tomorrow and waits on the card', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      q.store.saveSettings(const ConfirmSettings(quietFromSleep: false));
      lineOf(q, {'at': '2026-11-20T10:00:00+03:00', 'via': 'notification', 'estimates': ['a']});
      lineOf(q, {'at': '2026-11-20T13:00:00+03:00', 'via': 'notification', 'estimates': ['b']});
      q.register([walk]);
      now = at(21, 30);
      await q.plan();
      expect(phone.armed.single.$1, at(32), reason: 'tomorrow at the end of the quiet hours');
      expect([for (final c in q.pending()) c.id], [walk.id]);
      // an answer on the stop sheet is no push: the count stays
      q.answer(walk.id, Answer.yes, via: AnswerVia.stopSheet);
      expect(q.store.read().batches, hasLength(2));
    });

    test('backing off is written down once with its reason, and a pause arms nothing', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      q.store.saveSettings(const ConfirmSettings(quietFromSleep: false));
      for (var d = 15; d < 20; d++) {
        lineOf(q, {'at': '2026-11-${d}T12:00:00+03:00', 'via': 'notification', 'estimates': ['old$d']});
      }
      q.register([walk]);
      now = at(21, 30);
      await q.plan();
      await q.plan();
      final steps = [for (final e in q.store.read().events) if (e.event == 'backoff') (e.step, e.reason, e.until)];
      expect(steps, [('pause', '0 % of 5 batches answered in 7 days', at(21, 30).add(const Duration(days: 7)))]);
      expect(phone.armed, isEmpty, reason: 'no pushes for 7 days; by then the walk is too old to ask');
      expect([for (final c in q.pending()) c.id], [walk.id], reason: 'it waits in the app');
      expect(quickChecksWaiting.value, 1);
      // the pause is over: one a day, written down too
      now = at(21, 31).add(const Duration(days: 7));
      final later = est(Labels.walking, now.subtract(const Duration(hours: 2)), 30);
      q.register([later]);
      await q.plan();
      expect([for (final e in q.store.read().events) e.step], ['pause', 'one_a_day']);
      expect(phone.armed.single.$2, [later.id]);
    });

    test('after 10 fast all-Yes batches the next batch is blind cards, and says so in the log', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      q.store.saveSettings(const ConfirmSettings(quietFromSleep: false, quietStartMin: 23 * 60));
      for (var i = 0; i < 10; i++) {
        final a = est(Labels.walking, at(-240 + i * 20), 30, recording: 'a$i'), b = est(Labels.nap, at(-240 + i * 20 + 1), 30, recording: 'b$i');
        q.store.register([a, b]);
        final when = a.end.add(const Duration(hours: 2));
        lineOf(q, {'at': isoLocal(when), 'via': 'notification', 'estimates': [a.id, b.id]});
        q.store.answer(a.id, Answer.yes, at: when.add(const Duration(minutes: 3)), shown: when, via: AnswerVia.notification);
        q.store.answer(b.id, Answer.yes, at: when.add(const Duration(minutes: 3, seconds: 1)), shown: when.add(const Duration(minutes: 3, milliseconds: 200)), via: AnswerVia.notification);
      }
      q.register([walk]);
      now = at(21, 30);
      await q.plan();
      expect(phone.cards.single.single['card'], 'blind');
      expect(phone.armed.single.$3, ['What were you doing 19:08-21:14?']);
      expect(q.pending().single.kind, CardKind.blind, reason: 'blind on the card too');
      expect([for (final e in q.store.read().events) e.step], ['blind_batch']);
      now = at(21, 40);
      await q.plan();
      expect(q.store.read().pushes.last.blind, [walk.id]);
    });

    test('the other app\'s say comes last and can only make a push wait (the seam for the link to utof_tracker)', () async {
      final phone = FakePhone();
      final q = make(phone: phone);
      q.store.saveSettings(const ConfirmSettings(quietFromSleep: false, quietStartMin: 23 * 60));
      q.register([walk]);
      now = at(21, 30);
      ConfirmQuestions.otherApp = (t) => t.isBefore(at(21, 47)) ? at(21, 47) : null;
      addTearDown(() => ConfirmQuestions.otherApp = null);
      await q.plan();
      expect(phone.armed.single.$1, at(21, 47));
    });
  });

  group('the stop sheet', () {
    test('gets one recording\'s questions inside its times, and settles what a chip already said', () {
      final q = make();
      final sleep = est(Labels.asleep, at(12), 40, recording: 'rec-a');
      final nap = est(Labels.nap, at(16), 30, recording: 'rec-a');
      final walk = est(Labels.walking, at(17), 40, recording: 'rec-a');
      final other = est(Labels.walking, at(17), 40, recording: 'rec-b');
      q.register([sleep, nap, walk, other]);
      expect([for (final x in q.pendingFor('rec-a', at(11), at(18))) x.id], [sleep.id, nap.id, walk.id]);
      expect([for (final x in q.pendingFor('rec-a', at(15), at(18), max: 1)) x.id], hasLength(1));
      // "Awake the whole time": every sleep estimate of the recording is a No; "Walked 17:00-17:40": that walk is a Yes
      expect(q.settle('rec-a', Labels.asleep, at(11), at(18), answer: Answer.no), 2);
      expect(q.settle('rec-a', Labels.walking, at(17), at(17, 40)), 1);
      expect(q.settle('rec-a', Labels.walking, at(17), at(17, 40)), 0, reason: 'already answered');
      expect(q.pendingFor('rec-a', at(11), at(18)), isEmpty);
      final s = q.store.read();
      expect((s.answers[sleep.id]!.answer, s.answers[nap.id]!.answer, s.answers[walk.id]!.answer), (Answer.no, Answer.no, Answer.yes));
      expect(s.answered(other.id), isFalse);
      final rows = q.store.labelsFile.readAsLinesSync().skip(1).toList();
      expect(rows, hasLength(3));
      expect(rows.every((r) => r.contains('\towner_stop_sheet\t')), isTrue);
      // a chip over other times says nothing about an estimate mostly outside them
      final late = est(Labels.walking, at(19), 60, recording: 'rec-a');
      q.register([late]);
      expect(q.settle('rec-a', Labels.walking, at(17), at(19, 10)), 0);
    });
  });

  group('the detectors\' estimates', () {
    SleepReport report(List<Map<String, Object?>> periods, {String? wearer}) => SleepReport({
      'version': 2,
      'night_of': '2026-11-20',
      'built': '2026-11-20T18:00:00+03:00',
      'data_start': '2026-11-20T15:55:27+03:00',
      'data_end': '2026-11-20T17:55:00+03:00',
      'scored': true,
      'model': 'anysleep-test',
      'inputs': [
        {'file': '2026-11-20-155527-part2.f32', 'bytes': 1},
        {'file': '2026-11-20-155527.f32', 'bytes': 1},
      ],
      'total': {'asleep_min': 0, 'recorded_min': 0, 'missing_min': 0, 'stray_sleep_min': 0},
      'periods': periods,
      if (wearer != null) 'wearer': {'answer': wearer},
    });
    Map<String, Object?> period(String start, String end, double asleep, double awake) => {
      'start': start,
      'end': end,
      'asleep_min': asleep,
      'light_min': asleep,
      'deep_min': 0,
      'dream_min': 0,
      'awake_min': awake,
      'wake_ups': 0,
      'missing_min': 0,
    };

    test('a sleep report: a nap by day, a night with wake-ups is "likely", a few minutes are not asked about', () {
      final got = sleepEstimates(
        report([
          period('2026-11-20T15:59:00+03:00', '2026-11-20T17:49:00+03:00', 99, 11),
          period('2026-11-20T18:10:00+03:00', '2026-11-20T18:20:00+03:00', 6, 4),
          period('2026-11-20T23:41:00+03:00', '2026-11-21T07:05:00+03:00', 400, 44),
          period('2026-11-21T22:00:00+03:00', '2026-11-21T22:30:00+03:00', 30, 0),
        ]),
      );
      expect([for (final e in got) (e.label, e.yesMeans)], [
        (Labels.nap, YesMeans.certain),
        (Labels.asleep, YesMeans.likely),
        (Labels.asleep, YesMeans.certain),
      ]);
      expect(got.first.recording, '2026-11-20-155527');
      expect((got.first.detector, got.first.version), ('sleep-periods', 'anysleep-test'));
      expect(got.first.confidence, closeTo(0.9, 1e-9));
      expect(questionOf(got.first, DateTime(2026, 11, 20, 18)), '15:59-17:49. The headband thinks you napped. Did you?');
    });

    test('a night someone else wore asks nothing', () {
      final p = [period('2026-11-20T23:41:00+03:00', '2026-11-21T07:05:00+03:00', 400, 44)];
      expect(sleepEstimates(report(p, wearer: 'someone else')), isEmpty);
      expect(sleepEstimates(report(p, wearer: 'me')), hasLength(1));
    });

    test('a walking pass: one estimate per walk of five minutes or more, as sure as its least sure stretch', () {
      Map<String, Object?> stretch(String a, String b, String c) => {'kind': 'walking', 'start': a, 'end': b, 'steps': 100, 'pace': 110.0, 'confidence': c};
      final w = WalkResult.fromJson({
        'format': walkFormat,
        'version': walkFileVersion,
        'detector': 'walk-v2',
        'recording': '2026-11-20-175012',
        'start': '2026-11-20T17:50:12+03:00',
        'channels': ['T3'],
        'sample_rate': 250,
        'windows': 10,
        'walking_min': 86,
        'headband_steps': 8000,
        'confidence': 'sure',
        'walks': [
          {
            'start': '2026-11-20T19:08:00+03:00',
            'end': '2026-11-20T21:14:00+03:00',
            'walking_min': 81.2,
            'stopped_min': 44,
            'steps': 8373,
            'pace': 114.0,
            'stretches': [
              stretch('2026-11-20T19:08:00+03:00', '2026-11-20T20:00:00+03:00', 'sure'),
              stretch('2026-11-20T20:05:00+03:00', '2026-11-20T21:14:00+03:00', 'likely'),
            ],
          },
          {'start': '2026-11-20T22:00:00+03:00', 'end': '2026-11-20T22:03:00+03:00', 'walking_min': 3.0, 'stopped_min': 0, 'steps': 300, 'stretches': <Object>[]},
        ],
        'minutes': <Object>[],
      });
      expect(w, isNotNull);
      final got = walkEstimates(w!);
      expect(got, hasLength(1));
      expect((got.single.label, got.single.recording, got.single.confidence, got.single.version), (Labels.walking, '2026-11-20-175012', 0.7, 'walk-v2'));
      expect(questionOf(got.single, DateTime(2026, 11, 20, 22)), '19:08-21:14. The headband thinks you walked. Did you?');
    });

    test('gathering reads the reports and walk files on disk, once', () {
      final nights = Directory('${files.path}/nights')..createSync();
      File('${nights.path}/2026-11-20.report.json').writeAsStringSync(
        jsonEncode(report([period('2026-11-20T15:59:00+03:00', '2026-11-20T17:49:00+03:00', 99, 11)]).json),
      );
      final q = make();
      expect(q.gather(), 1);
      expect(q.gather(), 0);
      expect(q.pending().single.text, '15:59-17:49. The headband thinks you napped. Did you?');
    });
  });

  group('the hour of the day (the emulator checks of 2026-11-26, DECISIONS 1090 and 1091)', () {
    // A stretch whose card shows its guess: the start moves back by whole minutes until the id does not draw blind.
    Estimate shown(Label label, DateTime start, DateTime end) {
      var s = start;
      while (blindByDraw(est(label, s, end.difference(s).inMinutes).id)) {
        s = s.subtract(const Duration(minutes: 1));
      }
      return est(label, s, end.difference(s).inMinutes, confidence: 0.85);
    }

    String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    test('at 01:45 every card of the night so far has its times to the minute and may have them corrected', () {
      final d = DateTime(2026, 11, 26);
      final sleep = shown(Labels.asleep, DateTime(2026, 11, 25, 22, 25), d.add(const Duration(minutes: 15)));
      final walk = shown(Labels.walking, d.add(const Duration(minutes: 25)), d.add(const Duration(hours: 1)));
      final late = shown(Labels.walking, d.add(const Duration(hours: 1, minutes: 9)), d.add(const Duration(hours: 1, minutes: 30)));
      now = d.add(const Duration(hours: 1, minutes: 45));
      final q = make()..register([sleep, walk, late]);
      final got = q.pending();
      expect([for (final x in got) x.text], [
        '${hm(sleep.start)}-00:15. The headband thinks you slept. Did you?',
        '${hm(walk.start)}-01:00. The headband thinks you walked. Did you?',
        '${hm(late.start)}-01:30. The headband thinks you walked. Did you?',
      ]);
      expect([for (final x in got) x.exactTimes], [true, true, true]);
    });

    test('at 04:28 no question is held back and the three that ended before 04:00 still have their minutes and the link', () {
      final d = DateTime(2026, 11, 26);
      final sleep = shown(Labels.asleep, d.add(const Duration(hours: 1, minutes: 3)), d.add(const Duration(hours: 2, minutes: 55)));
      final walk = shown(Labels.walking, d.add(const Duration(hours: 3, minutes: 5)), d.add(const Duration(hours: 3, minutes: 37)));
      final late = shown(Labels.walking, d.add(const Duration(hours: 3, minutes: 46)), d.add(const Duration(hours: 4, minutes: 7)));
      now = d.add(const Duration(hours: 4, minutes: 28));
      final q = make()..register([sleep, walk, late]);
      final got = q.pending();
      expect(got, hasLength(3), reason: 'all three are asked');
      expect(got[0].text, '${hm(sleep.start)}-02:55. The headband thinks you slept. Did you?', reason: 'it ended 93 minutes ago: under 4 hours');
      expect(got[1].text, '${hm(walk.start)}-03:37. The headband thinks you walked. Did you?', reason: 'it ended 51 minutes ago');
      expect(got[2].text, '${hm(late.start)}-04:07. The headband thinks you walked. Did you?');
      expect([for (final x in got) x.exactTimes], [true, true, true], reason: '"Yes, but the times are off" on every one (DECISIONS 1091)');
      // the same three a moment before 04:00: all to the minute
      now = d.add(const Duration(hours: 3, minutes: 59));
      final before = make().pending();
      expect([for (final x in before) x.exactTimes], [true, true], reason: 'the third has not ended yet');
      expect(before.first.text, '${hm(sleep.start)}-02:55. The headband thinks you slept. Did you?');
    });

    test('4 hours after a stretch that ended before 04:00, its times go to the half hour and the link goes (DECISIONS 1091)', () {
      final d = DateTime(2026, 11, 26);
      final walk = shown(Labels.walking, d.add(const Duration(hours: 3, minutes: 20)), d.add(const Duration(hours: 3, minutes: 50)));
      final q = make()..register([walk]);
      for (final (since, exact) in [
        (const Duration(hours: 3, minutes: 59), true),
        (const Duration(hours: 4, minutes: 10), true),
        (const Duration(hours: 7, minutes: 49), true),
        (const Duration(hours: 7, minutes: 51), false),
      ]) {
        now = d.add(since);
        final got = q.pending();
        expect(got, hasLength(1), reason: hm(now));
        expect(got.single.exactTimes, exact, reason: 'at ${hm(now)}');
        expect(got.single.text, exact ? '${hm(walk.start)}-03:50. The headband thinks you walked. Did you?' : 'About 03:30 to 04:00. The headband thinks you walked. Did you?', reason: 'at ${hm(now)}');
      }
    });

    test('a night split by an hour awake: at 06:30 the first piece has its times, at 08:30 it has the half hour (the second keeps them)', () {
      final d = DateTime(2026, 11, 26);
      final first = shown(Labels.asleep, d.subtract(const Duration(hours: 1)), d.add(const Duration(hours: 3, minutes: 10)));
      final second = shown(Labels.asleep, d.add(const Duration(hours: 4, minutes: 20)), d.add(const Duration(hours: 8)));
      final q = make()..register([first, second]);
      now = d.add(const Duration(hours: 6, minutes: 30));
      var got = q.pending();
      expect([for (final x in got) x.exactTimes], [true], reason: 'the second piece is still going: no question yet');
      expect(got.single.text, '${hm(first.start)}-03:10. The headband thinks you slept. Did you?');
      now = d.add(const Duration(hours: 8, minutes: 30));
      got = q.pending();
      expect([for (final x in got) x.exactTimes], [false, true], reason: 'the first ended 5 h 20 min ago, the second 30 minutes ago');
      expect(got.first.text, 'About 23:00 to 03:00. The headband thinks you slept. Did you?');
      expect(got.last.text, '${hm(second.start)}-08:00. The headband thinks you slept. Did you?');
    });

    test('a night that ended at 07:00 keeps its minutes and the link all day', () {
      final d = DateTime(2026, 11, 26);
      final night = shown(Labels.asleep, d.subtract(const Duration(hours: 1)), d.add(const Duration(hours: 7)));
      final q = make()..register([night]);
      for (final since in [const Duration(hours: 7, minutes: 30), const Duration(hours: 13), const Duration(hours: 23, minutes: 59)]) {
        now = d.add(since);
        final got = q.pending();
        expect(got.single.exactTimes, isTrue, reason: 'at ${hm(now)}');
        expect(got.single.text, '${hm(night.start)}-07:00. The headband thinks you slept. Did you?', reason: 'at ${hm(now)}');
      }
    });
  });

  test('settings: defaults, kept whole, and anything out of range falls back', () {
    final q = make();
    expect((q.settings.on, q.settings.perBatch, q.settings.perDay, q.settings.quietStartMin, q.settings.quietEndMin), (true, 4, 2, 1320, 480));
    q.store.saveSettings(const ConfirmSettings(on: false, perBatch: 3, perDay: 1, quietStartMin: 60, quietEndMin: 120));
    expect((q.settings.on, q.settings.perBatch, q.settings.perDay, q.settings.quietStartMin, q.settings.quietEndMin), (false, 3, 1, 60, 120));
    q.store.settingsFile.writeAsStringSync('{"per_batch": 50, "per_day": 0}');
    expect((q.settings.on, q.settings.perBatch, q.settings.perDay), (true, 4, 2));
    q.store.settingsFile.writeAsStringSync('not json');
    expect(q.settings.perBatch, 4);
  });
}
