// The one judge of electrode quality (lib/signal/quality.dart, DECISIONS 850-852): the ohms limits, any number of
// electrodes, "busy" (everything at once: the wearer) against one electrode, words that do not jump, the 2-minute
// warning, and "the contact changed".
import 'dart:math' as math;

import 'package:eeg_tracker/signal/quality.dart';
import 'package:flutter_test/flutter_test.dart';

const calm = SecondClass.calm, loud = SecondClass.loud, wild = SecondClass.wild, off = SecondClass.off;

void main() {
  late DateTime now;
  QualityJudge judge(List<String> names) => QualityJudge(names: names, clock: () => now);

  /// [n] seconds of [second], the clock moving with them.
  void feed(QualityJudge j, List<SecondClass> second, int n) {
    for (var i = 0; i < n; i++) {
      now = now.add(const Duration(seconds: 1));
      j.second(second);
    }
  }

  setUp(() => now = DateTime(2026, 11, 21, 9));

  test('ohms: good up to 300 kΩ, ok up to 1 MΩ, poor above, none without a reading or off the head', () {
    expect(classifyOhms(30e3), Contact.good);
    expect(classifyOhms(300e3), Contact.good);
    expect(classifyOhms(300001), Contact.ok);
    expect(classifyOhms(1e6), Contact.ok);
    expect(classifyOhms(1000001), Contact.poor);
    expect(classifyOhms(2.45e6), Contact.poor);
    expect(classifyOhms(double.infinity), Contact.none);
    expect(classifyOhms(null), Contact.none);
    expect(classifyOhms(double.nan), Contact.none);
    expect(formatOhms(127e3), '127 kΩ');
    expect(formatOhms(1.5e6), '1.5 MΩ');
    expect(formatOhms(double.infinity), 'off');
    expect(formatOhms(null), '–');
  });

  test('one second of one electrode: flat or at the limit is off, over 500 µV wild, over 250 µV loud', () {
    expect(classifySecond(flat: true, railed: false, swingUv: 0), off);
    expect(classifySecond(flat: false, railed: true, swingUv: 900), off);
    expect(classifySecond(flat: false, railed: false, swingUv: 501), wild);
    expect(classifySecond(flat: false, railed: false, swingUv: 500), loud);
    expect(classifySecond(flat: false, railed: false, swingUv: 251), loud);
    expect(classifySecond(flat: false, railed: false, swingUv: 250), calm);
  });

  test('the seconds come from the samples: a flat channel, a calm one, a loud one, a wild one', () {
    final maker = SecondMaker(channels: 4);
    List<SecondClass>? out;
    for (var i = 0; i < 250 * 3; i++) {
      final s = math.sin(2 * math.pi * 10 * i / 250); // 10 Hz
      out = maker.push([0, 20 * s, 180 * s, 400 * s]) ?? out;
    }
    expect(out, [off, calm, loud, wild]);
    expect(maker.push([1, 2, 3]), isNull, reason: 'a row of another width is ignored');
  });

  test('before any signal the contact reading decides, and it carries its time', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    final at = now;
    j.ohms({'O1': 100e3, 'O2': 600e3, 'T3': 1.8e6, 'T4': null});
    final v = j.verdict;
    expect([for (final e in v.electrodes) e.grade], [Contact.good, Contact.ok, Contact.poor, Contact.none]);
    expect(v.ohmsAt, at);
    expect(v.electrodes.every((e) => !e.fromSignal), isTrue);
    expect(v.trouble, Trouble.electrodes);
    expect(v.words, contains('T3 and T4'));
  });

  test('one loose electrode is named; the others stay good', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    feed(j, [calm, wild, calm, calm], 4);
    final v = j.verdict;
    expect(v.gradeOf('O2'), Contact.poor);
    expect(v.gradeOf('O1'), Contact.good);
    expect(v.trouble, Trouble.electrodes);
    expect(v.troubled, ['O2']);
    expect(v.words, startsWith('O2: this electrode has poor contact'));
  });

  test('everything at once is you, not an electrode: "busy", the band is on, nobody is blamed', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    feed(j, [calm, calm, calm, calm], 4);
    feed(j, [wild, wild, loud, wild], 4);
    final v = j.verdict;
    expect(v.trouble, Trouble.busy);
    expect(v.troubled, isEmpty);
    expect(v.electrodes.every((e) => e.grade == Contact.good), isTrue);
    expect(v.words, contains('The band is on'));
    expect(v.worthWarning(), isEmpty);
    // three of four is still "at once"; two of four is two electrodes
    expect(sharedSecond([wild, loud, loud, calm]), isTrue);
    expect(sharedSecond([wild, loud, calm, calm]), isFalse);
    expect(sharedSecond([wild]), isFalse, reason: 'one electrode can never be "all at once"');
  });

  test('every electrode off: one message, the band is off or the forehead contact is lost', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    feed(j, [off, off, off, off], 4);
    final v = j.verdict;
    expect(v.trouble, Trouble.allOff);
    expect(v.words, contains('forehead'));
    expect(v.electrodes.every((e) => e.grade == Contact.none), isTrue);
  });

  test('any number of electrodes at any positions: 8 and 16', () {
    for (final n in [8, 16]) {
      final names = [for (var i = 1; i <= n; i++) 'CH$i'];
      final j = judge(names);
      final second = List<SecondClass>.filled(n, calm)..[n - 1] = wild;
      feed(j, second, 4);
      expect(j.verdict.troubled, ['CH$n'], reason: '$n channels');
      expect(j.verdict.trouble, Trouble.electrodes);
      // three in four at once (6 of 8, 12 of 16) is busy
      final busy = [for (var i = 0; i < n; i++) i < (n * 3) ~/ 4 ? loud : calm];
      expect(sharedSecond(busy), isTrue);
      expect(sharedSecond([for (var i = 0; i < n; i++) i < n ~/ 2 ? loud : calm]), isFalse);
    }
    final j = judge(['O1', 'O2']);
    j.second([calm, calm, calm]); // another width: ignored
    expect(j.verdict.electrodes.length, 2);
  });

  test('while fitting, a word gets worse after 3 of 4 seconds and better after 3 calm ones', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    feed(j, [calm, calm, calm, calm], 4);
    feed(j, [wild, calm, calm, calm], 2);
    expect(j.verdict.gradeOf('O1'), Contact.good, reason: '2 of 4 seconds is not enough');
    feed(j, [wild, calm, calm, calm], 1);
    expect(j.verdict.gradeOf('O1'), Contact.poor);
    feed(j, [calm, calm, calm, calm], 2);
    expect(j.verdict.gradeOf('O1'), Contact.poor, reason: 'two calm seconds do not clear it');
    feed(j, [calm, calm, calm, calm], 1);
    expect(j.verdict.gradeOf('O1'), Contact.good);
  });

  test('after the first 5 minutes a word moves slowly: worse after 20 of 30 seconds, better after 10', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    feed(j, [calm, calm, calm, calm], 6 * 60);
    expect(j.verdict.settling, isFalse);
    feed(j, [wild, calm, calm, calm], 19);
    expect(j.verdict.gradeOf('O1'), Contact.good, reason: 'a short burst is not a fault');
    feed(j, [wild, calm, calm, calm], 1);
    expect(j.verdict.gradeOf('O1'), Contact.poor);
    feed(j, [calm, calm, calm, calm], 9);
    expect(j.verdict.gradeOf('O1'), Contact.poor);
    feed(j, [calm, calm, calm, calm], 2);
    expect(j.verdict.gradeOf('O1'), isNot(Contact.poor));
  });

  test('a warning only after 2 minutes, only for an electrode the running feature needs, never for busy', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    feed(j, [calm, calm, calm, off], 60);
    expect(j.verdict.worthWarning(), isEmpty, reason: 'one minute is not yet worth a warning');
    feed(j, [calm, calm, calm, off], 70);
    expect(j.verdict.worthWarning(), ['T4']);
    expect(j.verdict.worthWarning(['O1', 'O2']), isEmpty, reason: 'the feature does not need T4');
    expect(j.verdict.worthWarning(['T3', 'T4']), ['T4']);
    feed(j, [calm, calm, calm, calm], 5);
    expect(j.verdict.worthWarning(), isEmpty, reason: 'it came back');
  });

  test('a contact reading in force can only make the word worse; a change in the signal retires it', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    j.ohms({'O1': 100e3, 'O2': 1.4e6, 'T3': 100e3, 'T4': 100e3});
    feed(j, [calm, calm, calm, calm], 4);
    expect(j.verdict.gradeOf('O2'), Contact.poor, reason: 'the signal looks calm, the reading says poor');
    expect(j.verdict.contactChanged, isFalse);
    // O1 comes loose: the signal changed since the reading
    feed(j, [off, calm, calm, calm], 3);
    final v = j.verdict;
    expect(v.gradeOf('O1'), Contact.none);
    expect(v.contactChanged, isTrue);
    expect(v.coaching, anyOf(contains('2 to 5 minutes'), contains('changed')));
    // a new reading restarts it
    j.ohms({'O1': 100e3, 'O2': 100e3, 'T3': 100e3, 'T4': 100e3});
    expect(j.verdict.contactChanged, isFalse);
  });

  test('a new fit says to wait; a settled one does not', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    j.ohms({'O1': 900e3, 'O2': 100e3, 'T3': 100e3, 'T4': 100e3});
    feed(j, [calm, calm, calm, calm], 5);
    expect(j.verdict.settling, isTrue);
    expect(j.verdict.coaching, contains('2 to 5 minutes'));
    feed(j, [calm, calm, calm, calm], 5 * 60);
    expect(j.verdict.settling, isFalse);
    expect(j.verdict.coaching, isNull);
  });

  test('the verdict crosses the isolate port as plain values', () {
    final j = judge(['O1', 'O2', 'T3', 'T4']);
    feed(j, [calm, wild, calm, calm], 4);
    final back = QualityVerdict.fromMap(j.verdict.toMap())!.withOhms({'O1': 1e5, 'O2': 2e6}, now);
    expect(back.gradeOf('O2'), Contact.poor);
    expect(back.trouble, Trouble.electrodes);
    expect(back.electrodes[1].ohms, 2e6);
    expect(back.ohmsAt, now);
    expect(QualityVerdict.fromMap('x'), isNull);
    expect(QualityVerdict.fromMap({'names': ['O1'], 'grades': [9], 'troubleS': [null]}), isNull);
  });
}
