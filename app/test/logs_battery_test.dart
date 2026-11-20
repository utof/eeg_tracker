// Battery per feature (DECISIONS 715-716): the sampler with a fake phone (when it reads, what it notes), the
// stretches between samples (chargers, long gaps, stale engines, the night logs' own lines), the per-feature
// attribution against made-up rates with a known answer, the advice in words, and the headband's gauge.
import 'package:eeg_tracker/logs/activity.dart';
import 'package:eeg_tracker/logs/battery_report.dart';
import 'package:eeg_tracker/logs/metrics.dart';
import 'package:flutter_test/flutter_test.dart';

/// A phone draining at [rate] mAh an hour from [startMah], sampled by [engine] every [every] with [on].
List<PowerPoint> _drain(
  DateTime from,
  Duration span,
  double rate, {
  required List<String> on,
  bool screen = false,
  double startMah = 4000,
  String engine = 'screen',
  Duration every = const Duration(minutes: 1),
  int cpuPerMin = 0,
}) {
  final out = <PowerPoint>[];
  for (var t = Duration.zero; t <= span; t += every) {
    final h = t.inMilliseconds / 3600000;
    out.add(
      PowerPoint(
        t: from.add(t),
        engine: engine,
        uah: ((startMah - rate * h) * 1000).round(),
        pct: ((startMah - rate * h) / 50).round(),
        plug: 'no',
        screen: screen,
        cpu: t.inMinutes * cpuPerMin,
        on: on,
      ),
    );
  }
  return out;
}

double _adds(BatteryReport r, String member) => r.groups.firstWhere((g) => g.use.members.contains(member)).adds!;

void main() {
  setUp(Activity.reset);
  tearDown(() {
    Activity.reset();
    Metrics.band = null;
  });

  group('the sampler', () {
    // testWidgets: its clock is fake, so minutes pass at once
    testWidgets('every 2 minutes with the app open, every minute while something runs, 3 s after a change; a last one at Stop', (
      tester,
    ) async {
      final lines = <Map<String, Object?>>[];
      var reads = 0;
      final s = PowerSampler(
        read: () async {
          reads++;
          return {'percent': 80, 'chargeUah': 3200000, 'currentUa': -250000, 'plugged': 'no', 'screenOn': true, 'cpuMs': 1000 * reads};
        },
        write: lines.add,
        rss: () => 123,
      );
      Activity.begin('app-open');
      s.start();
      await tester.pump();
      expect(lines.single, containsPair('why', 'start'));
      expect(lines.single['on'], ['app-open']);
      expect(lines.single, containsPair('uah', 3200000));
      expect(lines.single, containsPair('screen', true));
      expect(lines.single, containsPair('rss', 123));
      await tester.pump(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 2, seconds: 1));
      expect(lines.where((l) => l['why'] == 'every'), hasLength(2));
      Activity.begin('signal');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(lines.last, containsPair('why', 'change'));
      expect(lines.last['on'], ['app-open', 'signal']);
      final before = lines.length;
      for (var m = 0; m < 3; m++) {
        await tester.pump(const Duration(minutes: 1));
      }
      expect(lines.length - before, 3, reason: 'every minute while the Signal tab is open');
      Metrics.band = () => {'battery': 64, 'rssi': -71};
      await s.stop();
      expect(lines.last, containsPair('why', 'stop'));
      expect(lines.last['band'], {'battery': 64, 'rssi': -71});
      final n = lines.length;
      await tester.pump(const Duration(minutes: 10));
      expect(lines, hasLength(n));
    });

    testWidgets('nothing while "Measure battery" is off, nor when Android gives no numbers', (tester) async {
      final lines = <Map<String, Object?>>[];
      var on = false;
      final s = PowerSampler(read: () async => null, write: lines.add, enabled: () => on)..start();
      await tester.pump(const Duration(minutes: 5));
      on = true;
      await tester.pump(const Duration(minutes: 5));
      await s.stop();
      expect(lines, isEmpty);
    });
  });

  group('stretches', () {
    final t0 = DateTime(2026, 11, 20, 9);

    test('a charger at either end, a charge that went up, and a gap over a day are left out', () {
      final pts = [
        PowerPoint(t: t0, engine: 'screen', uah: 3000000, plug: 'no', on: const ['app-open']),
        PowerPoint(t: t0.add(const Duration(minutes: 1)), engine: 'screen', uah: 2998000, plug: 'no', on: const ['app-open']),
        PowerPoint(t: t0.add(const Duration(minutes: 2)), engine: 'screen', uah: 2999000, plug: 'usb', on: const ['app-open']),
        PowerPoint(t: t0.add(const Duration(minutes: 3)), engine: 'screen', uah: 3001000, plug: 'no', on: const ['app-open']),
        PowerPoint(t: t0.add(const Duration(minutes: 4)), engine: 'screen', uah: 3002000, plug: 'no', on: const ['app-open']),
        PowerPoint(t: t0.add(const Duration(hours: 30)), engine: 'screen', uah: 2000000, plug: 'no', on: const ['app-open']),
      ];
      final s = stretches(pts);
      expect(s, hasLength(1));
      expect(s.single.mah, closeTo(2, 1e-9));
      expect(s.single.on, ['app-open']);
    });

    test('a gap of an hour is the phone with the app closed; an engine\'s sample older than 5 minutes no longer counts', () {
      final pts = [
        PowerPoint(t: t0, engine: 'recorder', uah: 3000000, plug: 'no', on: const ['night']),
        PowerPoint(t: t0.add(const Duration(minutes: 1)), engine: 'screen', uah: 2999000, plug: 'no', screen: true, on: const ['app-open']),
        PowerPoint(t: t0.add(const Duration(minutes: 7)), engine: 'screen', uah: 2996000, plug: 'no', on: const []),
        PowerPoint(t: t0.add(const Duration(minutes: 8)), engine: 'screen', uah: 2995000, plug: 'no', on: const []),
        PowerPoint(t: t0.add(const Duration(minutes: 68)), engine: 'screen', uah: 2975000, plug: 'no', on: const []),
      ];
      final s = stretches(pts);
      expect(s[0].on, ['night']);
      expect(s[1].on, ['app-open', 'night', 'screen']);
      expect(s[2].on, isEmpty, reason: 'the recorder\'s sample is 7 minutes old');
      expect(s.last.watched, isFalse);
      final r = batteryReport(pts);
      expect(r.closed!.rate, closeTo(20, 1e-6));
    });

    test('a night log\'s phone battery line counts as a night sample, unless the engine measured the same minutes', () {
      final p = nightLogPoint('2026-11-20T08:16:20.222 phone battery 93% charge 3556000 uAh current 84000 uA unplugged temp 22.5 C')!;
      expect((p.pct, p.uah, p.plug), (93, 3556000, 'no'));
      expect(p.on, ['night', 'headband']);
      expect(nightLogPoint('2026-11-20T08:16:30.925 samples 2512 (+2520) battery 6%'), isNull);
      final plugged = nightLogPoint('2026-11-20T08:17:20 phone battery 93% charge 3556000 uAh current 84000 uA plugged ac temp 22.5 C')!;
      expect(plugged.plugged, isTrue);
      final own = _drain(t0, const Duration(minutes: 10), 60, on: const ['night', 'headband'], engine: 'recorder');
      final logs = _drain(t0.add(const Duration(seconds: 20)), const Duration(minutes: 10), 60, on: const ['night', 'headband'], engine: 'night-log');
      final s = stretches([...own, ...logs]);
      expect(s, hasLength(10));
      expect(s.fold<double>(0, (a, b) => a + b.mah), closeTo(10, 0.01));
    });

    test('the battery\'s size from the counter and the level', () {
      expect(capacityMah([PowerPoint(t: t0, engine: 'screen', uah: 4000000, pct: 80)]), closeTo(5000, 1e-9));
      expect(capacityMah([PowerPoint(t: t0, engine: 'screen', pct: 80)]), isNull);
    });
  });

  group('attribution', () {
    // the phone as the app sees it on a made-up day: the app open on a page 150 mAh/h (screen on), the Signal tab
    // 60 more, a night with its headband link 40, Share on Wi-Fi with its lock 30 more during a night
    final day = DateTime(2026, 11, 20, 8);
    List<PowerPoint> made() => [
      ..._drain(day, const Duration(hours: 2), 150, on: const ['app-open'], screen: true, cpuPerMin: 3000),
      ..._drain(day.add(const Duration(hours: 3)), const Duration(hours: 1), 210, on: const ['app-open', 'signal'], screen: true, cpuPerMin: 24000),
      ..._drain(DateTime(2026, 11, 20, 23), const Duration(hours: 8), 40, on: const ['night', 'headband'], engine: 'recorder'),
      ..._drain(DateTime(2026, 11, 21, 23), const Duration(hours: 2), 70, on: const ['night', 'headband', 'share', 'wifi-lock'], engine: 'recorder'),
    ];

    test('each group gets the rate it adds; things always on together stay one group', () {
      final r = batteryReport(made());
      final keys = {for (final g in r.groups) g.use.key};
      expect(keys, {'app-open+screen', 'signal', 'headband+night', 'share+wifi-lock'});
      expect(_adds(r, 'screen'), closeTo(150, 0.5));
      expect(_adds(r, 'signal'), closeTo(60, 0.5));
      expect(_adds(r, 'night'), closeTo(40, 0.5));
      expect(_adds(r, 'share'), closeTo(30, 0.5));
      final signal = r.groups.firstWhere((g) => g.use.key == 'signal');
      expect(signal.use.rate, closeTo(210, 0.5), reason: 'while on, the whole phone');
      expect(signal.use.screenShare, closeTo(1, 1e-9));
      expect(signal.use.cpuShare, closeTo(0.4, 0.01));
      expect(r.combos.map((c) => c.key), contains('app-open+screen+signal'));
      expect(r.days, 3, reason: 'the 20th, the 21st and the night into the 22nd');
    });

    test('the advice says what it costs, what it adds, that it is mostly the screen, and the processor', () {
      final r = batteryReport(made());
      final screen = r.groups.firstWhere((g) => g.use.members.contains('screen'));
      final signal = r.groups.firstWhere((g) => g.use.key == 'signal');
      final words = advice(signal, capacity: r.capacity, screen: screen)!;
      expect(words, startsWith('Signal tab: 210 mAh an hour while on'));
      expect(words, contains('it adds about 60 mAh an hour'));
      expect(words, contains('mostly the screen being on'));
      expect(words, contains('processor busy 40 %'));
      final night = r.groups.firstWhere((g) => g.use.members.contains('night'));
      expect(groupLabel(night.use), 'Headband link, Night recording');
      expect(groupLabel(screen.use), 'App open on the screen', reason: 'the screen goes unsaid beside the open app');
      expect(sentences(adviceParts(signal, capacity: r.capacity, screen: screen)), startsWith('4.2 % of the battery an hour. It adds'));
      expect(advice(night, capacity: r.capacity), isNot(contains('screen')));
    });

    test('under 15 minutes a group gets no number; a single combination is its own rate', () {
      final r = batteryReport(_drain(DateTime(2026, 11, 20, 8), const Duration(minutes: 10), 100, on: const ['export']));
      expect(r.groups.single.adds, isNull);
      expect(advice(r.groups.single), isNull);
      final one = batteryReport(_drain(DateTime(2026, 11, 20, 8), const Duration(hours: 1), 100, on: const ['export']));
      expect(one.groups.single.adds, closeTo(100, 0.5));
    });

    test('nothing measured: an empty report', () {
      expect(batteryReport(const []).empty, isTrue);
    });
  });

  group('the headband\'s gauge', () {
    final t0 = DateTime(2026, 11, 19, 23);
    String at(int min) => t0.add(Duration(minutes: min)).toIso8601String();

    test('readings from the night log: the headband\'s lines, not the phone\'s', () {
      final r = headbandReadings([
        '${at(0)} connected BB Black E7:05 serial 1 battery 100% signal -60 dBm',
        '${at(1)} phone battery 93% charge 3556000 uAh current 84000 uA unplugged temp 22.5 C',
        '${at(2)} samples 2512 (+2520) battery 87%',
      ]);
      expect([for (final (_, v) in r) v], [100, 87]);
    });

    test('a steady drain: a straight line, stuck 100 % and 0-2 % left out', () {
      final r = headbandRun([
        (t0, 100),
        for (var m = 0; m <= 300; m += 10) (t0.add(Duration(minutes: 5 + m)), 90 - m ~/ 10),
        (t0.add(const Duration(minutes: 310)), 1),
      ])!;
      expect(r.first, 90);
      expect(r.last, 60);
      expect(r.perHour, closeTo(6, 0.1));
      expect(r.stuckAt, isNull);
      expect(headbandWords(r), contains('6.0 % an hour'));
    });

    test('2026-11-19: 6 % for nine hours between 96-100 % readings is stuck, not the battery', () {
      final readings = [
        for (var m = 0; m < 540; m++) (t0.add(Duration(minutes: m)), m % 7 == 0 ? 96 + m % 5 : 6),
      ];
      final r = headbandRun(readings)!;
      expect(r.stuckAt, 6);
      expect(headbandWords(r), contains('stuck at 6 %'));
    });

    test('a value seen again after a charge is not stuck; the trend starts at the charge', () {
      final r = headbandRun([
        (t0, 50),
        (t0.add(const Duration(minutes: 30)), 45),
        (t0.add(const Duration(minutes: 60)), 90),
        for (var m = 1; m <= 40; m++) (t0.add(Duration(minutes: 60 + 6 * m)), 90 - m),
        (t0.add(const Duration(hours: 5)), 50),
      ])!;
      expect(r.first, 90);
      expect(r.perHour, closeTo(10, 0.5));
    });

    test('only stuck readings: no rate, and the words say why', () {
      final r = headbandRun([for (var m = 0; m < 60; m++) (t0.add(Duration(minutes: m)), 100)])!;
      expect(r.first, isNull);
      expect(headbandWords(r), contains('gauge was stuck at 100 %'));
    });
  });

  group('contact and link', () {
    test('contact by blocks of three hours: each channel\'s median in kΩ; off the head left out', () {
      final b = contactByBlock([
        {'t': DateTime(2026, 11, 20, 9).toIso8601String(), 'kind': 'contact', 'ohms': {'O1': 100000, 'O2': null}},
        {'t': DateTime(2026, 11, 20, 10).toIso8601String(), 'kind': 'contact', 'ohms': {'O1': 300000, 'O2': 200000}},
        {'t': DateTime(2026, 11, 20, 11).toIso8601String(), 'kind': 'contact', 'ohms': {'O1': 200000}},
        {'t': DateTime(2026, 11, 20, 23).toIso8601String(), 'kind': 'contact', 'ohms': {'O1': 150000}},
        {'t': DateTime(2026, 11, 20, 23).toIso8601String(), 'kind': 'power'},
      ]);
      expect(b.map((x) => x.fromHour), [9, 21]);
      expect(b.first.medianKohm, {'O1': 200.0, 'O2': 200.0});
      expect(b.first.readings, 3);
    });

    test('drops by cause, the median time back and the signal at connecting', () {
      final s = linkSummary([
        (sub: 'recorder', msg: 'connected BB Black', data: {'rssi': -70}),
        (sub: 'recorder', msg: 'headband link dropped: out of range', data: null),
        (sub: 'recorder', msg: 'headband back after a drop (out of range)', data: {'reconnect_ms': 18000}),
        (sub: 'recorder', msg: 'headband link dropped: no data for 40 s', data: null),
        (sub: 'recorder', msg: 'headband back after a drop (no data for 40 s)', data: {'reconnect_ms': 22000}),
        (sub: 'recorder', msg: 'connected BB Black', data: {'rssi': -80}),
        (sub: 'share', msg: 'connected', data: {'rssi': -10}),
      ]);
      expect(s.drops, 2);
      expect(s.causes, {'out of range': 1, 'no data for 40 s': 1});
      expect(s.medianBack, const Duration(seconds: 20));
      expect(s.medianRssi, -75);
      expect(s.connects, 2);
    });
  });
}
