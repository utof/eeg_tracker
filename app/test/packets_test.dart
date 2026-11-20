import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/packets.dart';
import 'package:flutter_test/flutter_test.dart';

List<Sample> rows(Iterable<int> packs) => [for (final p in packs) Sample.four(pack: p, o1: 0, o2: 0, t3: 0, t4: 0)];

void main() {
  test('a normal stretch has nothing missing or repeated', () {
    final a = PacketAccount()..add(rows(List.generate(500, (i) => i)));
    expect(a.counts.samples, 499); // the first sample has nothing before it
    expect(a.counts.missing, 0);
    expect(a.counts.repeated, 0);
    expect(a.counts.longestGap, 0);
  });

  test('a gap counts the numbers skipped, and the longest one is kept', () {
    final a = PacketAccount()..add(rows([10, 11, 15, 16, 17, 19, 20]));
    expect(a.counts.missing, 3 + 1);
    expect(a.counts.gaps, 2);
    expect(a.counts.longestGap, 3);
    expect(a.counts.repeated, 0);
  });

  test('a repeated number counts once per repeat, also across batches', () {
    final a = PacketAccount()
      ..add(rows([5, 6, 6]))
      ..add(rows([6, 7]));
    expect(a.counts.repeated, 2);
    expect(a.counts.missing, 0);
  });

  test('the wrap from 2047 to 0 is not a gap', () {
    final a = PacketAccount()..add(rows([2045, 2046, 2047, 0, 1, 2]));
    expect(a.counts.missing, 0);
    expect(a.counts.repeated, 0);
  });

  test('a gap over the wrap is counted: 2046 to 1 skips 2047 and 0', () {
    final a = PacketAccount()..add(rows([2046, 1]));
    expect(a.counts.missing, 2);
    expect(a.counts.longestGap, 2);
  });

  test('a counter that wraps later (uint32) is the same modulo 2048', () {
    final a = PacketAccount()..add(rows([65534, 65535, 0, 1, 4]));
    expect(a.counts.missing, 2);
    expect(a.counts.repeated, 0);
  });

  test('a number going backwards is a repeat, and the stream is followed from there', () {
    final a = PacketAccount()..add(rows([100, 101, 99, 100, 101, 102]));
    expect(a.counts.repeated, 1); // 101 -> 99
    expect(a.counts.missing, 0); // then 99, 100, 101, 102 are in order
  });

  test('a new run is not compared with the last number of the run before', () {
    final a = PacketAccount()
      ..add(rows([10, 11, 12]))
      ..startRun()
      ..add(rows([700, 701]));
    expect(a.counts.missing, 0);
    expect(a.counts.repeated, 0);
    expect(a.counts.samples, 3);
  });

  test('the counts survive JSON and a bad file gives zeros', () {
    final a = PacketAccount()..add(rows([1, 2, 5, 5]));
    final back = PacketCounts.fromJson(a.counts.toJson());
    expect(back.logLine(), a.counts.logLine());
    expect(a.counts.logLine(), 'packets: 3 samples, missing 2 in 1 gaps, repeated 1, longest gap 2 samples');
    expect(PacketCounts.fromJson('x').missing, 0);
    expect(PacketCounts.fromJson({'missing': -3}).missing, 0);
  });
}
