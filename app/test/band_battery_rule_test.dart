// One battery rule for the headband (DECISIONS 946): the drain per hour and the gauge's stuck values live in one place
// (lib/headband/battery_estimate.dart `BandBatteryRule`), and the card, the battery guard and the Battery page all
// use it.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/auto/battery_guard.dart';
import 'package:eeg_tracker/auto/bedtime.dart';
import 'package:eeg_tracker/auto/store.dart';
import 'package:eeg_tracker/headband/battery_estimate.dart';
import 'package:eeg_tracker/logs/battery_report.dart';
import 'package:eeg_tracker/logs/read.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the rule: 11 % an hour (measured on the owner\'s headband, 99 to 79 % in 1.8 h), stuck at 0-2 and 100 %', () {
    expect(BandBatteryRule.drainPctPerHour, 11);
    expect((99 - 79) / 1.8, closeTo(BandBatteryRule.drainPctPerHour, 0.2));
    expect(BandBatteryRule.stuckLevels, {0, 1, 2, 100});
    expect(BandBatteryRule.flatStuck, const Duration(minutes: 60));
  });

  test('one place: no other file in lib/ sets a drain per hour or a list of stuck values', () {
    final own = RegExp(r'drainPctPerHour\s*=|stuckLevels\s*=|flatStuck\s*=');
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (own.hasMatch(f.readAsStringSync())) hits.add(f.path.replaceAll('\\', '/'));
    }
    expect(hits, ['lib/headband/battery_estimate.dart']);
  });

  test('the card\'s estimate counts down by the rule', () {
    final t0 = DateTime(2026, 11, 20, 14);
    final track = BandBatteryTrack()..note(99, t0, streaming: false);
    for (var m = 1; m <= 60; m++) {
      track.streamingAt(t0.add(Duration(minutes: m)), streaming: true);
    }
    // the first minute is the step into streaming: 59 minutes streamed
    expect(track.now.estimate, (99 - BandBatteryRule.drainPctPerHour * 59 / 60).round());
    expect(const BandBattery(estimate: 55).hoursLeft, 5);
  });

  test('the battery guard counts with the same rule', () {
    final w = usualNight(const [], const AutoSettings()); // bed 23:00, wake 07:00: 8 h
    // 8 h x 11 % + 15 % is more than a full charge: tonight needs all of it
    expect(nightNeedPct(w), 100);
    // the stopping rule (the guard only warns by default, DECISIONS 1010) shows the drain it counts with
    final day = guardBattery(WearKind.work, 80, DateTime(2026, 11, 20, 10, 0), w, onlyWarns: false);
    expect(day.limit, Duration(minutes: ((80 - 15) / BandBatteryRule.drainPctPerHour * 60).floor()));
    expect(day.limit, const Duration(hours: 5, minutes: 54));
    final night = guardBattery(WearKind.night, 30, DateTime(2026, 11, 20, 23, 0), w);
    expect(night.note, 'headband at 30 %: about 2 h, the night needs about 8 h');
    expect(guardBattery(WearKind.night, 88, DateTime(2026, 11, 20, 23, 0), w).note, isNull, reason: '8 h x 11 %');
    expect(guardBattery(WearKind.night, 87, DateTime(2026, 11, 20, 23, 0), w).note, isNotNull);
  });

  test('the Battery page: a value that does not move for an hour of readings is stuck (the laptop\'s rule too)', () {
    final t0 = DateTime(2026, 11, 20, 23);
    final r = headbandRun([
      (t0, 80),
      (t0.add(const Duration(minutes: 5)), 79),
      for (var m = 10; m <= 100; m += 2) (t0.add(Duration(minutes: m)), 37),
      (t0.add(const Duration(minutes: 105)), 60),
      (t0.add(const Duration(minutes: 135)), 55),
    ])!;
    expect(r.stuckAt, 37);
    expect(r.first, 80);
    expect(r.last, 55);
  });

  test('the Battery page shows the card\'s number: the same estimate from the same file', () {
    final tmp = Directory.systemTemp.createTempSync('band_rule');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final now = DateTime(2026, 11, 20, 16);
    final store = BandBatteryStore.forRecordings('${tmp.path}/recordings');
    final track = BandBatteryTrack()..note(99, now.subtract(const Duration(hours: 2)), streaming: false);
    for (var m = 1; m <= 109; m++) {
      track.streamingAt(now.subtract(const Duration(hours: 2)).add(Duration(minutes: m)), streaming: true);
    }
    track.note(6, now, streaming: true); // the gauge sticks
    store.save(track);
    final i = loadBattery(tmp.path, now: now);
    expect(i.band.estimate, track.now.estimate);
    expect(i.band.estimate, 79);
    expect(i.band.words, 'about 79 %');
    expect(i.band.stuck, isTrue);
    expect(bandNowWords(i.band), 'about 7.2 h of streaming left at 11 % an hour · the same estimate as on the headband card');
    expect(jsonDecode(store.file.readAsStringSync()), isA<Map<String, Object?>>());
  });
}
