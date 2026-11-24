import 'package:eeg_tracker/recorder/contact.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/ui/night_screen.dart';
import 'package:eeg_tracker/ui/night_strip.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:flutter_test/flutter_test.dart';

int ms(DateTime t) => t.millisecondsSinceEpoch;
const perSlot = sampleRateHz * 1800;

void main() {
  group('contact', () {
    test('planning thresholds', () {
      expect(classifyOhms(2e5), Contact.good);
      expect(classifyOhms(4e5), Contact.ok);
      expect(classifyOhms(1e6), Contact.ok);
      expect(classifyOhms(2e6), Contact.poor);
      expect(classifyOhms(double.infinity), Contact.none);
      expect(classifyOhms(null), Contact.none);
    });
  });

  group('messages survive the trip between isolates and into storage', () {
    test('status', () {
      const s = RecorderStatus(
        phase: Phase.recording,
        nightStartMs: 1000,
        nightSamples: 250,
        lastDataMs: 2000,
        rssi: -64,
        battery: 78,
        contactOhms: {'O1': 4e5, 'O2': double.infinity, 'T3': 2e6, 'T4': null},
        runs: 2,
        note: 'recording',
        slots: {994444: 250},
      );
      final back = RecorderStatus.fromMap(s.toMap(nowMs: 3000))!;
      expect(back.phase, Phase.recording);
      expect(back.contactOf('O1'), Contact.ok);
      expect(back.contactOf('O2'), Contact.none);
      expect(back.contactOf('T3'), Contact.poor);
      expect(back.slots, {994444: 250});
      expect(back.sentMs, 3000);
      expect(RecorderStatus.fromMap({'kind': 'stopped'}), isNull);
    });

    test('night state', () {
      const n = NightState(
        active: true,
        startMs: 5,
        samples: 9,
        runs: 2,
        contactTried: true,
        contactOhms: {'O1': double.infinity},
        slots: {7: 9},
        band: BandId(name: 'BrainBit', address: 'AA:BB', serial: '1', family: 'leBrainBitBlack', model: 3),
        directPending: true,
        directOff: true,
      );
      final back = NightState.fromJson(n.toJson());
      expect(back.active, isTrue);
      expect(back.samples, 9);
      expect(back.contactOhms, {'O1': null});
      expect(back.slots, {7: 9});
      expect(back.band?.address, 'AA:BB');
      expect(back.band?.family, 'leBrainBitBlack');
      expect(back.band?.model, 3);
      expect(back.directPending, isTrue);
      expect(back.directOff, isTrue);
      expect(
        NightState.fromJson({
          'band': {'address': 5},
        }).band,
        isNull,
      );
      expect(NightState.fromJson('garbage').active, isFalse);
    });
  });

  group('watch strip', () {
    test('cells sit on the local clock, four hours a row, gaps show', () {
      final start = DateTime(2026, 11, 18, 23, 10);
      final end = DateTime(2026, 11, 19, 1, 15);
      int slot(DateTime t) => ms(t) ~/ slotMs;
      final slots = {
        slot(DateTime(2026, 11, 18, 23, 0)): 20 * 60 * sampleRateHz, // 23:10-23:30 full
        slot(DateTime(2026, 11, 18, 23, 30)): perSlot,
        slot(DateTime(2026, 11, 19, 0, 0)): perSlot ~/ 2, // a gap
        // 00:30 nothing
        slot(DateTime(2026, 11, 19, 1, 0)): 5 * 60 * sampleRateHz, // in progress, 01:00-01:05 of 01:00-01:15
      };
      final rows = stripRows(startMs: ms(start), endMs: ms(end), slots: slots, live: true);
      expect(rows, hasLength(2));
      expect(rows[0].start, DateTime(2026, 11, 18, 20));
      expect(rows[1].start, DateTime(2026, 11, 19, 0));
      expect(rows[0].cells.map((c) => c.column), [6, 7]);
      expect(rows[0].cells.every((c) => c.fraction == 1), isTrue);
      expect(rows[1].cells.map((c) => c.column), [0, 1, 2]);
      expect(rows[1].cells[0].fraction, closeTo(0.5, 1e-9));
      expect(rows[1].cells[1].fraction, 0);
      expect(rows[1].cells[2].current, isTrue);
      expect(rows[1].cells[2].fraction, closeTo(5 / (15 - 1 / 6), 1e-9));
      expect(nightCoverage(rows), closeTo((1 + 1 + 0.5 + 0) / 4, 1e-9));
    });

    test('nothing to draw without a night', () {
      expect(stripRows(startMs: 0, endMs: 10, slots: const {}, live: false), isEmpty);
    });
  });

  group('status words', () {
    final now = ms(DateTime(2026, 11, 19, 3));
    RecorderStatus st(Phase p, {String note = '', int? ageS}) =>
        RecorderStatus(phase: p, note: note, nightStartMs: 1, lastDataMs: ageS == null ? null : now - ageS * 1000);

    test('idle', () {
      expect(describeNight(status: null, running: false, nowMs: now, quietMs: 0).title, 'Ready');
      final morning = describeNight(
        status: null,
        running: false,
        nowMs: now,
        quietMs: 0,
        last: const NightState(samples: 1000),
      );
      expect(morning.sentence, startsWith('Last night is saved'));
    });

    test('recording: calm while data flow, caution then problem as data age', () {
      expect(
        describeNight(status: st(Phase.recording, ageS: 1), running: true, nowMs: now, quietMs: 0).tone,
        Tone.live,
      );
      final late = describeNight(status: st(Phase.recording, ageS: 12), running: true, nowMs: now, quietMs: 0);
      expect(late.tone, Tone.caution);
      expect(late.sentence, contains('12 s'));
      expect(
        describeNight(status: st(Phase.recording, ageS: 60), running: true, nowMs: now, quietMs: 0).tone,
        Tone.problem,
      );
    });

    test('a silent recorder is called out', () {
      final d = describeNight(status: st(Phase.recording, ageS: 1), running: true, nowMs: now, quietMs: 40000);
      expect(d.title, 'Not answering');
      expect(d.tone, Tone.problem);
    });

    test('reconnecting notes', () {
      expect(
        describeNight(
          status: st(Phase.reconnecting, note: 'headband lost; reconnecting'),
          running: true,
          nowMs: now,
          quietMs: 0,
        ).title,
        'Reconnecting',
      );
      expect(
        describeNight(
          status: st(Phase.searching, note: 'headband not found; is it on and charged?'),
          running: true,
          nowMs: now,
          quietMs: 0,
        ).sentence,
        contains('switched on'),
      );
      expect(
        describeNight(
          status: st(Phase.reconnecting, note: 'Bluetooth stuck; restarting the recorder'),
          running: true,
          nowMs: now,
          quietMs: 0,
        ).title,
        'Restarting',
      );
    });
  });
}
