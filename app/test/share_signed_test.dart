// The paired laptop's signed requests and where a paired phone shares (lib/share/auth.dart, server.dart; DECISIONS
// 751-752): the signatures against the laptop script's vectors (app/test/fixtures/phone_link.json), the phone's
// proof in each answer, the clock window and the nonce used once, the token in a header only, and the home Wi-Fi
// rule: a paired phone shares only on the network where the laptop said it is home, or one allowed by hand for 12
// hours. Real sockets on 127.0.0.1; a client on the Wi-Fi is told to the server by `clientOf`.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/share/auth.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/share/server.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'abcdefghjkmn';
const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';

void main() {
  final fixture = jsonDecode(File('test/fixtures/phone_link.json').readAsStringSync()) as Map;

  group('the signatures are the laptop script\'s (shared vectors)', () {
    test('requests and replies', () {
      for (final c in (fixture['requests'] as List).cast<Map<String, Object?>>()) {
        final u = Uri.parse(c['target']! as String);
        final got = requestSign(
          c['key']! as String,
          method: c['method']! as String,
          path: Uri.decodeComponent(u.path),
          query: Uri.decodeComponent(u.query),
          timeMs: c['time_ms']! as int,
          nonce: c['nonce']! as String,
          home: c['home']! as bool,
          body: utf8.encode(c['body']! as String),
        );
        expect(got, c['sign'], reason: c['target'] as String);
        expect(replyProof(c['key']! as String, c['nonce']! as String), c['reply']);
      }
    });

    test('a delete re-check\'s proof over byte ranges', () {
      final data = [for (var i = 0; i < 10000; i++) (i * 7 + 3) % 256];
      for (final c in (fixture['rechecks'] as List).cast<Map<String, Object?>>()) {
        final ranges = [for (final r in c['ranges']! as List) ((r as List)[0] as int, r[1] as int)];
        final mac = recheckMac(c['key']! as String, c['path']! as String, c['nonce']! as String, c['size']! as int, ranges, [
          for (final r in ranges) data.sublist(r.$1, r.$1 + r.$2),
        ]);
        expect(mac, c['mac']);
      }
    });

    test('the network a phone is on, as "home" remembers it', () {
      LanNet n(String a, int p) => (address: InternetAddress(a), prefix: p);
      expect(lanSignature([n('192.168.1.23', 24)]), '192.168.1.0/24');
      expect(lanSignature([n('10.1.2.3', 16), n('192.168.1.23', 24)]), '10.1.0.0/16,192.168.1.0/24');
      expect(lanSignature(const []), '');
      expect(redactAddresses('wifi wlan0 192.168.1.5/24; cell ccmni0 10.43.97.139/8'), 'wifi wlan0 x.x.x.x/24; cell ccmni0 x.x.x.x/8');
    });
  });

  late Directory files;
  late ShareServer server;
  late HttpClient client;
  var now = DateTime(2026, 11, 19, 3, 0, 0);
  InternetAddress? from;
  final heard = <String>[];
  final copied = <String>[];

  Future<void> start({String? withKey = key, int hereUntilMs = 0, String? hereNet}) async {
    server = ShareServer(
      filesDir: files,
      token: token,
      port: 0,
      clock: () => now,
      clientOf: (r) => from ?? r.connectionInfo?.remoteAddress,
      key: withKey,
      hereUntilMs: hereUntilMs,
      hereNet: hereNet,
      onHere: heard.add,
      onCopied: copied.add,
      onWork: (_, _) {},
    );
    await server.listen();
    server.lan = [(address: InternetAddress('192.168.1.5'), prefix: 24)];
  }

  setUp(() async {
    files = Directory.systemTemp.createTempSync('share_signed_test');
    File('${files.path}/nights/2026-11-18.report.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}')
      ..setLastModifiedSync(now.subtract(const Duration(hours: 1)));
    client = HttpClient();
    now = DateTime(2026, 11, 19, 3, 0, 0);
    from = null;
    heard.clear();
    copied.clear();
    await start();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    files.deleteSync(recursive: true);
  });

  /// One request: signed with [signWith] (the laptop: [home] says whether it is on its home network), with the
  /// token [tok], or neither. [nonce] and [timeMs] stand for a replay or a laptop whose clock is off.
  Future<({int code, Map<String, Object?> body, String? reply, String? nonce})> ask(
    String target, {
    String method = 'GET',
    String? signWith,
    bool home = true,
    String? tok,
    String body = '',
    String? nonce,
    int? timeMs,
    String? signedBody,
  }) async {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.boundPort}$target'));
    String? n;
    if (signWith != null) {
      n = nonce ?? newNonce();
      final t = timeMs ?? now.millisecondsSinceEpoch;
      final u = Uri.parse(target);
      req.headers
        ..set(timeHeader, '$t')
        ..set(nonceHeader, n)
        ..set(homeHeader, home ? '1' : '0')
        ..set(
          signHeader,
          requestSign(
            signWith,
            method: method,
            path: Uri.decodeComponent(u.path),
            query: Uri.decodeComponent(u.query),
            timeMs: t,
            nonce: n,
            home: home,
            body: utf8.encode(signedBody ?? body),
          ),
        );
    }
    if (tok != null) req.headers.set('Authorization', 'Bearer $tok');
    if (body.isNotEmpty) req.add(utf8.encode(body));
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    Map<String, Object?> j;
    try {
      j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
    } catch (_) {
      j = {'raw': utf8.decode(bytes, allowMalformed: true)};
    }
    return (code: res.statusCode, body: j, reply: res.headers.value(replyHeader), nonce: n);
  }

  group('signed requests', () {
    test('the paired laptop signs; the phone answers with its own proof of the key', () async {
      final r = await ask('/state', signWith: key);
      expect(r.code, 200);
      expect(r.reply, replyProof(key, r.nonce!)); // the laptop knows it reached this phone, not a stranger
      final w = await ask('/who', signWith: key);
      expect(w.code, 200);
      expect(w.body, {'app': 'eeg-tracker', 'v': 2, 'here': 'waiting'}); // the cable never makes a Wi-Fi home
    });

    test('another key, a changed body, a time off by more than 5 minutes, a nonce used twice: refused', () async {
      expect((await ask('/state', signWith: 'f' * 64)).body, {'error': 'signature'});
      expect((await ask('/state', signWith: 'f' * 64)).reply, isNull); // nothing proves the key to a stranger
      final changed = await ask('/work', method: 'POST', signWith: key, body: '{"working":false}', signedBody: '{"working":true}');
      expect((changed.code, changed.body['error']), (401, 'signature'));
      final late = await ask('/state', signWith: key, timeMs: now.millisecondsSinceEpoch - 6 * 60 * 1000);
      expect((late.code, late.body['error'], late.body['phone_ms']), (401, 'clock', now.millisecondsSinceEpoch));
      final first = await ask('/state', signWith: key, nonce: 'cmVwbGF5LW5vbmNlLTAwMDE');
      expect(first.code, 200);
      final again = await ask('/state', signWith: key, nonce: 'cmVwbGF5LW5vbmNlLTAwMDE');
      expect((again.code, again.body['error']), (401, 'replayed'));
    });

    test('an unpaired phone takes no signature, only the token', () async {
      await server.close();
      await start(withKey: null);
      expect((await ask('/state', signWith: key)).body, {'error': 'not paired'});
      expect((await ask('/state', tok: token)).code, 200);
    });

    test('the token only in the Authorization header: never in the address or another header', () async {
      expect((await ask('/state', tok: token)).code, 200);
      expect((await ask('/state?token=$token')).code, 401);
      final req = await client.openUrl('GET', Uri.parse('http://127.0.0.1:${server.boundPort}/state'));
      req.headers.set('X-EEG-Token', token);
      expect((await req.close()).statusCode, 401);
      expect((await ask('/who', tok: token)).code, 403); // /who is the paired laptop's
    });
  });

  group('a paired phone shares on its home Wi-Fi only', () {
    setUp(() => from = InternetAddress('192.168.1.30')); // a device on the phone's Wi-Fi

    test('nothing for the token until the paired laptop says this is its home network', () async {
      expect(server.here, 'waiting');
      expect((await ask('/files', tok: token)).body, {'error': 'not sharing on this Wi-Fi'});
      final away = await ask('/files', signWith: key, home: false); // the laptop is not on its own network either
      expect((away.code, away.body['error'], away.reply != null), (403, 'not sharing on this Wi-Fi', true));
      expect((await ask('/who', signWith: key, home: false)).body['here'], 'waiting'); // it still finds the phone
      expect(copied, isEmpty);
      expect((await ask('/files', signWith: key)).code, 200); // the laptop at home: this is home
      expect(server.here, 'home');
      expect(heard, contains('home'));
      expect(copied, ['laptop']);
      expect((await ask('/files', tok: token)).code, 200); // the code by hand, at home
      expect(copied, ['laptop', 'code']);
    });

    test('the laptop finding the phone at home (a signed /who) already says it is home', () async {
      // the emulator smoke of 2026-11-20: the tray's and the sweep's first word is /who
      final w = await ask('/who', signWith: key);
      expect(w.body['here'], 'home');
      expect(server.here, 'home');
      expect((await ask('/files', tok: token)).code, 200);
    });

    test('another network forgets that it was home', () async {
      await ask('/state', signWith: key);
      expect(server.here, 'home');
      server.lan = [(address: InternetAddress('10.20.0.7'), prefix: 24)];
      from = InternetAddress('10.20.0.9');
      expect(server.here, 'waiting');
      expect((await ask('/state', tok: token)).code, 403);
      expect(heard.last, 'waiting');
    });

    test('"Share here for 12 hours": on that network only, until then', () async {
      await server.close();
      await start(hereUntilMs: now.add(const Duration(hours: 12)).millisecondsSinceEpoch, hereNet: '192.168.1.0/24');
      expect(server.here, 'here');
      expect((await ask('/state', tok: token)).code, 200);
      expect((await ask('/state', signWith: key, home: false)).code, 200);
      now = now.add(const Duration(hours: 12, minutes: 1));
      expect(server.here, 'waiting');
      expect((await ask('/state', tok: token)).code, 403);
    });

    test('the phone itself (the USB cable) is always served', () async {
      from = InternetAddress.loopbackIPv4;
      expect((await ask('/files', tok: token)).code, 200);
      expect(copied, ['cable']);
    });

    test('an unpaired phone shares on any Wi-Fi it is switched on at (12 hours at most, as before)', () async {
      await server.close();
      await start(withKey: null);
      expect(server.here, 'open');
      expect((await ask('/files', tok: token)).code, 200);
    });
  });

  test('acks only from the paired laptop, signed', () async {
    final f = File('${files.path}/recordings/2026-11-18-231200.idx')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(32, 2))
      ..setLastModifiedSync(now.subtract(const Duration(hours: 2)));
    final sha = sha256.convert(f.readAsBytesSync()).toString();
    final body = jsonEncode({
      'v': 1,
      'files': [
        {'path': 'recordings/2026-11-18-231200.idx', 'sha256': sha},
      ],
    });
    expect((await ask('/ack', method: 'POST', tok: token, body: body)).body, {'error': 'the paired laptop signs this'});
    final r = await ask('/ack', method: 'POST', signWith: key, body: body);
    expect(r.code, 200);
    expect(r.body['acked'], ['recordings/2026-11-18-231200.idx']);
  });
}
