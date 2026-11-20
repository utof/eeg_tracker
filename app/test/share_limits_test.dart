// What may change something on the phone, and how much the server takes (lib/share/server.dart; DECISIONS 755):
// /work and /marker take only the paired laptop's signed requests (with a time and a nonce used once, so a copied
// request cannot be sent again); ten wrong tries in a minute from one address make that address wait a minute; and the
// server holds at most 16 connections from one address and 32 in all, closing more at once. Real sockets on
// 127.0.0.1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/share/auth.dart';
import 'package:eeg_tracker/share/server.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'abcdefghjkmn';
const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';

void main() {
  late Directory files;
  late ShareServer server;
  late HttpClient client;
  var now = DateTime(2026, 11, 19, 3, 0, 0);
  final works = <bool>[];
  final markers = <String>[];

  setUp(() async {
    files = Directory.systemTemp.createTempSync('share_limits_test');
    client = HttpClient();
    now = DateTime(2026, 11, 19, 3, 0, 0);
    works.clear();
    markers.clear();
    server = ShareServer(
      filesDir: files,
      token: token,
      port: 0,
      clock: () => now,
      key: key,
      onWork: (w, _) => works.add(w),
      onMarker: (t) async {
        markers.add(t);
        return (t: 1.0, i: 2);
      },
    );
    await server.listen();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    files.deleteSync(recursive: true);
  });

  Future<({int code, Map<String, Object?> body})> ask(String path, {String method = 'GET', String? tok, bool sign = false, String body = '', String? nonce}) async {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.boundPort}$path'));
    if (sign) {
      final n = nonce ?? newNonce(), t = now.millisecondsSinceEpoch;
      req.headers
        ..set(timeHeader, '$t')
        ..set(nonceHeader, n)
        ..set(homeHeader, '1')
        ..set(signHeader, requestSign(key, method: method, path: path, query: '', timeMs: t, nonce: n, home: true, body: utf8.encode(body)));
    }
    if (tok != null) req.headers.set('Authorization', 'Bearer $tok');
    if (body.isNotEmpty) req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Map<String, Object?> j;
    try {
      j = (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      j = {'raw': text};
    }
    return (code: res.statusCode, body: j);
  }

  test('/work and /marker: only the paired laptop, signed; a copied request is not taken again', () async {
    expect((await ask('/work', method: 'POST', tok: token, body: '{"working":true}')).body, {'error': 'the paired laptop signs this'});
    expect((await ask('/marker', method: 'POST', tok: token, body: 'eyes closed')).body, {'error': 'the paired laptop signs this'});
    expect(works, isEmpty);
    expect(markers, isEmpty);
    expect((await ask('/work', method: 'POST', sign: true, body: '{"working":true}', nonce: 'd29yay1ub25jZS0wMDAx')).code, 202);
    expect((await ask('/marker', method: 'POST', sign: true, body: 'eyes closed')).code, 200);
    expect(works, [true]);
    expect(markers, ['eyes closed']);
    final replay = await ask('/work', method: 'POST', sign: true, body: '{"working":true}', nonce: 'd29yay1ub25jZS0wMDAx');
    expect((replay.code, replay.body['error']), (401, 'replayed'));
    expect(works, [true]);
  });

  test('ten wrong tries in a minute from one address: it waits a minute, even with the right code', () async {
    for (var i = 0; i < 10; i++) {
      expect((await ask('/state', tok: 'wrongwrong${i}x')).code, 401);
    }
    final blocked = await ask('/state', tok: token);
    expect((blocked.code, blocked.body['error']), (429, 'too many wrong tries: wait a minute'));
    now = now.add(const Duration(seconds: 61));
    expect((await ask('/state', tok: token)).code, 200);
    // tries spread out over more than a minute never add up
    for (var i = 0; i < 9; i++) {
      expect((await ask('/state', tok: 'wrongwrong${i}x')).code, 401);
    }
    now = now.add(const Duration(seconds: 61));
    for (var i = 0; i < 9; i++) {
      expect((await ask('/state', tok: 'wrongwrong${i}x')).code, 401);
    }
    expect((await ask('/state', tok: token)).code, 200);
  });

  test('at most 16 connections from one address: more are closed at once; when they go, it answers again', () async {
    final held = <Socket>[];
    for (var i = 0; i < serverConnectionsPerClient; i++) {
      held.add(await Socket.connect('127.0.0.1', server.boundPort));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final extra = await Socket.connect('127.0.0.1', server.boundPort);
    final closed = Completer<void>();
    extra.listen((_) {}, onDone: closed.complete, onError: (Object _) => closed.complete());
    await closed.future.timeout(const Duration(seconds: 3)); // closed by the phone, not left hanging
    extra.destroy();
    for (final s in held) {
      s.destroy();
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await ask('/state', tok: token)).code, 200);
    expect(serverConnectionsMax, 32);
  });
}
