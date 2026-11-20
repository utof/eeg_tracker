// The phone link's signatures (DECISIONS 750-759; docs/phone-link.md), the phone's side. scripts/phone_auth.py is
// the laptop's; both are checked against app/test/fixtures/phone_link.json.
//
// - Pairing: the one-time code proves itself both ways ([linkProof]); then both sides work the key out ([deriveKey]),
//   so the key is never sent. The laptop's [confirmProof] shows it got the same key.
// - Every request of the paired laptop is signed with that key ([requestSign]): the method, the path and query, a
//   time, a nonce used once, whether the laptop is on the network where it paired, and the body's SHA-256. The phone
//   answers with [replyProof] over the same nonce.
// - Before the phone deletes a raw recording by itself it asks the laptop for [recheckMac] over random byte ranges of
//   the laptop's own copy and a fresh nonce (recorder/recheck.dart).
//
// Plain Dart (package:crypto): it runs in the share isolate, the screen's and tests.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const String linkTag = 'eeg-tracker link v2';
const String _keyTag = 'eeg-tracker key v2';
const String _requestTag = 'eeg-tracker request v2';
const String _replyTag = 'eeg-tracker reply v2';
const String _recheckTag = 'eeg-tracker recheck v1';

/// A nonce or a one-time code as both sides make them: 16-64 URL-safe characters.
final RegExp nonceShape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// A pairing key: 64 hex.
final RegExp keyShape = RegExp(r'^[0-9a-f]{64}$');

/// The headers of a signed request (lower case, as dart:io reads them).
const String timeHeader = 'x-eeg-time', nonceHeader = 'x-eeg-nonce', homeHeader = 'x-eeg-home', signHeader = 'x-eeg-sign';
const String replyHeader = 'x-eeg-reply';

String _hmac(String key, List<int> msg) => Hmac(sha256, utf8.encode(key)).convert(msg).toString();
String _sha(List<int> b) => sha256.convert(b).toString();

/// 16 random bytes, URL-safe, no padding (22 characters).
String newNonce([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]).replaceAll('=', '');
}

/// HMAC-SHA256(code, `eeg-tracker link v2|<who>|<first>|<second>`): the laptop answers the phone's nonce with
/// who=laptop (phone nonce, laptop nonce); the phone answers with who=phone (laptop nonce, phone nonce).
String linkProof(String code, String who, String first, String second) =>
    _hmac(code, utf8.encode([linkTag, who, first, second].join('|')));

/// The pairing's key, worked out on both sides from the code (never sent) and the two nonces: 64 hex.
String deriveKey(String code, String phoneNonce, String laptopNonce) =>
    _hmac(code, utf8.encode([_keyTag, phoneNonce, laptopNonce].join('|')));

/// The laptop's last word at pairing: it holds the same key.
String confirmProof(String key, String phoneNonce, String laptopNonce) =>
    _hmac(key, utf8.encode([linkTag, 'laptop', 'confirm', phoneNonce, laptopNonce].join('|')));

/// HMAC-SHA256(key, `eeg-tracker request v2|METHOD|time|nonce|home|sha256(body)|sha256(path)|sha256(query)`), where
/// [path] and [query] are percent-decoded. The two go in as hashes, so no character in them can move a field boundary.
String requestSign(
  String key, {
  required String method,
  required String path,
  required String query,
  required int timeMs,
  required String nonce,
  required bool home,
  List<int> body = const [],
}) => _hmac(
  key,
  utf8.encode(
    [
      _requestTag,
      method.toUpperCase(),
      '$timeMs',
      nonce,
      home ? '1' : '0',
      _sha(body),
      _sha(utf8.encode(path)),
      _sha(utf8.encode(query)),
    ].join('|'),
  ),
);

/// What the phone's answer to a signed request carries: HMAC-SHA256(key, `eeg-tracker reply v2|<the request's nonce>`).
String replyProof(String key, String nonce) => _hmac(key, utf8.encode('$_replyTag|$nonce'));

/// `0+16,4096+100`: the ranges as both sides write them into a re-check's proof.
String rangesText(List<(int, int)> ranges) => ranges.map((r) => '${r.$1}+${r.$2}').join(',');

/// HMAC-SHA256(key, `eeg-tracker recheck v1|sha256(path)|nonce|size|s+n,...|` + the bytes of each range in order).
String recheckMac(String key, String path, String nonce, int size, List<(int, int)> ranges, Iterable<List<int>> chunks) {
  final out = _DigestSink();
  final input = Hmac(sha256, utf8.encode(key)).startChunkedConversion(out);
  input.add(utf8.encode([_recheckTag, _sha(utf8.encode(path)), nonce, '$size', rangesText(ranges), ''].join('|')));
  for (final c in chunks) {
    input.add(c);
  }
  input.close();
  return out.value.toString();
}

/// Same length or not, the comparison takes the same time for every wrong value.
bool sameSecret(String given, String expected) {
  final a = utf8.encode(given), b = utf8.encode(expected);
  var diff = a.length ^ b.length;
  for (var i = 0; i < b.length; i++) {
    diff |= (i < a.length ? a[i] : 0) ^ b[i];
  }
  return diff == 0 && expected.isNotEmpty;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
