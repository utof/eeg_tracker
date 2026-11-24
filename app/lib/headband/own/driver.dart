// Our own Bluetooth LE driver for the BrainBit Black: no BrainBit SDK. A port of scripts/brainbit_ble.py, method
// for method, on a thin transport (transport.dart) so tests run it against a fake headband.
//
// What it does: finds the headband (a known address first; a name scan only when there is none, or when the
// known address does not answer), connects, reads the device information and the status bytes (battery), starts
// the signal (command 3) or signal + contact together (command 5, TO VERIFY), decodes every notification into
// samples, counts lost samples from the headband's own counter and, after a drop, reconnects to the same address
// by itself with a growing pause (1, 2, 5, 10, 20, 30 s). Every failure reaches the caller as a HeadbandError.
//
// Safety: it scans, connects to and disconnects from this one headband and reads, writes and listens to it. It
// never removes a bond or another device (the transport has no such call) and never sends "power down".
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'protocol.dart';
import 'transport.dart';

/// Any failure talking to the headband. Callers catch this one type and reconnect.
class HeadbandError implements Exception {
  HeadbandError(this.message);
  final String message;

  @override
  String toString() => message;
}

class HeadbandNotFound extends HeadbandError {
  HeadbandNotFound(super.message);
}

/// The scan itself could not run (Bluetooth off, no permission, no plugin): not the same as "nothing found".
class ScanFailed extends HeadbandNotFound {
  ScanFailed(super.message);
}

class HeadbandLost extends HeadbandError {
  HeadbandLost(super.message);
}

/// A one-way switch others can wait on (Python's asyncio.Event).
class Flag {
  bool _set = false;
  final Set<void Function()> _waiters = {};

  bool get isSet => _set;

  void set() {
    if (_set) return;
    _set = true;
    final wake = _waiters.toList();
    _waiters.clear();
    for (final w in wake) {
      w();
    }
  }

  /// Waits up to [d]; true if the flag is set.
  Future<bool> wait(Duration d) => either([this], d);

  /// Waits up to [d] for any of [flags]; true if one is set.
  static Future<bool> either(List<Flag> flags, Duration d) {
    if (flags.any((f) => f._set)) return Future.value(true);
    final done = Completer<bool>();
    late final Timer timer;
    late final void Function() wake;
    void finish(bool v) {
      timer.cancel();
      for (final f in flags) {
        f._waiters.remove(wake);
      }
      if (!done.isCompleted) done.complete(v);
    }

    wake = () => finish(true);
    timer = Timer(d, () => finish(false));
    for (final f in flags) {
      f._waiters.add(wake);
    }
    return done.future;
  }
}

class BandInfo {
  BandInfo(this.address, this.name, this.service, this.rssi);
  final String address;
  final String name;
  final String service;
  final int? rssi;

  /// model, serial, firmware, hardware, manufacturer (those the headband has).
  final Map<String, String> info = {};
  BandStatus? status;
  int? mtu;
}

class BrainBitBle {
  BrainBitBle({
    required this.transport,
    String? address,
    String? name,
    Layout? layout,
    this.pair = false,
    this.timeout = const Duration(seconds: 20),
    this.scanFor = const Duration(seconds: 30),
    this.stall = stallAfter,
    this.backoffs = backoff,
    this.statusPeriod = statusEvery,
    this.contactTime = contactFor,
    this.poll = const Duration(milliseconds: 250),
    void Function(String line)? log,
    DateTime Function()? clock,
  }) : address = address?.toUpperCase(),
       name = name ?? '',
       layout = layout ?? defaultLayout,
       _log = log ?? ((_) {}),
       _now = clock ?? DateTime.now;

  final BleTransport transport;
  String? address;
  String name;
  final Layout layout;

  /// Bond after connecting (the headband must be in pairing mode the first time).
  final bool pair;
  final Duration timeout;
  final Duration scanFor;
  final Duration stall;
  final List<Duration> backoffs;
  final Duration statusPeriod;
  final Duration contactTime;
  final Duration poll;
  void Function(String line) _log;
  final DateTime Function() _now;

  void log(String line) => _log(line);

  /// Sends the driver's own lines somewhere else (the app's headband object puts them in the night's log).
  void setLog(void Function(String line) to) => _log = to;

  /// Every signal notification; gap = [counterGap] (lost samples if > 0).
  void Function(SignalPacket packet, DateTime arrival, int gap)? onSamples;

  /// Every resistance notification: ohms by name.
  void Function(Map<String, double> ohms, DateTime arrival)? onResist;

  /// Every status read or notification.
  void Function(BandStatus status)? onStatus;

  /// Every notification as received (the probe logs these).
  void Function(String uuid, Uint8List data, DateTime arrival)? onRaw;

  BleLink? _link;
  String? service;
  int mode = cmdIdle;
  int? rssi;

  /// Arrival time of the newest signal packet (or of the last start command).
  DateTime lastSignal = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, double> lastResist = {};
  BandStatus? status;
  int packets = 0, badPackets = 0, lostSamples = 0;

  /// How many times a stream was started (command 3 or 5): the headband's counter starts again each time.
  int streamStarts = 0;

  /// The services of the current link, as discovered (the probe writes them out).
  List<GattService> gatt = const [];
  int? _next; // the counter expected next
  Flag? _lost;
  String _lostReason = '';
  bool _closing = false;
  bool _writeResponse = true;
  bool _contactWanted = false;

  bool get isConnected => _link != null && !(_lost?.isSet ?? true) && _link!.isConnected;

  /// Set when the current link broke (null before the first connection).
  Flag? get lost => _lost;
  String get lostReason => _lostReason;

  // ---- finding and connecting ------------------------------------------------------------------------------
  /// The address to connect to: the known one, or the first BrainBit a name scan finds.
  Future<String> find() async {
    final known = address;
    if (known != null) return known;
    return scanForBand();
  }

  /// A name scan, whatever address is known; the address found becomes the known one.
  Future<String> scanForBand() async {
    log('scanning up to ${scanFor.inSeconds} s for a BrainBit by name');
    final BleFound? dev;
    try {
      dev = await transport.scan(isBrainBit, scanFor).timeout(scanFor + const Duration(seconds: 5));
    } on BleError catch (e) {
      throw ScanFailed('scan failed: $e');
    } on TimeoutException {
      throw ScanFailed('scan failed: no answer');
    }
    if (dev == null) throw HeadbandNotFound('no BrainBit found: is it switched on?');
    address = dev.address.toUpperCase();
    name = dev.name;
    rssi = dev.rssi;
    return address!;
  }

  /// Awaits one transport call with a timeout; any failure becomes a HeadbandLost naming [what].
  Future<T> _ble<T>(Future<T> call, String what, [Duration? limit]) async {
    try {
      return await call.timeout(limit ?? timeout);
    } on BleError catch (e) {
      throw HeadbandLost('$what failed: $e');
    } on TimeoutException {
      throw HeadbandLost('$what failed: no answer in ${(limit ?? timeout).inSeconds} s');
    } on FormatException catch (e) {
      throw HeadbandLost('$what failed: ${e.message}');
    } on StateError catch (e) {
      throw HeadbandLost('$what failed: ${e.message}');
    }
  }

  /// The link of [session] (default: the current one) broke. A late callback from an earlier connection names
  /// that connection's flag, so it cannot mark a newer session as lost.
  void _markLost(String reason, [Flag? session]) {
    final ev = session ?? _lost;
    if (identical(ev, _lost) && ev != null && !_closing && !ev.isSet) {
      _lostReason = reason;
      ev.set();
    }
  }

  /// Connect, find the 7e4000xx service, read device information and status, subscribe to notifications.
  Future<BandInfo> connect() async {
    final address = await find();
    _closing = false;
    final session = _lost = Flag();
    _next = null;
    _factsSaid = 0;
    linkTiming = null;
    final attempt = transport.connect(address, timeout: timeout, onLost: () => _markLost('link dropped', session));
    final BleLink link;
    try {
      link = await _ble(attempt, 'connect', timeout + const Duration(seconds: 5));
    } on HeadbandLost {
      // A connection that still opens after we gave up must not stay open.
      unawaited(attempt.then((l) => l.disconnect(), onError: (_) {}));
      rethrow;
    }
    return _adopt(link, address);
  }

  /// The link is open: it becomes this driver's, and the headband is set up on it.
  Future<BandInfo> _adopt(BleLink link, String address) async {
    if (_closing) {
      // close() was called while the connection was still opening: do not keep the late link.
      unawaited(link.disconnect().catchError((_) {}));
      throw HeadbandLost('closed while connecting');
    }
    _link = link;
    if (link is LinkFacts) (link as LinkFacts).onFacts = _onLinkFacts;
    try {
      return await _setup(link, address);
    } on HeadbandError {
      await close(idle: false);
      rethrow;
    }
  }

  /// The link's real timing goes into the log once per connection, and again only when Android changes it (at most
  /// [_factsMax] lines a connection): the numbers the research asked for, without a snoop log.
  static const int _factsMax = 4;
  int _factsSaid = 0;

  /// The newest timing report of the current link (null: none yet).
  String? linkTiming;

  void _onLinkFacts(String line) {
    linkTiming = line;
    if (_factsSaid >= _factsMax) return;
    _factsSaid++;
    log(line);
  }

  /// Leaves a waiting connect to the known address open (DECISIONS 940): the phone's Bluetooth chip listens for the
  /// headband and connects when it shows up; then the headband is set up as after [connect]. Null when there is no
  /// known address or the transport has no waiting connect. `cancel` closes it (and a link that opened meanwhile).
  ({Future<BandInfo> info, Future<void> Function() cancel})? waitForBand() {
    final t = transport, address = this.address;
    if (address == null || t is! WaitingTransport) return null;
    _closing = false;
    final session = _lost = Flag();
    _next = null;
    _factsSaid = 0;
    linkTiming = null;
    final waiting = (t as WaitingTransport).connectWaiting(address, onLost: () => _markLost('link dropped', session));
    if (waiting == null) return null;
    final info = waiting.link.then<BandInfo>(
      (link) => _adopt(link, address),
      onError: (Object e) => throw HeadbandLost('the waiting connect ended: $e'),
    );
    info.ignore();
    return (
      info: info,
      cancel: () async {
        _closing = true;
        try {
          await waiting.cancel().timeout(const Duration(seconds: 6));
        } catch (_) {}
        await close(idle: false);
      },
    );
  }

  Future<BandInfo> _setup(BleLink link, String address) async {
    if (pair) {
      try {
        await _ble(link.pair(), 'pairing', const Duration(seconds: 30));
      } on HeadbandLost catch (e) {
        throw HeadbandLost('$e; $pairingHint');
      }
    }
    final services = await _ble(link.services(), 'service discovery');
    gatt = services;
    final found = services.where((s) => serviceRe.hasMatch(s.uuid.toLowerCase())).toList();
    if (found.isEmpty) {
      throw HeadbandError(
        'no 7e4000xx BrainBit service on this device; services: ${services.map((s) => s.uuid).join(', ')}',
      );
    }
    final svc = service = found.first.uuid.toLowerCase();
    final chars = {for (final c in found.first.characteristics) c.uuid.toLowerCase(): c};
    final cmd = chars[charUuid(svc, commandChar)];
    if (cmd == null) throw HeadbandError('service $svc has no command characteristic');
    _writeResponse = cmd.properties.contains('write');
    final info = BandInfo(address, name, svc, rssi);
    final infoSvc = uuid16(deviceInfoService);
    final have = {
      for (final s in services)
        if (s.uuid.toLowerCase() == infoSvc)
          for (final c in s.characteristics) c.uuid.toLowerCase(),
    };
    for (final e in deviceInfo.entries) {
      if (!have.contains(uuid16(e.value))) continue; // optional
      try {
        final raw = await _ble(link.read(infoSvc, uuid16(e.value)), 'read ${e.key}', const Duration(seconds: 5));
        info.info[e.key] = String.fromCharCodes(raw.where((b) => b >= 32 && b < 127)).trim();
      } on HeadbandLost {
        // optional
      }
    }
    info.mtu = link.mtu;
    final mtu = info.mtu;
    if (mtu != null && mtu < mtuNeeded) {
      log('the link carries $mtu-byte packets, the signal needs $mtuNeeded: packets may arrive cut short');
    }
    try {
      info.status = await readStatus();
    } on HeadbandLost catch (e) {
      if (!link.isConnected) rethrow;
      log('status read failed ($e); $pairingHint');
    }
    final handlers = <int, void Function(Uint8List)>{
      statusChar: _onStatusNote,
      signalChar: _onSignal,
      resistChar: _onResist,
    };
    for (final e in handlers.entries) {
      final c = chars[charUuid(svc, e.key)];
      if (c == null || !c.notifies) {
        if (e.key == signalChar) throw HeadbandError('service $svc has no signal characteristic to subscribe to');
        continue;
      }
      try {
        await _ble(link.subscribe(svc, c.uuid, e.value), 'subscribe to ${c.uuid}');
      } on HeadbandLost catch (e) {
        throw HeadbandLost('$e; $pairingHint');
      }
    }
    return info;
  }

  Future<BandStatus> readStatus() async {
    final link = _link, svc = service;
    if (link == null || svc == null) throw HeadbandLost('not connected');
    final raw = await _ble(link.read(svc, charUuid(svc, statusChar)), 'status read', const Duration(seconds: 5));
    final BandStatus st;
    try {
      st = decodeStatus(raw);
    } on FormatException catch (e) {
      throw HeadbandLost('status read failed: ${e.message}');
    }
    _noteStatus(st);
    return st;
  }

  /// Subscribes [onData] to one more characteristic of the open link (the probe listens to everything).
  Future<void> alsoSubscribe(String serviceUuid, String charUuid, void Function(Uint8List data) onData) async {
    final link = _link;
    if (link == null) throw HeadbandLost('not connected');
    await _ble(link.subscribe(serviceUuid, charUuid, onData), 'subscribe $charUuid');
  }

  /// Reads any characteristic of the open link (the probe's list of every readable value).
  Future<Uint8List> readAny(String serviceUuid, String charUuid) async {
    final link = _link;
    if (link == null) throw HeadbandLost('not connected');
    return _ble(link.read(serviceUuid, charUuid), 'read $charUuid', const Duration(seconds: 5));
  }

  // ---- notifications -------------------------------------------------------------------------------------
  void _guard(String what, void Function() call) {
    try {
      call();
    } catch (e) {
      log('$what callback failed: $e'); // a caller's bug must not break the link
    }
  }

  void _noteStatus(BandStatus st) {
    status = st;
    final cb = onStatus;
    if (cb != null) _guard('status', () => cb(st));
  }

  void _raw(int n, Uint8List data, DateTime now) {
    final cb = onRaw, svc = service;
    if (cb != null && svc != null) _guard('raw', () => cb(charUuid(svc, n), data, now));
  }

  void _onStatusNote(Uint8List data) {
    _raw(statusChar, data, _now());
    try {
      _noteStatus(decodeStatus(data));
    } on FormatException {
      // not a status we know
    }
  }

  void _onSignal(Uint8List data) {
    final now = _now();
    _raw(signalChar, data, now);
    final SignalPacket pkt;
    try {
      pkt = decodeSignal(data, layout);
    } on FormatException {
      badPackets++;
      return;
    }
    lastSignal = now;
    packets++;
    final gap = counterGap(_next, pkt.counter);
    if (gap > 0) lostSamples += gap;
    _next = (pkt.counter + pkt.samples.length) % counterMod;
    final cb = onSamples;
    if (cb != null) _guard('samples', () => cb(pkt, now, gap));
  }

  void _onResist(Uint8List data) {
    final now = _now();
    _raw(resistChar, data, now);
    final Map<String, double> ohms;
    try {
      ohms = decodeResist(data, layout);
    } on FormatException {
      return;
    }
    lastResist = ohms;
    final cb = onResist;
    if (cb != null) _guard('resistance', () => cb(ohms, now));
  }

  // ---- commands ------------------------------------------------------------------------------------------
  /// Writes one command byte (2 idle, 3 signal, 4 resistance, 5 signal+resistance).
  Future<void> command(int cmd) async {
    if (cmd == cmdPowerDown) {
      throw ArgumentError("power down is never sent: it would switch the headband's amplifier off");
    }
    final link = _link, svc = service;
    if (link == null || svc == null) throw HeadbandLost('not connected');
    await _ble(
      link.write(svc, charUuid(svc, commandChar), Uint8List.fromList([cmd]), withResponse: _writeResponse),
      'command $cmd',
    );
    mode = cmd;
    if (cmd == cmdSignal || cmd == cmdSignalResist) {
      _next = null;
      streamStarts++;
      lastSignal = _now(); // the stall timer starts now
    }
  }

  /// Asks for a contact check; the streaming loop runs it between packets.
  void checkContact() => _contactWanted = true;

  /// Resistance mode for [contactTime], then idle. Returns the last ohms per electrode (empty if none came).
  Future<Map<String, double>> measureContact() async {
    lastResist = {};
    await command(cmdIdle);
    await command(cmdResist);
    final lost = _lost;
    if (lost != null && await lost.wait(contactTime)) throw HeadbandLost(_lostReason);
    await command(cmdIdle);
    return Map.of(lastResist);
  }

  // ---- one session and the reconnecting loop -----------------------------------------------------------------
  /// Streams in [mode] until [stopping] is set (returns the mode in use) or the headband is lost (throws
  /// HeadbandLost). A stall first gets the start command again, then counts as lost. Command 5 that brings no
  /// signal falls back to command 3 (returned, so the caller keeps it).
  Future<int> streamUntilLost(
    int mode,
    Flag stopping, {
    void Function(Map<String, double> ohms)? onContact,
  }) async {
    await command(mode);
    final started = _now();
    var gotAny = false, resent = false;
    var nextStatus = _now().add(statusPeriod);
    final lost = _lost!;
    while (!stopping.isSet) {
      await Flag.either([lost, stopping], poll);
      if (lost.isSet) throw HeadbandLost(_lostReason.isEmpty ? 'link dropped' : _lostReason);
      if (stopping.isSet) break;
      final now = _now();
      gotAny = gotAny || lastSignal.isAfter(started);
      if (_contactWanted) {
        _contactWanted = false;
        final Map<String, double> ohms;
        if (mode == cmdSignalResist) {
          ohms = Map.of(lastResist);
        } else {
          ohms = await measureContact();
          await command(mode);
        }
        onContact?.call(ohms);
        resent = false;
        continue;
      }
      final quiet = now.difference(lastSignal);
      if (mode == cmdSignalResist && !gotAny && quiet > stall) {
        log(
          'signal+resistance (command 5) gave no signal in ${quiet.inSeconds} s; '
          'falling back to signal only (command 3)',
        );
        mode = cmdSignal;
        await command(cmdIdle);
        await command(mode);
        continue;
      }
      if (quiet > stall * 2) throw HeadbandLost('no signal for ${quiet.inSeconds} s');
      if (quiet > stall && !resent) {
        log('no signal for ${quiet.inSeconds} s: sending the start command again');
        await command(mode);
        lastSignal = now.subtract(quiet);
        resent = true;
      } else if (quiet < const Duration(seconds: 1)) {
        resent = false;
      }
      if (!now.isBefore(nextStatus)) {
        nextStatus = now.add(statusPeriod);
        try {
          await readStatus();
        } on HeadbandLost catch (e) {
          log('status read failed: $e');
        }
      }
    }
    return mode;
  }

  /// Connect, stream and reconnect to the same address after every failure, until [stopping] is set (true).
  ///
  /// [onConnected] (info, attempt) may return a Future; [onLost] (error, attempt, pause before the next try).
  /// Beyond the Python driver, for the app's headband object: [alreadyConnected] starts on the open link,
  /// [keepOpen] leaves the link open and idle at the end, and with [giveUpAfter] the loop ends (false, link
  /// closed) once the headband has given no data for that long, instead of trying for ever.
  Future<bool> run(
    int mode,
    Flag stopping, {
    FutureOr<void> Function(BandInfo info, int attempt)? onConnected,
    void Function(HeadbandError error, int attempt, Duration pause)? onLost,
    void Function(Map<String, double> ohms)? onContact,
    bool alreadyConnected = false,
    bool keepOpen = false,
    Duration? giveUpAfter,
  }) async {
    var attempt = 0;
    var useOpenLink = alreadyConnected && isConnected;
    DateTime? quietSince;
    var seenPackets = packets;
    while (!stopping.isSet) {
      try {
        if (!useOpenLink) {
          final info = await connect();
          if (stopping.isSet) break;
          await onConnected?.call(info, attempt);
          attempt = 0;
        }
        useOpenLink = false;
        mode = await streamUntilLost(mode, stopping, onContact: onContact);
      } on HeadbandError catch (e) {
        useOpenLink = false;
        if (packets != seenPackets) {
          seenPackets = packets;
          quietSince = null; // data came since the last failure: the wait starts again
        }
        final since = quietSince ??= _now();
        final pause = backoffs[math.min(attempt, backoffs.length - 1)];
        final giveUp = giveUpAfter != null && _now().difference(since) + pause >= giveUpAfter;
        onLost?.call(e, attempt, giveUp ? Duration.zero : pause);
        attempt++;
        await close(idle: false);
        if (giveUp) return false;
        await stopping.wait(pause);
        continue;
      }
    }
    if (keepOpen && isConnected) {
      try {
        await command(cmdIdle);
      } on HeadbandError {
        // the link broke as we stopped: the next start reconnects
      }
    } else {
      await close(idle: true);
    }
    return true;
  }

  /// Stops streaming (idle) when asked and the link is up, then disconnects this headband only.
  Future<void> close({bool idle = true}) async {
    final link = _link, svc = service;
    _link = null;
    _closing = true;
    if (link == null) return;
    try {
      if (idle && link.isConnected && svc != null) {
        await link
            .write(svc, charUuid(svc, commandChar), Uint8List.fromList([cmdIdle]), withResponse: _writeResponse)
            .timeout(const Duration(seconds: 3));
      }
    } catch (_) {}
    try {
      await link.disconnect().timeout(const Duration(seconds: 5));
    } catch (_) {}
    mode = cmdIdle;
  }
}
