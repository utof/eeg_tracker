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
//                        "sha256"}]} (recorder/acks.dart, DECISIONS 690-699); kept in files/transfer/acks.json, and
//                        /files marks those files `acked`
//   GET  /who            the paired laptop finds the phone: {"app","v","here"} (home, here, waiting or open)
//   the laptop's own jobs (/sleep-report, /morning-report, /hypnogram.png): 503, as the page server answers
//   while the recorder is away
//
// Who gets in (DECISIONS 562, 751-755): a client inside the phone's Wi-Fi network, or the phone itself, AND either
// - the paired laptop: every request signed with the pairing's key (auth.dart: method, path, query, time, a nonce used
//   once, whether the laptop is on the network where it paired, the body's SHA-256), answered with a proof of the key
//   (`X-Eeg-Reply`). The token never crosses the Wi-Fi for it. /work, /marker, /ack and /who take nothing else;
// - or the token in `Authorization: Bearer` (a laptop or tool given the code by hand); never in the address.
// While a laptop is paired the phone shares only on its home Wi-Fi: the network on which the paired laptop said, in
// a signed request, that it is on its own home network (it knows by its router), or one the owner allowed for 12
// hours. Elsewhere the paired laptop's signed requests get "not sharing on this Wi-Fi" and the token gets nothing.
// Nothing here writes, renames or deletes the app's files (the work signal goes to the app, which keeps it); it keeps
// one list of its own, the SHA-256 of finished files in `files/cache/share-hashes.json` (row 585), so an app update
// does not read every night again, and writes the laptop's acks (`files/transfer/acks.json`; the app, not this
// server, decides what to delete with them). Plain dart:io with no Flutter import: it runs in an isolate of its own
// (isolate.dart), and in tests.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../export/store.dart';
import '../recorder/acks.dart';
import '../recorder/recheck.dart';
import 'auth.dart';
import 'protocol.dart';
import 'push/state.dart' show writeLaptopAt;

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

/// The largest body any POST may have (the others are much smaller).
const int postBodyMax = ackBodyMax;

/// A signed request's time may differ from the phone's clock by this much (and its nonce is kept twice as long).
const Duration signWindow = Duration(minutes: 5);

/// Nonces kept at most: far more than the laptop sends in [signWindow] twice.
const int nonceCacheMax = 20000;

/// What the phone says of its Wi-Fi (DECISIONS 752): `open` not paired (shared by hand, on any Wi-Fi, 12 hours at most);
/// `home` the paired laptop said it is on its home network here; `here` the owner allowed this Wi-Fi for 12 hours;
/// `waiting` none of these: only the paired laptop's signed requests are answered, with "not sharing on this Wi-Fi"
/// unless it says it is home.
const List<String> sharingStates = ['open', 'home', 'here', 'waiting'];

/// Who a request comes from, once it is let in.
typedef _Caller = ({bool laptop, String? nonce, bool home});

/// How long the paired laptop's "this is my home network" holds without its next word (DECISIONS 752): the tray
/// looks every 45 s and the mirror every 2 minutes, so at home it never runs out.
const Duration homeFor = Duration(minutes: 30);

/// Connections held at once from one address, and in all (DECISIONS 755): one more is closed before HTTP reads it.
const int serverConnectionsPerClient = 16;
const int serverConnectionsMax = 32;

/// Wrong tries (a wrong token or signature, a replay) from one address within [triesWindow] before that address
/// waits [triesWait] (429): guessing the 59-bit token is hopeless anyway, and a flood of tries costs the phone work.
const int triesMax = 10;
const Duration triesWindow = Duration(minutes: 1);
const Duration triesWait = Duration(minutes: 1);

/// The phone's listening socket with a cap on connections: at most [perClient] from one address and [total] in all;
/// one more is closed at once.
class _CappedSocket extends Stream<Socket> implements ServerSocket {
  _CappedSocket(this._inner, {required this.total, required this.perClient});
  final ServerSocket _inner;
  final int total, perClient;
  final Map<String, int> _open = {};
  int _all = 0;

  @override
  StreamSubscription<Socket> listen(void Function(Socket event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _inner.map(_admit).where((s) => s != null).cast<Socket>().listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  /// The socket, counted, or null (closed at once: too many, or already gone).
  Socket? _admit(Socket s) {
    final String who;
    try {
      who = s.remoteAddress.address;
    } catch (_) {
      s.destroy();
      return null;
    }
    if (_all >= total || (_open[who] ?? 0) >= perClient) {
      s.destroy();
      return null;
    }
    _all++;
    _open[who] = (_open[who] ?? 0) + 1;
    return _CountedSocket(s, who, _gone);
  }

  /// One connection from [who] ended (HttpServer destroys every socket it is done with).
  void _gone(String who) {
    _all--;
    final n = (_open[who] ?? 1) - 1;
    if (n <= 0) {
      _open.remove(who);
    } else {
      _open[who] = n;
    }
  }

  @override
  int get port => _inner.port;

  @override
  InternetAddress get address => _inner.address;

  @override
  Future<ServerSocket> close() async {
    await _inner.close();
    return this;
  }
}

/// An accepted socket that says once when it ends: destroyed (as HttpServer ends each connection) or its output
/// done. Socket.done alone does not complete on destroy().
class _CountedSocket extends StreamView<Uint8List> implements Socket {
  _CountedSocket(this._s, this._who, this._onGone) : super(_s) {
    _s.done.then((_) => _end(), onError: (Object _) => _end());
  }
  final Socket _s;
  final String _who;
  final void Function(String who) _onGone;
  bool _ended = false;

  void _end() {
    if (_ended) return;
    _ended = true;
    _onGone(_who);
  }

  @override
  void destroy() {
    _end();
    _s.destroy();
  }

  @override
  Encoding get encoding => _s.encoding;

  @override
  set encoding(Encoding value) => _s.encoding = value;

  @override
  void write(Object? object) => _s.write(object);

  @override
  void writeln([Object? object = '']) => _s.writeln(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _s.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _s.writeCharCode(charCode);

  @override
  void add(List<int> data) => _s.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _s.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _s.addStream(stream);

  @override
  Future<void> flush() => _s.flush();

  @override
  Future<void> close() => _s.close();

  @override
  Future<void> get done => _s.done;

  @override
  bool setOption(SocketOption option, bool enabled) => _s.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _s.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _s.setRawOption(option);

  @override
  int get port => _s.port;

  @override
  int get remotePort => _s.remotePort;

  @override
  InternetAddress get address => _s.address;

  @override
  InternetAddress get remoteAddress => _s.remoteAddress;
}

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
    this.key,
    this.hereUntilMs = 0,
    this.hereNet,
    this.onHere,
    this.onCopied,
    this.onProved,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// The app's private `files/` folder.
  final Directory filesDir;

  /// File answers sent and their bytes since the server started (the app log's copy volumes, DECISIONS 718).
  int servedFiles = 0, servedBytes = 0;
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

  /// The key of the pairing with the laptop (link.dart): its signed requests are checked with it; null: not paired.
  final String? key;

  /// The owner's "Share here for 12 hours" (ShareConfig): until then, on the Wi-Fi network [hereNet] (`lanSignature`).
  final int hereUntilMs;
  final String? hereNet;

  /// What the phone says of its Wi-Fi changed ([sharingStates]).
  final void Function(String here)? onHere;

  /// A file or the list was sent: `laptop` (the paired one, signed) or `code` (someone with the token), or `cable`
  /// (the phone itself: adb forward).
  final void Function(String by)? onCopied;

  /// The laptop proved it still holds files the phone asked about before deleting them (recheck.dart): how many now.
  final void Function(int proven)? onProved;
  final DateTime Function() _now;

  /// The Wi-Fi network on which the paired laptop last said it is home (`lanSignature`); null: none yet.
  String? _home;

  /// Home lasts [homeFor] after the paired laptop last said so: a phone carried to another Wi-Fi with the same
  /// addresses (192.168.1.x is common) stops sharing by then, even without Android's word.
  int _homeUntilMs = 0;
  String _hereWas = '';
  final Map<String, int> _nonces = {}; // nonce -> until (ms), oldest first
  final Map<String, List<int>> _tries = {}; // address -> times (ms) of its wrong tries in the last minute
  final Map<String, int> _waitUntil = {}; // address -> until when (ms) it waits

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

  /// The Wi-Fi networks clients may come from now.
  List<LanNet> get lanNets => _lan;

  /// The Wi-Fi networks clients may come from (DECISIONS row 562), set again at every look at the phone's address. A
  /// change of network forgets that the laptop said this is home: it says so again at its next request.
  set lan(List<LanNet> nets) {
    _lan = List.unmodifiable(nets);
    if (_home != null && _home != lanSignature(_lan)) _home = null;
    _tellHere();
  }

  /// What the phone says of its Wi-Fi now ([sharingStates]).
  /// Android said the network changed (the app's network callback): another Wi-Fi may use the same addresses, so
  /// it is not home until the paired laptop says so again.
  void networkChanged() {
    _homeUntilMs = 0;
    _tellHere();
  }

  String get here {
    if (key == null) return 'open';
    final sig = lanSignature(_lan);
    if (sig.isNotEmpty && _home == sig && _now().millisecondsSinceEpoch < _homeUntilMs) return 'home';
    if (sig.isNotEmpty && hereNet == sig && _now().millisecondsSinceEpoch < hereUntilMs) return 'here';
    return 'waiting';
  }

  void _tellHere() {
    final h = '$here ${lanSignature(_lan)}';
    if (h == _hereWas) return;
    _hereWas = h;
    try {
      onHere?.call(here);
    } catch (_) {}
  }

  /// Listens on every IPv4 address of the phone (DECISIONS row 562): Wi-Fi, the phone itself for `adb forward`, and
  /// mobile data and a VPN too, which [isServedClient] turns away. So the server does not depend on finding the
  /// Wi-Fi address, and a new lease needs no new socket. Throws when the port is taken.
  /// [on]: another port than [port] (the spare ones, when something else holds it: isolate.dart).
  Future<void> listen({int? on}) async {
    if (_server != null) return;
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, on ?? port, shared: false);
    final s = HttpServer.listenOn(_CappedSocket(socket, total: serverConnectionsMax, perClient: serverConnectionsPerClient));
    s.idleTimeout = const Duration(seconds: 30);
    s.defaultResponseHeaders.clear();
    s.listen(_handle, onError: (Object _) {});
    _server = s;
    _socket = socket;
  }

  /// The listening socket: an HttpServer made by listenOn does not close it.
  ServerSocket? _socket;

  Future<void> close() async {
    for (final r in _readers.toList()) {
      r.closed = true;
      r.wake();
    }
    final s = _server, socket = _socket;
    _server = null;
    _socket = null;
    await s?.close(force: true);
    await socket?.close();
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
        await req.drain<void>();
        return await _json(res, 403, {'error': 'only the local network may connect'});
      }
      final who = client.address, nowMs = _now().millisecondsSinceEpoch;
      if ((_waitUntil[who] ?? 0) > nowMs) {
        await req.drain<void>();
        return await _json(res, 429, {'error': 'too many wrong tries: wait a minute'});
      }
      final method = req.method;
      if (method != 'GET' && method != 'POST' && method != 'HEAD') {
        await req.drain<void>();
        return await _json(res, 405, {'error': 'read-only'});
      }
      final body = await _body(req);
      if (body == null) return await _json(res, 413, {'error': 'too big'});
      final caller = await _caller(req, body);
      if (caller == null) return _wrongTry(who, nowMs); // answered
      final nonce = caller.nonce;
      if (nonce != null) res.headers.set(replyHeader, replyProof(key!, nonce)); // the laptop knows it is this phone
      final path = req.uri.path;
      final loopback = _loopback(client);
      if (!loopback) _vouch(caller);
      if (!loopback && caller.laptop) _noteLaptopAt(who);
      if (path == '/who' || path == '/who/') {
        if (!caller.laptop) return await _json(res, 403, {'error': 'the paired laptop signs this'});
        return await _json(res, 200, {'app': 'eeg-tracker', 'v': 2, 'here': here});
      }
      if (!loopback && !_mayShare(caller)) return await _json(res, 403, {'error': 'not sharing on this Wi-Fi'});
      final by = loopback ? 'cable' : (caller.laptop ? 'laptop' : 'code');
      if (path == '/files' || path == '/files/') {
        if (method == 'POST') return await _json(res, 405, {'error': 'read-only'});
        return await _copy(by, () async => _json(res, 200, await _fileList(hash: req.uri.queryParameters['sha'] != '0')));
      }
      if (path.startsWith('/files/')) {
        if (method == 'POST') return await _json(res, 405, {'error': 'read-only'});
        return await _copy(by, () => _file(req, Uri.decodeComponent(path.substring('/files/'.length))));
      }
      final trimmed = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
      final name = trimmed.substring(trimmed.lastIndexOf('/') + 1);
      if (path == '/work' || path == '/work/') {
        if (method != 'POST') return await _json(res, 405, {'error': 'POST {"working": true|false}'});
        if (!caller.laptop) return await _json(res, 403, {'error': 'the paired laptop signs this'});
        return await _work(res, body);
      }
      if (path == '/recheck' || path == '/recheck/') {
        if (!caller.laptop) return await _json(res, 403, {'error': 'the paired laptop signs this'});
        return method == 'POST' ? await _recheck(res, body) : await _json(res, 200, questions());
      }
      if (path == '/ack' || path == '/ack/') {
        if (method != 'POST') return await _json(res, 405, {'error': 'POST {"v":1,"files":[...]}'});
        if (!caller.laptop) return await _json(res, 403, {'error': 'the paired laptop signs this'});
        return await _ack(res, body);
      }
      if (method == 'POST') {
        if (name == 'marker') {
          if (!caller.laptop) return await _json(res, 403, {'error': 'the paired laptop signs this'});
          return await _marker(res, body);
        }
        if (name == 'contact') return await _json(res, 503, {'error': 'the phone checks contact once, at the start of the night'});
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
          'routes': [
            'GET /state',
            'GET /stream',
            'POST /marker',
            'GET /files',
            'GET /files/<path>',
            'POST /work',
            'POST /ack',
            'GET /who',
            'GET /recheck',
            'POST /recheck',
          ],
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

  /// One more wrong try from [who]: the tenth within a minute makes it wait a minute. Kept small: the oldest
  /// addresses are forgotten past 1000.
  void _wrongTry(String who, int nowMs) {
    final t = _tries.putIfAbsent(who, () => [])..add(nowMs);
    t.removeWhere((x) => x <= nowMs - triesWindow.inMilliseconds);
    if (t.length >= triesMax) {
      _waitUntil[who] = nowMs + triesWait.inMilliseconds;
      _tries.remove(who);
    }
    _waitUntil.removeWhere((_, until) => until <= nowMs);
    while (_tries.length > 1000) {
      _tries.remove(_tries.keys.first);
    }
  }

  static bool _loopback(InternetAddress a) {
    if (a.isLoopback) return true;
    final b = a.rawAddress; // ::ffff:127.x
    return b.length == 16 && b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff && b[12] == 127;
  }

  /// A POST's body, read whole before anything else (the laptop's signature covers it); null when it is too big.
  /// Other methods have none.
  Future<List<int>?> _body(HttpRequest req) async {
    if (req.method != 'POST') {
      await req.drain<void>();
      return const [];
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      if (bytes.length <= postBodyMax) bytes.add(chunk);
    }
    return bytes.length > postBodyMax ? null : bytes.takeBytes();
  }

  /// Who sent [req]: the paired laptop (signed), or someone with the token; null when it was answered with why not.
  Future<_Caller?> _caller(HttpRequest req, List<int> body) async {
    final res = req.response;
    final sign = req.headers.value(signHeader);
    if (sign != null) {
      final k = key;
      if (k == null) return _no(res, 401, {'error': 'not paired'});
      final t = int.tryParse(req.headers.value(timeHeader) ?? ''), nonce = req.headers.value(nonceHeader) ?? '';
      final home = req.headers.value(homeHeader);
      final now = _now().millisecondsSinceEpoch;
      if (t == null || (now - t).abs() > signWindow.inMilliseconds) {
        return _no(res, 401, {'error': 'clock', 'phone_ms': now});
      }
      if (!nonceShape.hasMatch(nonce) || (home != '0' && home != '1')) return _no(res, 401, {'error': 'signature'});
      final String path, query;
      try {
        path = Uri.decodeComponent(req.uri.path);
        query = Uri.decodeComponent(req.uri.query);
      } on ArgumentError {
        return _no(res, 400, {'error': 'bad request'});
      }
      final want = requestSign(k, method: req.method, path: path, query: query, timeMs: t, nonce: nonce, home: home == '1', body: body);
      if (!sameSecret(sign, want)) return _no(res, 401, {'error': 'signature'});
      _nonces.removeWhere((_, until) => until < now);
      if (_nonces.containsKey(nonce)) return _no(res, 401, {'error': 'replayed'});
      if (_nonces.length >= nonceCacheMax) _nonces.remove(_nonces.keys.first);
      _nonces[nonce] = now + 2 * signWindow.inMilliseconds;
      return (laptop: true, nonce: nonce, home: home == '1');
    }
    final auth = req.headers.value('authorization');
    final given = auth != null && auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
    if (!sameToken(given, token)) return _no(res, 401, {'error': 'token missing or wrong'});
    return (laptop: false, nonce: null, home: false);
  }

  Future<Null> _no(HttpResponse res, int code, Object body) async {
    await _json(res, code, body);
    return null;
  }

  /// The paired laptop, from the Wi-Fi, says it is on its home network (it knows its own router: scripts/phone_link.py
  /// `home_id`): then this Wi-Fi is home, also when its first word is /who (the tray's look, the search at home).
  void _vouch(_Caller c) {
    if (c.laptop && c.home && _lan.isNotEmpty) {
      _home = lanSignature(_lan);
      _homeUntilMs = _now().millisecondsSinceEpoch + homeFor.inMilliseconds;
      _tellHere();
    }
  }

  /// Whether this caller, from the Wi-Fi, may have anything now ([here]).
  bool _mayShare(_Caller c) {
    final h = here;
    if (c.laptop) return c.home || h == 'here';
    return h != 'waiting';
  }

  Future<void> _json(HttpResponse res, int code, Object body) => _send(res, code, utf8.encode(jsonEncode(body)), 'application/json');

  Future<void> _send(HttpResponse res, int code, List<int> body, String kind) async {
    res.statusCode = code;
    res.headers.set('Content-Type', kind);
    res.contentLength = body.length;
    res.add(body);
    await res.close();
  }

  Future<void> _marker(HttpResponse res, List<int> all) async {
    var text = utf8.decode(all.length > 2000 ? all.sublist(0, 2000) : all, allowMalformed: true).trim();
    if (text.length > 200) text = text.substring(0, 200);
    if (text.isEmpty) text = 'marker';
    MarkerResult? m;
    try {
      m = await onMarker?.call(text).timeout(const Duration(seconds: 3));
    } catch (_) {
      m = null;
    }
    if (m == null) return _json(res, 503, {'error': 'not recording yet'});
    _publish(jsonEncode({'marker': text, 'i': m.i, 't': _round(m.t, 3)}));
    return _send(res, 200, utf8.encode('ok'), 'text/plain');
  }

  /// The laptop's work signal: `{"working": true|false}`, optionally with `"meeting": true|false`, under 200 bytes.
  Future<void> _work(HttpResponse res, List<int> bytes) async {
    bool? working, meeting;
    if (bytes.length <= 200) {
      try {
        final Object? j = jsonDecode(utf8.decode(bytes));
        if (j is Map && j['working'] is bool) working = j['working'] as bool;
        if (j is Map && j['meeting'] is bool) meeting = j['meeting'] as bool;
      } catch (_) {}
    }
    if (working == null) return _json(res, 400, {'error': 'send {"working": true} or {"working": false}'});
    final take = onWork;
    if (take == null) return _json(res, 503, {'error': 'the work signal is not taken now (a night records)'});
    take(working, meeting);
    return _json(res, 202, {'ok': true});
  }

  /// The paired laptop's acks (recorder/acks.dart), in a request it signed: refused whole without a well-formed
  /// body; then each file on its own (kept only when it holds what the laptop says it checked).
  Future<void> _ack(HttpResponse res, List<int> body) async {
    final r = await takeAcks(body);
    return _json(res, r.code, r.json);
  }

  /// The acks of a `POST /ack` body, or of a push's answer (push/run.dart): the status and the answer.
  Future<({int code, Map<String, Object?> json})> takeAcks(List<int> body) async {
    final asked = <({String path, String sha256})>[];
    try {
      final Object? j = jsonDecode(utf8.decode(body));
      if (j is! Map || j['v'] != 1 || j['files'] is! List) throw const FormatException();
      for (final f in j['files'] as List) {
        if (f is! Map || f['path'] is! String || f['sha256'] is! String) throw const FormatException();
        asked.add((path: f['path'] as String, sha256: f['sha256'] as String));
      }
    } catch (_) {
      return (code: 400, json: <String, Object?>{'error': 'send {"v":1,"files":[{"path":...,"sha256":...}]}'});
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
      return (code: 500, json: <String, Object?>{'error': 'the acks could not be kept: $e'});
    }
    return (code: 200, json: <String, Object?>{'v': 1, 'acked': acked, 'refused': refused});
  }

  /// Where the paired laptop's signed requests come from, kept in `transfer/laptop-at.json` for the push
  /// (push/run.dart): the laptop's address may have changed since the pairing.
  String? _laptopAt;
  void _noteLaptopAt(String address) {
    if (address == _laptopAt) return;
    _laptopAt = address;
    writeLaptopAt(filesDir.path, address);
  }

  /// GET /recheck: the open questions before deleting (recheck.dart), for the paired laptop.
  Map<String, Object?> questions() => {
    'v': 1,
    'asks': [for (final a in RecheckStore(filesDir).open().values) a.toJson()..remove('asked_ms')],
  };

  /// POST /recheck: the laptop's answers. Each is checked against the phone's own bytes; a laptop that does not hold a
  /// file, or holds other bytes, loses that file's ack (nothing is deleted on it; the laptop copies and acks it again).
  Future<void> _recheck(HttpResponse res, List<int> body) async {
    final r = takeProofs(body);
    return _json(res, r.code, r.json);
  }

  /// The proofs of a `POST /recheck` body, or of a push's answer: the status and the answer.
  ({int code, Map<String, Object?> json}) takeProofs(List<int> body) {
    final List<Map<Object?, Object?>> answers;
    try {
      final Object? j = jsonDecode(utf8.decode(body));
      if (j is! Map || j['v'] != 1 || j['proofs'] is! List) throw const FormatException();
      answers = [for (final a in j['proofs'] as List) if (a is Map) a else throw const FormatException()];
    } catch (_) {
      return (code: 400, json: <String, Object?>{'error': 'send {"v":1,"proofs":[{"path","nonce","mac"}]}'});
    }
    final store = RecheckStore(filesDir), open = store.open(), now = _now();
    final proven = <String>[], failed = <Map<String, String>>[], lost = <String>[];
    for (final a in answers) {
      final path = a['path'], nonce = a['nonce'];
      final q = path is String ? open[path] : null;
      if (q == null || nonce != q.nonce) {
        failed.add({'path': '${path ?? ''}', 'why': 'not asked'});
        continue;
      }
      String? why;
      if (a['missing'] == true) {
        why = 'the laptop does not hold it';
      } else {
        final mac = a['mac'];
        final mine = phoneRanges(filesDir, q);
        if (mine == null) {
          why = 'not on the phone as acked';
        } else if (mac is! String || !sameSecret(mac, recheckMac(key!, q.path, q.nonce, q.bytes, q.ranges, mine))) {
          why = 'different bytes';
        }
      }
      store.prove(q.path, q.nonce, ok: why == null, why: why, at: now);
      if (why == null) {
        proven.add(q.path);
      } else {
        failed.add({'path': q.path, 'why': why});
        if (why != 'not on the phone as acked') lost.add(q.path);
      }
    }
    if (lost.isNotEmpty) AckStore(filesDir).remove(lost);
    if (proven.isNotEmpty) {
      try {
        onProved?.call(proven.length);
      } catch (_) {}
    }
    return (code: 200, json: <String, Object?>{'v': 1, 'proven': proven, 'failed': failed});
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

  /// One file request, counted for [onCopying], and said to [onCopied] with who asked.
  Future<void> _copy(String by, Future<void> Function() answer) async {
    _copying++;
    _tellCopying();
    try {
      onCopied?.call(by);
    } catch (_) {}
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
  Future<Map<String, Object?>> fileList({bool hash = true}) => _fileList(hash: hash);

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
    // asked about before deleting: not handed out until answered, so the answer comes from the laptop's own copy
    if (RecheckStore(filesDir).open().containsKey(ackPathOf(path))) return _json(res, 409, {'error': 'being re-checked'});
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
    if (req.method != 'HEAD' && end >= start) {
      await res.addStream(file.openRead(start, end + 1));
      servedFiles++;
      servedBytes += end - start + 1;
    }
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
