// The phone's side of a push (DECISIONS 840-849; scripts/push_receiver.py is the laptop's): four signed POSTs. Every
// answer must prove the pairing's key over the request's nonce and its own bytes, or nothing in it is used: the
// phone's files go to the paired laptop only, never to whatever device holds its old address.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../auth.dart';

/// Why a push stopped.
enum PushFailure {
  /// Nothing answered at the address (the laptop is off, asleep or elsewhere).
  noAnswer,

  /// Something answered without the key's proof: not the paired laptop (or it forgot this phone).
  notTheLaptop,

  /// The paired laptop refused (its words in [PushError.why]).
  refused,

  /// The laptop is busy copying (503): the same push goes on later.
  busy,
}

class PushError implements Exception {
  const PushError(this.failure, [this.why = '', this.json]);
  final PushFailure failure;
  final String why;

  /// The proven answer of a refusal (a 409's `staged`).
  final Map<String, Object?>? json;

  @override
  String toString() => 'PushError(${failure.name}${why.isEmpty ? '' : ': $why'})';
}

class PushClient {
  PushClient({required this.key, required this.host, required this.port, HttpClient? http, DateTime Function()? clock})
    : _http = http ?? (HttpClient()..findProxy = (_) => 'DIRECT'),
      _now = clock ?? DateTime.now;

  final String key, host;
  final int port;
  final HttpClient _http;
  final DateTime Function() _now;

  void close() => _http.close(force: true);

  /// One signed POST of [body] to [target] (`/push/chunk?s=..`, as sent); the proven JSON answer. Throws [PushError].
  Future<Map<String, Object?>> post(String target, List<int> body, {required Duration timeout}) async {
    final uri = Uri.parse('http://$host:$port$target');
    final nonce = newNonce(), timeMs = _now().millisecondsSinceEpoch;
    final sign = pushSign(key, method: 'POST', path: Uri.decodeComponent(uri.path), query: Uri.decodeComponent(uri.query), timeMs: timeMs, nonce: nonce, body: body);
    final int code;
    final List<int> answer;
    final String? proof;
    try {
      final req = await _http.postUrl(uri).timeout(timeout);
      req.followRedirects = false;
      req.headers.set(timeHeader, '$timeMs');
      req.headers.set(nonceHeader, nonce);
      req.headers.set(signHeader, sign);
      req.headers.contentType = ContentType.binary;
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close().timeout(timeout);
      code = res.statusCode;
      proof = res.headers.value(replyHeader);
      final got = BytesBuilder(copy: false);
      await for (final part in res.timeout(timeout)) {
        got.add(part);
        if (got.length > answerMax) throw const PushError(PushFailure.notTheLaptop, 'the answer is too long');
      }
      answer = got.takeBytes();
    } on PushError {
      rethrow;
    } catch (e) {
      throw PushError(PushFailure.noAnswer, e is TimeoutException ? 'no answer in time' : 'no answer');
    }
    if (proof == null || !sameSecret(proof, pushReplyProof(key, nonce, answer))) {
      throw const PushError(PushFailure.notTheLaptop, 'the answer did not prove the pairing');
    }
    Map<String, Object?> json;
    try {
      json = (jsonDecode(utf8.decode(answer)) as Map).cast<String, Object?>();
    } catch (_) {
      throw const PushError(PushFailure.refused, 'the answer could not be read');
    }
    if (code == 200 && json['v'] == 1) return json;
    final why = json['error'] is String ? json['error'] as String : 'answered $code';
    throw PushError(code == 503 ? PushFailure.busy : PushFailure.refused, why, json);
  }

  /// The laptop's proof that it is there, and whether it is on its home network.
  Future<bool> hello() async =>
      (await post('/push/hello', utf8.encode('{"v":1}'), timeout: const Duration(seconds: 4)))['home'] == true;

  Future<Map<String, Object?>> begin(Map<String, Object?> list, List<Object?> asks, int? sharePort) => post(
    '/push/begin',
    utf8.encode(jsonEncode({'v': 1, 'port': sharePort, 'files': list, 'asks': asks})),
    timeout: const Duration(seconds: 150),
  );

  /// Sends [bytes] of [path] for offset [at]; the bytes of it the laptop holds now. A wrong offset throws a refusal
  /// whose `json['staged']` says where to go on.
  Future<int> chunk(String session, String path, int at, List<int> bytes) async {
    final j = await post(
      '/push/chunk?s=${Uri.encodeComponent(session)}&p=${Uri.encodeComponent(path)}&at=$at',
      bytes,
      timeout: const Duration(seconds: 60),
    );
    return j['staged'] is int ? j['staged'] as int : 0;
  }

  Future<Map<String, Object?>> commit(String session) => post(
    '/push/commit?s=${Uri.encodeComponent(session)}',
    utf8.encode('{"v":1}'),
    timeout: const Duration(seconds: 330),
  );
}

/// The longest answer read (a commit's acks for thousands of files).
const int answerMax = 8 * 1024 * 1024;
