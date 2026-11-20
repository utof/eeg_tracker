// "Try these" (DECISIONS 340): the cards against app/README.md's owner steps (a new feature's owner step without a
// card fails here), the progress file and its log, what the app ticks by itself on a fake app folder, and that the
// notes leave the phone with Export data.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/export/store.dart' show isExported, storedFiles;
import 'package:eeg_tracker/try_these/cards.dart';
import 'package:eeg_tracker/try_these/progress.dart';
import 'package:eeg_tracker/try_these/seen.dart';
import 'package:flutter_test/flutter_test.dart';

/// `Sleep report (anything)` -> `Sleep report`: the README's headings carry their durations and notes in brackets.
String _bare(String heading) => heading.replaceFirst(RegExp(r'\s*\([^()]*\)\s*$'), '').trim();

/// Every `## Section` of the README with the titles of its `### Owner step: ...` headings.
Map<String, List<String>> readmeOwnerSteps(String readme) {
  final out = <String, List<String>>{};
  String? section;
  for (final line in const LineSplitter().convert(readme)) {
    if (line.startsWith('## ')) {
      section = _bare(line.substring(3));
      out.putIfAbsent(section, () => []);
    } else if (line.startsWith('### Owner step:') && section != null) {
      out[section]!.add(_bare(line.substring('### Owner step:'.length)));
    }
  }
  return out;
}

void main() {
  final readme = readmeOwnerSteps(File('README.md').readAsStringSync());

  group('the cards and app/README.md', () {
    test('the README parse finds the owner steps it should (a check on the check)', () {
      expect(readme['Sleep report'], ['how long does the phone take?', 'the night extras']);
      expect(readme['Dream catcher'], ['the first try', 'answers as words']);
      expect(readme['Self-experiments'], ['start a first experiment']);
      expect(readme['Sound for states'], ['the first sound sessions', 'a fair test of two sounds']);
      expect(readme['Meditate'], ['the silent minutes and the Bluetooth note', 'eight meditations, then the first learning verdict']);
      expect(readme.values.expand((s) => s).length, greaterThanOrEqualTo(17));
    });

    test('every owner step in the README has a card', () {
      final covered = {
        for (final c in tryCards)
          for (final r in c.readme) '${r.section} / ${r.step}',
      };
      final missing = [
        for (final e in readme.entries)
          for (final s in e.value)
            if (!covered.contains('${e.key} / $s')) '${e.key} / Owner step: $s',
      ];
      expect(missing, isEmpty, reason: 'add a card to lib/try_these/cards.dart for each of these');
    });

    test('every card points at a README section (and owner step) that exists', () {
      for (final c in tryCards) {
        expect(c.readme, isNotEmpty, reason: c.id);
        for (final r in c.readme) {
          expect(readme.containsKey(r.section), isTrue, reason: '${c.id}: no section "${r.section}"');
          if (r.step != null) expect(readme[r.section], contains(r.step), reason: '${c.id}: no owner step "${r.step}"');
        }
      }
    });

    test('short cards: unique ids, one sentence, 3 to 5 steps, something to tell, how long', () {
      expect({for (final c in tryCards) c.id}, hasLength(tryCards.length));
      for (final c in tryCards) {
        expect(c.steps.length, inInclusiveRange(3, 5), reason: c.id);
        expect(c.tell, isNotEmpty, reason: c.id);
        expect(c.takes, isNotEmpty, reason: c.id);
        expect(c.what.split(RegExp(r'[.!?] ')).length, lessThanOrEqualTo(2), reason: '${c.id}: keep "what" short');
        for (final s in [c.title, c.what, ...c.steps, ...c.tell]) {
          expect(s.trim(), s, reason: c.id);
          expect(s, isNot(contains('  ')), reason: c.id);
        }
      }
    });

    test('the order: the first night and morning, then sessions, then weeks-long tries, the probe, the board last', () {
      final ids = [for (final c in tryCards) c.id];
      expect(ids.take(5), ['night', 'sleep-time', 'sleep-extras', 'check-in', 'export']);
      expect(ids.skip(ids.length - 2), ['own-ble', 'diy-board']);
      expect(tryCards.last.group, TryGroup.board);
      final groups = [for (final c in tryCards) c.group.index];
      expect(groups, orderedEquals([...groups]..sort()), reason: 'cards stay in their group order');
      expect(tryCards.firstWhere((c) => c.id == 'meditation').group, TryGroup.sessions);
      expect(tryCards.firstWhere((c) => c.id == 'experiment').group, TryGroup.weeks);
    });

    test('the assistant\'s proposals are marked as such, the owner\'s wishes are not', () {
      expect(
        {
          for (final c in tryCards)
            if (c.proposal) c.id,
        },
        {'sharp', 'study', 'unusual', 'was-this-you', 'own-ble', 'memory-cues'},
      );
    });

    test('the weak-evidence marker follows the grade in the card\'s own evidence note', () {
      String grade(String slug) {
        final text = File('../docs/evidence/$slug.md').readAsStringSync();
        final m = RegExp(r'^## Evidence for this \w+: (\w+)', multiLine: true).firstMatch(text);
        expect(m, isNotNull, reason: '$slug has no grade line');
        return m!.group(1)!;
      }

      for (final c in tryCards) {
        if (c.evidence == null) {
          expect(c.weakEvidence, isFalse, reason: '${c.id} marks weak evidence without a note');
        } else {
          expect(c.weakEvidence, grade(c.evidence!) == 'weak', reason: '${c.id} against ${c.evidence}');
        }
      }
      // the lucid cues and the other weak-graded features the cards open
      expect(
        {
          for (final c in tryCards)
            if (c.weakEvidence) c.id,
        },
        {
          'smart-alarm',
          'meditation',
          'meditation-learning',
          'sound',
          'alpha-theta',
          'lucid',
          'was-this-you',
          'sound-test',
          'memory-cues',
          'walking',
        },
      );
      expect(tryCards.firstWhere((c) => c.id == 'sharp').weakEvidence, isFalse);
    });

    test('the cards the app ticks by itself are exactly those it has a check for', () {
      expect({
        for (final c in tryCards)
          if (c.auto) c.id,
      }, seenChecks.keys.toSet());
    });
  });

  group('progress: files/try-these/', () {
    late Directory tmp;
    late TryStore store;
    final t = DateTime(2026, 11, 20, 8, 15);
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('try_these');
      store = TryStore(Directory('${tmp.path}/files/try-these'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('nothing yet: every card open, nothing written', () {
      expect(store.load(), isEmpty);
      expect(store.dir.existsSync(), isFalse);
    });

    test('Done with a note: the progress file has the card\'s state, title and note; the log has one line', () {
      store.mark('check-in', TryState.done, at: t, note: 'tones too loud; O1 said noisy');
      final p = store.load()['check-in']!;
      expect(p.state, TryState.done);
      expect(p.at, t);
      expect(p.byApp, isFalse);
      expect(p.note, 'tones too loud; O1 said noisy');
      final json = jsonDecode(File('${store.dir.path}/progress.json').readAsStringSync()) as Map;
      expect(json['version'], 1);
      expect((json['cards'] as Map)['check-in'], containsPair('title', 'Morning check-in and Trends'));
      expect((json['cards'] as Map)['check-in'], containsPair('state', 'done'));
      expect((json['cards'] as Map)['check-in'], containsPair('by', 'owner'));
      final lines = File('${store.dir.path}/events.jsonl').readAsLinesSync();
      expect(lines, hasLength(1));
      expect(
        jsonDecode(lines.single),
        allOf(
          containsPair('card', 'check-in'),
          containsPair('event', 'done'),
          containsPair('note', 'tones too loud; O1 said noisy'),
        ),
      );
    });

    test('a note alone is kept without a state change and without a log line; Skip and reopening keep it', () {
      store.setNote('nap', 'woke me at 30 min, groggy', at: t);
      expect(store.load()['nap']!.state, TryState.open);
      expect(store.load()['nap']!.note, 'woke me at 30 min, groggy');
      expect(File('${store.dir.path}/events.jsonl').existsSync(), isFalse);
      store.mark('nap', TryState.skipped, at: t);
      expect(store.load()['nap']!.state, TryState.skipped);
      store.mark('nap', TryState.open, at: t);
      expect(store.load()['nap']!.note, 'woke me at 30 min, groggy');
      final events = [
        for (final l in File('${store.dir.path}/events.jsonl').readAsLinesSync()) (jsonDecode(l) as Map)['event'],
      ];
      expect(events, ['skipped', 'reopened']);
    });

    test('what the app saw ticks only untouched cards, once', () {
      store.mark('nap', TryState.open, at: t); // reopened by the owner: the app leaves it alone
      final ticked = store.applySeen({'check-in': 'Check-in saved Thu 20 Nov.', 'nap': 'A nap saved.'}, at: t);
      expect(ticked, ['check-in']);
      final p = store.load();
      expect(p['check-in']!.state, TryState.done);
      expect(p['check-in']!.byApp, isTrue);
      expect(p['check-in']!.seen, 'Check-in saved Thu 20 Nov.');
      expect(p['nap']!.state, TryState.open);
      expect(store.applySeen({'check-in': 'again'}, at: t), isEmpty);
      final events = [
        for (final l in File('${store.dir.path}/events.jsonl').readAsLinesSync()) (jsonDecode(l) as Map)['event'],
      ];
      expect(events, ['reopened', 'seen by the app']);
    });

    test('a damaged progress file reads as nothing done (and is replaced on the next change)', () {
      store.dir.createSync(recursive: true);
      File('${store.dir.path}/progress.json').writeAsStringSync('{"cards": [');
      expect(store.load(), isEmpty);
      store.mark('night', TryState.done, at: t);
      expect(store.load().keys, ['night']);
    });

    test('the notes leave the phone with Export data', () {
      store.mark('export', TryState.done, at: t, note: 'took 4 minutes');
      expect(isExported('try-these/progress.json'), isTrue);
      expect(isExported('try-these/events.jsonl'), isTrue);
      final paths = [for (final f in storedFiles(Directory('${tmp.path}/files'))) f.path];
      expect(paths, ['try-these/events.jsonl', 'try-these/progress.json']);
    });
  });

  group('the page: tally, next stop, groups', () {
    test('nothing done: the first card is next, every group in order', () {
      final page = buildTryPage(tryCards, const {});
      expect(page.tried, 0);
      expect(page.skipped, 0);
      expect(page.total, tryCards.length);
      expect(page.next?.id, 'night');
      expect([for (final g in page.groups) g.group], TryGroup.values);
      expect(page.finished, isEmpty);
      expect(page.tally, '0 of ${tryCards.length} tried');
    });

    test('done and skipped fold away; the next is the first open card; a group with nothing open goes', () {
      final t = DateTime(2026, 11, 20);
      final page = buildTryPage(tryCards, {
        'night': CardProgress(state: TryState.done, at: t),
        'sleep-time': CardProgress(state: TryState.done, at: t, byApp: true, seen: 'Scored.'),
        'sleep-extras': CardProgress(state: TryState.skipped, at: t),
        'check-in': CardProgress(note: 'a note, still open'),
        'own-ble': CardProgress(state: TryState.done, at: t),
      });
      expect(page.tried, 3);
      expect(page.skipped, 1);
      expect(page.next?.id, 'check-in');
      expect(page.tally, '3 of ${tryCards.length} tried');
      expect([for (final c in page.finished) c.id], ['night', 'sleep-time', 'sleep-extras', 'own-ble']);
      expect(page.groups.map((g) => g.group), isNot(contains(TryGroup.charged)));
      expect(page.groups.first.cards.first.id, 'check-in');
      expect(page.mark('sleep-extras'), LedgerMark.skipped);
      expect(page.mark('night'), LedgerMark.done);
      expect(page.mark('check-in'), LedgerMark.next);
      expect(page.mark('export'), LedgerMark.open);
    });

    test('all of it done or skipped: no next stop, and the main screen says so', () {
      final page = buildTryPage(tryCards, {for (final c in tryCards) c.id: const CardProgress(state: TryState.done)});
      expect(page.next, isNull);
      expect(page.groups, isEmpty);
      expect(entryLine(page), 'All ${tryCards.length} tried. Your notes go out with Export data.');
    });

    test('the main screen\'s line names the next stop and how long it takes', () {
      final page = buildTryPage(tryCards, {'night': const CardProgress(state: TryState.done)});
      expect(
        entryLine(page),
        '1 of ${tryCards.length} tried. Next: ${page.next!.title}, ${page.next!.takes.toLowerCase()}.',
      );
      expect(
        entryLine(null),
        '${tryCards.length} things in the app to try, one at a time, with what to tell the assistant.',
      );
    });
  });

  group('what the app sees by itself, on a fake app folder', () {
    late Directory tmp, files;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('try_seen');
      files = Directory('${tmp.path}/files')..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void put(String path, String text) => File('${files.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);

    /// A DIY board file set of [minutes] (one 20-byte record a sample, 250 Hz).
    void board(String stem, double minutes) => File('${files.path}/recordings-diy/$stem.f32')
      ..createSync(recursive: true)
      ..writeAsBytesSync(Uint8List((minutes * 60 * 250).round() * 20));

    test('an empty folder: nothing seen', () {
      expect(seenByApp(files, seenChecks.keys.toSet()), isEmpty);
    });

    test('each check on the files its feature writes', () {
      put(
        'nights/2026-11-18.report.json',
        jsonEncode({
          'night_of': '2026-11-18',
          'scored': true,
          'scoring_s': 241,
          'drift_off': {'source': 'night start'},
        }),
      );
      put(
        'nights/2026-11-19.report.json',
        jsonEncode({
          'night_of': '2026-11-19',
          'scored': true,
          'scoring_s': 95,
          'drift_off': {'source': 'button'},
        }),
      );
      put('mornings/2026-11-20-071500.morning.json', '{}');
      put(
        'export/exports.jsonl',
        '${jsonEncode({'exported': '2026-11-20T09:00:00+03:00', 'complete': false})}\n'
            '${jsonEncode({'exported': '2026-11-20T09:05:00+03:00', 'complete': true})}\n',
      );
      put(
        'alarms/rings.jsonl',
        '${jsonEncode({'endMs': 1, 'event': 'set', 'atMs': 1763600000000})}\n'
            '${jsonEncode({'endMs': 1, 'event': 'ring', 'atMs': 1763615520000, 'by': 'smart'})}\n',
      );
      put('meditations/2026-11-20-100000.meditation.json', '{}');
      put('sound-states/2026-11-20-230000.sound.json', jsonEncode({'recording': null}));
      put('sound-states/2026-11-21-000000.sound.json', jsonEncode({'recording': '2026-11-21-000000'}));
      put('naps/2026-11-20-150000.nap.json', '{}');
      put('work-sessions/2026-11-20-093000.work.json', '{}');
      put(
        'lucid/mornings/2026-11-21-070000.json',
        jsonEncode({
          'night': '2026-11-21-070000',
          'answered': '2026-11-21T07:00:00+03:00',
          'answers': {'lucid': 'no'},
        }),
      );
      put('dream-catcher/2026-11-20-160000.dream.json', '{}');
      put('dream-catcher/2026-11-20-160000-r1.text.json', '{}');
      put('alpha-theta/2026-11-20-170000.alphatheta.json', '{}');
      put('experiments/2026-11-20-120000/plan.json', '{}');
      put('sound-states/plans/2026-11-20-120000-asleep/plan.json', '{}');
      put('settings.json', jsonEncode({'replayCheck': true}));
      put(
        'sharp-hours/ratings.jsonl',
        '${jsonEncode({'at': '2026-11-20T11:02:00+03:00', 'sharp': 4})}\n'
            '${jsonEncode({'at': '2026-11-21T15:40:00+03:00', 'sharp': 3})}\n',
      );
      board('2026-11-21-200000', 6); // a board restart: two file sets, 10 minutes together
      board('2026-11-21-200610', 4);
      put(
        'study-review/log.jsonl',
        '${jsonEncode({'version': 1, 'at': '2026-11-20T21:40:00+03:00', 'kind': 'evening', 'studied': true})}\n'
            '${jsonEncode({'version': 1, 'at': '2026-11-21T08:10:00+03:00', 'kind': 'morning', 'recall': 'some'})}\n',
      );
      put(
        'memory_cues/mornings/2026-11-21-003000.json',
        jsonEncode({
          'version': 1,
          'session': '2026-11-20-232000',
          'made': '2026-11-21T08:05:00+03:00',
          'taps': {
            'dog': [0.2, 0.3],
          },
          'heard': 'no',
        }),
      );
      final seen = seenByApp(files, seenChecks.keys.toSet());
      expect(seen.keys.toSet(), seenChecks.keys.toSet());
      expect(seen['night'], 'A night with Lights off tapped, scored: the night of Thu 19 Nov.');
      expect(seen['sleep-time'], 'Scored on this phone in 95 s: the night of Thu 19 Nov.');
      expect(seen['check-in'], 'A check-in saved on Fri 20 Nov.');
      expect(seen['export'], 'Exported in full on Fri 20 Nov.');
      expect(seen['smart-alarm'], startsWith('The smart alarm rang on '));
      expect(seen['sound'], 'A Fall asleep session with the headband on Sat 21 Nov.');
      expect(seen['sharp'], 'Answers on 2 days.');
      expect(seen['study'], 'An evening and a morning answered.');
      expect(seen['replay'], 'Switched on.');
      expect(seen['sound-test'], 'A fair test of two sounds started.');
      expect(seen['lucid'], 'Lucid dream questions answered on Sat 21 Nov.');
      expect(seen['diy-board'], 'The board recorded 10 min on this phone, the newest on Sat 21 Nov.');
      expect(seen['work'], 'A work session saved on Fri 20 Nov.');
      expect(seen['memory-cues'], 'A morning test done on Sat 21 Nov.');
    });

    test(
      'not yet: a night without Lights off, an unfinished export, one day of answers, an evening without a morning, '
      'sound without the headband, a short board test',
      () {
        put('nights/2026-11-18.report.json', jsonEncode({'night_of': '2026-11-18', 'scored': false}));
        put('export/exports.jsonl', '${jsonEncode({'exported': '2026-11-20T09:00:00+03:00', 'complete': false})}\n');
        put(
          'sharp-hours/ratings.jsonl',
          '${jsonEncode({'at': '2026-11-20T11:02:00+03:00', 'sharp': 4})}\n'
              '${jsonEncode({'at': '2026-11-20T15:40:00+03:00', 'sharp': 3})}\nnot json\n',
        );
        put('sound-states/2026-11-20-230000.sound.json', jsonEncode({'recording': null}));
        Directory('${files.path}/sound-states/plans/2026-11-20-120000-asleep').createSync(recursive: true); // no plan saved
        put('settings.json', jsonEncode({'replayCheck': false}));
        put('lucid/mornings/2026-11-20-070000.json', jsonEncode({'night': '2026-11-20-070000'}));
        put('memory_cues/mornings/2026-11-20-003000.json', jsonEncode({'version': 1, 'session': 'x', 'taps': <String, Object?>{}}));
        board('2026-11-21-200000', 9.9); // under the card's 10 minutes
        put('study-review/log.jsonl', '${jsonEncode({'version': 1, 'at': '2026-11-20T21:40:00+03:00', 'kind': 'evening', 'studied': true})}\n');
        expect(seenByApp(files, seenChecks.keys.toSet()), isEmpty);
      },
    );

    test('only the cards asked about are checked', () {
      put('mornings/2026-11-20-071500.morning.json', '{}');
      put('naps/2026-11-20-150000.nap.json', '{}');
      expect(seenByApp(files, {'nap'}).keys, ['nap']);
    });
  });
}
