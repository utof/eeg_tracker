// The automatic Lights off (lib/sleep/auto_lights_off.dart, DECISIONS 1111-1112): the first run of 60 seconds with the
// phone's screen off, a clean signal, no blink and no movement; the screen read from the recording's own `.log`; the
// report's `auto_lights_off`; the check "4 of the newest 5 nights within 5 minutes of your tap"; its line in words.
import 'dart:io';

import 'package:eeg_tracker/sleep/auto_lights_off.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/ui/lights_off_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'drift_report_test.dart' show writeDriftRun;

const String wifiOff = 'wifi connected, 866 Mbps, -58 dBm, 5 GHz; default route wifi; screen off; idle no; lock held';
const String wifiOn = 'wifi connected; default route wifi; screen on; idle no; lock held';

/// Feeds seconds [from] to [to] (exclusive) of one kind into [f].
void feed(AutoLightsOffFinder f, int from, int to, {bool clean = true, bool blink = false, bool movement = false}) {
  for (var k = from; k < to; k++) {
    f.add(k: k, clean: clean, blink: blink, movement: movement);
  }
}

void main() {
  const start = 1000000;
  AutoLightsOffFinder finder(List<ScreenChange> screen) => AutoLightsOffFinder(screen, start);
  ScreenChange off(double after) => (t: start + after, off: true);
  ScreenChange on(double after) => (t: start + after, off: false);

  group('the log lines', () {
    test('the screen word of a line', () {
      expect(screenChangeIn('2026-11-18T02:40:13.123 $wifiOff')?.off, isTrue);
      expect(screenChangeIn('2026-11-18T02:40:13.123 $wifiOn')?.off, isFalse);
      expect(screenChangeIn('2026-11-18T02:40:13.123 wifi connected; default route wifi; screen ?; idle no; lock held'), isNull);
      expect(screenChangeIn('2026-11-18T02:40:13.123 wifi unreadable: no answer'), isNull);
      expect(screenChangeIn('2026-11-18T02:40:13.123 headband connected'), isNull);
      expect(screenChangeIn('not a time screen off'), isNull);
    });

    test('the time is local, as the laptop reads it', () {
      final c = screenChangeIn('2026-11-18T02:40:13.500 $wifiOff')!;
      expect(c.t, DateTime(2026, 11, 18, 2, 40, 13, 500).microsecondsSinceEpoch / 1e6);
    });
  });

  group('the rule', () {
    test('60 seconds screen off and clean: its first second', () {
      final f = finder([off(10)]);
      feed(f, 0, 200);
      expect(f.foundS, 10);
    });

    test('59 seconds are not enough', () {
      final f = finder([off(10)]);
      feed(f, 0, 69);
      expect(f.foundS, isNull);
      feed(f, 69, 70);
      expect(f.foundS, 10);
    });

    test('a blink or a movement starts the count again', () {
      final f = finder([off(0)]);
      feed(f, 0, 40);
      feed(f, 40, 41, blink: true);
      feed(f, 41, 70);
      expect(f.foundS, isNull, reason: 'only 29 since the blink');
      feed(f, 70, 101);
      expect(f.foundS, 41);

      final g = finder([off(0)]);
      feed(g, 0, 30);
      feed(g, 30, 31, movement: true);
      feed(g, 31, 120);
      expect(g.foundS, 31);
    });

    test('an unreadable second neither counts nor starts again', () {
      final f = finder([off(0)]);
      feed(f, 0, 30);
      feed(f, 30, 40, clean: false);
      feed(f, 40, 70);
      expect(f.foundS, 0, reason: '30 + 30 counted seconds, the run began at 0');
      final g = finder([off(0)]);
      feed(g, 0, 30);
      feed(g, 30, 40, clean: false);
      feed(g, 40, 69);
      expect(g.foundS, isNull);
    });

    test('a second the detectors never handed out (a gap) is unreadable too', () {
      final f = finder([off(0)]);
      feed(f, 0, 30);
      feed(f, 90, 120);
      expect(f.foundS, 0);
    });

    test('the screen coming on starts the count again', () {
      final f = finder([off(0), on(40), off(50)]);
      feed(f, 0, 109);
      expect(f.foundS, isNull, reason: 'off again from 50: 59 seconds');
      feed(f, 109, 110);
      expect(f.foundS, 50);
    });

    test('before the first screen line the screen is unknown: not off, and it starts nothing again', () {
      final f = finder([off(30)]);
      feed(f, 0, 30);
      feed(f, 30, 89);
      expect(f.foundS, isNull);
      feed(f, 89, 90);
      expect(f.foundS, 30);
      final none = finder(const []);
      feed(none, 0, 600);
      expect(none.foundS, isNull, reason: 'no screen line at all: never found');
    });

    test('the first run stays the answer', () {
      final f = finder([off(0)]);
      feed(f, 0, 80);
      feed(f, 80, 81, blink: true);
      feed(f, 81, 300);
      expect(f.foundS, 0);
    });

    test('screen lines in any order', () {
      final f = finder([on(40), off(0)]);
      feed(f, 0, 100);
      expect(f.foundS, isNull);
      expect(finder([on(40), off(0)]).foundS, isNull);
    });
  });

  group('the report field', () {
    final first = DateTime.fromMillisecondsSinceEpoch(start * 1000);
    test('time, second, the difference to the tap in minutes, version 1', () {
      final r = autoLightsOffReport(300, start + 120.0, first)!;
      expect(r.keys.toSet(), {'time', 'second', 'tap_diff_min', 'version'});
      expect(r['time'], isoLocal(first.add(const Duration(seconds: 300))));
      expect((r['second'], r['tap_diff_min'], r['version']), (300, 3.0, 1));
    });

    test('before the tap is negative; without a tap null; no run found: absent', () {
      expect(autoLightsOffReport(0, start + 90.0, first)!['tap_diff_min'], -1.5);
      expect(autoLightsOffReport(300, null, first)!['tap_diff_min'], isNull);
      expect(autoLightsOffReport(null, start + 5.0, first), isNull);
    });

    test('read back; damaged is null', () {
      final r = AutoLightsOff.read(autoLightsOffReport(300, start + 120.0, first));
      expect(r!.tapDiffMin, 3.0);
      expect(r.time, first.add(const Duration(seconds: 300)));
      expect(AutoLightsOff.read(null), isNull);
      expect(AutoLightsOff.read({'time': 'x', 'second': 1}), isNull);
    });
  });

  group('the check', () {
    SleepReport night(String nightOf, {double? diff, String from = 'button', bool hasAuto = true}) => SleepReport({
      'night_of': nightOf,
      'drift_off': {'source': from},
      if (hasAuto)
        'auto_lights_off': {'time': '2026-11-18T23:41:00+03:00', 'second': 10, 'tap_diff_min': diff, 'version': 1},
    });

    test('the newest 5 nights with your tap and the automatic one; trusted at 4 within 5 minutes', () {
      final none = autoLightsCheck(const []);
      expect((none.agree, none.nights, none.decided, none.trusted), (0, 0, false, false));
      final reports = [
        night('2026-11-25', diff: 3),
        night('2026-11-24', diff: null, from: 'night start'), // no tap: not counted
        night('2026-11-23', hasAuto: false), // no run found: not counted
        night('2026-11-22', diff: -5), // exactly 5: agrees
        night('2026-11-21', diff: 9),
        night('2026-11-20', diff: 0.5, from: 'dream catcher'), // not your tap: not counted
        night('2026-11-19', diff: 1),
      ];
      final c = autoLightsCheck(reports);
      expect((c.agree, c.nights, c.decided, c.trusted), (3, 4, false, false));
      final more = autoLightsCheck([night('2026-11-26', diff: -2), ...reports, night('2026-11-18', diff: 0)]);
      expect((more.agree, more.nights, more.decided, more.trusted), (4, 5, true, true));
      final later = autoLightsCheck([night('2026-11-27', diff: 20), night('2026-11-26', diff: 0), ...reports]);
      expect((later.agree, later.nights, later.trusted), (3, 5, false), reason: 'the 19th dropped out of the newest 5');
    });
  });

  group('the night pass', () {
    test('reads the recording\'s log and finds the run', () {
      final dir = Directory.systemTemp.createTempSync('auto_lights_');
      addTearDown(() => dir.deleteSync(recursive: true));
      const t0 = 1795468320.0;
      final f = writeDriftRun(dir, t0, 240, fadeAtS: 1000);
      final t = DateTime.fromMillisecondsSinceEpoch(((t0 + 20) * 1000).round());
      File(f.path.replaceFirst(RegExp(r'\.f32$'), '.log')).writeAsStringSync('${_logTime(t)} $wifiOff\n');
      final seen = seeNight([f])!;
      final s = seen.autoLightsOffS;
      expect(s, isNotNull);
      expect(s! >= 20 && s <= 60, isTrue, reason: 'screen off from second 20; clean from the first seconds on');
      expect(seen.driftError, isNull);
    });

    test('no log: not found, nothing else changes', () {
      final dir = Directory.systemTemp.createTempSync('auto_lights_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = writeDriftRun(dir, 1795468320.0, 240, fadeAtS: 1000);
      final seen = seeNight([f])!;
      expect(seen.autoLightsOffS, isNull);
      expect(seen.drift, isNotNull);
    });
  });

  group('the line in words', () {
    final at = DateTime(2026, 11, 18, 23, 41);
    AutoLightsOff auto(double? diff) => AutoLightsOff(time: at, second: 10, tapDiffMin: diff);
    const g = 'The app\'s own guess of lights off: 23:41';

    test('not trusted yet', () {
      expect(autoLightsOffLine(auto(3), const AutoLightsCheck(2, 5)),
          '$g (3\u00a0min after your tap). Not used yet: within 5 minutes of your tap on only 2 of the last 5 nights.');
      expect(autoLightsOffLine(auto(-1.5), const AutoLightsCheck(1, 2)),
          '$g (1½\u00a0min before your tap). Not used yet: within 5 minutes of your tap on 1 of 2 nights so far.');
      expect(autoLightsOffLine(auto(null), const AutoLightsCheck(0, 0)),
          '$g. Not used yet: no night with your tap and this guess yet.');
      expect(autoLightsOffLine(auto(0), const AutoLightsCheck(0, 1)), startsWith('$g (the same time as your tap).'));
      expect(autoLightsOffLine(auto(0), const AutoLightsCheck(1, 1)), contains('1 of 1 night so far.'));
    });

    test('trusted', () {
      expect(autoLightsOffLine(auto(3), const AutoLightsCheck(4, 5)),
          '$g (3\u00a0min after your tap). Within 5 minutes of your tap on 4 of 5 nights.');
    });
  });
}

String _logTime(DateTime t) => t.toIso8601String().substring(0, 23);
