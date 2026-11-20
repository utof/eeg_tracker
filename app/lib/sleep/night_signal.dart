// A night's recordings joined on the clock, the way scripts/to_bdf.py joins them before the laptop scores a night:
// runs of unbroken samples are found from the .idx arrival times, placed at their clock time from a start rounded
// down to a whole second, and missing time is filled by holding the last value and marked bad; the end is padded
// to a whole second (bad too). The layout is read first (small); the samples are read one channel at a time, so an
// 8-hour night needs about 58 MB per channel instead of all four at once.
//
// Each file's header (recorder/header.dart) says how wide its records are and which channels they hold; the layout
// reads the channels it is asked for by name (the sleep tools: O1 O2 T3 T4), wherever each file holds them, and a file
// without one is refused in words ([MissingSites]), never read from another channel (DECISIONS 630-639).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../recorder/chunk_writer.dart' show indexBytes;
import '../recorder/header.dart';
import '../recorder/nights.dart' show stemTime;
import '../recorder/packed.dart' show RawReader, openRaw, rawLength;

const int sampleRate = 250;

/// The channels the sleep tools read, in their order (the BrainBit's; header.dart [sleepSites]).
const List<String> channelNames = sleepSites;

/// to_bdf.py: a pause over 0.5 s between batches is missing time.
const double minGapSeconds = 0.5;

/// to_bdf.py: the BDF's physical range, ±400 000 µV (the headband's rails are ±0.4 V).
const double limitMicrovolts = 400000;

/// One stretch of unbroken samples inside a file.
class Run {
  const Run(this.file, this.first, this.count, this.t0, {this.recordBytes = 20, this.columns = const [0, 1, 2, 3]});
  final File file;

  /// Bytes per record in its file (its header's), and where in a record the layout's channels are, in the layout's
  /// order (column k = float k after the counter).
  final int recordBytes;
  final List<int> columns;

  /// Index of its first record in the file.
  final int first;
  final int count;

  /// Unix time of its first sample.
  final double t0;
}

/// A run's place in the joined night, or a stretch held at the previous value.
class Part {
  const Part.run(this.run, this.at) : count = 0;
  const Part.hold(this.at, this.count) : run = null;
  final Run? run;
  final int at;
  final int count;
  int get length => run?.count ?? count;
}

/// Missing time in samples from the start of the night: `BAD_gap` or `BAD_padding`.
typedef Bad = ({int at, int samples, String text});

class NightLayout {
  NightLayout(this.startUnix, this.samples, this.parts, this.bad, {this.names = channelNames});

  /// The channels it reads, in this order: [channel]'s index and [forEachRow]'s row.
  final List<String> names;

  /// The joined night's first sample, a whole second.
  final int startUnix;

  /// Samples of the joined night: gaps and the end padding included, a whole number of seconds.
  final int samples;
  final List<Part> parts;
  final List<Bad> bad;

  int get missingSamples => bad.where((b) => b.text == 'BAD_gap').fold(0, (s, b) => s + b.samples);

  /// One channel of the night in µV: held over gaps, clipped to ±400 000 µV, as the laptop's BDF holds it.
  Float64List channel(int c) {
    final out = Float64List(samples);
    var last = double.nan;
    var pending = 0; // a gap before the first run holds that run's first value
    RawReader? open;
    File? openFile;
    try {
      for (final p in parts) {
        final run = p.run;
        if (run == null) {
          if (last.isNaN) {
            pending = p.at + p.count;
          } else {
            out.fillRange(p.at, p.at + p.count, last);
          }
          continue;
        }
        if (openFile?.path != run.file.path) {
          open?.closeSync();
          open = openRaw(run.file);
          openFile = run.file;
        }
        _readChannel(open!, run, c, out, p.at);
        if (last.isNaN && pending > 0) out.fillRange(0, pending, out[p.at]);
        last = out[p.at + run.count - 1];
      }
    } finally {
      open?.closeSync();
    }
    final end = parts.fold(0, (e, p) => math.max(e, p.at + p.length));
    out.fillRange(end, samples, last);
    for (var i = 0; i < samples; i++) {
      out[i] = out[i].clamp(-limitMicrovolts, limitMicrovolts);
    }
    return out;
  }

  /// Samples [from, to) of [channel] (c), the very values it gives there, reading only the records of that stretch
  /// (and one record for a value held into it): "Sleep so far" prepares an 80-minute window of a long night this way
  /// (so_far.dart). Past the night's end, the last value held, as [channel] does up to [samples].
  Float64List channelRange(int c, int from, int to) {
    final out = Float64List(math.max(0, to - from));
    if (out.isEmpty) return out;
    RawReader? open;
    File? openFile;
    RawReader reader(File f) {
      if (openFile?.path != f.path) {
        open?.closeSync();
        open = openRaw(f);
        openFile = f;
      }
      return open!;
    }

    // record [k] of [r]: 0 where the file has shrunk under us, as [channel] keeps it
    double valueAt(Run r, int k) {
      final rb = r.recordBytes;
      final f = reader(r.file)..setPositionSync((r.first + k) * rb);
      final b = f.readSync(rb);
      return b.length < rb ? 0 : ByteData.sublistView(b).getFloat32(4 + 4 * r.columns[c], Endian.little) * 1e6;
    }

    try {
      Run? prev; // the run before the current part: its last value is held over a gap
      var end = 0;
      for (var i = 0; i < parts.length; i++) {
        final p = parts[i], run = p.run;
        end = math.max(end, p.at + p.length);
        final lo = math.max(p.at, from), hi = math.min(p.at + p.length, to);
        if (lo < hi) {
          if (run != null) {
            _readRange(reader(run.file), run, lo - p.at, hi - lo, c, out, lo - from);
          } else {
            // a gap holds the last value before it; one before the first run holds that run's first value
            final next = parts.skip(i + 1).map((q) => q.run).nonNulls.firstOrNull;
            final v = prev != null ? valueAt(prev, prev.count - 1) : (next == null ? 0.0 : valueAt(next, 0));
            out.fillRange(lo - from, hi - from, v);
          }
        }
        if (run != null) prev = run;
        if (p.at >= to) break;
      }
      if (to > end && prev != null) out.fillRange(math.max(end, from) - from, out.length, valueAt(prev, prev.count - 1));
    } finally {
      open?.closeSync();
    }
    for (var i = 0; i < out.length; i++) {
      out[i] = out[i].clamp(-limitMicrovolts, limitMicrovolts);
    }
    return out;
  }

  /// [n] records of [run] from its record [skip], the layout's channel [c], into out[at..]; zeros past a file that
  /// shrank.
  static void _readRange(RawReader f, Run run, int skip, int n, int c, Float64List out, int at) {
    const chunk = 16384; // records per read
    final rb = run.recordBytes, offset = 4 + 4 * run.columns[c];
    f.setPositionSync((run.first + skip) * rb);
    for (var done = 0; done < n;) {
      final want = math.min(chunk, n - done);
      final bytes = f.readSync(want * rb);
      final view = ByteData.sublistView(bytes);
      final got = bytes.length ~/ rb;
      for (var k = 0; k < got; k++) {
        out[at + done + k] = view.getFloat32(k * rb + offset, Endian.little) * 1e6;
      }
      if (got < want) break;
      done += want;
    }
  }

  /// Every sample of the night in time order, all [names] at once, the values [channel] gives (held over gaps, clipped
  /// to ±400 000 µV), with whether it was filled in (a gap or the end padding). [row] is reused between calls. For the
  /// detectors' pass over a whole night: one 330 KB read at a time.
  void forEachRow(void Function(Float64List row, bool missing) emit) {
    final width = names.length;
    final row = Float64List(width);
    var started = false;
    var pending = 0; // a gap before the first run holds that run's first value
    RawReader? open;
    File? openFile;
    try {
      for (final p in parts) {
        final run = p.run;
        if (run == null) {
          if (started) {
            for (var i = 0; i < p.count; i++) {
              emit(row, true);
            }
          } else {
            pending += p.count;
          }
          continue;
        }
        if (openFile?.path != run.file.path) {
          open?.closeSync();
          open = openRaw(run.file);
          openFile = run.file;
        }
        const chunk = 16384; // records per read
        final rb = run.recordBytes, cols = run.columns;
        open!.setPositionSync(run.first * rb);
        var done = 0;
        while (done < run.count) {
          final n = math.min(chunk, run.count - done);
          final bytes = open.readSync(n * rb);
          final view = ByteData.sublistView(bytes);
          final got = bytes.length ~/ rb;
          for (var k = 0; k < got; k++) {
            for (var c = 0; c < width; c++) {
              row[c] = (view.getFloat32(k * rb + 4 + 4 * cols[c], Endian.little) * 1e6)
                  .clamp(-limitMicrovolts, limitMicrovolts);
            }
            if (!started) {
              started = true;
              for (var i = 0; i < pending; i++) {
                emit(row, true);
              }
            }
            emit(row, false);
          }
          done += got;
          if (got < n) break; // the file shrank under us: [channel] keeps zeros there, so do we
        }
        if (done < run.count) {
          row.fillRange(0, width, 0);
          started = true;
          for (var i = done; i < run.count; i++) {
            emit(row, false);
          }
        }
      }
    } finally {
      open?.closeSync();
    }
    final end = parts.fold(0, (e, p) => math.max(e, p.at + p.length));
    for (var i = end; i < samples; i++) {
      emit(row, true);
    }
  }

  static void _readChannel(RawReader f, Run run, int c, Float64List out, int at) {
    const chunk = 16384; // records per read
    final rb = run.recordBytes, offset = 4 + 4 * run.columns[c];
    f.setPositionSync(run.first * rb);
    for (var done = 0; done < run.count;) {
      final n = math.min(chunk, run.count - done);
      final bytes = f.readSync(n * rb);
      final view = ByteData.sublistView(bytes);
      final got = bytes.length ~/ rb;
      for (var k = 0; k < got; k++) {
        out[at + done + k] = view.getFloat32(k * rb + offset, Endian.little) * 1e6;
      }
      if (got < n) break; // the file shrank under us: keep what was there
      done += n;
    }
  }
}

/// to_bdf.py `runs`: one file's runs of unbroken samples, from its .idx (one run at the file name's time if the
/// index is missing or empty). [f32] by its plain name, also when it is packed (`.f32.gz`). The channels [names] are
/// picked from its header by name ([who] needs them): [MissingSites] when it lacks one, [HeaderError] for a header
/// that cannot be used.
List<Run> runsOf(File f32, {List<String> names = channelNames, String who = 'The sleep report'}) {
  final header = readHeader(f32);
  final recordBytes = header.recordBytes;
  final records = rawLength(f32) ~/ recordBytes;
  if (records == 0) return const [];
  final columns = List<int>.unmodifiable(header.pick(names, who: who));
  Run run(int first, int count, double t0) => Run(f32, first, count, t0, recordBytes: recordBytes, columns: columns);
  final idxFile = File('${f32.path.substring(0, f32.path.length - 4)}.idx');
  final rows = <(double, int)>[];
  if (idxFile.existsSync()) {
    final b = ByteData.sublistView(idxFile.readAsBytesSync());
    for (var o = 0; o + indexBytes <= b.lengthInBytes; o += indexBytes) {
      final i = b.getUint64(o + 8, Endian.little);
      if (i < records) rows.add((b.getFloat64(o, Endian.little), i)); // a row can outlive a crash that lost samples
    }
  }
  if (rows.isEmpty) {
    final t = stemTime(f32.uri.pathSegments.last);
    return t == null ? const [] : [run(0, records, t.millisecondsSinceEpoch / 1000)];
  }
  final t0 = [
    for (var k = 0; k < rows.length; k++)
      rows[k].$1 - ((k + 1 < rows.length ? rows[k + 1].$2 : records) - rows[k].$2) / sampleRate,
  ]; // a batch arrives just after its last sample
  final out = <Run>[];
  var start = 0;
  for (var k = 1; k < rows.length; k++) {
    if (t0[k] - rows[k - 1].$1 > minGapSeconds) {
      out.add(run(rows[start].$2, rows[k].$2 - rows[start].$2, t0[start]));
      start = k;
    }
  }
  out.add(run(rows[start].$2, records - rows[start].$2, t0[start]));
  final before = rows.first.$2;
  if (before > 0) {
    // samples before the first index row (should not happen) join the first run
    final r = out.first;
    out[0] = run(0, r.count + before, r.t0 - before / sampleRate);
  }
  return out;
}

/// to_bdf.py `join` for the night's `.f32` files (oldest first), without reading the samples. The layout reads the
/// channels [names] (the sleep tools' O1 O2 T3 T4 unless said), picked by name in each file: a file without one is
/// refused ([MissingSites], naming what [who] needs and what the file has).
NightLayout joinLayout(List<File> f32Files, {List<String> names = channelNames, String who = 'The sleep report'}) {
  final runs = [for (final f in f32Files) ...runsOf(f, names: names, who: who)];
  if (runs.isEmpty) return NightLayout(0, 0, const [], const [], names: names);
  _stableSortByT0(runs);
  final start = _wholeSecond(runs.first.t0);
  final parts = <Part>[];
  final bad = <Bad>[];
  var n = 0;
  for (final r in runs) {
    final want = roundHalfEven((r.t0 - start) * sampleRate);
    if (want > n) {
      parts.add(Part.hold(n, want - n));
      bad.add((at: n, samples: want - n, text: 'BAD_gap'));
      n = want;
    }
    // A run more than a second early (clocks disagree) is kept after the one before, as on the laptop.
    parts.add(Part.run(r, n));
    n += r.count;
  }
  final pad = (sampleRate - n % sampleRate) % sampleRate;
  if (pad > 0) bad.add((at: n, samples: pad, text: 'BAD_padding'));
  return NightLayout(start, n + pad, parts, bad, names: names);
}

void _stableSortByT0(List<Run> runs) {
  final indexed = [for (var i = 0; i < runs.length; i++) (i, runs[i])];
  indexed.sort((a, b) {
    final c = a.$2.t0.compareTo(b.$2.t0);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < runs.length; i++) {
    runs[i] = indexed[i].$2;
  }
}

/// `datetime.fromtimestamp(t).replace(microsecond=0)`: rounded to microseconds, then down to the second.
int _wholeSecond(double t) {
  var whole = t.floor();
  if (roundHalfEven((t - whole) * 1e6) >= 1000000) whole += 1;
  return whole;
}

/// Python's round(): halves go to the even neighbour.
int roundHalfEven(double v) {
  final f = v.floorToDouble();
  final d = v - f;
  if (d > 0.5) return f.toInt() + 1;
  if (d < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// score_sleep.py `gap_mask`: a 30 s epoch with over 5 s of bad (filled-in) time is not scored.
List<bool> gapEpochs(NightLayout layout, int epochs, {int epochSamples = 30 * sampleRate}) {
  final missing = List<int>.filled(epochs, 0);
  for (final b in layout.bad) {
    final lo = b.at, hi = b.at + b.samples;
    for (var e = lo ~/ epochSamples; e < epochs && e * epochSamples < hi; e++) {
      missing[e] += math.min(hi, (e + 1) * epochSamples) - math.max(lo, e * epochSamples);
    }
  }
  return [for (final m in missing) m > 5 * sampleRate];
}
