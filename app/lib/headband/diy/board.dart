// The DIY ADS1299 board behind the app's one headband interface (recorder/headband.dart), so the night recorder uses
// it as it uses the BrainBit: frames arrive over Wi-Fi (link.dart, one E9 frame per UDP datagram), are checked and
// tracked as on the laptop (e9.dart = scripts/diy_board.py) and become samples in volts.
//
// What differs from a BrainBit:
// - one receiver listens all night (it belongs to the finder); each board object holds one capture of one board
//   boot. A restart (the sequence jumps far back, or the clock goes back) or a new configuration (channels, gain,
//   rate, mode) ends the object: it says "this file set ends here" in the log and "out of range" to the recorder,
//   which closes the file set and asks the finder again; the next object starts with the frames of the new capture,
//   kept meanwhile. Never joined silently to the old capture (PROTOCOL.md, host behaviour; DECISIONS row 355);
// - missing frames are counted, never filled: "lost N samples in M gaps (board missed X, link lost Y)"; damaged
//   datagrams, repeats and late ones are counted and dropped (DECISIONS row 354);
// - no contact and no battery reading (lead-off detection is off in the bench firmware); the recorder skips both;
// - it never sends a byte to the board (there is no send call in this folder; DECISIONS row 352);
// - its 4, 6 or 8 channels travel in the app's N-channel sample record, so the files are byte for byte the laptop's
//   DIY `<I4f` / `<I6f` / `<I8f`, with a header that names them (recorder/header.dart; DECISIONS 630-639; until
//   2026-11-20 the phone took the 4-channel chip only, row 363). Names: the setting's when it gives one per channel,
//   else Ch1..ChN (the laptop's rule), said in the log.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../recorder/chunk_writer.dart' show Sample;
import '../../recorder/header.dart';
import '../../recorder/headband.dart';
import '../../recorder/status.dart' show BoardLive, sampleRateHz;
import '../../share/protocol.dart' show isAllowedClient;
import 'e9.dart';
import '../../signal/layout.dart' show CustomPositions, diyBoardMontage, withPositions;
import 'link.dart';
import 'settings.dart' show defaultDiyNames;

/// The board's trouble in plain words (no frames, a port in use, no battery reading).
class DiyBoardError implements Exception {
  const DiyBoardError(this.message);
  final String message;

  @override
  String toString() => message;
}

class DiyTiming {
  const DiyTiming({
    this.flushEvery = const Duration(milliseconds: 40),
    this.notesEvery = const Duration(seconds: 10),
    this.directWait = const Duration(seconds: 60),
    this.keepMax = 2500,
  });

  /// Samples go to the recorder this often: one `.idx` row per batch, about 10 frames (the laptop's 40 ms).
  final Duration flushEvery;

  /// The count lines (lost, damaged, repeated) go into the log this often, when anything happened.
  final Duration notesEvery;

  /// How long a direct connection waits for frames.
  final Duration directWait;

  /// Frames kept while no board object holds the capture (between two file sets): 10 s; older ones are dropped.
  final int keepMax;
}

const String _name = 'DIY board';

class DiyFinder implements HeadbandFinder {
  DiyFinder({
    DiyLink Function()? link,
    this.names = defaultDiyNames,
    this.positions = const CustomPositions(),
    this.vref = defaultVref,
    this.port = diyUdpPort,
    this.timing = const DiyTiming(),
  }) : _makeLink = link ?? (() => UdpLink(port: port));

  /// The setting's channel names (CH1 on); used when they are as many as the board's channels.
  final List<String> names;

  /// The Signal tab's positions file (files/signal/positions.txt), for the header's places.
  final CustomPositions positions;
  final double vref;
  final int port;
  final DiyTiming timing;
  final DiyLink Function() _makeLink;
  _Receiver? _rx;

  Future<_Receiver> _open() async {
    final old = _rx;
    if (old != null && !old.failed) return old;
    final rx = _Receiver(_makeLink(), this);
    try {
      await rx.open();
    } on LinkFailed catch (e) {
      throw DiyBoardError('The phone cannot listen for the board on UDP port $port: $e.');
    }
    _rx = rx;
    return rx;
  }

  /// Listens (once; the receiver stays up until [dispose]) and waits up to [scanFor] for the board's frames; null when
  /// none came.
  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    final rx = await _open();
    if (await rx.waitForCapture(scanFor)) return rx.claim();
    return null;
  }

  /// The names for a board of [channels] channels: the setting's when it gives that many, else Ch1..ChN.
  List<String> namesFor(int channels) =>
      names.length == channels ? names : [for (var i = 1; i <= channels; i++) 'Ch$i'];

  /// The same board again (after a restart or a drop): waits up to [DiyTiming.directWait] for its frames.
  @override
  Future<Headband> connectDirect(BandId id) async {
    final rx = await _open();
    if (await rx.waitForCapture(timing.directWait)) return rx.claim();
    throw DiyBoardError(
      'No frames from the board for ${timing.directWait.inSeconds} s on UDP port $port. Is it on this Wi-Fi, '
      'sending to this phone, and past its prompts?',
    );
  }

  /// End of the night: stops listening.
  void dispose() {
    _rx?.close();
    _rx = null;
  }
}

String _configText(E9Frame f) => '${f.channels} ch ${f.fs} Hz gain ${f.gain} ${f.mode}';

String _restartReason(E9Frame prev, E9Frame f) {
  if ((f.seq - prev.seq) % (1 << 32) >= 1 << 31) return 'sequence went back from ${prev.seq} to ${f.seq}';
  return 'device clock went back from ${prev.timeUs} to ${f.timeUs} us';
}

/// The one listener of a night: frames in, tracked, handed to the board object that holds the capture, or kept for
/// the next one.
class _Receiver {
  _Receiver(this.link, this.finder);

  final DiyLink link;
  final DiyFinder finder;
  final Tracker tracker = Tracker();
  DiyHeadband? band;
  bool failed = false, closed = false;

  /// The capture under way: its first frame, why it began, and its frames while no board object holds them.
  E9Frame? _first;
  String? _why;
  List<E9Frame> _kept = [];
  int _dropped = 0;
  Completer<void>? _arrived;

  /// Log lines while no board object holds the capture.
  final List<String> _held = [];
  final Set<String> senders = {};
  String? sender;
  (int, int)? _leadOff;

  /// Since the last count lines.
  int _gaps = 0, _gapLost = 0, _gapBoard = 0, _bad = 0, _foreign = 0;
  int _dup0 = 0, _stale0 = 0, _clock0 = 0;

  /// This capture, for the night screen.
  int lost = 0, boardMissed = 0, bad = 0;

  Future<void> open() => link.open(_onDatagram, _onError);

  void close() {
    if (closed) return;
    closed = true;
    unawaited(link.close().catchError((Object _) {}));
  }

  void _line(String line) {
    final b = band;
    if (b != null && b.isLive) {
      b._note(line);
    } else if (_held.length < 200) {
      _held.add(line);
    }
  }

  void _onError(Object e) {
    if (closed) return;
    failed = true;
    _line('board link failed: $e');
    band?._end('the phone stopped receiving ($e)');
    close();
  }

  void _onDatagram(Uint8List data, InternetAddress from) {
    if (closed) return;
    if (!isAllowedClient(from)) {
      _foreign++;
      return;
    }
    final who = from.address;
    if (senders.add(who)) {
      _line('datagrams from $who');
      if (senders.length > 1) _line('more than one sender on this port: is another board or program sending here?');
    }
    sender = who;
    final E9Frame f;
    try {
      f = decodeFrame(data);
    } on FrameError {
      _bad++;
      bad++;
      return;
    }
    final prev = tracker.last;
    final step = tracker.observe(f);
    switch (step.kind) {
      case StepKind.duplicate || StepKind.stale:
        return;
      case StepKind.restart || StepKind.config:
        final reason = step.kind == StepKind.restart
            ? _restartReason(prev!, f)
            : 'configuration changed from ${_configText(prev!)} to ${_configText(f)}';
        band?._end('board restarted ($reason): this file set ends here');
        _begin(f, 'a new capture: board restarted ($reason)');
      case StepKind.first:
        _begin(f, null);
      case StepKind.next:
        if (step.lost > 0) {
          _gaps++;
          _gapLost += step.lost;
          _gapBoard += step.boardMissed;
          lost += step.lost;
          boardMissed += step.boardMissed;
        }
        _deliver(f);
    }
  }

  void _begin(E9Frame f, String? why) {
    band = null;
    _first = f;
    _why = why;
    _kept = [];
    lost = boardMissed = bad = 0;
    _leadOff = null;
    _deliver(f);
  }

  void _deliver(E9Frame f) {
    final lo = (f.leadOffP, f.leadOffN);
    if (lo != _leadOff) {
      _leadOff = lo;
      if (lo.$1 != 0 || lo.$2 != 0) {
        _line('status lead-off bits P=0x${_hex2(lo.$1)} N=0x${_hex2(lo.$2)} (lead-off detection is off in the bench '
            'firmware: not a contact reading)');
      }
    }
    final b = band;
    if (b != null && b.isLive) {
      b._frame(f);
    } else {
      if (_kept.length >= finder.timing.keepMax) {
        _kept.removeAt(0);
        _dropped++;
      }
      _kept.add(f);
      final w = _arrived;
      _arrived = null;
      if (w != null && !w.isCompleted) w.complete();
    }
  }

  static String _hex2(int v) => v.toRadixString(16).padLeft(2, '0');

  bool get _ready => _kept.isNotEmpty;

  /// True once a capture has frames no board object holds.
  Future<bool> waitForCapture(Duration wait) async {
    if (_ready) return true;
    final until = DateTime.now().add(wait);
    while (!_ready && !closed) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final c = _arrived ??= Completer<void>();
      await c.future.timeout(left, onTimeout: () {});
    }
    return _ready;
  }

  /// A new board object for the capture under way, with its kept frames and lines.
  DiyHeadband claim() {
    band?._end('handed over to a new connection');
    final first = _first ?? _kept.first;
    final lines = <String>[
      'driver DIY board (lib/headband/diy): eeg_ads1299_lab bench firmware, E9 protocol version 1; link ${link.describe}',
      ..._held,
      ?_why,
      if (_dropped > 0) '$_dropped frames arrived while no file set was open (not recorded)',
    ];
    _held.clear();
    _why = 'the board did not restart: this file set continues the capture of the one before';
    _dropped = 0;
    final b = DiyHeadband._(this, first, lines);
    band = b;
    final kept = _kept;
    _kept = [];
    for (final f in kept) {
      b._frame(f);
    }
    return b;
  }

  void release(DiyHeadband b) {
    if (identical(band, b)) band = null;
  }

  /// The count lines, when anything happened since the last ones (the laptop's flush_counts).
  List<String> takeCountLines() {
    final out = <String>[
      if (_gaps > 0) 'lost $_gapLost samples in $_gaps gaps (board missed $_gapBoard, link lost ${_gapLost - _gapBoard})',
      if (_bad > 0) 'bad datagrams $_bad (CRC or framing)',
    ];
    final dup = tracker.duplicates - _dup0, late = tracker.stale - _stale0, clock = tracker.timingAnomalies - _clock0;
    if (dup > 0 || late > 0) out.add('repeated $dup, late $late frames dropped');
    if (clock > 0) out.add('device clock off the sample rate at $clock frames');
    if (_foreign > 0) out.add('ignored $_foreign datagrams from outside the local network');
    _gaps = _gapLost = _gapBoard = _bad = _foreign = 0;
    _dup0 = tracker.duplicates;
    _stale0 = tracker.stale;
    _clock0 = tracker.timingAnomalies;
    return out;
  }
}

class DiyHeadband implements Headband, BandNotes, OtherBoard {
  DiyHeadband._(this._rx, this._firstFrame, List<String> lines)
    : names = List.unmodifiable(_rx.finder.namesFor(_firstFrame.channels)) {
    final f = _firstFrame;
    final k = voltsPerCount(f.gain, _rx.finder.vref);
    for (final l in lines) {
      _note(l);
    }
    final set = _rx.finder.names;
    if (set.length != f.channels) {
      _note('the setting names ${set.length} channels (${set.join(' ')}) but the board sends ${f.channels}: using '
          '${names.join(' ')}; give ${f.channels} names on the Headband connection page');
    }
    _note('channels ${names.join(' ')} (montage: the phone\'s setting on the Headband connection page; a plan until '
        'the firmware has an electrode mode)');
    _note('board ${f.channels} channels, ${f.fs} Hz, gain ${f.gain}, vref ${_g(_rx.finder.vref)} V (assumed; volts = '
        'counts x vref / (gain x 2^23) = ${(k * 1e6).toStringAsFixed(5)} uV per count)');
    _note('format .f32 records <I${f.channels}f: board sequence number, then ${names.join(' ')} in volts; ${f.fs} Hz');
    _note('mode ${f.modeText} (flags 0x${f.flags.toRadixString(16).padLeft(2, '0')})');
    _note('contact and battery: not measured by this board (lead-off detection is off in the bench firmware)');
    _ticker = Timer.periodic(_rx.finder.timing.notesEvery, (_) => _tick());
  }

  final _Receiver _rx;
  final E9Frame _firstFrame;

  /// CH1.. in order: the setting's names, or Ch1..ChN when it does not give one per channel.
  final List<String> names;

  /// What this capture's records hold: its channels by name with their places (the positions file's where it names
  /// them), the board's rate, volts, the board's sequence number first (recorder/header.dart).
  @override
  late final RecordingHeader header = headerForMontage(
    withPositions(diyBoardMontage(names), _rx.finder.positions),
    device: 'DIY board',
    sampleRate: _firstFrame.fs,
    counter: counterSequence,
  );
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();
  late final StreamController<BandNote> _notes = StreamController<BandNote>.broadcast(sync: true, onListen: _flushNotes);
  final List<BandNote> _pending = [];
  final List<Sample> _held = [];
  List<Sample> _batch = [];
  Timer? _flusher, _ticker;
  bool _streaming = false, _ended = false, _disposed = false;

  /// Each channel's lowest and highest count in the second under way, and the swing of the last whole second.
  late final List<int> _lo = List.filled(_firstFrame.channels, 0), _hi = List.filled(_firstFrame.channels, 0);
  int _inBlock = 0;
  late List<double?> _levels = List.filled(_firstFrame.channels, null);

  static String _g(double v) => v == v.roundToDouble() ? v.toStringAsFixed(1) : '$v';

  bool get isLive => !_ended && !_disposed;

  @override
  String get name => _name;
  @override
  String get address => 'udp:${_rx.finder.port}';
  @override
  String get serial => '';
  @override
  BandId get id => BandId(name: _name, address: address, family: 'diy');
  @override
  int? get rssi => null;
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;
  @override
  Stream<BandNote> get notes => _notes.stream;

  @override
  BoardLive get board => BoardLive(
    names: names,
    mode: _firstFrame.mode,
    modeText: _firstFrame.modeText,
    notEeg: _firstFrame.notEeg,
    levelsUv: _levels,
    fs: _firstFrame.fs,
    link: _rx.link.describe,
    sender: _rx.sender,
    lost: _rx.lost,
    boardMissed: _rx.boardMissed,
    bad: _rx.bad,
  );

  void _note(String line) {
    final n = BandNote(line);
    if (_notes.hasListener) {
      _notes.add(n);
    } else if (_pending.length < 500) {
      _pending.add(n);
    }
  }

  void _flushNotes() {
    final waiting = _pending.toList();
    _pending.clear();
    waiting.forEach(_notes.add);
  }

  void _tick() {
    for (final l in _rx.takeCountLines()) {
      _note(l);
    }
  }

  void _frame(E9Frame f) {
    _level(f);
    final s = Sample(f.seq, f.volts(_rx.finder.vref));
    if (_streaming) {
      _batch.add(s);
    } else {
      if (_held.length >= _rx.finder.timing.keepMax) _held.removeAt(0);
      _held.add(s);
    }
  }

  void _level(E9Frame f) {
    for (var c = 0; c < f.channels && c < _lo.length; c++) {
      final x = f.counts[c];
      if (_inBlock == 0 || x < _lo[c]) _lo[c] = x;
      if (_inBlock == 0 || x > _hi[c]) _hi[c] = x;
    }
    if (++_inBlock < f.fs.clamp(1, sampleRateHz)) return;
    final k = voltsPerCount(f.gain, _rx.finder.vref) * 1e6;
    _levels = [for (var c = 0; c < _lo.length; c++) (_hi[c] - _lo[c]) * k];
    _inBlock = 0;
  }

  void _flush() {
    if (_batch.isEmpty || _signal.isClosed) return;
    final out = _batch;
    _batch = [];
    _signal.add(out);
  }

  /// The capture ended (a restart, a new mode, a dead socket): the count lines, [line], then "out of range".
  void _end(String line) {
    if (_ended || _disposed) return;
    _flush();
    _note(line);
    _tick();
    _ended = true;
    _streaming = false;
    _flusher?.cancel();
    _ticker?.cancel();
    _rx.release(this);
    if (!_range.isClosed) _range.add(false);
  }

  @override
  Future<void> startSignal() async {
    if (!isLive) throw const DiyBoardError('the board restarted: this connection has ended');
    if (_streaming) return;
    _streaming = true;
    _batch.addAll(_held);
    _held.clear();
    _flush();
    _flusher = Timer.periodic(_rx.finder.timing.flushEvery, (_) => _flush());
  }

  @override
  Future<void> stopSignal() async {
    _flush();
    _streaming = false;
    _flusher?.cancel();
    _flusher = null;
  }

  /// The board has no contact measurement: nothing to start.
  @override
  Future<void> startResist() async {}

  @override
  Future<void> stopResist() async {}

  /// False once the capture has ended (a restart or a new mode: the recorder starts a new file set).
  @override
  Future<bool> isInRange() async => isLive;

  @override
  Future<int> battery() async => throw const DiyBoardError('no battery reading from this board');

  @override
  Future<void> disconnectAndDispose() async {
    if (_disposed) return;
    _flush();
    _disposed = true;
    _streaming = false;
    _flusher?.cancel();
    _ticker?.cancel();
    _rx.release(this);
    await _signal.close();
    await _resist.close();
    await _range.close();
    await _notes.close();
  }
}
