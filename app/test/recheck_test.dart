// The check just before the phone deletes a raw recording by itself (lib/recorder/recheck.dart, server.dart,
// storage/clear.dart; DECISIONS 756): the phone picks random byte ranges and a fresh nonce; the paired laptop must
// answer with an HMAC over those bytes of its OWN copy (GET/POST /recheck, signed); while a question is open the
// phone does not hand that file out, so its answer cannot come from the phone itself; a hash the phone lists is not
// enough; no fresh proof, nothing deleted; a laptop that lost its copy loses the ack instead. Real sockets on 127.0.0.1.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/recorder/acks.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem;
import 'package:eeg_tracker/recorder/packed.dart' show packRaw;
import 'package:eeg_tracker/recorder/recheck.dart';
import 'package:eeg_tracker/share/auth.dart';
import 'package:eeg_tracker/share/server.dart';
import 'package:eeg_tracker/storage/clear.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'abcdefghjkmn';
const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';

void main() {
  late Directory files, rec;
  final random = Random(756);
  final now = DateTime(2026, 11, 25, 12, 0);

  setUp(() {
    files = Directory.systemTemp.createTempSync('recheck_test');
    rec = Directory('${files.path}/recordings')..createSync();
  });
  tearDown(() => files.deleteSync(recursive: true));

  String sha(List<int> b) => sha256.convert(b).toString();

  /// One raw set written 10 days before [now], acked by the laptop 5 days before.
  ({String stem, Uint8List f32}) acked(DateTime start) {
    final stem = fileStem(start);
    final f32 = Uint8List.fromList([for (var i = 0; i < 60000; i++) random.nextInt(256)]);
    final idx = ByteData(16)..setFloat64(0, start.add(const Duration(hours: 1)).microsecondsSinceEpoch / 1e6, Endian.little);
    final made = now.subtract(const Duration(days: 10));
    for (final (name, bytes) in [('$stem.f32', f32), ('$stem.idx', idx.buffer.asUint8List())]) {
      File('${rec.path}/$name')
        ..writeAsBytesSync(bytes)
        ..setLastModifiedSync(made);
    }
    File('${rec.path}/$stem.header.json').writeAsStringSync('{"session":"work"}'); // a work session's set: no report needed
    for (final name in ['$stem.f32', '$stem.idx']) {
      final f = File('${rec.path}/$name'), st = f.statSync();
      AckStore(files).add({
        'recordings/$name': LaptopCopy(
          sha256: sha(f.readAsBytesSync()),
          bytes: st.size,
          modifiedMs: st.modified.millisecondsSinceEpoch,
          ackedMs: now.subtract(const Duration(days: 5)).millisecondsSinceEpoch,
        ),
      });
    }
    return (stem: stem, f32: f32);
  }

  test('the ranges: the whole of a small file; 8 x 4 KB somewhere in a big one, inside it, in order', () {
    expect(pickRanges(1000, Random(1)), [(0, 1000)]);
    expect(pickRanges(0, Random(1)), [(0, 0)]);
    final r = pickRanges(10000000, Random(2));
    expect(r, hasLength(8));
    for (final (s, n) in r) {
      expect(n, 4096);
      expect(s + n, lessThanOrEqualTo(10000000));
    }
    expect([for (final x in r) x.$1], [for (final x in r) x.$1]..sort());
    for (var i = 1; i < r.length; i++) {
      expect(r[i].$1, greaterThanOrEqualTo(r[i - 1].$1 + r[i - 1].$2), reason: 'never overlapping');
    }
    expect(pickRanges(10000000, Random(3)), isNot(r)); // fresh each time
  });

  group('the server', () {
    late ShareServer server;
    late HttpClient client;
    final proved = <int>[];

    setUp(() async {
      proved.clear();
      server = ShareServer(filesDir: files, token: token, key: key, port: 0, clock: () => now, onProved: proved.add);
      await server.listen();
      client = HttpClient();
    });
    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    Future<({int code, Map<String, Object?> body, List<int> raw})> ask(String path, {String method = 'GET', String? body, bool sign = true}) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.boundPort}$path'));
      if (sign) {
        final n = newNonce(), t = now.millisecondsSinceEpoch, u = Uri.parse(path);
        req.headers
          ..set(timeHeader, '$t')
          ..set(nonceHeader, n)
          ..set(homeHeader, '1')
          ..set(signHeader, requestSign(key, method: method, path: Uri.decodeComponent(u.path), query: '', timeMs: t, nonce: n, home: true, body: utf8.encode(body ?? '')));
      } else {
        req.headers.set('Authorization', 'Bearer $token');
      }
      if (body != null) req.add(utf8.encode(body));
      final res = await req.close();
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      Map<String, Object?> j;
      try {
        j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
      } catch (_) {
        j = const {};
      }
      return (code: res.statusCode, body: j, raw: bytes);
    }

    /// The laptop's answer: the HMAC over [data] (its own copy) at the asked ranges.
    String mac(Map<String, Object?> a, List<int> data) {
      final ranges = [for (final r in a['ranges']! as List) ((r as List)[0] as int, r[1] as int)];
      return recheckMac(key, a['path']! as String, a['nonce']! as String, a['bytes']! as int, ranges, [
        for (final (s, n) in ranges) data.sublist(s, s + n),
      ]);
    }

    test('only the paired laptop sees the questions; while one is open the file is not handed out', () async {
      final a = acked(DateTime(2026, 11, 15, 23));
      RecheckStore(files).ask(['recordings/${a.stem}.f32'], now: now, random: Random(9));
      expect((await ask('/recheck', sign: false)).code, 403);
      final q = (await ask('/recheck')).body;
      final asks = (q['asks']! as List).cast<Map<String, Object?>>();
      expect(asks.single['path'], 'recordings/${a.stem}.f32');
      expect(asks.single['bytes'], 60000);
      // the bytes cannot come from the phone itself: neither the laptop's nor the token's request gets the file now
      expect((await ask('/files/recordings/${a.stem}.f32')).code, 409);
      expect((await ask('/files/recordings/${a.stem}.f32', sign: false)).code, 409);
      expect((await ask('/files/recordings/${a.stem}.idx')).code, 200, reason: 'not asked about');
    });

    test('the right bytes prove it; other bytes, a lost copy or a stale nonce do not, and a lost copy loses its ack', () async {
      final a = acked(DateTime(2026, 11, 15, 23)), b = acked(DateTime(2026, 11, 16, 23)), c = acked(DateTime(2026, 11, 17, 23));
      RecheckStore(files).ask(['recordings/${a.stem}.f32', 'recordings/${b.stem}.f32', 'recordings/${c.stem}.f32'], now: now, random: Random(9));
      final asks = {for (final x in ((await ask('/recheck')).body['asks']! as List).cast<Map<String, Object?>>()) x['path']: x};
      final qa = asks['recordings/${a.stem}.f32']!, qb = asks['recordings/${b.stem}.f32']!, qc = asks['recordings/${c.stem}.f32']!;
      final at = ((qb['ranges']! as List).first as List)[0] as int;
      final other = Uint8List.fromList(b.f32)..[at] ^= 1;
      final r = await ask(
        '/recheck',
        method: 'POST',
        body: jsonEncode({
          'v': 1,
          'proofs': [
            {'path': qa['path'], 'nonce': qa['nonce'], 'mac': mac(qa, a.f32)},
            {'path': qb['path'], 'nonce': qb['nonce'], 'mac': mac(qb, other)},
            {'path': qc['path'], 'nonce': qc['nonce'], 'missing': true},
            {'path': qa['path'], 'nonce': 'c3RhbGUtbm9uY2UtMDAwMQ', 'mac': '0' * 64},
          ],
        }),
      );
      expect(r.code, 200);
      expect(r.body['proven'], ['recordings/${a.stem}.f32']);
      expect([for (final f in r.body['failed']! as List) (f as Map)['why']], ['different bytes', 'the laptop does not hold it', 'not asked']);
      expect(proved, [1]);
      final proofs = RecheckStore(files).proofs();
      expect(proofs['recordings/${a.stem}.f32']!.ok, isTrue);
      expect(proofs['recordings/${b.stem}.f32']!.ok, isFalse);
      final acks = AckStore(files).load();
      expect(acks.containsKey('recordings/${c.stem}.f32'), isFalse, reason: 'a laptop that lost its copy does not hold it');
      expect(acks.containsKey('recordings/${b.stem}.f32'), isFalse);
      expect(acks.containsKey('recordings/${a.stem}.f32'), isTrue);
      expect((await ask('/files/recordings/${c.stem}.f32')).code, 200, reason: 'answered: the laptop may copy it again');
    });

    test('a packed recording is asked about by its plain bytes, as the laptop holds them', () async {
      final a = acked(DateTime(2026, 11, 15, 23));
      packRaw(File('${rec.path}/${a.stem}.f32'));
      expect(File('${rec.path}/${a.stem}.f32.gz').existsSync(), isTrue);
      RecheckStore(files).ask(['recordings/${a.stem}.f32'], now: now, random: Random(9));
      final q = ((await ask('/recheck')).body['asks']! as List).cast<Map<String, Object?>>().single;
      expect(q['bytes'], 60000);
      expect((await ask('/files/recordings/${a.stem}.f32.gz')).code, 409);
      final r = await ask('/recheck', method: 'POST', body: jsonEncode({'v': 1, 'proofs': [{'path': q['path'], 'nonce': q['nonce'], 'mac': mac(q, a.f32)}]}));
      expect(r.body['proven'], ['recordings/${a.stem}.f32']);
    });
  });

  group('deleting by itself waits for a fresh proof', () {
    test('no proof: nothing goes, the questions are asked; a fresh proof: it goes; a stale or failed one: it stays', () async {
      final a = acked(DateTime(2026, 11, 15, 23)), b = acked(DateTime(2026, 11, 16, 23));
      Future<ClearRun?> clear(DateTime at) => autoClear(files, busy: () async => false, paired: true, clock: () => at);
      final first = (await clear(now))!;
      expect(first.removed, isEmpty);
      expect(File('${rec.path}/${a.stem}.f32').existsSync(), isTrue);
      final asks = RecheckStore(files).asks();
      expect(asks.keys.toSet(), {for (final s in [a.stem, b.stem]) for (final x in ['f32', 'idx']) 'recordings/$s.$x'});
      // the laptop proves a's two files (as the server records it), nothing for b
      for (final x in ['f32', 'idx']) {
        RecheckStore(files).prove('recordings/${a.stem}.$x', asks['recordings/${a.stem}.$x']!.nonce, ok: true, why: null, at: now.add(const Duration(minutes: 1)));
      }
      final second = (await clear(now.add(const Duration(minutes: 2))))!;
      expect(second.removed, ['${a.stem}.f32']);
      expect(File('${rec.path}/${a.stem}.f32').existsSync(), isFalse);
      expect(File('${rec.path}/${b.stem}.f32').existsSync(), isTrue);
      // a proof older than 15 minutes is not "right then": a new question instead
      final bAsks = RecheckStore(files).asks();
      for (final x in ['f32', 'idx']) {
        RecheckStore(files).prove('recordings/${b.stem}.$x', bAsks['recordings/${b.stem}.$x']!.nonce, ok: true, why: null, at: now.add(const Duration(minutes: 3)));
      }
      final late = (await clear(now.add(const Duration(minutes: 20))))!;
      expect(late.removed, isEmpty);
      expect(RecheckStore(files).asks()['recordings/${b.stem}.f32']!.nonce, isNot(bAsks['recordings/${b.stem}.f32']!.nonce));
      // a failed proof: never deleted on it
      final again = RecheckStore(files).asks();
      RecheckStore(files).prove('recordings/${b.stem}.f32', again['recordings/${b.stem}.f32']!.nonce, ok: false, why: 'different bytes', at: now.add(const Duration(minutes: 21)));
      RecheckStore(files).prove('recordings/${b.stem}.idx', again['recordings/${b.stem}.idx']!.nonce, ok: true, why: null, at: now.add(const Duration(minutes: 21)));
      expect((await clear(now.add(const Duration(minutes: 22))))!.removed, isEmpty);
      expect(File('${rec.path}/${b.stem}.f32').existsSync(), isTrue);
    });
  });
}
