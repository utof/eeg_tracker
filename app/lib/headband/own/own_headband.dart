// Our own connection behind the app's one headband interface (recorder/headband.dart), so the night recorder and
// every session use it exactly as they use BrainBit's SDK.
//
// What is different from the SDK's headband object:
// - a drop is mended inside the object: it reconnects to the same address after 1, 2, 5, 10 ... s (the driver's
//   pauses) and the signal goes on in the same stream, so the night stays in one file set and a session only sees
//   a hole. It still counts as "in range" meanwhile. Only when the headband has given nothing for [OwnTiming.healFor]
//   does it say "out of range" and close itself; then the app's usual reconnect takes over (a new object, reached
//   by the address, without a scan);
// - a contact check while the signal runs is done in the same connection (resistance for 6 s, then the signal
//   again); with command 5 contact arrives all the time;
// - lost packets are counted from the headband's own 32-bit counter, and the drops, reconnects and losses are
//   handed to the recorder as lines for the night's `.log` ([BandNotes]);
// - no call can block for ever (each has a deadline and fails as "lost"), and none removes a bond or a device.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../recorder/chunk_writer.dart' show Sample;
import '../../recorder/contact.dart' show ohmsLine;
import '../../recorder/headband.dart';
import 'driver.dart';
import 'protocol.dart';
import 'settings.dart';
import 'transport.dart';

class OwnTiming {
  const OwnTiming({
    this.callTimeout = const Duration(seconds: 12),
    this.healFor = const Duration(seconds: 30),
    this.stall = stallAfter,
    this.backoffs = backoff,
    this.contactFor = contactFor_,
    this.statusMaxAge = const Duration(seconds: 30),
    this.notesEvery = const Duration(seconds: 10),
    this.contactNoteEvery = const Duration(seconds: 60),
    this.poll = const Duration(milliseconds: 250),
    this.stopWait = const Duration(seconds: 3),
  });

  /// Deadline of one Bluetooth call, and of one connection try.
  final Duration callTimeout;

  /// How long the headband object mends a drop by itself before it reports "out of range".
  final Duration healFor;
  final Duration stall;
  final List<Duration> backoffs;
  final Duration contactFor;

  /// A battery reading younger than this is reused instead of read again.
  final Duration statusMaxAge;

  /// Lost packets are written to the log this often (only when there were any).
  final Duration notesEvery;

  /// With command 5: a `contact ohms` line this often.
  final Duration contactNoteEvery;
  final Duration poll;

  /// How long Stop waits for the signal loop to end (a connection try in flight ends later, by itself).
  final Duration stopWait;
}

const Duration contactFor_ = contactFor;

class OwnFinder implements HeadbandFinder {
  OwnFinder({
    required this.transport,
    this.settings = const OwnBleSettings(),
    this.remember,
    this.timing = const OwnTiming(),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now,
       _address = settings.address,
       _name = settings.name ?? '';

  final BleTransport transport;
  final OwnBleSettings settings;

  /// Called with the address and name of every headband reached, to keep them for the next time.
  final void Function(String address, String name)? remember;
  final OwnTiming timing;
  final DateTime Function() _now;
  String? _address;
  String _name;

  BrainBitBle _driver(String? address, String name, Duration scanFor) => BrainBitBle(
    transport: transport,
    address: address,
    name: name,
    layout: settings.layout,
    pair: settings.pair,
    timeout: timing.callTimeout,
    scanFor: scanFor,
    stall: timing.stall,
    backoffs: timing.backoffs,
    contactTime: timing.contactFor,
    poll: timing.poll,
    clock: _now,
  );

  /// The known address first, without a scan; a scan by name when there is none or it does not answer.
  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    final drv = _driver(_address, _name, scanFor);
    BandInfo? info;
    if (drv.address != null) {
      try {
        info = await drv.connect();
      } on HeadbandError catch (e) {
        info = null; // not there, or an address the phone cannot place without a scan
        debugPrint('own BLE: the known address did not answer ($e); scanning by name');
      }
    }
    if (info == null) {
      try {
        await drv.scanForBand();
      } on ScanFailed catch (e) {
        debugPrint('own BLE: $e');
        rethrow; // Bluetooth off or not allowed: the caller says "could not connect", not "not found"
      } on HeadbandNotFound {
        return null;
      }
      onFound?.call(drv.name, drv.rssi ?? 0);
      info = await drv.connect();
    }
    return _band(drv, info);
  }

  @override
  Future<Headband> connectDirect(BandId id) async {
    final drv = _driver(id.address, id.name, const Duration(seconds: 10));
    return _band(drv, await drv.connect());
  }

  OwnHeadband _band(BrainBitBle drv, BandInfo info) {
    _address = info.address;
    if (info.name.isNotEmpty) _name = info.name;
    try {
      remember?.call(info.address, info.name);
    } catch (_) {} // remembering is a convenience; the connection is what matters
    return OwnHeadband(drv, info, timing: timing, signalResist: settings.signalResist, clock: _now);
  }

  /// Nothing to free: every headband object closes its own link.
  void dispose() {}
}

class OwnHeadband implements Headband, BandNotes {
  OwnHeadband(
    this._drv,
    this._info, {
    this.timing = const OwnTiming(),
    bool signalResist = false,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now,
       _mode = signalResist ? cmdSignalResist : cmdSignal {
    _status = _info.status;
    _statusAt = _status == null ? null : _now();
    _streamsSeen = _drv.streamStarts;
    _drv.onSamples = _onSamples;
    _drv.onResist = _onResist;
    _drv.onStatus = (st) {
      _status = st;
      _statusAt = _now();
    };
    _drv.setLog((line) => _note(line));
    _note(
      'driver own Bluetooth LE (lib/headband/own, ${_drv.transport.describe}); service ${_info.service}; '
      'device ${_info.info}; mtu ${_info.mtu ?? 'unknown'}',
    );
    _note('layout ${_drv.layout.describe()}');
    _note('mode ${modeNames[_mode]} (command $_mode)');
    final st = _info.status;
    if (st != null) _note('status ${st.text()}');
  }

  final BrainBitBle _drv;
  final BandInfo _info;
  final OwnTiming timing;
  final DateTime Function() _now;
  final int _mode;

  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast(sync: true);
  final _range = StreamController<bool>.broadcast();
  late final StreamController<BandNote> _notes = StreamController<BandNote>.broadcast(sync: true, onListen: _flushNotes);
  final List<BandNote> _pending = [];

  Flag? _stopping;
  Future<void>? _runner;
  Timer? _ticker;
  bool _gone = false;
  bool _disposed = false;
  BandStatus? _status;
  DateTime? _statusAt;
  DateTime? _lostAt;
  DateTime? _contactNoted;
  int _gaps = 0, _gapSamples = 0;
  int _streamsSeen = 0;

  /// Samples the headband's counter showed as lost, over the life of this object.
  int get lostSamples => _drv.lostSamples;

  /// The driver's own view, for tests and the log.
  int get reconnects => _reconnects;
  int _reconnects = 0;

  @override
  String get name => _info.name.isEmpty ? 'BrainBit' : _info.name;
  @override
  String get address => _info.address;
  @override
  String get serial => _info.info['serial'] ?? '';
  @override
  int? get rssi => _info.rssi;
  @override
  BandId get id => BandId(name: name, address: address, serial: serial, family: 'own');

  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;
  @override
  Stream<BandNote> get notes => _notes.stream;

  // ---- notes for the night's log ---------------------------------------------------------------------------
  void _note(String? line, {bool newStream = false}) {
    final n = BandNote(line, newStream: newStream);
    if (_notes.hasListener) {
      _notes.add(n);
    } else if (_pending.length < 500) {
      _pending.add(n); // a session without a log never listens: keep the list bounded
    }
  }

  void _flushNotes() {
    final waiting = _pending.toList();
    _pending.clear();
    for (final n in waiting) {
      _notes.add(n);
    }
  }

  void _tick() {
    if (_gaps > 0) {
      _note('lost $_gapSamples samples in $_gaps gaps (packet counter jumps)');
      _gaps = _gapSamples = 0;
    }
    if (_drv.mode == cmdSignalResist && _drv.lastResist.isNotEmpty) {
      final last = _contactNoted;
      if (last == null || _now().difference(last) >= timing.contactNoteEvery) {
        _contactNoted = _now();
        _note('contact ohms ${ohmsLine(_drv.lastResist)}');
      }
    }
  }

  // ---- data ------------------------------------------------------------------------------------------------
  void _onSamples(SignalPacket pkt, DateTime at, int gap) {
    if (_drv.streamStarts != _streamsSeen) {
      _streamsSeen = _drv.streamStarts;
      _note(null, newStream: true); // the headband counts from the start again: not a gap, not a repeat
    }
    if (gap > 0) {
      _gaps++;
      _gapSamples += gap;
    }
    if (!_signal.isClosed) _signal.add(pkt.samples);
  }

  void _onResist(Map<String, double> ohms, DateTime at) {
    if (!_resist.isClosed) _resist.add(ohms);
  }

  // ---- the interface -----------------------------------------------------------------------------------------
  void _alive() {
    if (_gone || _disposed) throw HeadbandLost('the headband is out of range');
  }

  /// The signal is wanted and looked after (not being stopped).
  bool get _streaming => _runner != null && !(_stopping?.isSet ?? true);

  /// Starts the signal and keeps it going: a drop or a stall is mended here (see the top of the file). Asking
  /// again while it runs sends the start command once more.
  @override
  Future<void> startSignal() async {
    _alive();
    if (_streaming) {
      if (_drv.isConnected) await _drv.command(_drv.mode == cmdSignalResist || _drv.mode == cmdSignal ? _drv.mode : _mode);
      return;
    }
    final previous = _runner; // a stop that is still winding down (a connection try in flight)
    final stopping = _stopping = Flag();
    _ticker ??= Timer.periodic(timing.notesEvery, (_) => _tick());
    late final Future<void> mine;
    mine = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      if (stopping.isSet || _disposed || _gone) return;
      await _supervise(stopping);
    }().whenComplete(() {
      if (identical(_runner, mine)) _runner = null;
    });
    _runner = mine;
  }

  Future<void> _supervise(Flag stopping) async {
    var ok = false;
    try {
      ok = await _drv.run(
        _mode,
        stopping,
        alreadyConnected: true,
        keepOpen: true,
        giveUpAfter: timing.healFor,
        onConnected: (info, attempt) {
          _reconnects++;
          final away = _lostAt == null ? 0 : _now().difference(_lostAt!).inMilliseconds / 1000;
          _lostAt = null;
          _status = info.status ?? _status;
          _note(
            'reconnected after ${away.toStringAsFixed(1)} s away (try ${attempt + 1}), battery '
            '${info.status?.battery ?? '?'}%; same files',
          );
        },
        onLost: (e, attempt, pause) {
          _lostAt ??= _now();
          _note(
            pause == Duration.zero
                ? 'headband lost: $e; still away after ${_now().difference(_lostAt!).inSeconds} s, handing over to the '
                      "app's reconnect"
                : 'headband lost: $e; trying again in ${_secs(pause)} s (try ${attempt + 1})',
          );
        },
      );
    } catch (e) {
      _note('own connection stopped unexpectedly: $e'); // a bug, not a drop: treated as lost
    }
    if (stopping.isSet || _disposed) return; // stopped on request
    if (!ok) _giveUp();
  }

  void _giveUp() {
    if (_gone) return;
    _gone = true;
    _ticker?.cancel();
    _tick();
    if (!_range.isClosed) _range.add(false);
  }

  static String _secs(Duration d) {
    if (d.inMilliseconds % 1000 == 0) return '${d.inSeconds}';
    return (d.inMilliseconds / 1000).toStringAsFixed(2);
  }

  @override
  Future<void> stopSignal() async {
    final runner = _runner, stopping = _stopping;
    if (runner == null || stopping == null) {
      if (!_gone && !_disposed && _drv.isConnected) await _drv.command(cmdIdle);
      return;
    }
    stopping.set();
    // A connection try in flight cannot be cancelled; it ends by itself and is not waited for here.
    await runner.timeout(timing.stopWait, onTimeout: () {});
    _tick();
  }

  /// Before the signal: resistance mode. While the signal runs: a contact check inside the same connection
  /// (the driver switches to resistance for [OwnTiming.contactFor] and back by itself); with command 5 nothing
  /// to do, contact already arrives.
  @override
  Future<void> startResist() async {
    _alive();
    if (_streaming) {
      if (_drv.mode != cmdSignalResist) _drv.checkContact();
      return;
    }
    await _drv.command(cmdIdle);
    await _drv.command(cmdResist);
  }

  @override
  Future<void> stopResist() async {
    if (_streaming || _gone || _disposed) return;
    if (_drv.isConnected) await _drv.command(cmdIdle);
  }

  /// False only once this object has given up; while it mends a drop it still counts as in range.
  @override
  Future<bool> isInRange() async => !_gone && !_disposed;

  @override
  Future<int> battery() async {
    final at = _statusAt, st = _status;
    final fresh = at != null && _now().difference(at) < timing.statusMaxAge;
    if ((!fresh || st == null) && !_gone && _drv.isConnected) {
      try {
        return (await _drv.readStatus()).battery;
      } on HeadbandLost {
        if (st == null) rethrow;
      }
    }
    if (st == null) throw HeadbandLost('no battery reading yet');
    return st.battery;
  }

  /// Safe at any time, also while it mends a drop or after it gave up.
  @override
  Future<void> disconnectAndDispose() async {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _stopping?.set();
    try {
      await _runner?.timeout(timing.stopWait, onTimeout: () {});
    } catch (_) {}
    await _drv.close(idle: true);
    await _signal.close();
    await _resist.close();
    await _range.close();
    await _notes.close();
  }
}
