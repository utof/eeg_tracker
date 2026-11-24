// The push's small memory (DECISIONS 840-849): where the paired laptop was last heard from, when the phone last sent
// its files, and when the next try is due. Plain dart:io, in `files/transfer/` (never shared or exported).
import 'dart:convert';
import 'dart:io';

/// The laptop's receiver (scripts/push_receiver.py `PUSH_PORT`).
const int pushPort = 8772;

/// Android runs the job about this often (PushJob.kt), and once more soon after a recording ends.
const Duration pushEvery = Duration(minutes: 15);

/// A try this soon after the last one is left out (the job after a Stop and the regular one falling together).
const Duration pushSpacing = Duration(seconds: 30);

/// The home network is looked around for the laptop at most this often (254 short connects).
const Duration sweepEvery = Duration(hours: 2);

File _file(String filesDir, String name) => File('$filesDir/transfer/$name');

void _write(File f, Map<String, Object?> j) {
  try {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode(j), flush: true);
    tmp.renameSync(f.path);
  } catch (_) {
    // not kept: the next run finds it out again
  }
}

Object? _read(File f) {
  try {
    return jsonDecode(f.readAsStringSync());
  } catch (_) {
    return null;
  }
}

/// The address the paired laptop's signed requests last came from (share/server.dart), kept for the push.
void writeLaptopAt(String filesDir, String address) =>
    _write(_file(filesDir, 'laptop-at.json'), {'address': address, 'at_ms': DateTime.now().millisecondsSinceEpoch});

String? readLaptopAt(String filesDir) {
  final j = _read(_file(filesDir, 'laptop-at.json'));
  final a = j is Map ? j['address'] : null;
  return a is String && InternetAddress.tryParse(a) != null ? a : null;
}

/// `transfer/push.json`.
class PushState {
  const PushState({this.okMs = 0, this.tryMs = 0, this.fails = 0, this.why = '', this.files = 0, this.bytes = 0, this.sweptMs = 0});

  /// When the laptop last took a push whole, and when the last try started (unix ms; 0: never).
  final int okMs, tryMs;

  /// Tries in a row that did not reach the laptop at home, and the last one's reason in plain words.
  final int fails;
  final String why;

  /// What the last good push sent.
  final int files, bytes;

  /// When the network was last looked around for the laptop.
  final int sweptMs;

  static PushState read(String filesDir) {
    final j = _read(_file(filesDir, 'push.json'));
    if (j is! Map) return const PushState();
    int n(String k) => j[k] is int ? j[k] as int : 0;
    return PushState(
      okMs: n('ok_ms'),
      tryMs: n('try_ms'),
      fails: n('fails'),
      why: j['why'] is String ? j['why'] as String : '',
      files: n('files'),
      bytes: n('bytes'),
      sweptMs: n('swept_ms'),
    );
  }

  void write(String filesDir) => _write(_file(filesDir, 'push.json'), {
    'ok_ms': okMs,
    'try_ms': tryMs,
    'fails': fails,
    'why': why,
    'files': files,
    'bytes': bytes,
    'swept_ms': sweptMs,
  });

  PushState started(int nowMs) => PushState(okMs: okMs, tryMs: nowMs, fails: fails, why: why, files: files, bytes: bytes, sweptMs: sweptMs);
  PushState swept(int nowMs) => PushState(okMs: okMs, tryMs: tryMs, fails: fails, why: why, files: files, bytes: bytes, sweptMs: nowMs);
  PushState sent(int nowMs, int files, int bytes) => PushState(okMs: nowMs, tryMs: tryMs, files: files, bytes: bytes, sweptMs: sweptMs);
  PushState failed(String why) => PushState(okMs: okMs, tryMs: tryMs, fails: fails + 1, why: why, files: files, bytes: bytes, sweptMs: sweptMs);
}

/// How long the regular job waits after a try that did not reach the laptop: nothing for the first three (the laptop
/// was asleep for a moment), then half an hour, then an hour (the laptop is away or off: each try costs a little
/// battery).
Duration pushBackoff(int fails) => fails < 4
    ? Duration.zero
    : fails < 8
    ? const Duration(minutes: 30)
    : const Duration(hours: 1);

/// Whether a push should run now. [soon]: asked for by the app (a recording just ended, the app was opened), which
/// skips the wait after failures.
bool pushDue(PushState s, int nowMs, {required bool soon}) {
  final since = nowMs - s.tryMs;
  if (since < 0) return true; // the clock was set back
  if (since < pushSpacing.inMilliseconds) return false;
  return soon || since >= pushBackoff(s.fails).inMilliseconds;
}

/// Whether the network may be looked around for the laptop now.
bool sweepDue(PushState s, int nowMs) => nowMs - s.sweptMs >= sweepEvery.inMilliseconds || nowMs < s.sweptMs;
