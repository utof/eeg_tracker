// What the Signal view keeps and works out from the live signal (DECISIONS 594), for 4, 8 and 16 channels: the rings
// and looking back, the filters, RMS, mains, flat / railed / swings, the bands, missing packets and the measured rate.
// Every expected number comes from the made-up signal's own definition (a sine of amplitude A has RMS A/sqrt(2)).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart' show Quality;
import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/signal/live_signal.dart';
import 'package:flutter_test/flutter_test.dart';

/// [seconds] of signal for [n] channels in 25-sample batches; channel c's value at sample i is [f](c, i).
void feed(LiveSignal s, int n, double seconds, double Function(int c, int i) f, {int startPack = 0, DateTime? start}) {
  final t0 = start ?? DateTime(2026, 11, 20, 1, 0);
  final total = (seconds * liveRate).round();
  for (var at = 0; at < total; at += 25) {
    final len = math.min(25, total - at);
    final v = Float32List(len * n);
    final p = Int32List(len);
    for (var k = 0; k < len; k++) {
      final i = s.count + k;
      p[k] = (startPack + at + k) % 2048;
      for (var c = 0; c < n; c++) {
        v[k * n + c] = f(c, i);
      }
    }
    final arrival = t0.add(Duration(microseconds: ((at + len) * 1e6 / liveRate).round()));
    expect(s.add(LiveBatch(arrival: arrival, values: v, channels: n, packs: p)), isTrue);
  }
}

double sine(double hz, double amp, int i) => amp * math.sin(2 * math.pi * hz * i / liveRate);

List<String> names(int n) => [for (var i = 1; i <= n; i++) 'E$i'];

void main() {
  for (final n in [4, 8, 16]) {
    test('$n channels: every channel kept apart, the 5-minute ring wraps, looking back works', () {
      final s = LiveSignal(names: names(n), keepSeconds: 4, traceSeconds: 2);
      feed(s, n, 6, (c, i) => c * 1000.0 + i); // each channel its own ramp
      expect(s.count, 6 * liveRate);
      expect(s.oldest, 2 * liveRate); // 4 s kept of 6
      for (var c = 0; c < n; c++) {
        expect(s.latest(c), c * 1000.0 + s.count - 1);
        final w = s.window(c, TraceFilter.raw, 10, end: s.count - 100);
        expect(w.first, c * 1000.0 + s.count - 110);
        expect(w.last, c * 1000.0 + s.count - 101);
      }
      // older than kept: clipped, never wrong values
      final far = s.window(0, TraceFilter.raw, 3000);
      expect(far.length, 4 * liveRate);
      expect(far.first, s.oldest.toDouble());
      // the filtered traces keep their own 2 s
      expect(s.window(1, TraceFilter.band, 3000).length, 2 * liveRate);
    });
  }

  test('a batch with another channel count is refused', () {
    final s = LiveSignal(names: names(4));
    expect(s.add(LiveBatch(arrival: DateTime(2026), values: Float32List(16), channels: 8)), isFalse);
    expect(s.count, 0);
  });

  test('RMS of 1-40 Hz: a 10 Hz sine of 20 µV reads 14.1 µV, over a 50 mV electrode offset', () {
    final s = LiveSignal(names: names(4));
    feed(s, 4, 8, (c, i) => 50000 + sine(10, 20, i));
    final nums = s.numbers(0);
    expect(nums.rmsUv, closeTo(20 / math.sqrt2, 20 / math.sqrt2 * 0.06));
    expect(nums.flat, isFalse);
    expect(nums.railed, isFalse);
    // the 1-40 Hz trace sits around zero, the raw one at the offset
    final band = s.window(0, TraceFilter.band, 500);
    expect(band.reduce(math.max), closeTo(20, 2));
    expect(s.window(0, TraceFilter.raw, 1).first, greaterThan(49900));
  });

  test('the mains: a 50 Hz sine of 30 µV reads 21 µV of mains and almost nothing in 1-40 Hz or through the notch', () {
    final s = LiveSignal(names: names(4));
    feed(s, 4, 8, (c, i) => sine(50, 30, i));
    final nums = s.numbers(0);
    expect(nums.lineUv, closeTo(30 / math.sqrt2, 30 / math.sqrt2 * 0.08));
    expect(nums.rmsUv, lessThan(1.5));
    final notched = s.window(0, TraceFilter.notch, 500);
    expect(notched.reduce(math.max) - notched.reduce(math.min), lessThan(6));
  });

  test('flat, railed and large swings, with the detectors\' own limits', () {
    final s = LiveSignal(names: names(4));
    feed(s, 4, 3, (c, i) => switch (c) {
      0 => 1234.0, // a dead channel
      1 => Quality.railUv + 10, // at the amplifier's limit
      2 => (i ~/ 25).isEven ? 400.0 : -400.0, // 800 µV jumps
      _ => sine(10, 20, i),
    });
    expect([for (var c = 0; c < 4; c++) s.numbers(c).flat], [true, true, false, false]);
    expect([for (var c = 0; c < 4; c++) s.numbers(c).railed], [false, true, false, false]);
    expect([for (var c = 0; c < 4; c++) s.numbers(c).swinging], [false, false, true, false]);
  });

  test('the bands: 2, 6, 10 and 20 Hz each land in their own band', () {
    final s = LiveSignal(names: names(4));
    const hz = [2.0, 6.0, 10.0, 20.0];
    feed(s, 4, 8, (c, i) => sine(hz[c], 20, i));
    for (var c = 0; c < 4; c++) {
      final b = s.numbers(c).bands!;
      expect(b.fold(0.0, (a, x) => a + x), closeTo(1, 1e-9));
      expect(b[c], greaterThan(0.8), reason: '${hz[c]} Hz: $b');
    }
    expect(bandShares(Float32List(500), liveRate), isNull); // nothing: no shares
  });

  test('not enough signal yet: no numbers, and no flags', () {
    final s = LiveSignal(names: names(4));
    feed(s, 4, 0.5, (c, i) => 0);
    final nums = s.numbers(0);
    expect(nums.rmsUv, isNull);
    expect(nums.flat, isFalse);
    expect(nums.bands, isNull);
  });

  test('missing packets: a gap of 5 counts 5 in 1 gap; the 11-bit wrap is no gap; a new stretch is not compared', () {
    final s = LiveSignal(names: names(4));
    feed(s, 4, 1, (c, i) => 0, startPack: 2000); // 2000 .. 2249 wraps at 2048
    expect(s.packets.missing, 0);
    expect(s.numbered, isTrue);
    feed(s, 4, 0.1, (c, i) => 0, startPack: (2250 + 5) % 2048);
    expect(s.packets.missing, 5);
    expect(s.packets.gaps, 1);
    s.newRun();
    feed(s, 4, 0.1, (c, i) => 0, startPack: 700);
    expect(s.packets.missing, 5);
    expect(s.runs, 2);
  });

  test('times: each sample spread back from its batch\'s arrival; the rate measured from them', () {
    final s = LiveSignal(names: names(4));
    final t0 = DateTime(2026, 11, 20, 1, 0);
    feed(s, 4, 12, (c, i) => 0, start: t0);
    expect(s.timeOf(s.count - 1), t0.add(const Duration(seconds: 12)).millisecondsSinceEpoch.toDouble());
    expect(s.timeOf(s.count - 2), closeTo(s.timeOf(s.count - 1) - 4, 1e-6));
    expect(s.measuredRate(), closeTo(250, 0.5));
  });

  test('the app\'s 4-channel record in volts becomes µV, with its packet numbers', () {
    final b = LiveBatch.fromSamples(DateTime(2026), [Sample.four(pack: 7, o1: 1e-5, o2: -2e-5, t3: 0.05, t4: 0)]);
    expect(b.channels, 4);
    expect(b.values, [closeTo(10, 1e-4), closeTo(-20, 1e-4), closeTo(50000, 0.01), 0]);
    expect(b.packs, [7]);
  });

  test('the auto scale: the next of 10, 20, 50, 100 ... above the largest swing from the mean', () {
    expect(autoScaleUv(Float32List.fromList([0, 0])), 10);
    expect(autoScaleUv(Float32List.fromList([-37, 37])), 50);
    expect(autoScaleUv(Float32List.fromList([1000, 1120])), 100);
    expect(autoScaleUv(Float32List.fromList([-150, 150])), 200);
    expect(autoScaleUv(Float32List.fromList([-3000, 3000])), 5000);
    expect(autoScaleUv(Float32List(0)), 50);
  });
}
