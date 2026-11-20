// The DIY board behind the app's one headband interface (lib/headband/diy/board.dart), on the fake board
// (test/diy/fake_board.dart) and on a real UDP socket on this machine: frames become samples in volts, damaged
// datagrams are counted and dropped, gaps are counted (board missed / link lost), repeats and late datagrams are
// dropped, a restart or a new mode ends the board object (the recorder then starts a new file set), the 8-channel
// chip records all its channels with a header that names them (DECISIONS 630-639), and nothing is ever sent to the
// board.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/headband/diy/board.dart';
import 'package:eeg_tracker/headband/diy/e9.dart';
import 'package:eeg_tracker/headband/diy/link.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/signal/layout.dart' show parsePositions;
import 'package:flutter_test/flutter_test.dart';

import 'diy/fake_board.dart';

const _ms = Duration(milliseconds: 1);
const fast = DiyTiming(
  flushEvery: Duration(milliseconds: 5),
  notesEvery: Duration(milliseconds: 30),
  directWait: Duration(milliseconds: 100),
);

Uint8List _hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// A band with its samples, notes and range events collected.
class Watched {
  Watched(this.band) {
    band.signal.listen(batches.add);
    (band as BandNotes).notes.listen((n) {
      if (n.line != null) notes.add(n.line!);
    });
    band.rangeChanges.listen(range.add);
  }
  final Headband band;
  final List<List<Sample>> batches = [];
  final List<String> notes = [];
  final List<bool> range = [];

  List<Sample> get samples => [for (final b in batches) ...b];
  List<int> get seqs => [for (final s in samples) s.pack];
}

Future<void> settle([int ms = 30]) => Future<void>.delayed(_ms * ms);

Future<void> waitFor(bool Function() done, {Duration max = const Duration(seconds: 5)}) async {
  final t0 = DateTime.now();
  while (!done()) {
    if (DateTime.now().difference(t0) > max) fail('timed out waiting');
    await Future<void>.delayed(_ms * 5);
  }
}

void main() {
  late FakeLink link;
  late FakeBoard board;
  late DiyFinder finder;

  setUp(() {
    link = FakeLink();
    board = FakeBoard();
    finder = DiyFinder(link: () => link, timing: fast);
  });

  tearDown(() => finder.dispose());

  /// The finder's first band, with the board already streaming.
  Future<Watched> connected() async {
    final found = finder.find(const Duration(seconds: 2));
    await settle(5);
    sendAll(link, board.next(3));
    final band = await found;
    expect(band, isNotNull);
    final w = Watched(band!);
    await band.startSignal();
    return w;
  }

  test('the fake board encodes like the firmware (its golden frames)', () {
    final golden = jsonDecode(File('../tests/fake_diy/golden/e9_vectors.json').readAsStringSync()) as List;
    for (final g in golden.cast<Map<String, Object?>>()) {
      final got = encode(
        (g['codes']! as List).cast<int>(),
        seq: g['seq']! as int,
        timeUs: g['tick']! as int,
        overruns: g['overruns']! as int,
        flags: g['flags']! as int,
        gain: g['gain']! as int,
        fs: g['fs']! as int,
        status: g['status']! as int,
      );
      expect(got, _hex(g['hex']! as String), reason: g['name'] as String?);
    }
  });

  test('no frames: find gives null after its wait; connectDirect says so in words', () async {
    expect(await finder.find(const Duration(milliseconds: 50)), isNull);
    expect(link.isOpen, isTrue); // listening all along
    await expectLater(
      finder.connectDirect(const BandId(name: 'DIY board', address: 'udp:9000')),
      throwsA(isA<DiyBoardError>().having((e) => '$e', 'text', contains('No frames from the board'))),
    );
  });

  test('frames become samples: sequence number and CH1-CH4 in volts, in batches', () async {
    final w = await connected();
    expect(w.band.name, 'DIY board');
    expect(w.band.address, 'udp:$diyUdpPort');
    expect(w.band.id.family, 'diy');
    expect(w.band.rssi, isNull);
    expect(await w.band.isInRange(), isTrue);
    sendAll(link, board.next(40));
    await waitFor(() => w.samples.length == 43);
    expect(w.seqs, [for (var s = 501; s <= 543; s++) s]); // the three before startSignal are kept too
    expect(w.batches.length, lessThan(43)); // a batch every few ms, not a row per datagram
    final lsb = 4.5 / (24 * 8388608);
    final s = w.samples.first;
    final want = board.codes(501)[0] * lsb;
    expect([s.o1, s.o2, s.t3, s.t4], [want, want, want, want]);
    expect(want.abs(), closeTo(4.5 / 2400, 1e-8));
  });

  test('the board\'s own lines: driver, channels, scaling, format and "not EEG"', () async {
    finder = DiyFinder(link: () => link, timing: fast, names: const ['O1', 'O2', 'Fz', 'Fp1']);
    final w = await connected();
    await settle();
    final log = w.notes.join('\n');
    expect(log, contains('driver DIY board (lib/headband/diy): eeg_ads1299_lab bench firmware, E9 protocol version 1'));
    expect(log, contains('datagrams from $boardAddress'));
    expect(log, contains('channels O1 O2 Fz Fp1'));
    expect(log, contains('board 4 channels, 250 Hz, gain 24, vref 4.5 V (assumed'));
    expect(log, contains('format .f32 records <I4f: board sequence number, then O1 O2 Fz Fp1 in volts; 250 Hz'));
    expect(log, contains("mode test signal: the chip's own square wave, not EEG (flags 0x01)"));
    expect(log, contains('contact and battery: not measured by this board'));
    final live = (w.band as OtherBoard).board;
    expect(live.names, ['O1', 'O2', 'Fz', 'Fp1']);
    expect(live.notEeg, isTrue);
    expect(live.modeText, contains('not EEG'));
    expect(live.sender, boardAddress);
  });

  test('damaged datagrams are counted and dropped; the good ones go on', () async {
    final w = await connected();
    final frames = board.next(30);
    for (var i = 0; i < frames.length; i++) {
      final f = Uint8List.fromList(frames[i]);
      if (i % 7 == 3) f[30] ^= 0x10; // fails its CRC
      link.send(f);
    }
    link.send(utf8.encode('hello'));
    link.send(frames[0].sublist(0, 20));
    await waitFor(() => w.notes.any((l) => l.startsWith('bad datagrams')));
    expect(w.seqs.where((s) => s > 503), [for (var i = 0; i < 30; i++) if (i % 7 != 3) 504 + i]);
    expect(w.notes.firstWhere((l) => l.startsWith('bad datagrams')), 'bad datagrams 6 (CRC or framing)');
    // the lost sequence numbers of the damaged ones show as gaps on the link
    await waitFor(() => w.notes.any((l) => l.startsWith('lost ')));
    expect(w.notes.firstWhere((l) => l.startsWith('lost ')), 'lost 4 samples in 4 gaps (board missed 0, link lost 4)');
  });

  test('gaps are counted, never filled: board missed and link lost apart', () async {
    final w = await connected();
    sendAll(link, board.next(5));
    board.miss(2); // the board skipped 2 conversions itself
    sendAll(link, board.next(5));
    board.next(3); // lost on the way
    sendAll(link, board.next(5));
    await waitFor(() => w.notes.any((l) => l.startsWith('lost ')));
    expect(w.notes.firstWhere((l) => l.startsWith('lost ')), 'lost 5 samples in 2 gaps (board missed 2, link lost 3)');
    expect(w.samples.length, 3 + 15);
    final live = (w.band as OtherBoard).board;
    expect([live.lost, live.boardMissed], [5, 2]);
  });

  test('repeated and late datagrams are dropped, never sorted in', () async {
    final w = await connected();
    final f = board.next(10);
    sendAll(link, [f[0], f[1], f[1], f[2], f[3], f[0], f[4], f[5], f[5], f[6], f[2], f[7], f[8], f[9]]);
    await waitFor(() => w.notes.any((l) => l.startsWith('repeated')));
    expect(w.seqs, [for (var s = 501; s <= 513; s++) s]);
    expect(w.notes.firstWhere((l) => l.startsWith('repeated')), 'repeated 2, late 2 frames dropped');
  });

  test('a board restart ends the band (a new file set) and the next band starts from the restart', () async {
    final w = await connected();
    sendAll(link, board.next(10));
    await waitFor(() => w.samples.length == 13);
    board.restart();
    sendAll(link, board.next(6));
    await waitFor(() => w.range.contains(false));
    expect(await w.band.isInRange(), isFalse);
    expect(w.notes, contains('board restarted (sequence went back from 513 to 1): this file set ends here'));
    expect(w.seqs.last, 513); // nothing of the new capture in the old band
    sendAll(link, board.next(4));
    final again = await finder.connectDirect(w.band.id);
    final w2 = Watched(again);
    await again.startSignal();
    await waitFor(() => w2.samples.length == 10);
    expect(w2.seqs, [for (var s = 1; s <= 10; s++) s]); // kept while no band held them
    await settle();
    expect(w2.notes, contains('a new capture: board restarted (sequence went back from 513 to 1)'));
    await w.band.disconnectAndDispose();
    await again.disconnectAndDispose();
  });

  test('a new mode (test signal to shorted inputs) is a new capture too', () async {
    final w = await connected();
    board.restart(mode: 'N');
    sendAll(link, board.next(3));
    await waitFor(() => w.range.contains(false));
    expect(
      w.notes,
      contains('board restarted (configuration changed from 4 ch 250 Hz gain 24 test to 4 ch 250 Hz gain 24 short): '
          'this file set ends here'),
    );
    final again = Watched(await finder.connectDirect(w.band.id));
    await settle();
    expect(again.notes.join('\n'), contains("mode shorted inputs: the chip's own noise, not EEG (flags 0x02)"));
    expect((again.band as OtherBoard).board.mode, 'short');
  });

  test('the 8-channel chip records all eight channels in place, named Ch1..Ch8 when the setting gives four', () async {
    board = FakeBoard(channels: 8, mode: 'S'); // shorted inputs: a different value on every channel
    final w = await connected();
    final frames = board.next(20);
    sendAll(link, frames);
    await waitFor(() => w.samples.length == 23);
    for (var k = 0; k < 20; k++) {
      final s = w.samples[3 + k], f = decodeFrame(frames[k]);
      expect(s.pack, f.seq);
      expect(s.volts, f.volts()); // all eight, each in its place
    }
    final h = (w.band as OtherBoard).header;
    expect(h.names, ['Ch1', 'Ch2', 'Ch3', 'Ch4', 'Ch5', 'Ch6', 'Ch7', 'Ch8']);
    expect(h.record, '<I8f');
    expect(h.counter, 'board sequence number');
    expect(h.device, 'DIY board');
    expect(h.sampleRate, 250);
    expect((w.band as OtherBoard).board.names, h.names);
    await settle();
    expect(
      w.notes,
      contains('the setting names 4 channels (O1 O2 Fz Fp1) but the board sends 8: using Ch1 Ch2 Ch3 Ch4 Ch5 Ch6 Ch7 '
          'Ch8; give 8 names on the Headband connection page'),
    );
    expect(w.notes, contains(startsWith('format .f32 records <I8f: board sequence number, then Ch1 Ch2')));
  });

  test('eight names in the setting name the 8-channel chip; the positions file places them in its header', () async {
    finder = DiyFinder(
      link: () => link,
      timing: fast,
      names: const ['Fz', 'Cz', 'Pz', 'O1', 'O2', 'T7', 'T8', 'X1'],
      positions: parsePositions('X1 60 30\n'),
    );
    board = FakeBoard(channels: 8);
    final w = await connected();
    final h = (w.band as OtherBoard).header;
    expect(h.names, ['Fz', 'Cz', 'Pz', 'O1', 'O2', 'T7', 'T8', 'X1']);
    expect(h.channels[3].site, 'O1');
    expect(h.channels[7].xyz, isNotNull); // placed by the positions file
    expect(h.pick(const ['O1', 'O2', 'T3', 'T4'], who: 'x'), [3, 4, 5, 6]);
  });

  test('datagrams from outside the local network are ignored; a second sender is named', () async {
    final w = await connected();
    sendAll(link, board.next(5), from: '8.8.8.8');
    sendAll(link, board.next(5));
    sendAll(link, board.next(2), from: '192.168.1.77');
    await waitFor(() => w.notes.any((l) => l.startsWith('ignored')));
    expect(w.notes, contains('ignored 5 datagrams from outside the local network'));
    expect(w.notes, contains('datagrams from 192.168.1.77'));
    expect(w.notes, contains('more than one sender on this port: is another board or program sending here?'));
    expect(w.seqs.contains(506), isFalse);
  });

  test('levels: the test square is about 3750 uV from peak to peak on every channel', () async {
    final w = await connected();
    sendAll(link, board.next(600));
    await waitFor(() => (w.band as OtherBoard).board.levelsUv.every((v) => v != null));
    for (final v in (w.band as OtherBoard).board.levelsUv) {
      expect(v, closeTo(2 * 4.5 / 2400 * 1e6, 1));
    }
  });

  test('no contact and no battery: resistance never arrives, battery says why', () async {
    final w = await connected();
    final ohms = <Map<String, double>>[];
    w.band.resistance.listen(ohms.add);
    await w.band.startResist();
    await w.band.stopResist();
    await settle();
    expect(ohms, isEmpty);
    await expectLater(w.band.battery(), throwsA(isA<DiyBoardError>()));
  });

  test('a failing socket ends the band; dispose closes the link once', () async {
    final w = await connected();
    link.fail(const SocketException('network is down'));
    await waitFor(() => w.range.contains(false));
    expect(w.notes.any((l) => l.contains('network is down')), isTrue);
    finder.dispose();
    expect(link.closes, 1);
  });

  test('a port taken by another app: the error says so', () async {
    finder = DiyFinder(link: () => FakeLink(failOpen: 'port 9000 is in use'), timing: fast);
    await expectLater(
      finder.find(const Duration(milliseconds: 20)),
      throwsA(isA<DiyBoardError>().having((e) => '$e', 'text', contains('port 9000 is in use'))),
    );
  });

  test('a real UDP socket on this machine: frames sent to it arrive as samples', () async {
    final udp = UdpLink(port: 0, host: InternetAddress.loopbackIPv4);
    finder = DiyFinder(link: () => udp, timing: fast);
    final found = finder.find(const Duration(seconds: 3));
    await waitFor(() => udp.boundPort != null);
    final out = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    for (final f in board.next(5)) {
      out.send(f, InternetAddress.loopbackIPv4, udp.boundPort!);
    }
    final band = await found;
    final w = Watched(band!);
    await band.startSignal();
    for (final f in board.next(20)) {
      out.send(f, InternetAddress.loopbackIPv4, udp.boundPort!);
    }
    await waitFor(() => w.samples.length == 25);
    expect(w.seqs, [for (var s = 501; s <= 525; s++) s]);
    out.close();
    expect(udp.describe, contains('UDP port ${udp.boundPort}'));
  });

  test('a port another program holds with address reuse: shared, said in the log, frames still arrive', () async {
    // the emulator's OpenThread simulator holds UDP 9000 on a multicast address; a phone can have a neighbour too
    final other = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0, reuseAddress: true);
    final udp = UdpLink(port: other.port, host: InternetAddress.loopbackIPv4);
    finder = DiyFinder(link: () => udp, timing: fast);
    final found = finder.find(const Duration(seconds: 3));
    await waitFor(() => udp.boundPort != null);
    expect(udp.shared, isTrue);
    expect(udp.describe, contains('shared with another program on this phone'));
    final out = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    for (final f in board.next(5)) {
      out.send(f, InternetAddress.loopbackIPv4, other.port);
    }
    final band = await found; // the last socket bound gets unicast datagrams
    expect(band, isNotNull);
    out.close();
    other.close();
  });

  test('the host never sends: no send or write call in the link or the board', () {
    for (final f in ['lib/headband/diy/link.dart', 'lib/headband/diy/board.dart', 'lib/headband/diy/e9.dart']) {
      final code = File(f).readAsStringSync();
      expect(RegExp(r'\.send\(|\.write\(|\.add\(\s*utf8').hasMatch(code), isFalse, reason: f);
    }
  });
}
