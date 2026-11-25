// Writes one recorder run as <stamp>.f32 + <stamp>.idx + <stamp>.log + <stamp>.header.json, byte for byte the layout of
// scripts/record_night.py (docs/data-format.md), so scripts/to_bdf.py joins phone and laptop files alike. A record is
// the counter and one float32 per channel; the header (header.dart) says how many and which (DECISIONS 630-639).
import 'dart:io';
import 'dart:typed_data';

import 'header.dart';

/// One sample: the device's packet (BrainBit) or sequence (DIY board) number, and one value per channel in volts, in
/// the recording's channel order (its header names them).
final class Sample {
  Sample(this.pack, List<double> volts) : volts = volts is Float64List ? volts : Float64List.fromList(volts);

  /// The BrainBit's four channels, in the order it sends them.
  Sample.four({required this.pack, required double o1, required double o2, required double t3, required double t4})
    : volts = Float64List(4)
        ..[0] = o1
        ..[1] = o2
        ..[2] = t3
        ..[3] = t4;

  final int pack;
  final Float64List volts;

  int get channels => volts.length;

  /// The BrainBit's channels, for code that reads only the BrainBit (sessions) or rows already put in its order
  /// ([inOrder]). A sample of any other width has none: asking is an error, never another channel's value.
  double get o1 => _four(0);
  double get o2 => _four(1);
  double get t3 => _four(2);
  double get t4 => _four(3);

  double _four(int i) {
    if (volts.length != 4) throw StateError('a ${volts.length}-channel sample has no BrainBit channels O1 O2 T3 T4');
    return volts[i];
  }

  /// This sample's channels [idx] (header.dart `pick`), in that order.
  Sample inOrder(List<int> idx) => Sample(pack, Float64List.fromList([for (final i in idx) volts[i]]));

  @override
  bool operator ==(Object other) {
    if (other is! Sample || other.pack != pack || other.volts.length != volts.length) return false;
    for (var i = 0; i < volts.length; i++) {
      if (other.volts[i] != volts[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(pack, Object.hashAll(volts));

  @override
  String toString() => 'Sample($pack, $volts)';
}

/// [rows] with their channels [idx] in that order; [rows] itself when [idx] is null (already in order).
List<Sample> inOrder(List<Sample> rows, List<int>? idx) => idx == null ? rows : [for (final s in rows) s.inOrder(idx)];

/// The BrainBit's `.f32` record `<I4f`: uint32 packet number, then 4 float32 volts, little-endian; any file set from
/// before the header. Others: [RecordingHeader.recordBytes].
const int recordBytes = 20;

/// `.idx` record `<dQ`: float64 unix arrival time in seconds, uint64 index of the batch's first sample.
const int indexBytes = 16;

/// Local time as a file stem, `YYYY-MM-DD-HHMMSS` (the laptop's `%Y-%m-%d-%H%M%S`).
String fileStem(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}-'
    '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

/// Local time as in the laptop's `.log`: `2026-11-18T02:40:13.123` (no zone).
String logTime(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}T'
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

String _two(int v) => v.toString().padLeft(2, '0');

/// Seconds since the unix epoch as a float, like Python's `time.time()`.
double unixSeconds(DateTime t) => t.microsecondsSinceEpoch / 1e6;

/// Adds one line to a closed run's `.log`: drops and reconnect tries happen after its data files are closed.
void appendLogLine(File log, String message, DateTime at) =>
    log.writeAsStringSync('${logTime(at)} $message\n', mode: FileMode.append, flush: true);

/// Buffers samples in memory; [append] adds them to the files (call it about once a second) and
/// [sync] also flushes them to disk with fsync (about every 10 s). Add-only: nothing is ever rewritten.
class ChunkWriter {
  ChunkWriter._(this.stem, this.header, this.opened, this._data, this._index, this._log) : _recordBytes = header.recordBytes;

  /// Opens a new file set in [dir] named after [start], its [header] (the BrainBit's unless said) written first. If
  /// that stem is taken (two runs in the same second), the next free second is used, so two runs never share one
  /// `.idx` numbering.
  static ChunkWriter open(Directory dir, DateTime start, {RecordingHeader? header, bool inRecording = false, String? recording}) {
    var h = header ?? brainBitHeader;
    dir.createSync(recursive: true);
    var t = start;
    while (File('${dir.path}/${fileStem(t)}.f32').existsSync()) {
      t = t.add(const Duration(seconds: 1));
    }
    final stem = fileStem(t);
    if (inRecording) h = h.inRecording(recording ?? stem);
    writeHeader(File('${dir.path}/$stem.f32'), h);
    RandomAccessFile f(String ext) => File('${dir.path}/$stem.$ext').openSync(mode: FileMode.append);
    return ChunkWriter._(stem, h, start, f('f32'), f('idx'), f('log'));
  }

  final String stem;

  /// When the set was opened (the caller's clock): a long recording goes on in a new set after a while
  /// (night_recorder.dart, DECISIONS 1035).
  final DateTime opened;

  /// What each record holds; every sample must have [RecordingHeader.count] channels.
  final RecordingHeader header;
  final int _recordBytes;
  final RandomAccessFile _data;
  final RandomAccessFile _index;
  final RandomAccessFile _log;
  final BytesBuilder _dataBuf = BytesBuilder(copy: false);
  final BytesBuilder _indexBuf = BytesBuilder(copy: false);
  int _received = 0; // samples handed to [addBatch]; the next batch's first-sample index
  int _written = 0; // samples appended to the .f32 file
  int _indexBytes = 0; // bytes appended to the .idx file
  bool _closed = false;

  /// Share on Wi-Fi's tap (lib/share/isolate.dart): every batch any recording buffers, with its run and the index
  /// of its first sample. It only sends the batch to another isolate. One per isolate; a tap that throws is
  /// dropped, so it can never cost a sample.
  static void Function(String stem, int first, DateTime arrival, List<Sample> samples)? onBatch;

  /// The Signal view's tap during a night (lib/signal/live_tap.dart, DECISIONS 595), beside [onBatch] and on the same
  /// terms: it only gathers the batch for the screen, and one that throws is dropped.
  static void Function(String stem, int first, DateTime arrival, List<Sample> samples)? onLive;

  int get samplesReceived => _received;
  int get samplesWritten => _written;

  /// Bytes of samples in the `.f32` so far.
  int get bytesWritten => _written * _recordBytes;
  bool get isClosed => _closed;

  /// Buffers one batch as it arrived from the headband: one `.idx` row, then one `.f32` row per sample. A sample whose
  /// width is not the header's is an error (nothing of the batch is buffered): the file never holds a record its header
  /// does not describe.
  void addBatch(DateTime arrival, List<Sample> samples) {
    if (_closed || samples.isEmpty) return;
    final n = header.count;
    for (final s in samples) {
      if (s.volts.length != n) {
        throw ArgumentError('a ${s.volts.length}-channel sample in a ${header.record} recording ($stem)');
      }
    }
    final idx = ByteData(indexBytes)
      ..setFloat64(0, unixSeconds(arrival), Endian.little)
      ..setUint64(8, _received, Endian.little);
    _indexBuf.add(idx.buffer.asUint8List());
    final rec = ByteData(_recordBytes * samples.length);
    var o = 0;
    for (final s in samples) {
      rec.setUint32(o, s.pack & 0xFFFFFFFF, Endian.little);
      final v = s.volts;
      for (var c = 0; c < n; c++) {
        rec.setFloat32(o + 4 + 4 * c, v[c], Endian.little);
      }
      o += _recordBytes;
    }
    _dataBuf.add(rec.buffer.asUint8List());
    _received += samples.length;
    final tap = onBatch;
    if (tap != null) {
      try {
        tap(stem, _received - samples.length, arrival, samples);
      } catch (_) {
        onBatch = null;
      }
    }
    final live = onLive;
    if (live != null) {
      try {
        live(stem, _received - samples.length, arrival, samples);
      } catch (_) {
        onLive = null;
      }
    }
  }

  /// One line in the `.log`, written at once (`ISO-local-time message`). Never throws: a line that cannot be
  /// written (storage full) is lost, and never costs the run.
  void log(String message, {DateTime? at}) {
    if (_closed) return;
    try {
      _log.writeStringSync('${logTime(at ?? DateTime.now())} $message\n');
    } on FileSystemException {
      // storage full or gone: the line is lost
    }
  }

  /// Moves the buffered samples into the files (no fsync). Returns the number of samples added.
  ///
  /// All or nothing: a write that fails (storage full) is cut back to the last whole append in both files, so the
  /// `.f32` never holds part of a record or samples the `.idx` does not cover, and the samples stay buffered for the
  /// next try (or are lost at [close]); the exception is passed on.
  int append() {
    if (_closed) return 0;
    final data = _dataBuf.takeBytes();
    final index = _indexBuf.takeBytes();
    try {
      if (data.isNotEmpty) _data.writeFromSync(data);
      if (index.isNotEmpty) _index.writeFromSync(index);
    } catch (_) {
      _cut(_data, _written * _recordBytes);
      _cut(_index, _indexBytes);
      _dataBuf.add(data);
      _indexBuf.add(index);
      rethrow;
    }
    final n = data.length ~/ _recordBytes;
    _written += n;
    _indexBytes += index.length;
    return n;
  }

  static void _cut(RandomAccessFile f, int length) {
    try {
      f
        ..truncateSync(length)
        ..setPositionSync(length);
    } catch (_) {
      // nothing more can be done for this file
    }
  }

  /// [append], then flush all three files to the storage device (Dart's flush is fsync on Android/Linux).
  void sync() {
    if (_closed) return;
    append();
    _data.flushSync();
    _index.flushSync();
    _log.flushSync();
  }

  /// Saves everything and closes the files. Safe to call twice, and never throws: what cannot be saved (storage
  /// full) is lost, and the files are closed all the same.
  void close() {
    if (_closed) return;
    try {
      sync();
    } catch (_) {
      // the samples still buffered are lost
    }
    _closed = true;
    for (final f in [_data, _index, _log]) {
      try {
        f.closeSync();
      } catch (_) {}
    }
  }
}
