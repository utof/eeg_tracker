// A file set that goes on from the one before it without a gap (a roll-over, DECISIONS 1036) is joined to it sample
// to sample: the 0.5 s rule that says what is unbroken inside one file holds between two sets of one recording too.
// The laptop's twin: analysis/tests/test_roll_over_join.py, on the same numbers.
import 'dart:io';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('roll_join_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final t0 = DateTime(2026, 11, 25, 9, 0, 0);
  var pack = 0;

  /// A set of [batches] batches of 25 samples, the first arriving at [first], one every 100 ms (250 Hz to the sample).
  File set(DateTime start, DateTime first, int batches, {String? recording, bool inRecording = true}) {
    final w = ChunkWriter.open(dir, start, header: brainBitHeader, inRecording: inRecording, recording: recording);
    for (var b = 0; b < batches; b++) {
      w.addBatch(first.add(Duration(milliseconds: 100 * b)), [
        for (var i = 0; i < 25; i++) Sample.four(pack: pack++, o1: pack * 1e-6, o2: 0, t3: 0, t4: 0),
      ]);
    }
    w.close();
    return File('${dir.path}/${w.stem}.f32');
  }

  DateTime ms(int n) => t0.add(Duration(milliseconds: n));

  test('the next set of the same recording, 40 ms late: no held samples at the seam', () {
    pack = 0;
    final a = set(t0, ms(100), 100, recording: 'r1'); // samples of 09:00:00.0 to 09:00:10.0
    final b = set(ms(10000), ms(10140), 100, recording: 'r1'); // its first batch 40 ms later than the clock says
    final layout = joinLayout([a, b]);
    expect(layout.bad.where((x) => x.text == 'BAD_gap'), isEmpty);
    expect(layout.samples, 5000);
    final o1 = layout.channel(0);
    for (var i = 0; i < 5000; i++) {
      expect(o1[i], closeTo(i + 1, 1e-3), reason: 'sample $i'); // every sample once, in order, none held
    }
  });

  test('40 ms early (the batch before came late): nothing changes, nothing is dropped', () {
    pack = 0;
    final a = set(t0, ms(100), 100, recording: 'r1');
    final b = set(ms(10000), ms(10060), 100, recording: 'r1');
    final layout = joinLayout([a, b]);
    expect(layout.bad.where((x) => x.text == 'BAD_gap'), isEmpty);
    expect(layout.parts.where((p) => p.run != null).fold(0, (n, p) => n + p.run!.count), 5000);
  });

  test('a real gap stays a gap: over 0.5 s, another recording, or sets from before Record first', () {
    pack = 0;
    final a = set(t0, ms(100), 100, recording: 'r1');
    final late = set(ms(10000), ms(10700), 100, recording: 'r1'); // 0.6 s of nothing
    expect(joinLayout([a, late]).bad.where((x) => x.text == 'BAD_gap').single, (at: 2500, samples: 150, text: 'BAD_gap'));
    late.deleteSync();
    File('${late.path.substring(0, late.path.length - 4)}.idx').deleteSync();

    final other = set(ms(11000), ms(10140), 100, recording: 'r2');
    expect(joinLayout([a, other]).bad.where((x) => x.text == 'BAD_gap').single, (at: 2500, samples: 10, text: 'BAD_gap'));

    final dir2 = Directory('${dir.path}/old')..createSync();
    final keep = dir;
    dir = dir2;
    final x = set(t0, ms(100), 100, inRecording: false);
    final y = set(ms(10000), ms(10140), 100, inRecording: false);
    dir = keep;
    expect(joinLayout([x, y]).bad.where((x) => x.text == 'BAD_gap').single, (at: 2500, samples: 10, text: 'BAD_gap'));
  });

  test('a sleep window across the seam reads both sides as one stretch; one that starts after it is placed by the clock', () {
    pack = 0;
    final a = set(t0, ms(100), 100, recording: 'r1');
    final b = set(ms(10000), ms(10140), 100, recording: 'r1');
    double unix(int n) => ms(n).microsecondsSinceEpoch / 1e6;
    final across = joinLayout([a, b], windows: [(unix(8000), unix(12000))]);
    expect(across.bad.where((x) => x.text == 'BAD_gap'), isEmpty);
    expect(across.samples, 1000);
    final o1 = across.channel(0);
    for (var i = 0; i < 1000; i++) {
      expect(o1[i], closeTo(2000 + i + 1, 1e-3));
    }
    // two windows, the second inside the second set: the time between them is missing, as between any two windows
    final two = joinLayout([a, b], windows: [(unix(2000), unix(4000)), (unix(14000), unix(16000))]);
    expect(two.bad.where((x) => x.text == 'BAD_gap').single, (at: 500, samples: 2500, text: 'BAD_gap'));
    expect(two.channel(0)[3000], closeTo(3500 + 1, 1e-3));
  });

  test('three sets in a row are one chain', () {
    pack = 0;
    final a = set(t0, ms(100), 50, recording: 'r1');
    final b = set(ms(5000), ms(5130), 50, recording: 'r1');
    final c = set(ms(10000), ms(10160), 50, recording: 'r1');
    final layout = joinLayout([a, b, c]);
    expect(layout.bad.where((x) => x.text == 'BAD_gap'), isEmpty);
    expect(layout.samples, 3750);
  });
}
