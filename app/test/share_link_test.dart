// Pairing with a laptop by one scan (lib/share/link.dart, DECISIONS rows 530-539): the pair link, the proofs (the
// same numbers as scripts/phone_link.py, app/test/fixtures/phone_link.json), the handshake against a fake laptop
// (the token leaves only after the laptop proved the code), the remembered laptop in the setting, the announcer in
// the real share isolate, and ShareControl.pair.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/link.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'share_control_test.dart' show fakeServer;

const code = 'AbCdEfGhIjKlMnOpQrStUv';
const key = 'a-key-of-forty-three-characters-0123456789';

/// The laptop's side as scripts/phone_link.py answers it, on loopback. [proveWith] stands for a laptop that holds
/// another code.
class FakeLaptop {
  FakeLaptop._(this._server);
  final HttpServer _server;
  String? code;
  String? key;
  String? proveWith;
  int status = 200;
  final List<Map<String, Object?>> finishes = [];
  final Map<String, (String, String)> _nonces = {}; // laptop nonce -> (phone nonce, via)
  int hellos = 0;

  int get port => _server.port;

  static Future<FakeLaptop> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final f = FakeLaptop._(s);
    s.listen(f._handle);
    return f;
  }

  Future<void> _handle(HttpRequest r) async {
    // like Python's http.server: the body is read by its Content-Length, never chunked
    expect(r.headers.chunkedTransferEncoding, isFalse);
    expect(r.headers.contentLength, greaterThan(0));
    final body = jsonDecode(await utf8.decodeStream(r)) as Map;
    final via = body['via'] as String;
    final secret = via == 'code' ? code : key;
    Object answer;
    var st = status;
    if (st != 200) {
      answer = {'error': st == 410 ? 'expired' : (st == 404 ? 'not paired' : 'no')};
    } else if (secret == null) {
      st = via == 'code' ? 410 : 404;
      answer = {'error': via == 'code' ? 'expired' : 'not paired'};
    } else if (r.uri.path == '/link/hello') {
      hellos++;
      final mine = newNonce();
      _nonces[mine] = (body['nonce'] as String, via);
      answer = {'v': 1, 'nonce': mine, 'proof': linkProof(proveWith ?? secret, 'laptop', via, body['nonce'] as String, mine), 'name': 'my-laptop'};
    } else {
      final n = _nonces.remove(body['nonce']);
      if (n == null || body['proof'] != linkProof(secret, 'phone', via, body['nonce'] as String, n.$1)) {
        st = 403;
        answer = {'error': 'wrong proof'};
      } else {
        finishes.add(body.cast<String, Object?>());
        answer = {'v': 1, 'name': 'my-laptop', if (via == 'code') 'key': key ?? 'k' * 43};
        if (via == 'code') code = null; // used
      }
    }
    r.response.statusCode = st;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(answer));
    await r.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

Future<void> until(bool Function() ok, {int ms = 5000}) async {
  for (var i = 0; i < ms ~/ 10 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue);
}

void main() {
  final fixture = jsonDecode(File('test/fixtures/phone_link.json').readAsStringSync()) as Map;

  group('the pair link', () {
    test('what the laptop\'s page opens', () {
      final l = PairLink.parse('eegtracker://pair?h=192.168.1.10&p=8771&s=$code&n=my-laptop')!;
      expect((l.host, l.port, l.code, l.name), ('192.168.1.10', 8771, code, 'my-laptop'));
      expect(PairLink.parse('eegtracker://pair?h=10.0.2.2&p=8771&s=$code')!.name, 'laptop'); // the emulator's host
      expect(PairLink.parse('eegtracker://pair?h=172.20.0.4&p=8771&s=$code&n=Ilya%E2%80%99s%20%3Cb%3EPC%3C%2Fb%3E')!.name, 'Ilyas bPCb');
      expect(PairLink.parse('eegtracker://pair?h=127.0.0.1&p=8771&s=$code&n=${'x' * 80}')!.name, hasLength(40));
    });

    test('anything else is not a pair link', () {
      for (final bad in [
        null,
        '',
        'https://192.168.1.10:8771/p?s=$code', // the web link is for the browser, not the app
        'eegtracker://other?h=192.168.1.10&p=8771&s=$code',
        'eegtracker://pair?h=laptop.local&p=8771&s=$code', // no names: no DNS
        'eegtracker://pair?h=8.8.8.8&p=8771&s=$code', // never an internet address
        'eegtracker://pair?h=172.32.0.1&p=8771&s=$code',
        'eegtracker://pair?h=fe80::1&p=8771&s=$code',
        'eegtracker://pair?h=192.168.1.10&p=80&s=$code',
        'eegtracker://pair?h=192.168.1.10&p=70000&s=$code',
        'eegtracker://pair?h=192.168.1.10&p=8771&s=short',
        'eegtracker://pair?h=192.168.1.10&p=8771&s=${'a' * 15}!',
        'eegtracker://pair?h=192.168.1.10&p=8771',
        'eegtracker://pair?h=192.168.1.10&p=8771&s=$code&n=${'x' * 600}',
      ]) {
        expect(PairLink.parse(bad), isNull, reason: bad);
      }
    });

    test('the proofs are the laptop script\'s (shared vectors)', () {
      for (final c in (fixture['proofs'] as List).cast<Map<String, Object?>>()) {
        final s = c['secret'] as String, via = c['via'] as String, p = c['phone_nonce'] as String, l = c['laptop_nonce'] as String;
        expect(linkProof(s, 'laptop', via, p, l), c['laptop_proof']);
        expect(linkProof(s, 'phone', via, l, p), c['phone_proof']);
      }
      expect(newNonce(), matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    });
  });

  group('the remembered laptop', () {
    const laptop = PairedLaptop(host: '192.168.1.10', port: 8771, key: key, name: 'my-laptop', pairedAtMs: 5);

    test('kept in the setting through every change, and only a usable one is read back', () {
      final c = const ShareConfig().switchedOn(1000, random: Random(1)).withLaptop(laptop);
      expect(ShareConfig.decode(c.encode()).laptop, laptop);
      expect(c.switchedOff().laptop, laptop);
      expect(c.withNewToken().laptop, laptop);
      expect(c.afterStop(2000).laptop, laptop);
      expect(c.switchedOff().switchedOn(3000).laptop, laptop);
      expect(c.withLaptop(null).laptop, isNull);
      expect(ShareConfig.decode(const ShareConfig().encode()).laptop, isNull);
      for (final bad in [
        {'host': '8.8.8.8', 'port': 8771, 'key': key},
        {'host': '192.168.1.10', 'port': 8771, 'key': 'short'},
        {'host': '192.168.1.10', 'port': '8771', 'key': key},
        'not a map',
      ]) {
        expect(PairedLaptop.fromJson(bad), isNull);
      }
    });

    test('the share isolate gets it', () {
      final rp = ReceivePort();
      final c = const ShareConfig(on: true, token: 'abcdefghjkmn', offAtMs: 9).withLaptop(laptop);
      expect(shareIsolateArgs(rp.sendPort, '/files', c)[7], laptop.toJson());
      expect(shareIsolateArgs(rp.sendPort, '/files', const ShareConfig())[7], isNull);
      rp.close();
    });
  });

  group('the handshake', () {
    late FakeLaptop laptop;
    setUp(() async => laptop = await FakeLaptop.start());
    tearDown(() => laptop.close());

    Future<LinkAnswer> pair({String secret = code, String via = 'code'}) => LinkClient(timeout: const Duration(seconds: 2))
        .handshake(host: '127.0.0.1', port: laptop.port, via: via, secret: secret, sharePort: 8765, token: 'abcdefghjkmn');

    test('the laptop proves the code, then the phone sends its port and token, and gets a key', () async {
      laptop.code = code;
      laptop.key = key;
      final a = await pair();
      expect((a.name, a.key), ('my-laptop', key));
      expect(laptop.finishes.single, containsPair('token', 'abcdefghjkmn'));
      expect(laptop.finishes.single, containsPair('port', 8765));
      expect(laptop.finishes.single.containsKey('code'), isFalse); // the code itself never travels back
    });

    test('a laptop that cannot prove the code gets nothing', () async {
      laptop.code = code;
      laptop.proveWith = 'another-code-entirely-x';
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.wrongLaptop)));
      expect(laptop.hellos, 1);
      expect(laptop.finishes, isEmpty); // the token never left
    });

    test('expired, not paired, refused, no answer', () async {
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.expired)));
      await expectLater(pair(via: 'key', secret: key), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.notPaired)));
      laptop.code = code;
      laptop.status = 403;
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.refused)));
      final port = laptop.port;
      await laptop.close();
      await expectLater(
        LinkClient(timeout: const Duration(seconds: 2))
            .handshake(host: '127.0.0.1', port: port, via: 'code', secret: code, sharePort: 8765, token: 'abcdefghjkmn'),
        throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.noAnswer)),
      );
      await expectLater(
        LinkClient().handshake(host: '8.8.8.8', port: port, via: 'code', secret: code, sharePort: 8765, token: 'x'),
        throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.bad)),
      );
    });
  });

  group('telling the laptop where this phone is', () {
    late FakeLaptop laptop;
    setUp(() async => laptop = await FakeLaptop.start());
    tearDown(() => laptop.close());

    test('at once, then every few minutes; a failure is said once and tried again sooner', () async {
      laptop.key = key;
      final lines = <String>[];
      final a = LaptopAnnouncer(
        laptop: PairedLaptop(host: '127.0.0.1', port: laptop.port, key: key, name: 'my-laptop'),
        sharePort: 8765,
        token: 'abcdefghjkmn',
        client: LinkClient(timeout: const Duration(seconds: 2)),
        onLine: lines.add,
        every: const Duration(milliseconds: 150),
        retries: const [Duration(milliseconds: 50)],
      )..start();
      await until(() => laptop.finishes.length >= 3);
      expect(laptop.finishes.first, containsPair('via', 'key'));
      expect(laptop.finishes.first, containsPair('token', 'abcdefghjkmn'));
      expect(lines, ['the laptop my-laptop knows where this phone is']); // once, not per try
      laptop.key = 'another-key-after-pairing-another-phone-xx'; // the laptop paired again: this key proves nothing
      await until(() => lines.length == 2);
      expect(lines.last, contains('no longer knows this phone'));
      final before = laptop.finishes.length;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lines, hasLength(2)); // tried again, not said again
      expect(laptop.finishes.length, before); // and the token went nowhere
      laptop.key = key;
      await until(() => lines.length == 3);
      a.stop();
      final n = laptop.finishes.length;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(laptop.finishes.length, n);
    });

    test('the real share isolate tells it as soon as it serves, and the night log gets one line', () async {
      laptop.key = key;
      final files = Directory.systemTemp.createTempSync('share_link_test');
      final log = <String>[];
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final host = ShareHost(filesDir: files.path, onLog: log.add);
      try {
        await host.start(
          ShareConfig(
            on: true,
            token: 'abcdefghjkmn',
            port: port,
            offAtMs: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
            laptop: PairedLaptop(host: '127.0.0.1', port: laptop.port, key: key, name: 'my-laptop'),
          ),
        );
        await until(() => laptop.finishes.isNotEmpty, ms: 10000);
        expect(laptop.finishes.single, containsPair('port', port));
        await until(() => log.any((l) => l.contains('knows where this phone is')));
      } finally {
        await host.stop();
        files.deleteSync(recursive: true);
      }
    });
  });

  group('ShareControl.pair', () {
    late ShareConfig saved;
    late List<Map<String, Object?>> sent;
    late ShareControl c;
    late Directory files;
    final now = DateTime(2026, 11, 22, 22, 5);

    setUp(() {
      files = Directory.systemTemp.createTempSync('share_pair_test');
      saved = const ShareConfig();
      sent = [];
      c = ShareControl(
        load: () async => saved,
        save: (x) async => saved = x,
        sendToRecorder: sent.add,
        keepScreenOn: (_) async {},
        clock: () => now,
        host: (dir, onChange) => ShareHost(filesDir: dir, onLog: (_) {}, onChange: onChange, entry: fakeServer),
      );
    });
    tearDown(() async {
      await c.setOn(false);
      c.dispose();
      files.deleteSync(recursive: true);
    });

    final link = PairLink.parse('eegtracker://pair?h=192.168.1.10&p=8771&s=$code&n=my-laptop')!;

    test('Connect with sharing off: the handshake with a token, then sharing on and the laptop remembered', () async {
      await c.sync(night: false, filesDir: files.path);
      final client = RecordingClient();
      final out = await c.pair(link, client: client);
      expect(out.failure, isNull);
      expect(out.laptop!.name, 'my-laptop');
      expect(client.calls.single, (host: '192.168.1.10', port: 8771, via: 'code', secret: code, sharePort: 8765, token: saved.token));
      expect(saved.token, hasLength(12));
      expect(saved.on, isTrue);
      expect(saved.laptop, out.laptop);
      expect(saved.laptop!.key, key);
      expect(c.config.laptop, out.laptop);
      await until(() => c.status.up); // the app serves (it carries the laptop to its isolate)
    });

    test('during a night the recorder gets the setting with the laptop', () async {
      await c.sync(night: true, filesDir: files.path);
      final before = const ShareConfig().switchedOn(now.millisecondsSinceEpoch, random: Random(3));
      saved = before;
      await c.pair(link, client: RecordingClient());
      expect(sent.last['kind'], 'share');
      final config = ShareConfig.fromJson(sent.last['config']);
      expect(config.laptop!.host, '192.168.1.10');
      expect(config.token, before.token); // the same token the laptop got: no new code
      expect(config.offAtMs, before.offAtMs); // already on: its time is not moved
    });

    test('a failed pairing changes nothing, and forgetting takes the laptop away', () async {
      await c.sync(night: false, filesDir: files.path);
      final out = await c.pair(link, client: RecordingClient(fail: LinkFailure.expired));
      expect(out, (laptop: null, failure: LinkFailure.expired));
      expect(saved.on, isFalse);
      expect(saved.laptop, isNull);
      await c.pair(link, client: RecordingClient());
      expect(saved.laptop, isNotNull);
      await c.forgetLaptop();
      expect(saved.laptop, isNull);
      expect(saved.on, isTrue); // sharing itself stays as it was
    });
  });
}

/// Records the handshakes asked for; answers with [key], or fails.
class RecordingClient extends LinkClient {
  RecordingClient({this.fail});
  final LinkFailure? fail;
  final calls = <({String host, int port, String via, String secret, int sharePort, String token})>[];

  @override
  Future<LinkAnswer> handshake({
    required String host,
    required int port,
    required String via,
    required String secret,
    required int sharePort,
    required String token,
  }) async {
    calls.add((host: host, port: port, via: via, secret: secret, sharePort: sharePort, token: token));
    if (fail != null) throw LinkError(fail!);
    return (name: 'my-laptop', key: key);
  }
}
