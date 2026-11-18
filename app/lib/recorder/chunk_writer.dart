// Writes one recorder run as <stamp>.f32 + <stamp>.idx + <stamp>.log, byte for byte the layout of
// scripts/record_night.py (docs/data-format.md), so scripts/to_bdf.py joins phone and laptop files alike.
import 'dart:io';
import 'dart:typed_data';

/// One BrainBit sample: packet number and O1 O2 T3 T4 in volts, as the headband sent them.
typedef Sample = ({int pack, double o1, double o2, double t3, double t4});

/// `.f32` record `<I4f`: uint32 packet number, then 4 float32 volts, little-endian.
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

/// Buffers samples in memory; [append] adds them to the files (call it about once a second) and
/// [sync] also flushes them to disk with fsync (about every 10 s). Add-only: nothing is ever rewritten.
class ChunkWriter {
  ChunkWriter._(this.stem, this._data, this._index, this._log);

  /// Opens a new file set in [dir] named after [start]. If that stem is taken (two runs in the same
  /// second), the next free second is used, so two runs never share one `.idx` numbering.
  static ChunkWriter open(Directory dir, DateTime start) {
    dir.createSync(recursive: true);
    var t = start;
    while (File('${dir.path}/${fileStem(t)}.f32').existsSync()) {
      t = t.add(const Duration(seconds: 1));
    }
    final stem = fileStem(t);
    RandomAccessFile f(String ext) => File('${dir.path}/$stem.$ext').openSync(mode: FileMode.append);
    return ChunkWriter._(stem, f('f32'), f('idx'), f('log'));
  }

  final String stem;
  final RandomAccessFile _data;
  final RandomAccessFile _index;
  final RandomAccessFile _log;
  final BytesBuilder _dataBuf = BytesBuilder(copy: false);
  final BytesBuilder _indexBuf = BytesBuilder(copy: false);
  int _received = 0; // samples handed to [addBatch]; the next batch's first-sample index
  int _written = 0; // samples appended to the .f32 file
  bool _closed = false;

  int get samplesReceived => _received;
  int get samplesWritten => _written;
  bool get isClosed => _closed;

  /// Buffers one batch as it arrived from the headband: one `.idx` row, then one `.f32` row per sample.
  void addBatch(DateTime arrival, List<Sample> samples) {
    if (_closed || samples.isEmpty) return;
    final idx = ByteData(indexBytes)
      ..setFloat64(0, unixSeconds(arrival), Endian.little)
      ..setUint64(8, _received, Endian.little);
    _indexBuf.add(idx.buffer.asUint8List());
    final rec = ByteData(recordBytes * samples.length);
    var o = 0;
    for (final s in samples) {
      rec
        ..setUint32(o, s.pack & 0xFFFFFFFF, Endian.little)
        ..setFloat32(o + 4, s.o1, Endian.little)
        ..setFloat32(o + 8, s.o2, Endian.little)
        ..setFloat32(o + 12, s.t3, Endian.little)
        ..setFloat32(o + 16, s.t4, Endian.little);
      o += recordBytes;
    }
    _dataBuf.add(rec.buffer.asUint8List());
    _received += samples.length;
  }

  /// One line in the `.log`, written at once (`ISO-local-time message`).
  void log(String message, {DateTime? at}) {
    if (_closed) return;
    _log.writeStringSync('${logTime(at ?? DateTime.now())} $message\n');
  }

  /// Moves the buffered samples into the files (no fsync). Returns the number of samples added.
  int append() {
    if (_closed) return 0;
    final data = _dataBuf.takeBytes();
    final index = _indexBuf.takeBytes();
    if (data.isNotEmpty) _data.writeFromSync(data);
    if (index.isNotEmpty) _index.writeFromSync(index);
    final n = data.length ~/ recordBytes;
    _written += n;
    return n;
  }

  /// [append], then flush all three files to the storage device (Dart's flush is fsync on Android/Linux).
  void sync() {
    if (_closed) return;
    append();
    _data.flushSync();
    _index.flushSync();
    _log.flushSync();
  }

  /// Saves everything and closes the files. Safe to call twice.
  void close() {
    if (_closed) return;
    sync();
    _closed = true;
    _data.closeSync();
    _index.closeSync();
    _log.closeSync();
  }
}
