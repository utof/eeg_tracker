// Pairing with a laptop by one scan (lib/share/link.dart, DECISIONS rows 530-539, 753): the pair link, the proofs
// and the key both sides work out (the same numbers as scripts/phone_auth.py, app/test/fixtures/phone_link.json),
// the pairing against a fake laptop (nothing secret is sent: not the code, the key or the token), the remembered
// laptop in the setting (an old pairing is not used), and ShareControl.pair.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:eeg_tracker/share/auth.dart';
import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/link.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'share_control_test.dart' show fakeServer;

const code = 'AbCdEfGhIjKlMnOpQrStUv';
const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';

/// The laptop's side as scripts/phone_link.py answers it, on loopback. [proveWith] stands for a laptop that holds
/// another code; [oldScripts] for scripts that speak the first version.
class FakeLaptop {
  FakeLaptop._(this._server);
  final HttpServer _server;
  String? code;
  String? proveWith;
  bool confirmWrong = false;
  bool oldScripts = false;
  int status = 200;
  final List<String> wire = []; // every body both ways, as it crossed
  final List<Map<String, Object?>> finishes = [];
  final Map<String, String> _nonces = {}; // laptop nonce -> phone nonce
  String? key; // the key it worked out
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
    final raw = await utf8.decodeStream(r);
    wire.add(raw);
    final body = jsonDecode(raw) as Map;
    Object answer;
    var st = status;
    final c = code;
    if (oldScripts) {
      st = 400;
      answer = {'error': 'bad request'};
    } else if (st != 200) {
      answer = {'error': st == 410 ? 'expired' : 'no'};
    } else if (c == null) {
      st = 410;
      answer = {'error': 'expired'};
    } else if (r.uri.path == '/link/hello') {
      hellos++;
      final mine = newNonce();
      _nonces[mine] = body['nonce'] as String;
      answer = {'v': 2, 'nonce': mine, 'proof': linkProof(proveWith ?? c, 'laptop', body['nonce'] as String, mine), 'name': 'my-laptop'};
    } else {
      final theirs = _nonces.remove(body['nonce']);
      if (theirs == null || body['proof'] != linkProof(c, 'phone', body['nonce'] as String, theirs)) {
        st = 403;
        answer = {'error': 'wrong proof'};
      } else {
        finishes.add(body.cast<String, Object?>());
        final k = key = deriveKey(c, theirs, body['nonce'] as String);
        answer = {'v': 2, 'name': 'my-laptop', 'confirm': confirmWrong ? '0' * 64 : confirmProof(k, theirs, body['nonce'] as String)};
        code = null; // used
      }
    }
    final out = jsonEncode(answer);
    wire.add(out);
    r.response.statusCode = st;
    r.response.headers.contentType = ContentType.json;
    r.response.write(out);
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

    test('the proofs and the key are the laptop script\'s (shared vectors)', () {
      for (final c in (fixture['proofs'] as List).cast<Map<String, Object?>>()) {
        final s = c['code'] as String, p = c['phone_nonce'] as String, l = c['laptop_nonce'] as String;
        expect(linkProof(s, 'laptop', p, l), c['laptop_proof']);
        expect(linkProof(s, 'phone', l, p), c['phone_proof']);
        expect(deriveKey(s, p, l), c['key']);
        expect(confirmProof(c['key'] as String, p, l), c['confirm']);
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
        {'v': 2, 'host': '8.8.8.8', 'port': 8771, 'key': key},
        {'v': 2, 'host': '192.168.1.10', 'port': 8771, 'key': 'short'},
        {'v': 2, 'host': '192.168.1.10', 'port': '8771', 'key': key},
        {'v': 2, 'host': '192.168.1.10', 'port': 8771, 'key': 'K' * 64},
        'not a map',
      ]) {
        expect(PairedLaptop.fromJson(bad), isNull);
      }
    });

    test('a pairing made the first way (its key crossed the Wi-Fi) is not used: one new scan pairs again', () {
      final old = {'host': '192.168.1.10', 'port': 8771, 'key': 'a-key-of-forty-three-characters-0123456789', 'name': 'my-laptop'};
      expect(PairedLaptop.fromJson(old), isNull);
      final c = ShareConfig.fromJson({'on': true, 'token': 'abcdefghjkmn', 'off_at_ms': 5, 'laptop': old});
      expect((c.laptop, c.oldLaptop, c.paired), (null, 'my-laptop', false));
      expect(c.activeAt(10), isFalse); // without a pairing sharing has its old end time: long past
      expect(ShareConfig.decode(c.encode()).oldLaptop, 'my-laptop'); // said until the new scan
      expect(c.withLaptop(laptop).oldLaptop, isNull);
      expect(c.withLaptop(null).oldLaptop, isNull); // Forget too
    });

    test('the share isolate gets it, and "Share here"', () {
      final rp = ReceivePort();
      final c = const ShareConfig(on: true, token: 'abcdefghjkmn', offAtMs: 9).withLaptop(laptop).sharedHere(100, '10.0.0.0/24');
      final args = shareIsolateArgs(rp.sendPort, '/files', c);
      expect(args[7], laptop.toJson());
      expect((args[9], args[10]), (100 + shareHereFor.inMilliseconds, '10.0.0.0/24'));
      expect(shareIsolateArgs(rp.sendPort, '/files', const ShareConfig())[7], isNull);
      expect(c.notHere().hereNet, isNull);
      expect(c.sharedHere(5, '').hereUntilMs, 0); // no Wi-Fi: nothing to allow
      expect(c.switchedOff().hereUntilMs, 0);
      rp.close();
    });
  });

  group('the pairing', () {
    late FakeLaptop laptop;
    setUp(() async => laptop = await FakeLaptop.start());
    tearDown(() => laptop.close());

    Future<LinkAnswer> pair({String c = code}) =>
        LinkClient(timeout: const Duration(seconds: 2)).pair(host: '127.0.0.1', port: laptop.port, code: c, sharePort: 8765);

    test('the laptop proves the code; both work out the same key; nothing secret crosses the Wi-Fi', () async {
      laptop.code = code;
      final a = await pair();
      expect(a.name, 'my-laptop');
      expect(a.key, laptop.key);
      expect(a.key, matches(keyShape));
      expect(laptop.finishes.single, containsPair('port', 8765));
      final wire = laptop.wire.join('\n');
      expect(wire.contains(a.key), isFalse); // the key never travels
      expect(wire.contains(code), isFalse); // nor the code
      expect(wire.contains('token'), isFalse); // nor the token: the laptop never needs it
    });

    test('a laptop that cannot prove the code gets nothing; a wrong confirm is no pairing', () async {
      laptop.code = code;
      laptop.proveWith = 'another-code-entirely-x';
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.wrongLaptop)));
      expect(laptop.hellos, 1);
      expect(laptop.finishes, isEmpty);
      laptop.proveWith = null;
      laptop.confirmWrong = true;
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.bad)));
    });

    test('expired, refused, old scripts, no answer, not a local address', () async {
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.expired)));
      laptop.code = code;
      laptop.status = 403;
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.refused)));
      laptop.status = 200;
      laptop.oldScripts = true;
      await expectLater(pair(), throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.oldLaptop)));
      final port = laptop.port;
      await laptop.close();
      await expectLater(
        LinkClient(timeout: const Duration(seconds: 2)).pair(host: '127.0.0.1', port: port, code: code, sharePort: 8765),
        throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.noAnswer)),
      );
      await expectLater(
        LinkClient().pair(host: '8.8.8.8', port: port, code: code, sharePort: 8765),
        throwsA(isA<LinkError>().having((e) => e.why, 'why', LinkFailure.bad)),
      );
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
        host: (dir, onChange, wifiLock) =>
            ShareHost(filesDir: dir, onLog: (_) {}, onChange: onChange, entry: fakeServer, wifiLock: wifiLock),
      );
    });
    tearDown(() async {
      await c.setOn(false);
      c.dispose();
      files.deleteSync(recursive: true);
    });

    final link = PairLink.parse('eegtracker://pair?h=192.168.1.10&p=8771&s=$code&n=my-laptop')!;

    test('Connect with sharing off: the pairing, then sharing on and the laptop remembered', () async {
      await c.sync(night: false, filesDir: files.path);
      final client = RecordingClient();
      final out = await c.pair(link, client: client);
      expect(out.failure, isNull);
      expect(out.laptop!.name, 'my-laptop');
      expect(client.calls.single, (host: '192.168.1.10', port: 8771, code: code, sharePort: 8765));
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
      expect(config.token, before.token); // the same code: pairing does not change it
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

/// Records the pairings asked for; answers with [key], or fails.
class RecordingClient extends LinkClient {
  RecordingClient({this.fail});
  final LinkFailure? fail;
  final calls = <({String host, int port, String code, int sharePort})>[];

  @override
  Future<LinkAnswer> pair({required String host, required int port, required String code, required int sharePort}) async {
    calls.add((host: host, port: port, code: code, sharePort: sharePort));
    if (fail != null) throw LinkError(fail!);
    return (name: 'my-laptop', key: key);
  }
}
