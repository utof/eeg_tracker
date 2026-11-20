// The push's pure parts (lib/share/push/; DECISIONS 840-849): the signatures against the laptop script's vectors
// (app/test/fixtures/phone_link.json), which of the laptop's wishes the phone fills, the chunks, where the laptop may
// be, and when a push is due.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/share/auth.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/share/push/plan.dart';
import 'package:eeg_tracker/share/push/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('signatures', () {
    final vectors = (jsonDecode(File('test/fixtures/phone_link.json').readAsStringSync()) as Map)['push'] as List;

    test('the laptop script\'s vectors: the request and the answer', () {
      expect(vectors.length, greaterThanOrEqualTo(3));
      for (final v in vectors.cast<Map>()) {
        final uri = Uri.parse('http://x${v['target']}');
        final body = utf8.encode(v['body'] as String);
        expect(
          pushSign(
            v['key'] as String,
            method: v['method'] as String,
            path: Uri.decodeComponent(uri.path),
            query: Uri.decodeComponent(uri.query),
            timeMs: v['time_ms'] as int,
            nonce: v['nonce'] as String,
            body: body,
          ),
          v['sign'],
          reason: '${v['target']}',
        );
        expect(pushReplyProof(v['key'] as String, v['nonce'] as String, utf8.encode(v['reply_body'] as String)), v['reply']);
      }
    });

    test('a push is not the laptop\'s kind of request, and every field counts', () {
      const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';
      String sign({String method = 'POST', String path = '/push/chunk', String query = 'at=0', int t = 5, String n = 'nonce-nonce-nonce-1', String body = 'a'}) =>
          pushSign(key, method: method, path: path, query: query, timeMs: t, nonce: n, body: utf8.encode(body));
      final base = sign();
      expect(base, isNot(requestSign(key, method: 'POST', path: '/push/chunk', query: 'at=0', timeMs: 5, nonce: 'nonce-nonce-nonce-1', home: false, body: utf8.encode('a'))));
      for (final other in [sign(method: 'GET'), sign(path: '/push/commit'), sign(query: 'at=1'), sign(t: 6), sign(n: 'nonce-nonce-nonce-2'), sign(body: 'b')]) {
        expect(other, isNot(base));
      }
      expect(pushReplyProof(key, 'n', utf8.encode('{"v":1}')), isNot(pushReplyProof(key, 'n', utf8.encode('{"v":2}'))));
    });
  });

  group('what the laptop may ask for', () {
    const listed = {'recordings/a.f32': 1000, 'recordings/a.idx': 40, 'nights/r.json': 10};

    test('only listed files, only bytes inside their listed size, each once', () {
      final w = usableWants([
        {'path': 'recordings/a.f32', 'from': 400, 'have': 100},
        {'path': 'recordings/a.f32', 'from': 0, 'have': 0}, // twice
        {'path': '../transfer/acks.json', 'from': 0, 'have': 0}, // not listed
        {'path': '/data/user/0/x', 'from': 0, 'have': 0},
        {'path': 'recordings/a.idx', 'from': 40, 'have': 0}, // nothing left
        {'path': 'recordings/a.idx', 'from': 30, 'have': 20}, // past the end
        {'path': 'nights/r.json', 'from': -1, 'have': 0},
        {'path': 'nights/r.json', 'from': 0, 'have': 'x'},
        'junk',
        {'path': 'nights/r.json', 'from': 0, 'have': 0},
      ], listed);
      expect(w, [(path: 'recordings/a.f32', from: 400, have: 100), (path: 'nights/r.json', from: 0, have: 0)]);
      expect(usableWants('junk', listed), isEmpty);
      expect(usableWants(null, listed), isEmpty);
    });

    test('a file the phone is asking about before deleting is never sent', () {
      final w = usableWants([
        {'path': 'recordings/a.f32', 'from': 0, 'have': 0},
        {'path': 'recordings/a.idx', 'from': 0, 'have': 0},
      ], listed, held: {'recordings/a.f32'});
      expect(w.map((x) => x.path), ['recordings/a.idx']);
    });

    test('chunks: from where the laptop is, up to the listed size, never bigger than the limit', () {
      final c = chunksOf((path: 'p', from: 400, have: 100), 1000, max: 300).toList();
      expect(c, [(path: 'p', at: 500, length: 300), (path: 'p', at: 800, length: 200)]);
      expect(chunksOf((path: 'p', from: 0, have: 0), 5, max: 0).single.length, 5);
      expect(chunksOf((path: 'p', from: 0, have: 0), pushChunkMax + 1, max: 1 << 40).map((x) => x.length), [pushChunkMax, 1]);
      expect(chunksOf((path: 'p', from: 0, have: 10), 10), isEmpty);
    });

    test('the phone\'s list as path -> bytes', () {
      expect(
        listedBytes({
          'files': [
            {'path': 'a', 'bytes': 3},
            {'path': 'b'},
            7,
          ],
        }),
        {'a': 3},
      );
    });
  });

  group('where the laptop may be', () {
    final wifi = parseLanNets(['192.168.1.5/24']);

    test('where it last asked from first, then where it paired; only inside the phone\'s Wi-Fi', () {
      expect(laptopCandidates('192.168.1.9', '192.168.1.6', wifi), ['192.168.1.9', '192.168.1.6']);
      expect(laptopCandidates('192.168.1.6', '192.168.1.6', wifi), ['192.168.1.6']);
      expect(laptopCandidates('10.0.0.3', '8.8.8.8', wifi), isEmpty, reason: 'never outside the Wi-Fi the phone is on');
      expect(laptopCandidates(null, 'not an address', wifi), isEmpty);
      expect(laptopCandidates('192.168.1.6', null, const []), isEmpty, reason: 'no Wi-Fi: nowhere');
    });

    test('the look around covers a home network, not a big one', () {
      final all = sweepAddresses(wifi.single, skip: {'192.168.1.6'});
      expect(all.length, 252); // 254 hosts, less the phone and the one already asked
      expect(all, isNot(contains('192.168.1.5')));
      expect(all, isNot(contains('192.168.1.6')));
      expect(all.first, '192.168.1.1');
      expect(all.last, '192.168.1.254');
      expect(sweepAddresses(parseLanNets(['10.43.97.139/8']).single), isEmpty);
      expect(sweepAddresses(parseLanNets(['10.0.2.16/30']).single), ['10.0.2.17', '10.0.2.18']..remove('10.0.2.16'));
    });
  });

  group('when a push is due', () {
    const m = 60000;
    test('the regular job: at once after good tries, later and later while the laptop is away', () {
      expect(pushDue(const PushState(), 1000 * m, soon: false), isTrue);
      expect(pushDue(const PushState(tryMs: 1000 * m), 1000 * m + 10000, soon: false), isFalse, reason: 'two jobs together');
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 3), 1015 * m, soon: false), isTrue);
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 4), 1015 * m, soon: false), isFalse);
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 4), 1030 * m, soon: false), isTrue);
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 9), 1045 * m, soon: false), isFalse);
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 9), 1060 * m, soon: false), isTrue);
    });

    test('after a recording it does not wait for the back-off, and a clock set back does not stop it', () {
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 9), 1001 * m, soon: true), isTrue);
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 9), 1000 * m + 5000, soon: true), isFalse);
      expect(pushDue(const PushState(tryMs: 1000 * m, fails: 9), 900 * m, soon: false), isTrue);
    });

    test('the look around the network: every two hours at most', () {
      expect(sweepDue(const PushState(), 1000 * m), isTrue);
      expect(sweepDue(const PushState(sweptMs: 1000 * m), 1100 * m), isFalse);
      expect(sweepDue(const PushState(sweptMs: 1000 * m), 1120 * m), isTrue);
    });

    test('what is remembered survives a restart; a good push clears the failures', () {
      final dir = Directory.systemTemp.createTempSync('push_state');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(PushState.read(dir.path).okMs, 0);
      const PushState().started(5).failed('the laptop did not answer on this Wi-Fi').failed('again').swept(7).write(dir.path);
      var s = PushState.read(dir.path);
      expect((s.tryMs, s.fails, s.why, s.sweptMs), (5, 2, 'again', 7));
      s.sent(9, 3, 4096).write(dir.path);
      s = PushState.read(dir.path);
      expect((s.okMs, s.fails, s.why, s.files, s.bytes, s.sweptMs), (9, 0, '', 3, 4096, 7));
      File('${dir.path}/transfer/push.json').writeAsStringSync('{broken');
      expect(PushState.read(dir.path).fails, 0);
      expect(readLaptopAt(dir.path), isNull);
      writeLaptopAt(dir.path, '192.168.1.6');
      expect(readLaptopAt(dir.path), '192.168.1.6');
      File('${dir.path}/transfer/laptop-at.json').writeAsStringSync('{"address":"; rm -rf"}');
      expect(readLaptopAt(dir.path), isNull);
    });
  });
}
