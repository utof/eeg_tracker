// Share on Wi-Fi's `POST /ack` (share/server.dart; DECISIONS 690-699, 755): the paired laptop's word that it holds
// checked copies, in a request signed with the pairing's key (refused otherwise), kept per file only for the bytes the
// phone holds, and marked `acked` in `/files`. Real sockets on 127.0.0.1 (no widget binding here: it would answer every request with 400).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/recorder/acks.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem;
import 'package:eeg_tracker/share/auth.dart';
import 'package:eeg_tracker/share/server.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'abcdefghjkmn';
const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';

void main() {
  late Directory files, rec;
  final random = Random(691);

  setUp(() {
    files = Directory.systemTemp.createTempSync('share_ack');
    rec = Directory('${files.path}/recordings')..createSync();
  });
  tearDown(() => files.deleteSync(recursive: true));

  DateTime later() => DateTime.now().add(const Duration(hours: 2));
  String sha(File f) => sha256.convert(f.readAsBytesSync()).toString();
  List<String> names(Directory d) => (d.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList())..sort();

  String run(DateTime start) {
    final stem = fileStem(start);
    File('${rec.path}/$stem.f32').writeAsBytesSync([for (var i = 0; i < 20000; i++) random.nextInt(256)]);
    final idx = ByteData(16)..setFloat64(0, start.add(const Duration(hours: 1)).microsecondsSinceEpoch / 1e6, Endian.little);
    File('${rec.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
    File('${rec.path}/$stem.log').writeAsStringSync('started\n');
    return stem;
  }

  group('Share on Wi-Fi\'s POST /ack', () {
    late ShareServer server;
    late HttpClient client;
    var now = DateTime.now();

    Future<void> start(String? withKey) async {
      server = ShareServer(filesDir: files, token: token, port: 0, key: withKey, clock: () => now);
      await server.listen();
    }

    setUp(() {
      client = HttpClient();
      now = later();
    });
    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    /// POST /ack signed with [withKey] (the paired laptop's), or with only the token when [withKey] is null.
    Future<({int code, Map<String, Object?> body})> post(String body, {String? withKey = key}) async {
      final req = await client.openUrl('POST', Uri.parse('http://127.0.0.1:${server.boundPort}/ack'));
      if (withKey == null) {
        req.headers.set('Authorization', 'Bearer $token');
      } else {
        final n = newNonce(), t = now.millisecondsSinceEpoch;
        req.headers
          ..set(timeHeader, '$t')
          ..set(nonceHeader, n)
          ..set(homeHeader, '1')
          ..set(signHeader, requestSign(withKey, method: 'POST', path: '/ack', query: '', timeMs: t, nonce: n, home: true, body: utf8.encode(body)));
      }
      req.add(utf8.encode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (code: res.statusCode, body: jsonDecode(text) as Map<String, Object?>);
    }

    Future<Map<String, Map<String, Object?>>> listed() async {
      final req = await client.openUrl('GET', Uri.parse('http://127.0.0.1:${server.boundPort}/files'));
      req.headers.set('Authorization', 'Bearer $token');
      final j = jsonDecode(await (await req.close()).transform(utf8.decoder).join()) as Map<String, Object?>;
      return {for (final f in (j['files']! as List).cast<Map<String, Object?>>()) f['path']! as String: f};
    }

    String body(List<(String, String)> items) => jsonEncode({
      'v': 1,
      'files': [for (final (p, s) in items) {'path': p, 'sha256': s}],
    });

    test('unpaired: refused, nothing kept', () async {
      await start(null);
      final stem = run(DateTime(2026, 11, 17, 23));
      final r = await post(body([('recordings/$stem.f32', sha(File('${rec.path}/$stem.f32')))]));
      expect((r.code, r.body['error']), (401, 'not paired'));
      expect(AckStore(files).load(), isEmpty);
    });

    test('signed with another key, or only the token: refused, nothing kept', () async {
      await start(key);
      final stem = run(DateTime(2026, 11, 17, 23));
      final b = body([('recordings/$stem.f32', sha(File('${rec.path}/$stem.f32')))]);
      expect((await post(b, withKey: 'f' * 64)).code, 401);
      expect((await post(b, withKey: null)).body, {'error': 'the paired laptop signs this'});
      expect(AckStore(files).load(), isEmpty);
    });

    test('each file on its own: the right hash kept and listed `acked`, a wrong one or a missing file refused; again changes nothing', () async {
      await start(key);
      final a = run(DateTime(2026, 11, 17, 23)), b = run(DateTime(2026, 11, 18, 23));
      final fa = File('${rec.path}/$a.f32'), fb = File('${rec.path}/$b.f32');
      final ask = body([
        ('recordings/$a.f32', sha(fa)),
        ('recordings/$b.f32', sha(fa)), // not its bytes
        ('recordings/2026-11-10-230000.idx', sha(fa)),
      ]);
      final r = await post(ask);
      expect(r.code, 200);
      expect(r.body['acked'], ['recordings/$a.f32']);
      expect([for (final x in r.body['refused']! as List) (x as Map)['why']], ['different bytes', 'not on the phone']);
      final kept = AckStore(files).load();
      expect(kept.keys, ['recordings/$a.f32']);
      final list = await listed();
      expect(list['recordings/$a.f32']!['acked'], isTrue);
      expect(list['recordings/$b.f32']!.containsKey('acked'), isFalse);
      expect(list['recordings/$a.log']!.containsKey('acked'), isFalse);
      expect(fb.existsSync(), isTrue);
      final again = await post(ask);
      expect(again.body['acked'], ['recordings/$a.f32']);
      expect(AckStore(files).load()['recordings/$a.f32']!.sha256, kept['recordings/$a.f32']!.sha256);
      expect(names(rec).where((n) => n.endsWith('.f32')).length, 2, reason: 'the server itself never deletes');
    });

    test('a body that is too big is refused whole', () async {
      await start(key);
      final big = body([for (var i = 0; i < 3000; i++) ('recordings/2026-11-10-230000.f32', '0' * 64)]);
      expect((await post(big)).code, 413);
    });
  });

}
