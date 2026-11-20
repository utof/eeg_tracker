// The headband's battery estimate (lib/headband/battery_estimate.dart, DECISIONS 853): the gauge sticks while it
// streams, so the number is the last believed reading minus 10 % for every hour streamed.
import 'dart:io';

import 'package:eeg_tracker/headband/battery_estimate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 11, 20, 15, 55);

  /// Readings every minute from [from] for [minutes], the gauge saying [gauge] while streaming.
  void stream(BandBatteryTrack t, DateTime from, int minutes, int gauge) {
    for (var m = 1; m <= minutes; m++) {
      t.note(gauge, from.add(Duration(minutes: m)), streaming: true);
    }
  }

  test('a new connection\'s first reading is believed; then 10 % an hour of streaming comes off', () {
    final t = BandBatteryTrack()..note(100, t0, streaming: false);
    expect(t.now.estimate, 100);
    expect(t.now.stuck, isFalse);
    stream(t, t0, 120, 100); // the gauge sits at 100 % for two hours
    expect(t.now.estimate, 80);
    expect(t.now.gauge, 100);
    expect(t.now.stuck, isTrue);
    expect(t.now.words, 'about 80 %');
    expect(t.now.note, contains('100 %'));
    expect(t.now.hoursLeft, 8);
  });

  test('the gauge that moved in line with the estimate is believed again (99 -> 79 on 2026-11-20)', () {
    final t = BandBatteryTrack()..note(99, t0, streaming: false);
    stream(t, t0, 115, 99);
    expect(t.now.estimate, 80);
    t.note(79, t0.add(const Duration(minutes: 116)), streaming: true);
    expect(t.now.estimate, 79);
    expect(t.now.stuck, isFalse);
    expect(t.now.note, isNull);
  });

  test('99 % one moment and 6 % the next is the gauge sticking: the estimate goes on (2026-11-19: 6 % for nine hours)', () {
    final t = BandBatteryTrack()..note(99, t0, streaming: false);
    stream(t, t0, 4 * 60, 6);
    expect(t.now.gauge, 6);
    expect(t.now.estimate, 59, reason: '99 % minus four hours at 10 % an hour');
    expect(t.now.stuck, isTrue);
    expect(t.now.note, contains('6 %'));
    stream(t, t0.add(const Duration(hours: 4)), 5 * 60, 6);
    expect(t.now.estimate, 9, reason: 'nine hours in all');
    // the same stuck value at the next connection, minutes later, is not believed either
    t.note(6, t0.add(const Duration(hours: 9, minutes: 3)), streaming: false);
    expect(t.now.estimate, 9);
  });

  test('a new connection that reads higher was charged; 0-2 % is never believed over a fuller estimate', () {
    final t = BandBatteryTrack()..note(60, t0, streaming: false);
    stream(t, t0, 60, 60);
    expect(t.now.estimate, 50);
    t.note(100, t0.add(const Duration(hours: 5)), streaming: false);
    expect(t.now.estimate, 100);
    t.note(1, t0.add(const Duration(hours: 5, minutes: 1)), streaming: true);
    expect(t.now.estimate, 100);
    expect(t.now.stuck, isTrue);
  });

  test('time without streaming takes nothing off; a gap between readings is not counted as streaming', () {
    final t = BandBatteryTrack()..note(70, t0, streaming: false);
    t.note(70, t0.add(const Duration(hours: 3)), streaming: false);
    expect(t.now.estimate, 70);
    t.note(70, t0.add(const Duration(hours: 3, minutes: 1)), streaming: true);
    t.note(70, t0.add(const Duration(hours: 7)), streaming: true); // one step of at most 2 minutes
    expect(t.now.estimate, 70);
  });

  test('half a day without a reading: the next connection\'s reading replaces the estimate', () {
    final t = BandBatteryTrack()..note(90, t0, streaming: false);
    t.note(55, t0.add(const Duration(hours: 20)), streaming: false);
    expect(t.now.estimate, 55);
  });

  test('estimated empty is told once per charge, and only after counting down from a real charge', () {
    final t = BandBatteryTrack()..note(40, t0, streaming: false);
    stream(t, t0, 200, 40);
    expect(t.now.empty, isFalse);
    expect(t.takeEmpty(), isFalse);
    stream(t, t0.add(const Duration(minutes: 200)), 20, 40);
    expect(t.now.estimate, lessThanOrEqualTo(5));
    expect(t.takeEmpty(), isTrue);
    expect(t.takeEmpty(), isFalse, reason: 'once');
    t.note(100, t0.add(const Duration(hours: 9)), streaming: false);
    expect(t.now.empty, isFalse);
    // a first reading that is already low is no countdown: no "empty" notice from it
    final low = BandBatteryTrack()..note(6, t0, streaming: false);
    stream(low, t0, 60, 6);
    expect(low.takeEmpty(), isFalse);
  });

  test('the track is kept in a file both engines write, one reading at a time', () {
    final dir = Directory.systemTemp.createTempSync('band-battery');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = BandBatteryStore.forRecordings('${dir.path}/recordings');
    expect(store.load().now.percent, isNull);
    expect(store.load().now.words, '–');
    store.note(88, t0, streaming: false);
    final again = BandBatteryStore.forRecordings('${dir.path}/recordings');
    again.note(88, t0.add(const Duration(minutes: 1)), streaming: true);
    again.note(88, t0.add(const Duration(minutes: 2)), streaming: true);
    expect(store.load().streamedMs, 60000);
    expect(store.load().now.estimate, 88);
    expect(File('${dir.path}/headband/battery.json').existsSync(), isTrue);
  });
}
