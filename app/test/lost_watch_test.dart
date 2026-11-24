// The headband-lost notices (lib/headband/lost_watch.dart, DECISIONS 857): one after N minutes without data, one when
// it is back, none after Stop.
import 'dart:io';

import 'package:eeg_tracker/headband/lost_watch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late List<BandNotice> told;
  var settings = const LostSettings();
  LostWatch watch() => LostWatch(settings: () => settings, tell: told.add, what: 'The recording', clock: () => now);

  /// [seconds] of one-second looks.
  void run(LostWatch w, int seconds, {required bool expecting, required bool data, bool empty = false}) {
    for (var i = 0; i < seconds; i++) {
      now = now.add(const Duration(seconds: 1));
      w.update(expecting: expecting, dataFresh: data, batteryEmpty: empty);
    }
  }

  setUp(() {
    now = DateTime(2026, 11, 21, 2);
    told = [];
    settings = const LostSettings();
  });

  test('lost for 5 minutes: one notice, however long it lasts; back: one more', () {
    final w = watch();
    run(w, 600, expecting: true, data: true);
    expect(told, isEmpty);
    run(w, 299, expecting: true, data: false);
    expect(told, isEmpty, reason: 'not yet 5 minutes');
    run(w, 3, expecting: true, data: false);
    expect(told.map((n) => n.kind), [BandNoticeKind.lost]);
    expect(told.single.title, 'Headband lost');
    expect(told.single.text, contains('5 min'));
    expect(told.single.text, contains('The recording waits'));
    run(w, 3600, expecting: true, data: false);
    expect(told.length, 1, reason: 'one per loss');
    run(w, 2, expecting: true, data: true);
    expect(told.map((n) => n.kind), [BandNoticeKind.lost, BandNoticeKind.back]);
    expect(told.last.text, contains('65 min'));
    run(w, 600, expecting: true, data: true);
    expect(told.length, 2);
  });

  test('a short loss says nothing, and nothing about being back', () {
    final w = watch();
    run(w, 240, expecting: true, data: false);
    run(w, 60, expecting: true, data: true);
    run(w, 240, expecting: true, data: false);
    expect(told, isEmpty, reason: 'two losses of 4 minutes are not one of 8');
  });

  test('stopped on purpose: no notice, and none later about "back"', () {
    final w = watch();
    run(w, 200, expecting: true, data: false);
    run(w, 3600, expecting: false, data: false); // Stop was tapped
    expect(told, isEmpty);
    // lost, told, then stopped: no "back" when another recording starts with data
    run(w, 400, expecting: true, data: false);
    expect(told.length, 1);
    run(w, 10, expecting: false, data: false);
    run(w, 10, expecting: true, data: true);
    expect(told.length, 1);
  });

  test('the minutes are the owner\'s choice, 5 to 10; a change counts from the next loss; off is off', () {
    settings = const LostSettings(afterMin: 10);
    final w = watch();
    run(w, 599, expecting: true, data: false);
    expect(told, isEmpty);
    run(w, 2, expecting: true, data: false);
    expect(told.single.text, contains('10 min'));
    expect(const LostSettings(afterMin: 3).after, const Duration(minutes: 5));
    expect(const LostSettings(afterMin: 60).after, const Duration(minutes: 10));

    told.clear();
    settings = const LostSettings(on: false);
    final quiet = watch();
    run(quiet, 3600, expecting: true, data: false);
    run(quiet, 5, expecting: true, data: true);
    expect(told, isEmpty);
  });

  test('a loss with the battery estimated empty says so; the battery notice has its own words', () {
    final w = watch();
    run(w, 301, expecting: true, data: false, empty: true);
    expect(told.single.text, contains('battery is probably empty'));
    w.batteryEmpty(4);
    expect(told.last.kind, BandNoticeKind.battery);
    expect(told.last.text, contains('About 4 %'));
    final m = told.last.toMap();
    expect(m['kind'], 'battery');
    expect(m['at'], now.millisecondsSinceEpoch ~/ 1000);
    expect(m['title'], isA<String>());
  });

  test('the setting is kept in a file, with the defaults for anything unreadable', () {
    final dir = Directory.systemTemp.createTempSync('lost-settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = LostSettings.fileFor('${dir.path}/recordings');
    expect(LostSettings.load(f).afterMin, 5);
    expect(LostSettings.load(f).on, isTrue);
    const LostSettings(afterMin: 8, on: false).save(f);
    expect(LostSettings.load(f).afterMin, 8);
    expect(LostSettings.load(f).on, isFalse);
    f.writeAsStringSync('{"lostAfterMin": 99}');
    expect(LostSettings.load(f).afterMin, 10);
    f.writeAsStringSync('not json');
    expect(LostSettings.load(f).afterMin, 5);
  });
}
