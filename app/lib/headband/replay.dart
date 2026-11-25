// The replay headband (DECISIONS 730-739): a recording the app wrote (`<stamp>.f32`, plain or packed, `.idx`,
// `<stamp>.header.json`) played back into the app through the slot every test's fake headband uses (a
// [HeadbandFinder] that hands out a [Headband]), batch by batch at the recorded arrival times, at real speed or faster,
// so talking, chewing, the headband off and drop-outs reach the real sessions and the real night recorder.
//
// Any channel count and layout: the header says what each record holds. Four channels at the BrainBit's sites
// (O1 O2 T3 T4, in any order) at 250 Hz play as a BrainBit, in its order, so every session can use them. Anything else
// plays as another board ([OtherBoard], as the DIY board does): the night recorder keeps it with its own header, and
// a session says in words that it needs the BrainBit's sites.
//
// Never in the owner's app by accident: the app looks for a replay only in a build made with
// `--dart-define=EEG_REPLAY=true` ([replayBuild] is a compile-time constant, so a normal build does not even contain
// that path), and then only while `files/replay/plan.json` exists, which only `adb root` can put there. Tests use the
// classes here directly (no switch needed): the same recordings drive plain laptop tests.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../recorder/chunk_writer.dart' show Sample, indexBytes;
import '../recorder/header.dart';
import '../recorder/headband.dart';
import '../recorder/packed.dart' show RawReader, isPackedPath, openRaw, plainFileOf, rawExists, rawLength;
import '../recorder/status.dart' show BoardLive;
import '../signal/layout.dart' show brainBitNames;

/// True only in a build made with `--dart-define=EEG_REPLAY=true` (the emulator check's replay APK). The app's
/// finder consults [ReplayPlan] only then.
const bool replayBuild = bool.fromEnvironment('EEG_REPLAY');

/// The folder of `files/` that holds the plan and the recordings to replay.
const String replayFolder = 'replay';

/// `files/replay/` beside `files/recordings`.
Directory replayDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/$replayFolder');

/// What the name and the logs call it.
const String replayName = 'Replay (not a headband)';

/// A plan or a recording that cannot be replayed, in words that name the file.
class ReplayError implements Exception {
  const ReplayError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A session was asked to use a replay whose layout is not the BrainBit's.
class NotForReplayBoard implements Exception {
  const NotForReplayBoard(this.describe);
  final String describe;

  @override
  String toString() =>
      "The replay plays $describe. Sessions read the BrainBit's O1 O2 T3 T4; only Record and Sleep record this layout.";
}

/// One batch as it arrived: [at] seconds after the replay's first batch (long gaps shortened), its samples.
class ReplayBatch {
  const ReplayBatch(this.at, this.samples);
  final double at;
  final List<Sample> samples;
}

/// How to play: [speed] times real time, from [fromS] seconds in, gaps longer than [maxGapS] shortened to it, and
/// whether to start again at the end.
class ReplayPlan {
  const ReplayPlan({
    required this.files,
    this.speed = 1,
    this.fromS = 0,
    this.maxGapS = 60,
    this.loop = false,
    this.contactOhms,
    this.rollBytes,
  });

  /// The emulator check's short roll-over (`"roll_bytes"`, tool/record_check.py R1): the night recorder closes a file
  /// set at this many bytes instead of its 4 hours or 128 MB (recorder/night_recorder.dart, DECISIONS 1035). Only a
  /// replay build reads a plan, so the owner's app has no such knob. Null: the recorder's own limits.
  final int? rollBytes;

  /// The `.f32` files (plain names; a packed one is read as such), played one after another.
  final List<File> files;
  final double speed;
  final double fromS;
  final double maxGapS;
  final bool loop;

  /// What the contact check reads, per channel name; null: 300 kOhm on every channel (good contact).
  final Map<String, double>? contactOhms;

  /// `files/replay/plan.json`:
  /// `{"files": ["talking/2026-11-20-100000.f32"], "speed": 1, "from_s": 0, "max_gap_s": 60, "loop": false,
  ///   "contact_ohms": {"O1": 300000}}`. `files` are paths inside `files/replay/` (no `..`, not absolute); without
  /// it every recording directly in that folder plays, oldest first. Throws [ReplayError] naming the file for
  /// anything it cannot use.
  static ReplayPlan load(Directory replayDir) {
    final f = File('${replayDir.path}/plan.json');
    final Object? j;
    try {
      j = jsonDecode(f.readAsStringSync());
    } on FileSystemException catch (e) {
      throw ReplayError('${f.path}: cannot be read (${e.message})');
    } on FormatException catch (e) {
      throw ReplayError('${f.path}: not valid JSON (${e.message})');
    }
    Never bad(String why) => throw ReplayError('${f.path}: $why');
    if (j is! Map) bad('not a JSON object');
    final m = j;
    double number(String key, double fallback, {required double min, required double max}) {
      final v = m[key] ?? fallback;
      if (v is! num || !v.isFinite || v < min || v > max) bad('$key must be a number from $min to $max');
      return v.toDouble();
    }

    final speed = number('speed', 1, min: 0.01, max: 1000);
    final fromS = number('from_s', 0, min: 0, max: 7 * 86400);
    final maxGapS = number('max_gap_s', 60, min: 0, max: 86400);
    final ohms = m['contact_ohms'];
    final contact = <String, double>{};
    if (ohms != null) {
      if (ohms is! Map) bad('contact_ohms must map channel names to ohms');
      for (final e in ohms.entries) {
        final v = e.value;
        if (v is! num || !v.isFinite || v <= 0) bad('contact_ohms: ${e.key} must be ohms above 0');
        contact['${e.key}'] = v.toDouble();
      }
    }
    final loop = m['loop'] ?? false;
    if (loop is! bool) bad('loop must be true or false');
    final roll = m['roll_bytes'];
    if (roll != null && (roll is! int || roll < 20000)) bad('roll_bytes must be a whole number of bytes, 20000 or more');
    final named = m['files'];
    final files = <File>[];
    if (named == null) {
      files.addAll(_recordingsIn(replayDir));
    } else {
      if (named is! List || named.isEmpty) bad('files must be a list of recordings');
      for (final n in named) {
        if (n is! String || n.isEmpty || n.startsWith('/') || n.split('/').contains('..')) {
          bad('files: ${jsonEncode(n)} is not a path inside ${replayDir.path}');
        }
        files.add(plainFileOf(File('${replayDir.path}/$n')));
      }
    }
    if (files.isEmpty) bad('no recording to replay in ${replayDir.path}');
    for (final r in files) {
      if (!r.path.endsWith('.f32')) bad('${r.path} is not a recording (.f32)');
      if (!rawExists(r)) bad('${r.path} is not there');
    }
    return ReplayPlan(
      files: files,
      speed: speed,
      fromS: fromS,
      maxGapS: maxGapS,
      loop: loop,
      contactOhms: ohms == null ? null : contact,
      rollBytes: roll as int?,
    );
  }
}

/// The roll-over size the replay plan of [recordingsDir] asks for, or null: no replay build, no plan, or none asked.
int? replayRollBytes(String recordingsDir, {bool allowed = replayBuild}) {
  if (!allowed) return null;
  try {
    final dir = replayDirFor(recordingsDir);
    return File('${dir.path}/plan.json').existsSync() ? ReplayPlan.load(dir).rollBytes : null;
  } on ReplayError {
    return null;
  }
}

List<File> _recordingsIn(Directory dir) {
  final out = <String, File>{};
  if (!dir.existsSync()) return const [];
  for (final f in dir.listSync().whereType<File>()) {
    if (f.path.endsWith('.f32') || isPackedPath(f.path)) {
      final plain = plainFileOf(f);
      out[plain.path] = plain;
    }
  }
  return out.values.toList()..sort((a, b) => a.path.compareTo(b.path));
}

/// The header that [files] share (channels and rate); throws [ReplayError] when they differ or one is damaged.
RecordingHeader replayHeader(List<File> files) {
  RecordingHeader? first;
  for (final f in files) {
    final RecordingHeader h;
    try {
      h = readHeader(f);
    } on HeaderError catch (e) {
      throw ReplayError(e.message);
    }
    if (first == null) {
      first = h;
    } else if (!first.isIn(h.names) || first.sampleRate != h.sampleRate) {
      throw ReplayError(
        '${f.path} holds ${h.describe} at ${h.sampleRate} Hz; the first holds ${first.describe} at '
        '${first.sampleRate} Hz: one replay plays one layout',
      );
    }
  }
  if (first == null) throw const ReplayError('no recording to replay');
  return first;
}

/// Where the BrainBit's O1 O2 T3 T4 are when [h] is exactly those four sites at 250 Hz (null: in that order
/// already); throws [MissingSites] otherwise (the replay then plays as another board).
List<int>? brainBitOrder(RecordingHeader h) {
  if (h.count != 4 || h.sampleRate != legacySampleRate) {
    throw MissingSites("not the BrainBit's layout (${h.describe} at ${h.sampleRate} Hz)");
  }
  return mapping(h, brainBitNames, who: 'A BrainBit replay');
}

/// Reads the batches of one or more file sets in order, as they arrived: one `.idx` row is one batch. Reads a file
/// at a time and a little at a time (a night's `.idx` has a million rows), packed files too. A damaged `.idx` row (out
/// of order or past the data) ends the file's rows there, and the records after the last good row play with it; a file
/// set without an `.idx` plays in batches of 0.1 s.
class ReplayCursor {
  ReplayCursor(this.files, {this.maxGapS = 60, this.order}) : header = replayHeader(files);

  final List<File> files;
  final double maxGapS;
  final RecordingHeader header;

  /// The channels to hand out, in this order (null: as recorded).
  final List<int>? order;

  int _file = -1;
  RawReader? _raw;
  RandomAccessFile? _idx;
  int _records = 0; // records in the current file
  int _rawAt = 0; // the record the raw reader stands at
  final Queue<(double, int)> _rows = Queue(); // index rows read ahead: (arrival, first sample)
  int _prevFirst = -1;
  bool _idxDone = true;
  double? _lastArrival;
  double _at = 0;
  ReplayBatch? _ahead;
  bool _ended = false;

  /// Unix seconds of the first batch's arrival (null before the first batch).
  double? firstArrival;

  /// Samples read so far.
  int samples = 0;

  /// Nothing more to read (a batch read ahead by [skipTo] may still be waiting).
  bool get ended => _ended && _ahead == null;

  bool _open() {
    _closeFile();
    while (++_file < files.length) {
      final f = files[_file];
      try {
        _records = rawLength(f) ~/ header.recordBytes;
        if (_records == 0) continue;
        _raw = openRaw(f);
        _rawAt = 0;
        final idx = File('${f.path.substring(0, f.path.length - 4)}.idx');
        _idx = idx.existsSync() ? idx.openSync() : null;
        _rows.clear();
        _prevFirst = -1;
        _idxDone = _idx == null;
        return true;
      } on FileSystemException {
        _closeFile();
      }
    }
    return false;
  }

  void _closeFile() {
    try {
      _raw?.closeSync();
      _idx?.closeSync();
    } on FileSystemException {
      // nothing more to do for it
    }
    _raw = null;
    _idx = null;
  }

  /// Up to 4096 more index rows of the current file.
  void _readRows() {
    final idx = _idx;
    if (idx == null || _idxDone) return;
    final bytes = idx.readSync(4096 * indexBytes);
    if (bytes.length < indexBytes) {
      _idxDone = true;
      return;
    }
    final b = ByteData.sublistView(bytes);
    for (var o = 0; o + indexBytes <= bytes.length; o += indexBytes) {
      final arrival = b.getFloat64(o, Endian.little);
      final first = b.getUint64(o + 8, Endian.little);
      if (!arrival.isFinite || first <= _prevFirst || first >= _records) {
        _idxDone = true; // damaged, or past the data (the samples not yet flushed): the file ends here
        return;
      }
      _prevFirst = first;
      _rows.add((arrival, first));
    }
  }

  /// The next batch, or null at the end of the last file.
  ReplayBatch? next() {
    final a = _ahead;
    if (a != null) {
      _ahead = null;
      return a;
    }
    while (!_ended) {
      if (_raw == null && !_open()) {
        _ended = true;
        return null;
      }
      final b = _nextInFile();
      if (b != null) return b;
      _closeFile();
    }
    return null;
  }

  /// Reads past every batch before [seconds] on the replay's clock; the first one at or after it comes next.
  void skipTo(double seconds) {
    ReplayBatch? b;
    do {
      b = next();
    } while (b != null && b.at < seconds);
    _ahead = b;
  }

  ReplayBatch? _nextInFile() {
    final int first, count;
    double? arrival;
    if (_idx == null) {
      // no index: batches of 0.1 s of signal, as if they had arrived on time
      if (_rawAt >= _records) return null;
      first = _rawAt;
      count = math.min(math.max(1, (header.sampleRate / 10).round()), _records - first);
    } else {
      while (_rows.length < 2 && !_idxDone) {
        _readRows();
      }
      if (_rows.isEmpty) return null;
      final row = _rows.removeFirst();
      arrival = row.$1;
      first = row.$2;
      count = (_rows.isNotEmpty ? _rows.first.$2 : _records) - first;
    }
    final raw = _raw!;
    if (_rawAt != first) raw.setPositionSync(first * header.recordBytes);
    final bytes = raw.readSync(count * header.recordBytes);
    final n = bytes.length ~/ header.recordBytes;
    if (n == 0) return null;
    _rawAt = first + n;
    final rows = _decode(ByteData.sublistView(bytes), n);
    // the replay's clock: the recorded time between arrivals, a gap no longer than maxGapS, never backwards
    final last = _lastArrival;
    final t = arrival ?? (last ?? 0) + n / header.sampleRate;
    if (last == null) {
      firstArrival ??= t;
    } else {
      _at += (t - last).clamp(0, maxGapS).toDouble();
    }
    _lastArrival = t;
    samples += n;
    return ReplayBatch(_at, rows);
  }

  List<Sample> _decode(ByteData d, int n) {
    final width = header.count, rb = header.recordBytes;
    final cols = order ?? [for (var c = 0; c < width; c++) c];
    return [
      for (var k = 0; k < n; k++)
        Sample(d.getUint32(k * rb, Endian.little), Float64List.fromList([
          for (final c in cols) d.getFloat32(k * rb + 4 + 4 * c, Endian.little),
        ])),
    ];
  }

  void close() {
    _closeFile();
    _ended = true;
    _ahead = null;
  }
}

/// How the replay keeps time. [ReplayPace.real]: [speed] times the phone's clock (the app, the emulator check).
/// [ReplayPace.virtual]: a clock of its own that moves [stepS] seconds every millisecond of real time, read through
/// [ReplayFinder.now] (laptop tests: a working day in seconds, the session's clock given as `clock: finder.now`).
class ReplayPace {
  const ReplayPace.real({this.speed = 1}) : stepS = 0, tick = const Duration(milliseconds: 40);
  const ReplayPace.virtual({this.stepS = 1}) : speed = 0, tick = const Duration(milliseconds: 1);

  final double speed;
  final double stepS;
  final Duration tick;
  bool get isVirtual => stepS > 0;
}

/// Hands out the replayed headband: one recording, one playhead, kept across reconnects (a session's or the
/// recorder's), so a drop in the recording plays as a drop and the replay goes on where it was.
class ReplayFinder implements HeadbandFinder {
  ReplayFinder(this.plan, {ReplayPace? pace, this.forSessions = false, this.clockStart})
    : pace = pace ?? ReplayPace.real(speed: plan.speed),
      header = replayHeader(plan.files) {
    try {
      _order = brainBitOrder(header);
      asBrainBit = true;
    } on MissingSites {
      asBrainBit = false;
    }
  }

  final ReplayPlan plan;
  final ReplayPace pace;
  final RecordingHeader header;

  /// A session asks: a layout that is not the BrainBit's is refused in words ([NotForReplayBoard]).
  final bool forSessions;

  /// The virtual clock's start; null: the recording's own first arrival.
  final DateTime? clockStart;
  List<int>? _order;

  /// Plays as a BrainBit (four channels at its sites, 250 Hz); else as another board.
  late final bool asBrainBit;

  ReplayCursor? _cursor;
  ReplayBand? _band;

  // the playhead, in seconds of the replay's clock: [_played] up to the last stop, plus the running stretch; [_base]
  // is where the current cursor's 0 sits (a loop starts the cursor again further on)
  double _played = 0, _base = 0, _virtual = 0;
  final Stopwatch _running = Stopwatch();
  ReplayBatch? _next;
  bool _finished = false;

  /// The band handed out last (tests read its counts).
  ReplayBand? get band => _band;

  /// Seconds of the replay played so far.
  double get played => _played + (_running.isRunning ? _running.elapsedMicroseconds / 1e6 * pace.speed : 0);

  /// The recording has been played to its end (never while looping).
  bool get finished => _finished;

  /// The replay's clock. Virtual pace: [clockStart] (else the recording's first arrival) plus the seconds played;
  /// real pace: the phone's clock.
  DateTime now() {
    if (!pace.isVirtual) return DateTime.now();
    final start = clockStart ?? DateTime.fromMicrosecondsSinceEpoch((((_cursor ??= _open()).firstArrival ?? 0) * 1e6).round());
    return start.add(Duration(microseconds: (_virtual * 1e6).round()));
  }

  ReplayCursor _open() {
    final c = ReplayCursor(plan.files, maxGapS: plan.maxGapS, order: asBrainBit ? _order : null);
    if (plan.fromS > 0 && _base == 0) c.skipTo(plan.fromS);
    return c;
  }

  ReplayBand _hand() {
    if (forSessions && !asBrainBit) throw NotForReplayBoard('${header.describe} at ${header.sampleRate} Hz');
    _cursor ??= _open();
    _band?._retire();
    return _band = asBrainBit ? ReplayBand._(this) : ReplayBoard._(this);
  }

  void _start() {
    _pause();
    if (!pace.isVirtual) _running.start();
  }

  void _pause() {
    if (_running.isRunning) {
      _played += _running.elapsedMicroseconds / 1e6 * pace.speed;
      _running
        ..stop()
        ..reset();
    }
  }

  /// One tick of [band]'s timer: every batch due by now on [band]'s signal.
  void _tick(ReplayBand band) {
    if (pace.isVirtual) {
      _virtual += pace.stepS;
      _played += pace.stepS;
    }
    final due = played + (plan.fromS > 0 ? plan.fromS : 0);
    for (var guard = 0; guard < 100000; guard++) {
      final c = _cursor ??= _open();
      final b = _next ??= c.next();
      if (b == null) {
        if (plan.loop && c.samples > 0) {
          _base = due;
          c.close();
          _cursor = _open();
          continue;
        }
        _finished = true;
        band._ended((c.samples / header.sampleRate).round());
        return;
      }
      if (_base + b.at > due) return;
      _next = null;
      band._send(b.samples);
    }
  }

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    await Future<void>.delayed(Duration.zero);
    if (_finished) return null;
    final b = _hand();
    onFound?.call(b.name, -50);
    return b;
  }

  @override
  Future<Headband> connectDirect(BandId id) async {
    await Future<void>.delayed(Duration.zero);
    if (id.family != 'replay' || _finished) throw StateError('the replay has no more to play');
    return _hand();
  }

  void dispose() {
    _band?._retire();
    _cursor?.close();
  }
}

/// The replayed headband: the recording's batches on [signal] when they are due, the plan's contact on
/// [resistance], its notes (what it replays) for the night's log.
class ReplayBand implements Headband, BandNotes {
  ReplayBand._(this._finder) {
    final p = _finder.plan, h = _finder.header;
    _note(
      '$replayName: ${[for (final f in p.files) f.uri.pathSegments.last].join(' ')}, ${h.describe} at '
      '${h.sampleRate} Hz, ${_finder.pace.isVirtual ? 'on its own clock' : '${p.speed}x real time'}'
      '${p.fromS > 0 ? ' from ${p.fromS} s' : ''}${p.loop ? ', looping' : ''}; gaps over ${p.maxGapS} s shortened',
    );
  }

  final ReplayFinder _finder;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();
  late final StreamController<BandNote> _notes = StreamController<BandNote>.broadcast(sync: true, onListen: _flush);
  final List<BandNote> _pendingNotes = [];
  Timer? _timer, _resistTimer;
  bool _retired = false;

  /// Batches and samples sent by this connection.
  int batches = 0, sent = 0;

  void _note(String line) {
    final n = BandNote(line);
    if (_notes.hasListener) {
      _notes.add(n);
    } else {
      _pendingNotes.add(n);
    }
  }

  void _flush() {
    for (final n in _pendingNotes) {
      _notes.add(n);
    }
    _pendingNotes.clear();
  }

  void _send(List<Sample> rows) {
    batches++;
    sent += rows.length;
    if (_signal.hasListener) _signal.add(rows);
  }

  void _ended(int seconds) {
    _stop();
    _note('$replayName: the recording ended after $seconds s of signal');
    _range.add(false);
  }

  void _retire() {
    _stop();
    _retired = true;
  }

  void _stop() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    _finder._pause();
  }

  @override
  String get name => replayName;
  @override
  String get address => 'replay';
  @override
  String get serial => 'replay';
  @override
  int? get rssi => -50;
  @override
  BandId get id => const BandId(name: replayName, address: 'replay', family: 'replay');
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;
  @override
  Stream<BandNote> get notes => _notes.stream;

  @override
  Future<void> startSignal() async {
    if (_retired) throw StateError('this replayed headband was handed over to a new connection');
    _stop();
    if (_finder.finished) return;
    _finder._start();
    _timer = Timer.periodic(_finder.pace.tick, (_) => _finder._tick(this));
  }

  @override
  Future<void> stopSignal() async => _stop();

  @override
  Future<void> startResist() async {
    final ohms = _finder.plan.contactOhms;
    final names = _finder.asBrainBit ? brainBitNames : _finder.header.names;
    final reading = {for (final n in names) n: ohms?[n] ?? 3e5};
    _resistTimer?.cancel();
    _resistTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _resist.add(reading));
  }

  @override
  Future<void> stopResist() async {
    _resistTimer?.cancel();
    _resistTimer = null;
  }

  @override
  Future<bool> isInRange() async => !_retired && !_finder.finished;
  @override
  Future<int> battery() async => 80;

  @override
  Future<void> disconnectAndDispose() async {
    _stop();
    await stopResist();
  }
}

/// A replay of a layout that is not the BrainBit's: the night recorder keeps it under its own header.
class ReplayBoard extends ReplayBand implements OtherBoard {
  ReplayBoard._(super.finder) : super._();

  @override
  late final RecordingHeader header = RecordingHeader(
    channels: _finder.header.channels,
    sampleRate: _finder.header.sampleRate,
    device: 'Replay of ${_finder.header.device ?? _finder.header.layout ?? 'a recording'}',
    layout: _finder.header.layout,
    reference: _finder.header.reference,
    ground: _finder.header.ground,
    counter: _finder.header.counter,
    madeBy: 'eeg_tracker app (replay)',
  );

  @override
  BoardLive get board => BoardLive(
    names: _finder.header.names,
    mode: 'electrodes',
    modeText: 'A replayed recording, not a headband.',
    notEeg: false,
    fs: _finder.header.sampleRate.round(),
    link: replayName,
  );
}

/// The replay for this app's folder when this is a replay build ([allowed]) and `files/replay/plan.json` is there;
/// else null. A plan that cannot be used is an error in words ([ReplayError]): a replay build never falls back to the
/// real headband silently.
ReplayFinder? replayFinderFor(String recordingsDir, {required bool forSessions, bool allowed = replayBuild}) {
  if (!allowed) return null;
  final dir = replayDirFor(recordingsDir);
  if (!File('${dir.path}/plan.json').existsSync()) return null;
  return ReplayFinder(ReplayPlan.load(dir), forSessions: forSessions);
}
