// A fake BrainBit Black for tests: a [BleTransport] that speaks the protocol as our notes describe it
// (docs/own-ble-driver.md), with the same behaviour as the laptop's fake (tests/fake_bleak): link drops, lost
// packets, a stalled stream, resistance, command 5 (or a headband that does not know it), either service suffix.
// Written from the notes and the Python fake, not from the Dart parser, so the tests check the driver's decoding
// against a second reading.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/headband/own/transport.dart';

const int fakeFs = 250;
const List<String> fakeWireOrder = ['O2', 'T3', 'T4', 'O1']; // wire order the fake sends
const double fakeVoltsPerCount = 2.4 / (6 * (1 << 23)); // volts per count at gain 6
const String fakeAddress = 'C0:FF:EE:00:00:01';

String fakeUuid(int n, String suffix) => '7e40000$n-b534-f393-68a9-e50e24dcca9$suffix';

/// One made-up sample (volts by channel name): 10 Hz alpha that switches every minute, a blink every 7 s, noise.
Map<String, double> fakeSample(int n, math.Random rng) {
  final t = n / fakeFs;
  final closed = (t ~/ 60) % 2 == 0;
  double gauss() {
    final u = 1 - rng.nextDouble(), v = rng.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  final alpha = (closed ? 25e-6 : 6e-6) * math.sin(2 * math.pi * 10 * t);
  final blink = 80e-6 * math.exp(-math.pow(((t % 7) - 0.15) / 0.08, 2));
  double noise() => 4e-6 * gauss();
  return {
    'O1': alpha + blink + noise(),
    'O2': 0.9 * alpha + blink + noise(),
    'T3': 0.3 * blink + noise(),
    'T4': 0.3 * blink + noise(),
  };
}

Uint8List encodeSignal(int counter, List<Map<String, double>> rows, {int marker = 0}) {
  final out = BytesBuilder();
  final c32 = counter % (1 << 32);
  out.add([c32 & 0xFF, (c32 >> 8) & 0xFF, (c32 >> 16) & 0xFF, (c32 >> 24) & 0xFF]);
  for (final r in rows) {
    out.addByte(marker);
    for (final name in fakeWireOrder) {
      final c = (r[name]! / fakeVoltsPerCount).round().clamp(-(1 << 23), (1 << 23) - 1) & 0xFFFFFF;
      out.add([c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF]);
    }
  }
  return out.toBytes();
}

Uint8List encodeResist(int counter, Map<String, int> ohms) {
  final b = ByteData(20)..setUint32(0, counter % (1 << 32), Endian.little);
  for (var j = 0; j < 4; j++) {
    b.setUint32(4 + 4 * j, ohms[fakeWireOrder[j]]!, Endian.little);
  }
  return b.buffer.asUint8List();
}

class FakeHeadband implements BleTransport, WaitingTransport {
  FakeHeadband({
    this.address = fakeAddress,
    this.name = 'BB Black',
    this.suffix = '7',
    this.interval = const Duration(milliseconds: 4),
    this.dropAfter,
    this.dropFor = const Duration(seconds: 3),
    this.maxDrops,
    this.loseEvery = 0,
    this.counter0 = 0,
    this.battery = 87,
    this.resistOhms = const {'O1': 150000, 'O2': 220000, 'T3': 400000, 'T4': 180000},
    this.ignoreCmd5 = false,
    this.stallAfter,
    this.mtu = 517,
    this.needsPairing = false,
    this.directFails = false,
    this.rows,
    this.packetsPerTick = 1,
    int seed = 1,
  }) : rng = math.Random(seed);

  final String address;
  final String name;
  final String suffix;

  /// Time between signal packets (8 samples each): 32 ms on the real headband, shorter in tests.
  final Duration interval;

  /// Streaming time before the link drops, and how long the headband then stays away.
  Duration? dropAfter;
  Duration dropFor;
  int? maxDrops;

  /// Lose every Nth signal packet (0 = none).
  int loseEvery;
  final int counter0;
  int battery;
  Map<String, int> resistOhms;

  /// A headband that does not know command 5 ("mode error", no signal).
  final bool ignoreCmd5;

  /// The stream goes silent this long after each connection (the link stays up).
  Duration? stallAfter;
  final int? mtu;

  /// Reads and subscriptions fail until the link is paired.
  final bool needsPairing;

  /// A connection without a scan first never answers (an address Android cannot place).
  bool directFails;

  /// The samples to send, by sample index; default [fakeSample].
  final Map<String, double> Function(int n)? rows;

  /// Signal packets per timer tick: above 1 the fake runs faster than its clock (whole sessions in a second).
  final int packetsPerTick;
  final math.Random rng;

  int mode = 2;
  int cmdError = 0;
  FakeLink? link; // the connected client
  DateTime awayUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int n = 0; // signal sample index
  late int counter = counter0;
  int packets = 0, drops = 0, scans = 0, connects = 0;
  final List<DateTime> connectTimes = [];
  final List<int> commands = [];
  final List<Map<String, double>> sent = []; // every sample put into a packet that was sent
  bool paired = false;
  bool _scanned = false;

  @override
  String get describe => 'fake headband';

  bool get away => DateTime.now().isBefore(awayUntil);

  List<GattService> gattTable() => [
    GattService('0000180a-0000-1000-8000-00805f9b34fb', [
      for (final x in ['24', '25', '26', '27', '29'])
        GattChar('00002a$x-0000-1000-8000-00805f9b34fb', const {'read'}),
    ]),
    GattService(fakeUuid(1, suffix), [
      GattChar(fakeUuid(2, suffix), const {'read', 'notify'}),
      GattChar(fakeUuid(3, suffix), const {'write'}),
      GattChar(fakeUuid(4, suffix), const {'notify'}),
      GattChar(fakeUuid(5, suffix), const {'notify'}),
    ]),
  ];

  Uint8List read(String uuid) {
    const dev = {
      '2a24': 'BrainBit Black (fake)',
      '2a25': 'fake-serial',
      '2a26': '1.10.0',
      '2a27': '1.0.0',
      '2a29': 'fake',
    };
    if (needsPairing && !paired) throw BleError('read needs pairing');
    if (uuid.startsWith('00002a')) return Uint8List.fromList(dev[uuid.substring(4, 8)]!.codeUnits);
    if (uuid == fakeUuid(2, suffix)) return Uint8List.fromList([battery, cmdError & 0xFF, mode, 0]);
    throw BleError('read not permitted on $uuid');
  }

  void command(int cmd) {
    commands.add(cmd);
    if (cmd == 5 && ignoreCmd5) {
      cmdError = 2; // "mode error": this headband does not know command 5
      return;
    }
    cmdError = 0;
    if ((cmd == 3 || cmd == 5) && mode != 3 && mode != 5) {
      counter = counter0; // the counter restarts with each new stream (seen through the SDK)
    }
    mode = cmd;
  }

  /// The headband goes out of range: the link breaks and it does not answer for [dropFor].
  void drop() {
    drops++;
    awayUntil = DateTime.now().add(dropFor);
    link?._lostNow();
  }

  /// Bluetooth is switched off: a scan cannot even start.
  bool bluetoothOff = false;

  /// What each new link reports as its timing (none by default).
  List<String> linkFacts = const [];

  /// Waiting connects: whether this fake has them, how many were opened, are open now and were closed by their owner.
  bool hasWaiting = true;
  int waitingOpened = 0, waitingOpen = 0, waitingClosed = 0;
  Duration waitingPoll = const Duration(milliseconds: 10);

  @override
  BleWaiting? connectWaiting(String address, {required void Function() onLost}) {
    if (!hasWaiting) return null;
    waitingOpened++;
    waitingOpen++;
    return FakeWaiting(this, address, onLost);
  }

  @override
  Future<BleFound?> scan(bool Function(String name) match, Duration timeout) async {
    scans++;
    if (bluetoothOff) throw BleError('Bluetooth not enabled');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (link == null && !away && match(name)) {
      _scanned = true;
      return (address: address, name: name, rssi: -61, services: <String>[]);
    }
    await Future<void>.delayed(timeout < const Duration(milliseconds: 50) ? timeout : const Duration(milliseconds: 50));
    return null;
  }

  @override
  Future<BleLink> connect(String address, {required Duration timeout, required void Function() onLost}) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (directFails && !_scanned) {
      await Future<void>.delayed(timeout < const Duration(milliseconds: 100) ? timeout : const Duration(milliseconds: 100));
      throw BleError('no answer from $address');
    }
    if (address.toUpperCase() != this.address.toUpperCase() || away) {
      throw BleError('Device with address $address was not found.');
    }
    if (link != null) throw BleError('the headband keeps one connection');
    connects++;
    connectTimes.add(DateTime.now());
    final l = link = FakeLink(this, onLost);
    l._start();
    return l;
  }
}

/// The fake's waiting connect: it looks every [FakeHeadband.waitingPoll] whether the headband is back.
class FakeWaiting implements BleWaiting {
  FakeWaiting(this.hb, this._address, this._onLost) {
    _done.future.ignore();
    _timer = Timer.periodic(hb.waitingPoll, (_) => _look());
    _look();
  }
  final FakeHeadband hb;
  final String _address;
  final void Function() _onLost;
  final Completer<BleLink> _done = Completer<BleLink>();
  Timer? _timer;

  @override
  Future<BleLink> get link => _done.future;

  void _look() {
    if (_done.isCompleted) return;
    if (hb.bluetoothOff) return _end(error: BleError('Bluetooth not enabled'));
    if (_address.toUpperCase() != hb.address.toUpperCase() || hb.away || hb.link != null) return;
    hb.connects++;
    hb.connectTimes.add(DateTime.now());
    final l = hb.link = FakeLink(hb, _onLost);
    l._start();
    _end(link: l);
  }

  void _end({BleLink? link, BleError? error}) {
    _timer?.cancel();
    hb.waitingOpen--;
    if (link != null) {
      _done.complete(link);
    } else {
      _done.completeError(error!);
    }
  }

  @override
  Future<void> cancel() async {
    if (_done.isCompleted) return;
    hb.waitingClosed++;
    _end(error: BleError('the waiting connect was closed'));
  }
}

class FakeLink implements BleLink, LinkFacts {
  FakeLink(this.hb, this._onLost);

  /// The link's timing as Android would report it: every line of [FakeHeadband.linkFacts], at once.
  @override
  set onFacts(void Function(String line)? to) {
    if (to == null) return;
    for (final line in hb.linkFacts) {
      to(line);
    }
  }

  final FakeHeadband hb;
  final void Function() _onLost;
  final Map<String, void Function(Uint8List)> _subs = {};
  bool _connected = true;
  Timer? _timer;
  late DateTime _since;
  DateTime _nextResist = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _due = DateTime.now();

  @override
  bool get isConnected => _connected;
  @override
  int? get mtu => hb.mtu;

  /// Notifications while connected: signal packets every `interval`, resistance every third interval.
  void _start() {
    _since = _due = DateTime.now();
    _timer = Timer.periodic(hb.interval, (_) => _tick());
  }

  void _tick() {
    if (!_connected || !identical(hb.link, this)) return;
    final now = DateTime.now();
    // A late timer catches up, so the sample rate holds on a busy test machine (capped: no long bursts).
    var due = 0;
    while (!_due.isAfter(now) && due < 64) {
      _due = _due.add(hb.interval);
      due++;
    }
    if (due == 64) _due = now.add(hb.interval);
    for (var i = 0; i < due * hb.packetsPerTick && _connected; i++) {
      _packet(now);
    }
  }

  void _packet(DateTime now) {
    final stalled = hb.stallAfter != null && now.difference(_since) > hb.stallAfter!;
    if ((hb.mode == 3 || hb.mode == 5) && !stalled) {
      final rows = [
        for (var k = 0; k < 8; k++) hb.rows?.call(hb.n + k) ?? fakeSample(hb.n + k, hb.rng),
      ];
      hb.n += 8;
      hb.packets++;
      final pkt = encodeSignal(hb.counter, rows);
      hb.counter = (hb.counter + 8) % (1 << 32);
      if (!(hb.loseEvery > 0 && hb.packets % hb.loseEvery == 0)) {
        hb.sent.addAll(rows);
        _notify(fakeUuid(4, hb.suffix), pkt);
      }
    }
    if ((hb.mode == 4 || hb.mode == 5) && !now.isBefore(_nextResist)) {
      _nextResist = now.add(hb.interval * 3); // about 10 a second at the real packet rate (32 ms)
      _notify(fakeUuid(5, hb.suffix), encodeResist(hb.packets, hb.resistOhms));
    }
    final after = hb.dropAfter;
    if (after != null && now.difference(_since) > after && (hb.maxDrops == null || hb.drops < hb.maxDrops!)) {
      hb.drop();
    }
  }

  void _notify(String uuid, Uint8List data) {
    if (_connected) _subs[uuid]?.call(data);
  }

  void _end() {
    _connected = false;
    _timer?.cancel();
    if (identical(hb.link, this)) {
      hb.link = null;
      hb.mode = 2;
    }
  }

  /// Called by the fake headband when the link breaks.
  void _lostNow() {
    if (!_connected) return;
    _end();
    scheduleMicrotask(_onLost);
  }

  /// A "disconnected" callback that arrives late, after the driver has moved on (test hook).
  void lateLostCallback() => _onLost();

  void _need() {
    if (!_connected) throw BleError('Not connected');
  }

  @override
  Future<List<GattService>> services() async {
    _need();
    return hb.gattTable();
  }

  @override
  Future<Uint8List> read(String service, String characteristic) async {
    _need();
    await Future<void>.delayed(Duration.zero);
    return hb.read(characteristic.toLowerCase());
  }

  @override
  Future<void> write(String service, String characteristic, Uint8List data, {required bool withResponse}) async {
    _need();
    await Future<void>.delayed(Duration.zero);
    if (characteristic.toLowerCase() != fakeUuid(3, hb.suffix)) throw BleError('write not permitted on $characteristic');
    hb.command(data[0]);
  }

  @override
  Future<void> subscribe(String service, String characteristic, void Function(Uint8List data) onData) async {
    _need();
    if (hb.needsPairing && !hb.paired) throw BleError('subscribe needs pairing');
    _subs[characteristic.toLowerCase()] = onData;
  }

  @override
  Future<void> pair() async {
    _need();
    hb.paired = true;
  }

  @override
  Future<void> disconnect() async {
    if (_connected) _end();
  }
}
