// Share on Wi-Fi's server (lib/share/server.dart): the laptop recorder's routes and JSON, the files with Range,
// the token and the client address. Real sockets on 127.0.0.1.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/export/store.dart';
import 'package:eeg_tracker/recorder/packed.dart' show packRaw;
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/share/server.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'abcdefghjkmn';

void main() {
  late Directory files;
  late ShareServer server;
  late HttpClient client;
  final shapes = jsonDecode(File('test/fixtures/share_api.json').readAsStringSync()) as Map<String, Object?>;
  var now = DateTime(2026, 11, 19, 3, 0, 0);
  InternetAddress? clientAddress;
  final markers = <String>[];
  MarkerResult? markerAnswer;
  final works = <bool>[];
  final meetings = <bool?>[];

  Future<void> start({Duration keepalive = const Duration(seconds: 10)}) async {
    server = ShareServer(
      filesDir: files,
      token: token,
      port: 0,
      keepalive: keepalive,
      clock: () => now,
      clientOf: (r) => clientAddress ?? r.connectionInfo?.remoteAddress,
      onMarker: (text) async {
        markers.add(text);
        return markerAnswer;
      },
      onWork: (working, meeting) {
        works.add(working);
        meetings.add(meeting);
      },
    );
    await server.listen();
  }

  setUp(() async {
    files = Directory.systemTemp.createTempSync('share_server_test');
    client = HttpClient();
    now = DateTime(2026, 11, 19, 3, 0, 0);
    clientAddress = null;
    markers.clear();
    markerAnswer = null;
    works.clear();
    meetings.clear();
    await start();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    files.deleteSync(recursive: true);
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.boundPort}$path');

  Future<({int code, List<int> body, HttpHeaders headers})> ask(
    String path, {
    String method = 'GET',
    String? tok = token,
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final req = await client.openUrl(method, url(path));
    if (tok != null) req.headers.set('Authorization', 'Bearer $tok');
    headers.forEach(req.headers.set);
    if (body != null) req.add(utf8.encode(body));
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (code: res.statusCode, body: bytes, headers: res.headers);
  }

  Future<Map<String, Object?>> json(String path) async {
    final r = await ask(path);
    expect(r.code, 200, reason: path);
    return jsonDecode(utf8.decode(r.body)) as Map<String, Object?>;
  }

  File put(String path, List<int> bytes, {DateTime? modified}) {
    final f = File('${files.path}/$path')..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    f.setLastModifiedSync(modified ?? now.subtract(const Duration(minutes: 5)));
    return f;
  }

  /// [n] samples: O1 = (first + k) µV, O2 = 2 µV, T3 = -1 µV, T4 = 0.
  Float32List batch(int first, int n) {
    final v = Float32List(n * 4);
    for (var k = 0; k < n; k++) {
      v[k * 4] = (first + k) * 1e-6;
      v[k * 4 + 1] = 2e-6;
      v[k * 4 + 2] = -1e-6;
    }
    return v;
  }

  group('token and address', () {
    test('no token, a wrong token: 401; header, X-EEG-Token and ?token= all work', () async {
      expect((await ask('/state', tok: null)).code, 401);
      expect((await ask('/state', tok: 'abcdefghjkmx')).code, 401);
      expect((await ask('/state', tok: '')).code, 401);
      expect((await ask('/files/settings.json', tok: null)).code, 401);
      expect((await ask('/state')).code, 200);
      expect((await ask('/state', tok: null, headers: {'X-EEG-Token': token})).code, 200);
      expect((await ask('/state?token=$token', tok: null)).code, 200);
    });

    test('a client that is not on the local network is refused, token or not', () async {
      server.lan = parseLanNets(['192.168.1.5/24']);
      clientAddress = InternetAddress('8.8.8.8');
      expect((await ask('/state')).code, 403);
      clientAddress = InternetAddress('2001:db8::1');
      expect((await ask('/files')).code, 403);
      clientAddress = InternetAddress('192.168.1.40');
      expect((await ask('/state')).code, 200);
      // private, but not this Wi-Fi: the VPN's other end, mobile data's carrier network (DECISIONS row 562)
      for (final a in ['10.10.10.2', '10.43.0.1']) {
        clientAddress = InternetAddress(a);
        expect((await ask('/state')).code, 403, reason: a);
      }
      server.lan = const [];
      clientAddress = InternetAddress('192.168.1.40');
      expect((await ask('/state')).code, 403, reason: 'no Wi-Fi network known: the phone itself only');
      clientAddress = InternetAddress('127.0.0.1');
      expect((await ask('/state')).code, 200);
    });

    test('it listens on every address: a real client on this machine\'s own network is let in only inside the '
        'Wi-Fi network', () async {
      expect(server.addresses, isEmpty);
      final own = [
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
          for (final a in i.addresses)
            if (isPrivateV4(a)) a,
      ];
      if (own.isEmpty) {
        markTestSkipped('this machine has no private IPv4 address');
        return;
      }
      final a = own.first;
      final at = Uri.parse('http://${a.address}:${server.boundPort}/state');
      Future<int> code() async {
        final req = await client.getUrl(at);
        req.headers.set('Authorization', 'Bearer $token');
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      expect(await code(), 403); // reached, but no Wi-Fi network is known yet
      server.lan = [(address: a, prefix: a.prefixLength)];
      expect(await code(), 200);
      expect(server.addresses, [a.address]);
    });

    test('which addresses are local', () {
      for (final a in ['10.0.2.2', '172.16.0.9', '172.31.255.1', '192.168.0.7', '169.254.3.3', '127.0.0.1', '::1', '::ffff:192.168.1.5']) {
        expect(isAllowedClient(InternetAddress(a)), isTrue, reason: a);
      }
      for (final a in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '192.169.0.1', '100.64.0.1', '2a00::1', 'fe80::1', '::ffff:8.8.8.8']) {
        expect(isAllowedClient(InternetAddress(a)), isFalse, reason: a);
      }
    });

    test('tokens: 12 easy characters, different every time, compared whole', () {
      final a = newToken(), b = newToken();
      expect(a, hasLength(12));
      expect(a, isNot(b));
      expect(RegExp(r'^[a-km-np-z2-9]+$').hasMatch(a), isTrue);
      expect(sameToken(a, a), isTrue);
      expect(sameToken('${a}x', a), isFalse);
      expect(sameToken(a.substring(1), a), isFalse);
      expect(sameToken('', ''), isFalse);
    });

    test('only GET, HEAD and POST; nothing writes or deletes a file', () async {
      final f = put('settings.json', utf8.encode('{}'));
      for (final m in ['DELETE', 'PUT', 'PATCH']) {
        expect((await ask('/files/settings.json', method: m)).code, 405, reason: m);
      }
      expect((await ask('/files/settings.json', method: 'POST', body: 'x')).code, 405);
      expect((await ask('/files', method: 'POST', body: 'x')).code, 405);
      expect(f.readAsStringSync(), '{}');
    });
  });

  group('the laptop recorder\'s routes', () {
    test('/state before any data: the keys of the laptop, empty data, age 999', () async {
      final s = await json('/state');
      expect(s.keys.toSet(), {...(shapes['state_keys']! as List), ...(shapes['phone_state_keys']! as List)});
      expect(s['session'], isNull);
      expect(s['status'], 'not recording');
      expect(s['battery'], '?');
      expect(s['names'], shapes['names']);
      expect(s['fs'], shapes['fs']);
      expect(s['data'], [<Object?>[], <Object?>[], <Object?>[], <Object?>[]]);
      expect(s['contact'], {'O1': null, 'O2': null, 'T3': null, 'T4': null});
      expect(s['contact_t'], isNull);
      expect(s['age'], 999);
      expect(s['minutes'], 0);
    });

    test("/state's session: a Work session's level and signal for the laptop tray, its data's age by the phone's clock (DECISIONS 671)", () async {
      server.setSession({
        'kind': 'work',
        'since': '2026-11-19T00:00:00.000Z',
        'stage': 'running',
        'level': 'getting_drowsy',
        'signal': 'good',
        'on_break': false,
        'hint': {'reason': 'drowsy', 'at': '2026-11-19T00:50:00.000Z'},
        'data_at': now.microsecondsSinceEpoch / 1e6 - 2.5,
        'not_listed': 'dropped',
      });
      var s = (await json('/state'))['session'] as Map;
      expect(s.keys.toList(), shapes['session_keys']);
      expect(s['level'], 'getting_drowsy');
      expect(s['hint'], {'reason': 'drowsy', 'at': '2026-11-19T00:50:00.000Z'});
      expect(s['age'], 2.5);
      now = now.add(const Duration(minutes: 2)); // the screen stopped telling: its data grows old
      expect(((await json('/state'))['session'] as Map)['age'], 122.5);
      server.setSession({'kind': 'work', 'since': '2026-11-19T00:00:00.000Z', 'data_at': null});
      s = (await json('/state'))['session'] as Map;
      expect(s['age'], isNull);
      server.setSession(null);
      expect((await json('/state'))['session'], isNull);
      expect((await json('/state'))['status'], 'not recording', reason: 'a Work session writes no recording');
    });

    test('/state while recording: the last 4 s in µV around each channel\'s mean, the status in the laptop\'s words', () async {
      for (var i = 0; i < 1250; i += 25) {
        server.addBatch('2026-11-19-030000', i, now.microsecondsSinceEpoch / 1e6, batch(i, 25));
      }
      server.setLive({
        'kind': 'status',
        'phase': 'recording',
        'nightSamples': 45000,
        'battery': 71,
        'contact': [400000.4, 1500000.0, null, null],
        'contactKnown': true,
      });
      now = now.add(const Duration(milliseconds: 1500));
      final s = await json('/state');
      expect(s['status'], 'recording');
      expect(s['battery'], 71);
      expect(s['minutes'], 3.0);
      expect(s['age'], 1.5);
      expect(s['contact'], {'O1': 400000, 'O2': 1500000, 'T3': null, 'T4': null});
      expect(s['contact_t'], isA<double>());
      final data = (s['data']! as List).cast<List<Object?>>();
      expect(data.map((c) => c.length), [1000, 1000, 1000, 1000]); // 4 s of the 5 s kept
      // O1 ran 250..1249 µV: mean 749.5
      expect(data[0].first, -499.5);
      expect(data[0].last, 499.5);
      expect(data[1].toSet(), {0.0});
      // a reconnect shows as the laptop's word, which its pages know
      server.setLive({'phase': 'reconnecting', 'nightSamples': 45000});
      expect((await json('/state'))['status'], 'reconnecting');
      server.setLive({'phase': 'searching'});
      expect((await json('/state'))['status'], 'reconnecting');
    });

    test('a DIY board night: the board\'s channel names, as the laptop\'s DIY recorder sends them', () async {
      server.setLive({
        'kind': 'status',
        'phase': 'recording',
        'nightSamples': 2500,
        'board': {'names': ['O1', 'O2', 'Fz', 'Fp1'], 'mode': 'test', 'modeText': 'test signal, not EEG'},
      });
      final s = await json('/state');
      expect(s['names'], ['O1', 'O2', 'Fz', 'Fp1']);
      expect((s['contact'] as Map).keys, ['O1', 'O2', 'Fz', 'Fp1']);
      server.setLive({'kind': 'status', 'phase': 'recording', 'nightSamples': 2500});
      expect((await json('/state'))['names'], shapes['names']); // the BrainBit's again
    });

    test('an 8-channel board: /state has its eight names, eight data rows and its rate (DECISIONS 630-639)', () async {
      final names = ['Fz', 'Cz', 'Pz', 'O1', 'O2', 'T7', 'T8', 'Oz'];
      server.setLive({
        'kind': 'status',
        'phase': 'recording',
        'nightSamples': 5000,
        'board': {'names': names, 'mode': 'test', 'modeText': 'test signal, not EEG', 'fs': 500},
      });
      final v = Float32List(500 * 8);
      for (var i = 0; i < 500; i++) {
        for (var c = 0; c < 8; c++) {
          v[i * 8 + c] = (c + 1) * 1e-5 * (i.isEven ? 1 : -1); // each channel its own swing
        }
      }
      server.addBatch('2026-11-20-030000', 0, now.microsecondsSinceEpoch / 1e6, v, channels: 8);
      final s = await json('/state');
      expect(s['names'], names);
      expect(s['fs'], 500);
      expect((s['contact'] as Map).keys, names);
      final data = (s['data'] as List).cast<List<Object?>>();
      expect(data, hasLength(8));
      for (var c = 0; c < 8; c++) {
        expect((data[c].first! as num).abs(), closeTo((c + 1) * 10, 0.1), reason: names[c]); // µV around the mean
      }
      // the BrainBit again: four channels, its names, the ring starts over at its width
      server.setLive({'kind': 'status', 'phase': 'recording', 'nightSamples': 5000});
      server.addBatch('2026-11-20-031000', 0, now.microsecondsSinceEpoch / 1e6, batch(0, 250));
      final b = await json('/state');
      expect(b['names'], shapes['names']);
      expect(b['data'] as List, hasLength(4));
      expect(b['fs'], 250);
    });

    test('/state from the app between nights: "session" while a session records, then "not recording"', () async {
      server.setLive(const {});
      server.addBatch('2026-11-19-030000', 0, now.microsecondsSinceEpoch / 1e6, batch(0, 250));
      var s = await json('/state');
      expect(s['status'], 'session');
      expect(s['minutes'], 0.0);
      now = now.add(const Duration(seconds: 30));
      s = await json('/state');
      expect(s['status'], 'not recording');
      expect(s['age'], 30.0);
    });

    test('/stream: a hello, each batch, markers and keep-alives, as plain server-sent events', () async {
      await server.close();
      await start(keepalive: const Duration(milliseconds: 150));
      server.addBatch('2026-11-19-030000', 0, 1763500000.0, batch(0, 10));
      final socket = await Socket.connect('127.0.0.1', server.boundPort);
      final text = StringBuffer();
      final sub = socket.cast<List<int>>().transform(utf8.decoder).listen(text.write);
      socket.write('GET /stream HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer $token\r\n\r\n');
      Future<void> until(bool Function() ok) async {
        for (var i = 0; i < 200 && !ok(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(ok(), isTrue, reason: text.toString());
      }

      await until(() => text.toString().contains('"hello"'));
      expect(server.readers, 1);
      server.addBatch('2026-11-19-030000', 10, 1763500000.1004, batch(10, 2));
      markerAnswer = (t: 1763500000.2, i: 12);
      expect((await ask('/marker', method: 'POST', body: '  eyes closed start \n')).code, 200);
      await until(() => text.toString().contains('"marker"') && text.toString().contains(': keepalive'));
      final all = text.toString();
      final head = all.substring(0, all.indexOf('\r\n\r\n')).toLowerCase();
      expect(head, contains('content-type: text/event-stream'));
      expect(head, isNot(contains('chunked'))); // the laptop's page server passes the raw lines through
      final events = [
        for (final line in all.substring(all.indexOf('\r\n\r\n') + 4).split('\n'))
          if (line.startsWith('data: ')) jsonDecode(line.substring(6)) as Map<String, Object?>,
      ];
      expect(events[0].keys.toSet(), (shapes['hello_keys']! as List).toSet());
      expect(events[0], containsPair('next_i', 10));
      expect(events[0], containsPair('unit', 'uV'));
      expect(events[1].keys.toSet(), (shapes['batch_keys']! as List).toSet());
      expect(events[1], {
        'i': 10,
        't': 1763500000.1,
        'uv': [
          [10.0, 2.0, -1.0, 0.0],
          [11.0, 2.0, -1.0, 0.0],
        ],
      });
      expect(events[2], {'marker': 'eyes closed start', 'i': 12, 't': 1763500000.2});
      expect(events[2].keys.toSet(), (shapes['marker_keys']! as List).toSet());
      expect(markers, ['eyes closed start']);
      await sub.cancel();
      socket.destroy();
      await until(() => server.readers == 0); // the next keep-alive finds the reader gone
    });

    test('a /stream reader that does not read loses batches; memory stays bounded', () async {
      final socket = await Socket.connect('127.0.0.1', server.boundPort);
      socket.write('GET /stream HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer $token\r\n\r\n');
      final sub = socket.listen((_) {});
      for (var i = 0; i < 100 && server.readers == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      sub.pause(); // a reader that stopped reading
      for (var i = 0; i < 20000; i++) {
        server.addBatch('s', i * 25, 1.0, batch(i * 25, 25));
        if (i % 500 == 0) await Future<void>.delayed(Duration.zero);
      }
      expect((await json('/state'))['fs'], 250); // still answering others
      await sub.cancel();
      socket.destroy();
    });

    test('POST /marker without a recording: 503, as the laptop before its files are open', () async {
      final r = await ask('/marker', method: 'POST', body: 'x');
      expect(r.code, 503);
      expect(markers, ['x']);
    });

    test("POST /work: the paired laptop's work signal for automatic recording, with the token only", () async {
      // scripts/laptop_work.py sends it when a work session starts or ends (DECISIONS 603)
      final r = await ask('/work', method: 'POST', body: '{"working": true}');
      expect(r.code, 202);
      expect(jsonDecode(utf8.decode(r.body)), {'ok': true});
      expect((await ask('/work', method: 'POST', body: '{"working": false}')).code, 202);
      expect(works, [true, false]);
      for (final bad in ['', 'yes', '{"working": "yes"}', '[true]', '{"working": true, "x": "${'y' * 300}"}']) {
        expect((await ask('/work', method: 'POST', body: bad)).code, 400, reason: bad);
      }
      expect((await ask('/work', method: 'POST', body: '{"working": true}', tok: 'wrongwrongwr')).code, 401);
      expect((await ask('/work', method: 'POST', body: '{"working": true}', tok: null)).code, 401);
      expect((await ask('/work')).code, 405, reason: 'a signal, not a page');
      expect(works, [true, false]);
      expect((await json('/'))['routes'], contains('POST /work'));
    });

    test('POST /work says whether the laptop is in a meeting; older trays say nothing (DECISIONS 685)', () async {
      expect((await ask('/work', method: 'POST', body: '{"working": true, "meeting": true}')).code, 202);
      expect((await ask('/work', method: 'POST', body: '{"working": true, "meeting": false}')).code, 202);
      expect((await ask('/work', method: 'POST', body: '{"working": true}')).code, 202);
      expect((await ask('/work', method: 'POST', body: '{"working": true, "meeting": "yes"}')).code, 202, reason: 'an odd meeting is not said');
      expect(works, [true, true, true, true]);
      expect(meetings, [true, false, null, null]);
    });

    test('POST /work where nothing takes it (the night recorder serves): 503', () async {
      await server.close();
      server = ShareServer(filesDir: files, token: token, port: 0, clientOf: (r) => r.connectionInfo?.remoteAddress);
      await server.listen();
      expect((await ask('/work', method: 'POST', body: '{"working": true}')).code, 503);
    });

    test('what the phone does not do answers as the page server does while the recorder is away', () async {
      expect((await ask('/contact', method: 'POST')).code, 503);
      for (final p in ['/sleep-report', '/morning-report', '/hypnogram.png?date=2026-11-18']) {
        final r = await ask(p);
        expect(r.code, 503, reason: p);
        expect(jsonDecode(utf8.decode(r.body)), containsPair('error', isA<String>()));
      }
      expect((await ask('/sleep-report', method: 'POST')).code, 503);
      expect((await ask('/nothing')).code, 404);
      expect((await json('/'))['app'], 'eeg-tracker');
    });
  });

  group('files', () {
    test('/files lists what Export data would copy, with the manifest\'s fields', () async {
      final f32 = put('recordings/2026-11-18-231200.f32', List.filled(40, 7));
      put('nights/2026-11-18.report.json', utf8.encode('{"version": 2}'));
      put('settings.json', utf8.encode('{}'));
      put('models/anysleep-run1.onnx', [1, 2, 3]);
      put('export/state.json', utf8.encode('{}'));
      put('nights/2026-11-18.report.json.tmp', [1]);
      put('profileInstalled', [1]);
      final list = await json('/files');
      expect(list['format'], 'eeg-tracker-phone-files');
      final rows = (list['files']! as List).cast<Map<String, Object?>>();
      expect(rows.map((r) => r['path']), ['nights/2026-11-18.report.json', 'recordings/2026-11-18-231200.f32', 'settings.json']);
      expect(rows.map((r) => r['path']), storedFiles(files).map((f) => f.path));
      final row = rows[1];
      expect(row.keys.toSet(), {'path', 'bytes', 'sha256', 'modified_ms'});
      expect(row['bytes'], 40);
      expect(row['sha256'], sha256.convert(f32.readAsBytesSync()).toString());
      expect(row['modified_ms'], f32.lastModifiedSync().millisecondsSinceEpoch);
    });

    test('a recording packed after a day is listed and served as it is, naming the .f32 it holds', () async {
      final f32 = put('recordings/2026-11-17-231200.f32', List.generate(70000, (i) => i % 7),
          modified: now.subtract(const Duration(days: 2)));
      final body = f32.readAsBytesSync();
      final p = packRaw(f32);
      final row = ((await json('/files'))['files']! as List).single as Map<String, Object?>;
      expect(row['path'], 'recordings/2026-11-17-231200.f32.gz');
      expect(row['bytes'], p.packedBytes);
      expect(row['sha256'], sha256.convert(p.packed.readAsBytesSync()).toString());
      expect(row['original'], {
        'path': 'recordings/2026-11-17-231200.f32',
        'bytes': body.length,
        'sha256': sha256.convert(body).toString(),
      });
      expect((await ask('/files/recordings/2026-11-17-231200.f32.gz')).body, p.packed.readAsBytesSync());
    });

    test('a file being written is listed as growing, without a SHA-256, until it rests', () async {
      final f = put('recordings/2026-11-19-030000.f32', List.filled(20, 1), modified: now.subtract(const Duration(seconds: 2)));
      var row = ((await json('/files'))['files']! as List).single as Map<String, Object?>;
      expect(row['sha256'], isNull);
      expect(row['growing'], isTrue);
      expect(row['bytes'], 20);
      now = now.add(const Duration(minutes: 1));
      row = ((await json('/files'))['files']! as List).single as Map<String, Object?>;
      expect(row['sha256'], sha256.convert(f.readAsBytesSync()).toString());
      expect(row.containsKey('growing'), isFalse);
    });

    test('?sha=0 lists without reading; the Export index and earlier lists supply what is known', () async {
      final a = put('recordings/a.log', utf8.encode('one\n'));
      final b = put('recordings/b.log', utf8.encode('two\n'));
      ExportStore(files).save(
        ExportState(
          files: {
            'recordings/a.log': ExportedFile(
              bytes: 4,
              modifiedMs: a.lastModifiedSync().millisecondsSinceEpoch,
              sha256: 'from-the-export-index',
              written: 'x',
            ),
          },
        ),
      );
      Future<Map<String, Object?>> shas(String q) async => {
        for (final r in ((await json('/files$q'))['files']! as List).cast<Map<String, Object?>>()) r['path']! as String: r['sha256'],
      };
      expect(await shas('?sha=0'), {'recordings/a.log': 'from-the-export-index', 'recordings/b.log': null});
      final full = await shas('');
      expect(full['recordings/b.log'], sha256.convert(b.readAsBytesSync()).toString());
      expect(await shas('?sha=0'), full); // remembered
    });

    test('SHA-256 are kept between runs (row 585): a restarted server reads only new or changed files', () async {
      final night = put('recordings/2026-11-18-231200.f32', List.generate(3000, (i) => i % 251));
      final log = put('recordings/2026-11-18-231200.log', utf8.encode('a night\n'));
      final cache = File('${files.path}/cache/share-hashes.json');
      Future<Map<String, Object?>> listFrom(ShareServer sv) async {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:${sv.boundPort}/files'));
        req.headers.set('Authorization', 'Bearer $token');
        final res = await req.close();
        expect(res.statusCode, 200);
        return jsonDecode(await utf8.decodeStream(res)) as Map<String, Object?>;
      }

      ShareServer kept() => ShareServer(filesDir: files, token: token, port: 0, clock: () => now, hashCache: cache);
      final first = kept();
      await first.listen();
      final one = await listFrom(first);
      expect(first.hashed, 2);
      expect(cache.existsSync(), isTrue);
      expect(((one['files']! as List).cast<Map<String, Object?>>()).map((r) => r['path']), isNot(contains('cache/share-hashes.json')));
      await first.close();

      final second = kept(); // the app after an update
      await second.listen();
      expect(await listFrom(second), one);
      expect(second.hashed, 0, reason: 'nothing read again');
      log.writeAsStringSync('a night\nreconnected\n');
      log.setLastModifiedSync(now.subtract(const Duration(minutes: 1)));
      final rows = ((await listFrom(second))['files']! as List).cast<Map<String, Object?>>();
      expect(second.hashed, 1, reason: 'only the changed file');
      expect(rows.firstWhere((r) => r['path'] == 'recordings/2026-11-18-231200.log')['sha256'],
          sha256.convert(log.readAsBytesSync()).toString());
      expect(rows.firstWhere((r) => r['path'] == 'recordings/2026-11-18-231200.f32')['sha256'],
          sha256.convert(night.readAsBytesSync()).toString());
      await second.close();

      cache.writeAsStringSync('{"format": "eeg-tracker-share-hashes", "files": {"recordings/2026-11-18-231200.f32": '
          '{"bytes": 3000, "modified_ms": 1, "sha256": "not a digest"}}}');
      final third = kept(); // a damaged list is worked out again, never trusted
      await third.listen();
      await listFrom(third);
      expect(third.hashed, 2);
      await third.close();
    });

    test('a night packed after a day (rows 540-549) is read once in its packed form, then kept with its original '
        '(row 585)', () async {
      final f32 = put('recordings/2026-11-17-231200.f32', List.generate(70000, (i) => i % 7),
          modified: now.subtract(const Duration(days: 2)));
      final body = f32.readAsBytesSync();
      final cache = File('${files.path}/cache/share-hashes.json');
      ShareServer kept() => ShareServer(filesDir: files, token: token, port: 0, clock: () => now, hashCache: cache);
      Future<Map<String, Object?>> rowFrom(ShareServer sv) async {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:${sv.boundPort}/files'));
        req.headers.set('Authorization', 'Bearer $token');
        final res = await req.close();
        expect(res.statusCode, 200);
        final list = jsonDecode(await utf8.decodeStream(res)) as Map<String, Object?>;
        return (list['files']! as List).single as Map<String, Object?>;
      }

      final plain = kept(); // the laptop copied the night while it was plain
      await plain.listen();
      expect((await rowFrom(plain))['sha256'], sha256.convert(body).toString());
      expect(plain.hashed, 1);
      await plain.close();

      final p = packRaw(f32); // a day later the phone packs it between nights
      final original = {'path': 'recordings/2026-11-17-231200.f32', 'bytes': body.length, 'sha256': sha256.convert(body).toString()};
      final packedSha = sha256.convert(p.packed.readAsBytesSync()).toString();
      final after = kept();
      await after.listen();
      var row = await rowFrom(after);
      expect((row['path'], row['sha256']), ('recordings/2026-11-17-231200.f32.gz', packedSha));
      expect(row['original'], original);
      expect(after.hashed, 1, reason: 'the packed form is read once');
      row = await rowFrom(after);
      expect(after.hashed, 1, reason: 'listed again: not read again');
      await after.close();

      final restarted = kept(); // the app after an update
      await restarted.listen();
      row = await rowFrom(restarted);
      expect(row['sha256'], packedSha);
      expect(row['original'], original);
      expect(restarted.hashed, 0, reason: 'nothing read again after a restart');
      await restarted.close();
    });

    test('the laptop copying is counted while the list and each file are answered', () async {
      put('recordings/2026-11-18-231200.f32', List.filled(40, 7));
      final counts = <int>[];
      final sv = ShareServer(filesDir: files, token: token, port: 0, clock: () => now, onCopying: counts.add);
      await sv.listen();
      for (final path in ['/files', '/files/recordings/2026-11-18-231200.f32', '/state']) {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:${sv.boundPort}$path'));
        req.headers.set('Authorization', 'Bearer $token');
        await (await req.close()).drain<void>();
      }
      await sv.close();
      expect(counts, [1, 0, 1, 0], reason: '/state is not copying');
    });

    test('GET /files/<path>: whole, by Range, and a file that grows between two reads', () async {
      final f = put('recordings/2026-11-19-030000.f32', List.generate(100, (i) => i));
      var r = await ask('/files/recordings/2026-11-19-030000.f32');
      expect(r.code, 200);
      expect(r.body, List.generate(100, (i) => i));
      expect(r.headers.value('accept-ranges'), 'bytes');
      expect(r.headers.value('x-modified-ms'), '${f.lastModifiedSync().millisecondsSinceEpoch}');

      r = await ask('/files/recordings/2026-11-19-030000.f32', headers: {'Range': 'bytes=10-19'});
      expect(r.code, 206);
      expect(r.body, List.generate(10, (i) => 10 + i));
      expect(r.headers.value('content-range'), 'bytes 10-19/100');

      r = await ask('/files/recordings/2026-11-19-030000.f32', headers: {'Range': 'bytes=-5'});
      expect(r.body, [95, 96, 97, 98, 99]);
      expect(r.headers.value('content-range'), 'bytes 95-99/100');

      // nothing new yet: 416 with the size
      r = await ask('/files/recordings/2026-11-19-030000.f32', headers: {'Range': 'bytes=100-'});
      expect(r.code, 416);
      expect(r.headers.value('content-range'), 'bytes */100');

      // the recorder appends; the laptop asks for the rest only
      f.writeAsBytesSync(List.generate(60, (i) => 100 + i), mode: FileMode.append);
      r = await ask('/files/recordings/2026-11-19-030000.f32', headers: {'Range': 'bytes=100-'});
      expect(r.code, 206);
      expect(r.body, List.generate(60, (i) => 100 + i));
      expect(r.headers.value('content-range'), 'bytes 100-159/160');

      r = await ask('/files/recordings/2026-11-19-030000.f32', method: 'HEAD');
      expect(r.code, 200);
      expect(r.headers.contentLength, 160);
      expect(r.body, isEmpty);
    });

    test('only the app\'s exported files are served: no climbing out, no kept-back folders, no links', () async {
      put('settings.json', utf8.encode('{}'));
      put('models/m.onnx', [1]);
      put('export/state.json', utf8.encode('{}'));
      final outside = File('${files.parent.path}/share_server_outside.txt')..writeAsStringSync('secret');
      addTearDown(outside.deleteSync);
      Link('${files.path}/link.txt').createSync(outside.path);
      for (final p in [
        '/files/../share_server_outside.txt',
        '/files/%2e%2e/share_server_outside.txt',
        '/files/..%2Fshare_server_outside.txt',
        '/files/%2Fetc%2Fpasswd',
        '/files//etc/passwd',
        '/files/models/m.onnx',
        '/files/export/state.json',
        '/files/link.txt',
        '/files/nope.json',
        '/files/recordings',
      ]) {
        final r = await ask(p);
        expect(r.code, 404, reason: p);
        expect(utf8.decode(r.body), isNot(contains('secret')));
      }
      expect((await ask('/files/settings.json')).code, 200);
    });

    test('Range headers', () {
      expect(parseRange(null, 100), isNull);
      expect(parseRange('bytes=0-', 100), (start: 0, end: 99));
      expect(parseRange('bytes=40-49', 100), (start: 40, end: 49));
      expect(parseRange('bytes=40-4000', 100), (start: 40, end: 99));
      expect(parseRange('bytes=-30', 100), (start: 70, end: 99));
      expect(parseRange('bytes=-300', 100), (start: 0, end: 99));
      expect(parseRange('bytes=0-10,20-30', 100), isNull); // several ranges: the whole file, as HTTP allows
      expect(parseRange('lines=1-2', 100), isNull);
      expect(() => parseRange('bytes=100-', 100), throwsRangeError);
      expect(() => parseRange('bytes=0-', 0), throwsRangeError);
    });
  });

  group('the setting', () {
    test('off by default; on for 12 hours; Stop leaves 15 minutes; the token is kept', () {
      const off = ShareConfig();
      expect(off.on, isFalse);
      expect(off.activeAt(0), isFalse);
      final on = off.switchedOn(1000000);
      expect(on.token, hasLength(12));
      expect(on.port, 8765);
      expect(on.activeAt(1000000 + 12 * 3600 * 1000 - 1), isTrue);
      expect(on.activeAt(1000000 + 12 * 3600 * 1000), isFalse);
      final stopped = on.afterStop(2000000);
      expect(stopped.offAtMs, 2000000 + 15 * 60 * 1000);
      expect(on.afterStop(on.offAtMs - 1000).offAtMs, on.offAtMs); // never longer than it had
      final again = ShareConfig.decode(on.switchedOff().encode()).switchedOn(5);
      expect(again.token, on.token);
      expect(on.withNewToken().token, isNot(on.token));
      expect(ShareConfig.decode('not json').on, isFalse);
      expect(ShareConfig.decode(null).on, isFalse);
      expect(const ShareConfig(on: true, token: 'short', offAtMs: 99).activeAt(1), isFalse);
    });

    test('the laptop\'s words for the phases, and the address the QR code holds', () {
      expect(statusWord('recording'), 'recording');
      expect(statusWord('idle'), 'not recording');
      expect(shareUrl('192.168.1.23', 8765, 'abc'), 'http://192.168.1.23:8765/?token=abc');
    });
  });
}
