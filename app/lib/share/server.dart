// Share on Wi-Fi: the HTTP server (DECISIONS rows 220-229). It answers the laptop recorder's routes with the
// same JSON (scripts/recorder_hub.py), so scripts/page_server.py --recorder http://<phone>:8765 --token <t> shows
// the laptop's pages on the phone's recording, and it lists and serves the app's files read-only:
//
//   GET  /state          status, battery, minutes, age, contact, the last 4 s of data, and `session`: the daytime
//                        session that holds the headband (a Work session's level and signal, DECISIONS 671) or null
//   GET  /stream         server-sent events: a hello, every batch {"i","t","uv"}, every marker
//   POST /marker         a text marker into the run's .markers.jsonl (503 while nothing records)
//   POST /contact        503: the phone checks contact once, at the start of the night (row 52)
//   GET  /files          every file Export data would copy: path, bytes, sha256, modified_ms (and a packed
//                        recording's `original`: the .f32 it holds)
//   GET  /files/<path>   one file, with HTTP Range (a growing night file is fetched piece by piece)
//   POST /work           the paired laptop's work signal, {"working": true|false} and optionally "meeting":
//                        true|false (scripts/laptop_work.py), for automatic recording and the work session's
//                        meetings (lib/auto/laptop.dart; 503 where nothing takes it: during a night)
//   POST /ack            the paired laptop's word that it holds checked copies of raw files: {"v":1,"files":[{"path",
//                        "sha256"}]} with `X-Eeg-Ack`, the HMAC of the body with the pairing's key (recorder/acks.dart,
//                        DECISIONS 690-699); kept in files/transfer/acks.json, and /files marks those files `acked`
//   the laptop's own jobs (/sleep-report, /morning-report, /hypnogram.png): 503, as the page server answers
//   while the recorder is away
//
// Every request needs the token and a client inside the phone's Wi-Fi network, or the phone itself (DECISIONS row
// 562). Nothing here writes, renames or deletes the app's files (the work signal goes to the app, which keeps it); it keeps one list of its own, the SHA-256 of finished
// files in `files/cache/share-hashes.json` (row 585), so an app update does not read every night again, and writes the
// laptop's acks (`files/transfer/acks.json`; the app, not this server, decides what to delete with them). Plain
// dart:io with no Flutter import: it runs in an isolate of its own (isolate.dart), and in tests.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../export/store.dart';
import '../recorder/acks.dart';
import 'protocol.dart';

const List<String> _brainBit = ['O1', 'O2', 'T3', 'T4'];
const int _fs = 250;
const int _ringRows = _fs * 5;
const int _stateRows = _fs * 4;

/// Lines a slow /stream reader may have waiting; past it batches are dropped for that reader only.
const int streamQueueMax = 200;

/// /stream readers at once.
const int streamReadersMax = 8;

/// The largest `POST /ack` body: about 2000 files.
const int ackBodyMax = 256 * 1024;

/// A file changed in the last seconds is still being written: listed without a SHA-256, marked `growing`.
const Duration _settled = Duration(seconds: 20);

const Set<String> _laptopOnly = {'sleep-report', 'morning-report', 'hypnogram.png'};

/// What the recorder answers for a marker: its unix time and the index of the next sample; null = not recording.
typedef MarkerResult = ({double t, int i});

class _Reader {
  final ListQueue<String> queue = ListQueue();
  Completer<void>? _wake;
  bool closed = false;

  void push(String line) {
    if (queue.length >= streamQueueMax) return; // this reader loses the batch; nobody else does
    queue.add(line);
    wake();
  }

  void wake() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> wait(Duration d) {
    final w = _wake = Completer<void>();
    return w.future.timeout(d, onTimeout: () {});
  }
}

class ShareServer {
  ShareServer({
    required this.filesDir,
    required this.token,
    this.port = sharePort,
    this.onMarker,
    this.clientOf,
    this.keepalive = const Duration(seconds: 10),
    this.hashCache,
    this.onCopying,
    this.onWork,
    this.ackKey,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// The app's private `files/` folder.
  final Directory filesDir;
  final String token;
  final int port;

  /// Asks the recorder to write a marker; null (or no answer) = nothing is recording.
  final Future<MarkerResult?> Function(String text)? onMarker;

  /// Tests: the client's address instead of the socket's.
  final InternetAddress? Function(HttpRequest request)? clientOf;
  final Duration keepalive;

  /// Where the SHA-256 of finished files are kept between runs (`files/cache/share-hashes.json`, DECISIONS row 585), so
  /// a restart or an app update does not read every night again for the laptop's list; null keeps them in memory.
  final File? hashCache;

  /// How many file requests (the list and the files) are being answered, at each change: the night's sleep scoring
  /// waits while the laptop copies (DECISIONS row 583).
  final void Function(int copying)? onCopying;

  /// The paired laptop's work signal (`POST /work`): a work session started ([working]) or ended there (DECISIONS
  /// 603), and whether it is in a meeting (null: not said; DECISIONS 685); null: nothing takes it here (503).
  final void Function(bool working, bool? meeting)? onWork;

  /// The key of the pairing with the laptop (link.dart): `POST /ack` must carry its proof; null: not paired (403).
  final String? ackKey;
  final DateTime Function() _now;

  /// SHA-256 worked out by this server (not taken from the cache or the export's index); for tests.
  int hashed = 0;
  bool _cacheRead = false;
  int _copying = 0;

  HttpServer? _server;
  List<LanNet> _lan = const [];
  final List<_Reader> _readers = [];
  final Map<String, ({int bytes, int modifiedMs, String sha256})> _hashes = {};

  // The last 5 s of samples in volts, [_width] per row (the recording's channels), as a ring.
  int _width = 4;
  Float32List _ring = Float32List(_ringRows * 4);
  int _ringNext = 0;
  int _ringCount = 0;

  String? _stem;
  int _nextI = 0;
  double? _lastT;
  Map<Object?, Object?> _live = const {};
  String _contactKey = '';
  double? _contactT;

  int get boundPort => _server?.port ?? port;
  int get readers => _readers.length;

  /// The phone's Wi-Fi addresses, for the screen; empty while none is known.
  List<String> get addresses => [for (final n in _lan) n.address.address];

  /// The Wi-Fi networks clients may come from (DECISIONS row 562), set again at every look at the phone's address.
  set lan(List<LanNet> nets) => _lan = List.unmodifiable(nets);

  /// Listens on every IPv4 address of the phone (DECISIONS row 562): Wi-Fi, the phone itself for `adb forward`, and
  /// mobile data and a VPN too, which [isServedClient] turns away. So the server does not depend on finding the
  /// Wi-Fi address, and a new lease needs no new socket. Throws when the port is taken.
  Future<void> listen() async {
    if (_server != null) return;
    final s = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: false);
    s.idleTimeout = const Duration(seconds: 60);
    s.defaultResponseHeaders.clear();
    s.listen(_handle, onError: (Object _) {});
    _server = s;
  }

  Future<void> close() async {
    for (final r in _readers.toList()) {
      r.closed = true;
      r.wake();
    }
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  // ---- live data in ------------------------------------------------------------------------------------------

  /// One batch as it arrived: [first] is the index of its first sample in the run [stem], [t] its unix time in
  /// seconds, [volts] [channels] values per sample (the BrainBit's O1 O2 T3 T4; a board's CH1..).
  void addBatch(String stem, int first, double t, Float32List volts, {int channels = 4}) {
    final w = channels;
    if (w < 1) return;
    final n = volts.length ~/ w;
    if (n == 0) return;
    if (w != _width) {
      // another device or board: the ring starts again at its width
      _width = w;
      _ring = Float32List(_ringRows * w);
      _ringNext = 0;
      _ringCount = 0;
    }
    for (var k = 0; k < n * w; k += w) {
      _ring.setRange(_ringNext * w, _ringNext * w + w, volts, k);
      _ringNext = (_ringNext + 1) % _ringRows;
    }
    _ringCount = _ringCount + n > _ringRows ? _ringRows : _ringCount + n;
    _stem = stem;
    _nextI = first + n;
    _lastT = t;
    if (_readers.isEmpty) return; // nobody listens: nothing is built or sent
    final b = StringBuffer('{"i":$first,"t":${_num(t, 3)},"uv":[');
    for (var k = 0; k < n * w; k += w) {
      if (k > 0) b.write(',');
      b.write('[');
      for (var c = 0; c < w; c++) {
        if (c > 0) b.write(',');
        b.write(_num(volts[k + c] * 1e6, 2));
      }
      b.write(']');
    }
    b.write(']}');
    _publish(b.toString());
  }

  /// The recorder's status about once a second (`RecorderStatus.toMap`), or `{}` when the app itself serves.
  /// The channels' names: the DIY board's from the recorder's status while it records one (DECISIONS rows 360-369),
  /// as many as the samples carry (630-639); else the BrainBit's for four, Ch1..ChN for any other width.
  List<String> get _names {
    final b = _live['board'];
    final n = b is Map ? b['names'] : null;
    if (n is List && n.length == _width && n.every((x) => x is String)) return n.cast<String>();
    return _width == 4 ? _brainBit : [for (var c = 1; c <= _width; c++) 'Ch$c'];
  }

  /// Samples a second: the board's from the recorder's status, else the BrainBit's.
  int get _rate {
    final b = _live['board'];
    final fs = b is Map ? b['fs'] : null;
    return fs is int && fs > 0 ? fs : _fs;
  }

  /// The daytime session that holds the headband, for /state's `session` (DECISIONS 671): its screen's own summary
  /// (`WorkController.shareState`), or null when none runs.
  void setSession(Map<Object?, Object?>? session) => _session = session;
  Map<Object?, Object?>? _session;

  /// /state's `session`: the known fields only, and `age`, the seconds since the headband's last data by this
  /// phone's clock, so the laptop sees a session whose data stopped (or whose screen froze) as stale.
  Map<String, Object?>? _sessionState() {
    final s = _session;
    if (s == null || s['kind'] is! String) return null;
    final dataAt = s['data_at'];
    return {
      for (final k in const ['kind', 'since', 'stage', 'level', 'signal', 'on_break', 'hint']) k: s[k],
      'age': dataAt is num ? _round(_seconds() - dataAt, 1) : null,
    };
  }

  void setLive(Map<Object?, Object?> live) {
    _live = live;
    final c = live['contact'];
    if (live['contactKnown'] == true && c is List) {
      final key = c.join(',');
      if (key != _contactKey) {
        _contactKey = key;
        _contactT = _round(_seconds(), 3);
      }
    }
  }

  void _publish(String line) {
    for (final r in _readers) {
      r.push(line);
    }
  }

  double _seconds() => _now().microsecondsSinceEpoch / 1e6;

  String get _status {
    final phase = _live['phase'];
    if (phase is String) return statusWord(phase);
    final t = _lastT; // the app serves: a session (meditation, check-in, ...) may be writing a recording
    return t != null && _seconds() - t < 5 ? 'session' : 'not recording';
  }

  /// GET /state, with the keys and rounding of `Hub.state()` in scripts/recorder_hub.py.
  Map<String, Object?> state() {
    final rows = _ringCount < _stateRows ? _ringCount : _stateRows;
    final data = <List<double>>[];
    final w = _width;
    for (var c = 0; c < w; c++) {
      var sum = 0.0;
      final col = Float64List(rows);
      for (var k = 0; k < rows; k++) {
        final row = (_ringNext - rows + k + _ringRows * 2) % _ringRows;
        col[k] = _ring[row * w + c];
        sum += col[k];
      }
      final mean = rows == 0 ? 0.0 : sum / rows;
      data.add([for (final v in col) _round((v - mean) * 1e6, 1)]);
    }
    final ohms = _live['contact'];
    final names = _names;
    final known = _live['contactKnown'] == true && ohms is List && ohms.length == names.length;
    final samples = _live['nightSamples'];
    final t = _lastT;
    final battery = _live['battery'];
    return {
      'status': _status,
      'battery': battery is num ? battery.toInt() : '?',
      'battery_note': null,
      'minutes': _round((samples is num ? samples : (_stem == null ? 0 : _nextI)) / _rate / 60, 1),
      'age': t == null ? 999 : _round(_seconds() - t, 1),
      'names': names,
      'fs': _rate,
      'contact': {
        for (var c = 0; c < names.length; c++) names[c]: known && ohms[c] is num ? (ohms[c] as num).round() : null,
      },
      'contact_t': _contactT,
      'data': data,
      'session': _sessionState(),
    };
  }

  // ---- requests ----------------------------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      res.headers.set('Cache-Control', 'no-store');
      final client = clientOf != null ? clientOf!(req) : req.connectionInfo?.remoteAddress;
      if (client == null || !isServedClient(client, _lan)) {
        return await _json(res, 403, {'error': 'only the local network may connect'});
      }
      if (!_authorized(req)) return await _json(res, 401, {'error': 'token missing or wrong'});
      final method = req.method;
      if (method != 'GET' && method != 'POST' && method != 'HEAD') {
        return await _json(res, 405, {'error': 'read-only'});
      }
      final path = req.uri.path;
      if (path == '/files' || path == '/files/') {
        if (method == 'POST') return await _json(res, 405, {'error': 'read-only'});
        return await _copy(() async => _json(res, 200, await _fileList(hash: req.uri.queryParameters['sha'] != '0')));
      }
      if (path.startsWith('/files/')) {
        if (method == 'POST') return await _json(res, 405, {'error': 'read-only'});
        return await _copy(() => _file(req, Uri.decodeComponent(path.substring('/files/'.length))));
      }
      final trimmed = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
      final name = trimmed.substring(trimmed.lastIndexOf('/') + 1);
      if (path == '/work' || path == '/work/') {
        if (method != 'POST') return await _json(res, 405, {'error': 'POST {"working": true|false}'});
        return await _work(req);
      }
      if (path == '/ack' || path == '/ack/') {
        if (method != 'POST') return await _json(res, 405, {'error': 'POST {"v":1,"files":[...]}'});
        return await _ack(req);
      }
      if (method == 'POST') {
        if (name == 'marker') return await _marker(req);
        if (name == 'contact') {
          await req.drain<void>();
          return await _json(res, 503, {'error': 'the phone checks contact once, at the start of the night'});
        }
        await req.drain<void>();
        if (_laptopOnly.contains(name)) return await _json(res, 503, {'error': 'recorder reconnecting'});
        return await _json(res, 404, {'error': 'no such route'});
      }
      if (name == 'stream') return await _stream(res);
      if (name == 'state') return await _json(res, 200, state());
      if (_laptopOnly.contains(name)) return await _json(res, 503, {'error': 'recorder reconnecting'});
      if (path == '/') {
        return await _json(res, 200, {
          'app': 'eeg-tracker',
          'share': 1,
          'status': _status,
          'routes': ['GET /state', 'GET /stream', 'POST /marker', 'GET /files', 'GET /files/<path>', 'POST /work', 'POST /ack'],
        });
      }
      return await _json(res, 404, {'error': 'no such route'});
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
    }
  }

  bool _authorized(HttpRequest req) {
    final auth = req.headers.value('authorization');
    final given = auth != null && auth.startsWith('Bearer ')
        ? auth.substring(7).trim()
        : req.headers.value('x-eeg-token') ?? req.uri.queryParameters['token'] ?? '';
    return sameToken(given, token);
  }

  Future<void> _json(HttpResponse res, int code, Object body) => _send(res, code, utf8.encode(jsonEncode(body)), 'application/json');

  Future<void> _send(HttpResponse res, int code, List<int> body, String kind) async {
    res.statusCode = code;
    res.headers.set('Content-Type', kind);
    res.contentLength = body.length;
    res.add(body);
    await res.close();
  }

  Future<void> _marker(HttpRequest req) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      if (bytes.length < 2000) bytes.add(chunk);
    }
    final all = bytes.takeBytes();
    var text = utf8.decode(all.length > 2000 ? all.sublist(0, 2000) : all, allowMalformed: true).trim();
    if (text.length > 200) text = text.substring(0, 200);
    if (text.isEmpty) text = 'marker';
    MarkerResult? m;
    try {
      m = await onMarker?.call(text).timeout(const Duration(seconds: 3));
    } catch (_) {
      m = null;
    }
    if (m == null) return _json(req.response, 503, {'error': 'not recording yet'});
    _publish(jsonEncode({'marker': text, 'i': m.i, 't': _round(m.t, 3)}));
    return _send(req.response, 200, utf8.encode('ok'), 'text/plain');
  }

  /// The laptop's work signal: `{"working": true|false}`, optionally with `"meeting": true|false`, under 200 bytes.
  Future<void> _work(HttpRequest req) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      if (bytes.length <= 200) bytes.add(chunk);
    }
    bool? working, meeting;
    if (bytes.length <= 200) {
      try {
        final Object? j = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (j is Map && j['working'] is bool) working = j['working'] as bool;
        if (j is Map && j['meeting'] is bool) meeting = j['meeting'] as bool;
      } catch (_) {}
    }
    if (working == null) return _json(req.response, 400, {'error': 'send {"working": true} or {"working": false}'});
    final take = onWork;
    if (take == null) return _json(req.response, 503, {'error': 'the work signal is not taken now (a night records)'});
    take(working, meeting);
    return _json(req.response, 202, {'ok': true});
  }

  /// The paired laptop's acks (recorder/acks.dart): refused whole without a pairing, a proof made with its key, or
  /// a well-formed body; then each file on its own (kept only when it holds what the laptop says it checked).
  Future<void> _ack(HttpRequest req) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      if (bytes.length <= ackBodyMax) bytes.add(chunk);
    }
    final res = req.response;
    if (bytes.length > ackBodyMax) return _json(res, 413, {'error': 'too many files at once'});
    final key = ackKey;
    if (key == null) return _json(res, 403, {'error': 'not paired'});
    final body = bytes.takeBytes();
    if (!sameToken(req.headers.value('x-eeg-ack') ?? '', ackProof(key, body))) {
      return _json(res, 403, {'error': 'wrong proof'});
    }
    final asked = <({String path, String sha256})>[];
    try {
      final Object? j = jsonDecode(utf8.decode(body));
      if (j is! Map || j['v'] != 1 || j['files'] is! List) throw const FormatException();
      for (final f in j['files'] as List) {
        if (f is! Map || f['path'] is! String || f['sha256'] is! String) throw const FormatException();
        asked.add((path: f['path'] as String, sha256: f['sha256'] as String));
      }
    } catch (_) {
      return _json(res, 400, {'error': 'send {"v":1,"files":[{"path":...,"sha256":...}]}'});
    }
    _readCache();
    final now = _now();
    final kept = <String, LaptopCopy>{};
    final acked = <String>[];
    final refused = <Map<String, String>>[];
    for (final a in asked) {
      final r = await checkAck(filesDir, a.path, a.sha256, now: now, plainSha: _plainSha);
      if (r.copy != null) {
        kept[ackPathOf(a.path)] = r.copy!;
        acked.add(a.path);
      } else {
        refused.add({'path': a.path, 'why': r.why ?? 'refused'});
      }
    }
    try {
      AckStore(filesDir).add(kept);
    } catch (e) {
      return _json(res, 500, {'error': 'the acks could not be kept: $e'});
    }
    return _json(res, 200, {'v': 1, 'acked': acked, 'refused': refused});
  }

  /// A plain file's SHA-256 for an ack: the kept one while the file is unchanged, else read now.
  Future<String?> _plainSha(File file, FileStat st) async {
    final rel = file.path.substring(filesDir.path.length + 1);
    final ms = st.modified.millisecondsSinceEpoch;
    final known = _hashes[rel];
    if (known != null && known.bytes == st.size && known.modifiedMs == ms) return known.sha256;
    final sha = await _sha256(StoredFile(rel, file, st.size, ms));
    if (sha != null) _writeCache(_hashes.keys.toSet());
    return sha;
  }

  /// Server-sent events, as `Page.stream` on the laptop. No chunked framing: the laptop's page server passes the
  /// raw lines through.
  Future<void> _stream(HttpResponse res) async {
    if (_readers.length >= streamReadersMax) return _json(res, 503, {'error': 'too many stream readers'});
    res.statusCode = 200;
    res.headers.set('Content-Type', 'text/event-stream');
    res.headers.chunkedTransferEncoding = false;
    res.persistentConnection = false;
    final r = _Reader();
    _readers.add(r);
    Socket? socket;
    try {
      // The socket itself, with the headers written: it says when the reader goes away, and its flush waits for
      // the network, so a slow reader fills its own short queue and never the phone's memory.
      final out = socket = await res.detachSocket();
      void gone([Object? _]) {
        r.closed = true;
        r.wake();
      }

      out.listen((_) {}, onDone: gone, onError: gone, cancelOnError: true);
      unawaited(out.done.then(gone, onError: gone));
      final hello = {'hello': true, 'names': _names, 'fs': _rate, 'unit': 'uV', 'status': _status, 'next_i': _nextI};
      out.write('data: ${jsonEncode(hello)}\n\n');
      await out.flush();
      while (!r.closed) {
        if (r.queue.isEmpty) {
          await r.wait(keepalive);
          if (r.closed) break;
          if (r.queue.isEmpty) out.write(': keepalive\n\n');
        }
        while (r.queue.isNotEmpty) {
          out.write('data: ${r.queue.removeFirst()}\n\n');
        }
        await out.flush();
      }
    } catch (_) {
      // the reader went away
    } finally {
      r.closed = true;
      _readers.remove(r);
      socket?.destroy();
    }
  }

  // ---- files -------------------------------------------------------------------------------------------------

  /// One file request, counted for [onCopying].
  Future<void> _copy(Future<void> Function() answer) async {
    _copying++;
    _tellCopying();
    try {
      await answer();
    } finally {
      _copying--;
      _tellCopying();
    }
  }

  void _tellCopying() {
    try {
      onCopying?.call(_copying);
    } catch (_) {}
  }

  /// The kept SHA-256, read once: entries whose file changed are worked out again when listed.
  void _readCache() {
    if (_cacheRead) return;
    _cacheRead = true;
    final f = hashCache;
    if (f == null) return;
    try {
      final d = jsonDecode(f.readAsStringSync());
      if (d is! Map || d['format'] != 'eeg-tracker-share-hashes' || d['files'] is! Map) return;
      for (final e in (d['files'] as Map).entries) {
        final v = e.value;
        if (e.key is! String || v is! Map) continue;
        final bytes = v['bytes'], ms = v['modified_ms'], sha = v['sha256'];
        if (bytes is int && ms is int && sha is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
          _hashes.putIfAbsent(e.key as String, () => (bytes: bytes, modifiedMs: ms, sha256: sha));
        }
      }
    } catch (_) {
      // none yet, or damaged: worked out again
    }
  }

  /// Keeps the SHA-256 of the files listed now (written to a temporary file, then renamed).
  void _writeCache(Set<String> listed) {
    final f = hashCache;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      final tmp = File('${f.path}.${identityHashCode(this)}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'format': 'eeg-tracker-share-hashes',
          'files': {
            for (final e in _hashes.entries)
              if (listed.contains(e.key))
                e.key: {'bytes': e.value.bytes, 'modified_ms': e.value.modifiedMs, 'sha256': e.value.sha256},
          },
        }),
        flush: true,
      );
      tmp.renameSync(f.path);
    } catch (_) {
      // a list that cannot be kept is worked out again next time
    }
  }

  /// The list Export data's manifest holds (`path`, `bytes`, `sha256`, `modified_ms`), made now from the folder.
  /// A file still being written has `sha256: null` and `growing: true`; so has every file with [hash] false
  /// unless its SHA-256 is already known.
  Future<Map<String, Object?>> _fileList({required bool hash}) async {
    _readCache();
    final stored = storedFiles(filesDir);
    final exported = _exportIndex();
    final acks = AckStore(filesDir).load();
    final nowMs = _now().millisecondsSinceEpoch;
    final files = <Map<String, Object?>>[];
    final before = hashed;
    for (final f in stored) {
      final growing = nowMs - f.modifiedMs < _settled.inMilliseconds;
      String? sha;
      if (!growing) {
        final known = _hashes[f.path];
        final ex = exported[f.path];
        if (known != null && known.bytes == f.bytes && known.modifiedMs == f.modifiedMs) {
          sha = known.sha256;
        } else if (ex != null && ex.sameAs(f)) {
          sha = ex.sha256;
        } else if (hash) {
          sha = await _sha256(f);
        }
      }
      files.add({
        'path': f.path,
        'bytes': f.bytes,
        'sha256': sha,
        'modified_ms': f.modifiedMs,
        if (growing) 'growing': true,
        // a recording packed after a day: the .f32 it holds, so the laptop never fetches a night twice (DECISIONS 540-549)
        if (f.originalJson != null) 'original': f.originalJson,
        // the paired laptop holds a checked copy of it as it is now (DECISIONS 690-699): no need to ack it again
        if (!growing && isAckable(f.path) && ackedNow(acks, f.path, f.file)) 'acked': true,
      });
    }
    if (hashed > before) _writeCache({for (final f in stored) f.path});
    return {
      'format': 'eeg-tracker-phone-files',
      'version': 1,
      'listed': _now().toIso8601String(),
      'recording': _stem,
      'files': files,
      'totals': {'files': files.length, 'bytes': stored.fold<int>(0, (n, f) => n + f.bytes)},
    };
  }

  Map<String, ExportedFile> _exportIndex() {
    try {
      return ExportStore(filesDir).load().files;
    } catch (_) {
      return const {};
    }
  }

  /// SHA-256 of a file that did not change while it was read; null otherwise (the next list tries again).
  Future<String?> _sha256(StoredFile f) async {
    try {
      final out = _DigestSink();
      final input = sha256.startChunkedConversion(out);
      await for (final chunk in f.file.openRead()) {
        input.add(chunk);
      }
      input.close();
      final st = f.file.statSync();
      if (st.size != f.bytes || st.modified.millisecondsSinceEpoch != f.modifiedMs) return null;
      final digest = out.value.toString();
      _hashes[f.path] = (bytes: f.bytes, modifiedMs: f.modifiedMs, sha256: digest);
      hashed++;
      return digest;
    } catch (_) {
      return null;
    }
  }

  Future<void> _file(HttpRequest req, String path) async {
    final res = req.response;
    // Only what Export data would copy, by the same rule; never a link, never a path that climbs out.
    if (!isExported(path)) return _json(res, 404, {'error': 'no such file'});
    final file = File('${filesDir.path}/$path');
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) {
      return _json(res, 404, {'error': 'no such file'});
    }
    final st = file.statSync();
    final size = st.size; // the file may grow while it is sent: this answer ends where it was now
    res.headers.set('Accept-Ranges', 'bytes');
    res.headers.set('X-Modified-Ms', '${st.modified.millisecondsSinceEpoch}');
    res.headers.set('Content-Type', 'application/octet-stream');
    ByteRange? range;
    try {
      range = parseRange(req.headers.value('range'), size);
    } on RangeError {
      res.headers.set('Content-Range', 'bytes */$size');
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.contentLength = 0;
      return res.close();
    }
    final start = range?.start ?? 0, end = range?.end ?? size - 1;
    if (range != null) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set('Content-Range', 'bytes $start-$end/$size');
    }
    res.contentLength = end - start + 1;
    if (req.method != 'HEAD' && end >= start) await res.addStream(file.openRead(start, end + 1));
    return res.close();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

double _round(num v, int digits) {
  final p = digits == 1 ? 10.0 : (digits == 2 ? 100.0 : 1000.0);
  final r = (v * p).roundToDouble() / p;
  return r.isFinite ? r : 0.0;
}

/// A number as JSON with at most [digits] decimals; never `NaN` or `Infinity`, which JSON does not have.
String _num(num v, int digits) => _round(v, digits).toString();
