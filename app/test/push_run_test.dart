// A whole push against the laptop's real receiver (lib/share/push/run.dart <-> scripts/push_receiver.py inside
// `phone_link.py --keep`; DECISIONS 840-849): real files, real sockets, python3 as the laptop. What lands on the
// laptop is pull_phone.py's layout; the laptop's acks come back in the answer; a file the phone is asking about is
// never sent; nothing goes to a laptop that does not prove the pairing. Skipped where python3 is missing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/recorder/acks.dart';
import 'package:eeg_tracker/recorder/recheck.dart';
import 'package:eeg_tracker/share/isolate.dart' show readCopied;
import 'package:eeg_tracker/share/link.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/share/push/client.dart';
import 'package:eeg_tracker/share/push/run.dart';
import 'package:eeg_tracker/share/push/state.dart';
import 'package:flutter_test/flutter_test.dart';

const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';
const otherKey = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const token = 'abcdefghjkmn';
const WifiNets wifi = (nets: ['192.168.1.5/24'], note: '');

final bool hasPython = () {
  try {
    return Process.runSync('python3', ['-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

/// `phone_link.py --keep` with only its receiver, paired with [laptopKey], taking a loopback client as "at home".
class Laptop {
  Laptop(this.dest, this.port, this._process);
  final Directory dest;
  final int port;
  final Process _process;

  static Future<Laptop> start(String laptopKey) async {
    final dest = Directory.systemTemp.createTempSync('push_laptop');
    Directory('${dest.path}/phone').createSync();
    File('${dest.path}/phone/link.json').writeAsStringSync(
      jsonEncode({
        'version': 2,
        'key': laptopKey,
        'paired': '2026-11-19T21:00:00+03:00',
        'home': null,
        'phone': {'address': '192.168.1.5', 'port': 8765},
      }),
    );
    final port = await freePort(), linkPort = await freePort();
    final p = await Process.start('python3', [
      '-I',
      '${Directory.current.parent.path}/scripts/phone_link.py',
      '--keep',
      '--dest', dest.path,
      '--port', '$linkPort',
      '--push-port', '$port',
      '--no-pages',
      '--no-mirror',
      '--no-after-pull',
      '--push-loopback-home',
      '--address', '127.0.0.1',
    ]);
    unawaited(p.stdout.drain<void>());
    unawaited(p.stderr.drain<void>());
    for (var i = 0; i < 100; i++) {
      try {
        (await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 200))).destroy();
        return Laptop(dest, port, p);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    p.kill();
    throw StateError('the receiver did not start');
  }

  File file(String path) => File('${dest.path}/$path');
  bool get inboxEmpty {
    final d = Directory('${dest.path}/phone/push-inbox');
    return !d.existsSync() || d.listSync().isEmpty;
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
    dest.deleteSync(recursive: true);
  }
}

void main() {
  late Laptop laptop;
  late Directory files;
  var nowMs = DateTime.now().millisecondsSinceEpoch;
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(nowMs);

  ShareConfig config({String k = key, bool on = true}) => ShareConfig(
    on: on,
    token: token,
    laptop: PairedLaptop(host: '192.168.1.6', port: 8771, key: k, name: 'my-laptop'),
  );

  /// A file of the phone, last changed [ageS] seconds ago (under 20 s: still being written).
  File put(String path, List<int> bytes, {int ageS = 600}) {
    final f = File('${files.path}/$path')..createSync(recursive: true);
    f.writeAsBytesSync(bytes, flush: true);
    f.setLastModifiedSync(DateTime.now().subtract(Duration(seconds: ageS)));
    return f;
  }

  List<int> samples(int n, [int seed = 3]) => [for (var i = 0; i < n; i++) (i * 7 + seed) % 256];

  Future<PushResult> push({Laptop? to, ShareConfig? c, bool soon = true, Duration? uploadFor, WifiNets w = wifi}) {
    nowMs += 60000; // a minute after the last try
    return runPush(
      filesDir: files.path,
      config: c ?? config(),
      wifi: w,
      soon: soon,
      sharePort: 8765,
      clock: clock,
      uploadFor: uploadFor ?? pushUploadFor,
      client: (k, host) => PushClient(key: k, host: '127.0.0.1', port: (to ?? laptop).port),
      reachable: (_) async => false,
    );
  }

  setUp(() async {
    laptop = await Laptop.start(key);
    files = Directory.systemTemp.createTempSync('push_phone');
    nowMs = DateTime.now().millisecondsSinceEpoch;
  });

  tearDown(() async {
    await laptop.stop();
    files.deleteSync(recursive: true);
  });

  test('a finished recording lands on the laptop, checked, and the laptop\'s acks come back', () async {
    final f32 = samples(9000000), idx = samples(4000, 9);
    put('recordings/2026-11-19-010000.f32', f32);
    put('recordings/2026-11-19-010000.idx', idx);
    put('nights/2026-11-19.report.json', utf8.encode('{"night":"2026-11-19"}'));
    put('transfer/storage.json', utf8.encode('{"private":true}')); // never leaves the phone

    final r = await push();
    expect(r.sent, isTrue, reason: r.why);
    expect(r.files, 3);
    expect(r.bytes, f32.length + idx.length + 22);
    expect(laptop.file('recordings/2026-11-19-010000.f32').readAsBytesSync(), f32);
    expect(laptop.file('recordings/2026-11-19-010000.idx').readAsBytesSync(), idx);
    expect(laptop.file('phone/nights/2026-11-19.report.json').readAsStringSync(), '{"night":"2026-11-19"}');
    expect(laptop.file('phone/transfer/storage.json').existsSync(), isFalse);
    expect(laptop.inboxEmpty, isTrue);
    // the acks, taken as a POST /ack would be: only for what the phone still holds unchanged
    expect(r.acked, 3);
    expect(AckStore(files).load().keys, containsAll(['recordings/2026-11-19-010000.f32', 'recordings/2026-11-19-010000.idx']));
    expect(readCopied(files.path).by, 'laptop');
    final s = PushState.read(files.path);
    expect((s.fails, s.files, s.okMs > 0), (0, 3, true));

    // nothing new: nothing is sent again
    final again = await push();
    expect((again.sent, again.files, again.bytes), (true, 0, 0));
  }, skip: !hasPython, timeout: const Timeout(Duration(minutes: 2)));

  test('a recording still being written grows on the laptop push after push', () async {
    final first = samples(300000);
    final f = put('recordings/2026-11-20-221706.f32', first, ageS: 0);
    var r = await push();
    expect(r.sent, isTrue, reason: r.why);
    expect(laptop.file('recordings/2026-11-20-221706.f32').readAsBytesSync(), first);
    expect(r.acked, 0, reason: 'not finished: nothing to ack yet');

    final more = samples(200000, 11);
    f.writeAsBytesSync(more, mode: FileMode.append, flush: true);
    r = await push();
    expect(r.bytes, more.length, reason: 'only the new end travels');
    expect(laptop.file('recordings/2026-11-20-221706.f32').readAsBytesSync(), [...first, ...more]);

    // the recording ended (the file rests): the whole copy is checked against its SHA-256 and acked
    f.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    r = await push();
    expect((r.bytes, r.acked), (0, 1));
    expect(laptop.file('recordings/2026-11-20-221706.f32').readAsBytesSync(), [...first, ...more]);
  }, skip: !hasPython, timeout: const Timeout(Duration(minutes: 2)));

  test('a push cut off by its time goes on from there next time', () async {
    final big = samples(pushChunkMaxForTest * 2 + 5000);
    put('recordings/2026-11-19-010000.f32', big);
    var calls = 0;
    nowMs += 60000;
    // the time runs out after the first chunk
    final cut = await runPush(
      filesDir: files.path,
      config: config(),
      wifi: wifi,
      soon: true,
      clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs + (calls++ > 3 ? 3600000 : 0)),
      uploadFor: const Duration(minutes: 1),
      client: (k, host) => PushClient(key: k, host: '127.0.0.1', port: laptop.port),
      reachable: (_) async => false,
    );
    expect(cut.sent, isTrue, reason: cut.why);
    expect(cut.why, 'more next time');
    expect(cut.bytes, lessThan(big.length));
    expect(laptop.file('recordings/2026-11-19-010000.f32').existsSync(), isFalse, reason: 'nothing half-made in the real folder');
    expect(laptop.inboxEmpty, isFalse);

    final rest = await push();
    expect(rest.sent, isTrue, reason: rest.why);
    expect(rest.bytes, big.length - cut.bytes, reason: 'what arrived before is not sent twice');
    expect(laptop.file('recordings/2026-11-19-010000.f32').readAsBytesSync(), big);
    expect(laptop.inboxEmpty, isTrue);
  }, skip: !hasPython, timeout: const Timeout(Duration(minutes: 2)));

  test('a file the phone is asking about before deleting is not sent: the laptop must prove it from its own copy', () async {
    final f32 = samples(50000);
    put('recordings/2026-11-19-010000.f32', f32);
    put('recordings/2026-11-19-010000.idx', samples(100));
    expect((await push()).acked, 2);
    // the phone asks before deleting; meanwhile the laptop lost its copy
    final asked = RecheckStore(files).ask(['recordings/2026-11-19-010000.f32'], now: DateTime.now());
    expect(asked, hasLength(1));
    laptop.file('recordings/2026-11-19-010000.f32').deleteSync();
    final r = await push();
    expect(r.sent, isTrue, reason: r.why);
    expect(r.bytes, 0);
    expect(laptop.file('recordings/2026-11-19-010000.f32').existsSync(), isFalse, reason: 'not handed over while asked about');
    expect(RecheckStore(files).proven('recordings/2026-11-19-010000.f32', DateTime.now()), isFalse);
    expect(AckStore(files).load().containsKey('recordings/2026-11-19-010000.f32'), isFalse, reason: 'the laptop said it does not hold it: the ack is gone');
  }, skip: !hasPython, timeout: const Timeout(Duration(minutes: 2)));

  test('the laptop proves a file it holds, from its own copy, in the same push', () async {
    put('recordings/2026-11-19-010000.f32', samples(50000));
    expect((await push()).acked, 1);
    RecheckStore(files).ask(['recordings/2026-11-19-010000.f32'], now: DateTime.now());
    final r = await push();
    expect(r.sent, isTrue, reason: r.why);
    expect(RecheckStore(files).proven('recordings/2026-11-19-010000.f32', DateTime.now()), isTrue);
  }, skip: !hasPython, timeout: const Timeout(Duration(minutes: 2)));

  test('nothing goes to a laptop that does not prove the pairing', () async {
    final impostor = await Laptop.start(otherKey);
    addTearDown(impostor.stop);
    put('recordings/2026-11-19-010000.f32', samples(5000));
    final r = await push(to: impostor);
    expect(r.sent, isFalse);
    expect(r.why, 'the laptop did not answer on this Wi-Fi');
    expect(impostor.inboxEmpty, isTrue);
    expect(impostor.file('recordings/2026-11-19-010000.f32').existsSync(), isFalse);
    expect(PushState.read(files.path).fails, 1);
  }, skip: !hasPython, timeout: const Timeout(Duration(minutes: 2)));

  test('no push with sharing off, with no laptop paired, off Wi-Fi, or to an address outside the phone\'s Wi-Fi', () async {
    put('recordings/2026-11-19-010000.f32', samples(5000));
    expect((await push(c: config(on: false))).why, 'sharing is off or no laptop is paired');
    expect((await push(c: const ShareConfig(on: true, token: token))).why, 'sharing is off or no laptop is paired');
    expect((await push(w: noWifiAnswer)).why, 'not on Wi-Fi');
    expect(PushState.read(files.path).tryMs, 0, reason: 'none of these counts as a try');
    final elsewhere = await push(w: (nets: const ['10.20.30.5/24'], note: ''));
    expect((elsewhere.sent, elsewhere.why), (false, 'the laptop did not answer on this Wi-Fi'));
    expect(laptop.file('recordings/2026-11-19-010000.f32').existsSync(), isFalse);
  }, skip: !hasPython);

  test('two jobs falling together: the second leaves it', () async {
    put('nights/2026-11-19.report.json', utf8.encode('{}'));
    expect((await push()).sent, isTrue);
    final r = await runPush(
      filesDir: files.path,
      config: config(),
      wifi: wifi,
      soon: false,
      clock: clock,
      client: (k, host) => PushClient(key: k, host: '127.0.0.1', port: laptop.port),
    );
    expect(r.why, 'too soon after the last try');
  }, skip: !hasPython);
}

/// The laptop's chunk size (scripts/push_receiver.py `MAX_CHUNK`).
const int pushChunkMaxForTest = 4 * 1024 * 1024;
