// The laptop's work word (DECISIONS 603, 1107, 1113): kept as the latest word, and every word is one `laptop` line of
// the auto log, so the laptop's tables can say "the laptop said working" for any minute.
import 'dart:io';

import 'package:eeg_tracker/auto/laptop.dart';
import 'package:eeg_tracker/auto/log.dart';
import 'package:eeg_tracker/auto/rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('laptop-word'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a word is kept, logged, and says whether it asks for a check', () {
    final t = DateTime(2026, 11, 26, 10, 0);
    expect(keepLaptopWord(dir, LaptopWork(working: true, at: t)), isTrue);
    expect(LaptopStore(dir).load()!.working, isTrue);
    // a word that only changes the meeting asks for no check, but is logged
    expect(keepLaptopWord(dir, LaptopWork(working: true, at: t.add(const Duration(minutes: 5)), meeting: true)), isFalse);
    expect(keepLaptopWord(dir, LaptopWork(working: false, at: t.add(const Duration(minutes: 50)))), isFalse);
    final lines = [for (final e in AutoLog(dir).events()) if (e['event'] == 'laptop') e];
    expect([for (final e in lines) e['working']], [true, true, false]);
    expect([for (final e in lines) e['meeting']], [null, true, null]);
    expect(DateTime.parse('${lines.first['at']}').toLocal(), t);
    expect(AutoLog(dir).stats().values.every((s) => s.asked == 0 && s.automatic == 0), isTrue, reason: 'not a question');
  });
}
