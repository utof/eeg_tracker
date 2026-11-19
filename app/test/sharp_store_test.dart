// The sharp-hours files (DECISIONS row 288): settings, the ratings and reaction tests as JSON lines, the Android
// side's prompt log; written whole or appended a line at a time, read back strictly (a broken line is skipped,
// never guessed at).
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/export/store.dart' show storedFiles;
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sharp/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late SharpStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sharp');
    store = SharpStore(sharpDirFor('${tmp.path}/files/recordings'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the folder sits beside the recordings: files/sharp-hours', () {
    expect(store.dir.path, '${tmp.path}/files/sharp-hours');
  });

  test('no settings yet: null; saved settings come back; no temporary file is left', () {
    expect(store.settings(), isNull);
    final s = SharpSettings(on: true, perDay: 4, fromMin: 600, untilMin: 1320, seed: 'abc', firstOn: DateTime(2026, 11, 20, 9));
    store.saveSettings(s);
    expect(store.settings()!.toJson(), s.toJson());
    expect(store.dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')), isEmpty);
  });

  test('a rating is one line with the local time and its offset, the prompt it answers, and the scale', () {
    final r = SharpRating(
      at: DateTime(2026, 11, 20, 14, 5, 12),
      sharp: 4,
      prompt: DateTime(2026, 11, 20, 14, 2),
      shown: DateTime(2026, 11, 20, 14, 3, 40),
      testAsked: true,
    );
    store.addRating(r);
    store.addRating(SharpRating(at: DateTime(2026, 11, 20, 16), sharp: 2));
    final lines = File('${store.dir.path}/ratings.jsonl').readAsLinesSync();
    expect(lines, hasLength(2));
    final j = jsonDecode(lines.first) as Map<String, Object?>;
    expect(j['version'], 1);
    expect(j['sharp'], 4);
    expect(j['scale'], '1-5');
    expect(j['at'], matches(RegExp(r'^2026-11-20T14:05:12[+-]\d\d:\d\d$')));
    expect(j['prompt'], matches(RegExp(r'^2026-11-20T14:02:00[+-]\d\d:\d\d$')));
    expect(j['test_asked'], isTrue);
    final back = store.ratings();
    expect(back, hasLength(2));
    expect(back.first.at, DateTime(2026, 11, 20, 14, 5, 12));
    expect(back.first.prompted, isTrue);
    expect(back.last.prompt, isNull);
    expect(back.last.prompted, isFalse, reason: 'rated from the page, not a question');
  });

  test('a broken or out-of-range line is skipped, the rest are read', () {
    store.addRating(SharpRating(at: DateTime(2026, 11, 20, 14), sharp: 3));
    final f = File('${store.dir.path}/ratings.jsonl');
    f.writeAsStringSync(
      '{"version":1,"at":"2026-11-20T15:00:00+03:00","sharp":6,"scale":"1-5"}\n'
      '{"version":1,"at":"2026-11-20T15:00:00+03:00","sharp":"4","scale":"1-5"}\n'
      '{"version":1,"at":"later","sharp":4,"scale":"1-5"}\n'
      '{"version":1,"at":"2026-11-20T15:00:00+03:00","sharp":4,"scale":"1-5"\n'
      'not json\n'
      '{"version":1,"at":"2026-11-20T16:00:00+03:00","sharp":5,"scale":"1-5"}\n',
      mode: FileMode.append,
    );
    expect([for (final r in store.ratings()) r.sharp], [3, 5]);
  });

  test('a reaction test keeps the median, the taps, false starts and lapses, linked to its rating', () {
    final t = SharpReaction(
      at: DateTime(2026, 11, 20, 14, 7),
      ratingAt: DateTime(2026, 11, 20, 14, 5, 12),
      timesMs: const [301, 288, 345, 512, 299, 310],
      falseStarts: 1,
    );
    expect(t.medianMs, 306, reason: '(301 + 310) / 2 = 305.5, rounded as the test itself rounds');
    expect(t.lapses, 1);
    store.addReaction(t);
    store.addReaction(SharpReaction(at: DateTime(2026, 11, 20, 18), ratingAt: DateTime(2026, 11, 20, 17, 59), timesMs: const [300, 310]));
    final back = store.reactions();
    expect(back, hasLength(2));
    expect(back.first.medianMs, 306);
    expect(back.first.ratingAt, DateTime(2026, 11, 20, 14, 5, 12));
    expect(back.last.medianMs, isNull, reason: 'fewer than 5 taps: no median');
    final j = jsonDecode(File('${store.dir.path}/reactions.jsonl').readAsLinesSync().first) as Map<String, Object?>;
    expect(j['median_ms'], 306);
    expect(j['times_ms'], [301, 288, 345, 512, 299, 310]);
    expect(j['length_s'], 60);
  });

  test('the prompt log the Android side writes is read; unknown events and broken lines are skipped', () {
    store.dir.createSync(recursive: true);
    File('${store.dir.path}/prompts.jsonl').writeAsStringSync(
      '{"planned":"2026-11-20T10:41:00+03:00","at":"2026-11-20T10:44:10+03:00","event":"shown","test":true}\n'
      '{"planned":"2026-11-20T13:12:00+03:00","at":"2026-11-20T13:12:30+03:00","event":"skipped","reason":"night recording"}\n'
      '{"planned":"2026-11-20T15:00:00+03:00","at":"2026-11-20T16:30:00+03:00","event":"late"}\n'
      '{"planned":"2026-11-20T15:00:00+03:00","at":"2026-11-20T16:30:00+03:00","event":"exploded"}\n'
      '{"planned":"2026-11-20T18:0',
    );
    final e = store.promptEvents();
    expect([for (final x in e) x.event], [PromptEventKind.shown, PromptEventKind.skipped, PromptEventKind.late]);
    expect(e.first.test, isTrue);
    expect(e[1].reason, 'night recording');
    expect(e.first.planned, DateTime.parse('2026-11-20T10:41:00+03:00').toLocal());
  });

  test('each change of the switch, the window or the count is logged', () {
    store.logEvent(DateTime(2026, 11, 20, 9), 'on', {'per_day': 4});
    store.logEvent(DateTime(2026, 11, 21, 9), 'off');
    final lines = File('${store.dir.path}/events.jsonl').readAsLinesSync();
    expect(lines, hasLength(2));
    expect(jsonDecode(lines.first), containsPair('event', 'on'));
  });

  test('Export data takes the whole folder, the Android side\'s log included; a half-written file stays', () {
    final files = Directory('${tmp.path}/files');
    store.saveSettings(const SharpSettings(on: true, perDay: 4, fromMin: 600, untilMin: 1320, seed: 'abc'));
    store.addRating(SharpRating(at: DateTime(2026, 11, 20, 14), sharp: 3));
    store.addReaction(SharpReaction(at: DateTime(2026, 11, 20, 14, 2), ratingAt: DateTime(2026, 11, 20, 14), timesMs: const [300]));
    store.logEvent(DateTime(2026, 11, 20, 9), 'on');
    File('${store.dir.path}/prompts.jsonl').writeAsStringSync('{}\n');
    File('${store.dir.path}/settings.json.tmp').writeAsStringSync('{');
    expect([for (final f in storedFiles(files)) f.path], [
      'sharp-hours/events.jsonl',
      'sharp-hours/prompts.jsonl',
      'sharp-hours/ratings.jsonl',
      'sharp-hours/reactions.jsonl',
      'sharp-hours/settings.json',
    ]);
  });

  test('delete everything removes the folder; reading afterwards is empty', () {
    store.addRating(SharpRating(at: DateTime(2026, 11, 20, 14), sharp: 3));
    store.deleteAll();
    expect(store.dir.existsSync(), isFalse);
    expect(store.ratings(), isEmpty);
    expect(store.reactions(), isEmpty);
    expect(store.promptEvents(), isEmpty);
  });
}
