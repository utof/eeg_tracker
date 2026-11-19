// The speech-to-text model on the phone (DECISIONS rows 250-251): not in the APK but downloaded once, when you ask,
// into the app's private `files/models/<id>/` (Export data leaves `models/` on the phone, row 150; an app update
// keeps it; uninstalling removes it). Each file is fetched from a fixed revision on Hugging Face, can resume after
// an interruption, and is kept only when its SHA-256 matches the one written here. The only thing the app ever
// downloads; your answers never leave the phone.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// The speech model's licence notice (CC-BY-4.0 asks for the attribution), shown under Licences.
const String parakeetNotice =
    'Parakeet TDT 0.6B v3, by NVIDIA, licensed under CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/). '
    'Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3. Converted to ONNX and quantized to int8 for '
    'sherpa-onnx by the k2-fsa project (https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8). '
    'Not in the app: downloaded to the phone only when you tap Download in the dream catcher; used unchanged.';

class ModelFile {
  const ModelFile(this.name, this.bytes, this.sha256);
  final String name;
  final int bytes;
  final String sha256;
}

class SpeechModelSpec {
  const SpeechModelSpec({required this.id, required this.label, required this.base, required this.files});

  /// Folder name and the `model` in each text file.
  final String id;
  final String label;

  /// The files' address, ending in `/` (a fixed revision).
  final String base;
  final List<ModelFile> files;

  int get bytes => files.fold(0, (n, f) => n + f.bytes);
}

/// NVIDIA's Parakeet TDT 0.6B v3 (25 European languages, Russian and English among them; CC-BY-4.0), int8, as
/// converted for sherpa-onnx by its maintainers; revision of 2026-11-07. Row 250 says why this one.
const SpeechModelSpec parakeetV3 = SpeechModelSpec(
  id: 'parakeet-tdt-0.6b-v3-int8',
  label: 'Parakeet TDT 0.6B v3',
  base: 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/ed5d745623472f97cfc2e6c2916ee248798fc5a8/',
  files: [
    ModelFile('encoder.int8.onnx', 652282294, '1afbe69c1ffdabee94755f42e4daf1d93549131a3da11356bda84fcef0f2c479'),
    ModelFile('decoder.int8.onnx', 11845274, '0222a86147299d4dee90edf95b6d13827edb42ad8b7c9cf0b2582f030937c0b5'),
    ModelFile('joiner.int8.onnx', 6355277, 'cbd02f3696e9944970111fb439d9c3fd365a80374565f13f2b9c7007d253fc98'),
    ModelFile('tokens.txt', 93939, 'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d'),
  ],
);

/// The bytes of a file from [from] on; the server may start at 0 instead (no resume), which [FetchReply.from] says.
class FetchReply {
  const FetchReply(this.body, this.from);
  final Stream<List<int>> body;
  final int from;
}

typedef Fetch = Future<FetchReply> Function(Uri uri, int from);

class ModelDownloadError implements Exception {
  const ModelDownloadError(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();
  @override
  String toString() => 'stopped';
}

class SpeechModelStore {
  SpeechModelStore(Directory modelsDir, this.spec, {Fetch? fetch})
    : dir = Directory('${modelsDir.path}/${spec.id}'),
      _fetch = fetch ?? httpFetch;

  final SpeechModelSpec spec;
  final Directory dir;
  final Fetch _fetch;

  /// Written once every file is checked: the ids and hashes it was checked against.
  File get _checked => File('${dir.path}/checked.txt');
  String get _checkedText => [spec.id, for (final f in spec.files) '${f.sha256}  ${f.name}'].join('\n');

  String path(String name) => '${dir.path}/$name';

  /// Every file there, of its size, and checked when it came.
  bool get ready {
    try {
      if (!_checked.existsSync() || _checked.readAsStringSync() != _checkedText) return false;
      return spec.files.every((f) => File(path(f.name)).existsSync() && File(path(f.name)).lengthSync() == f.bytes);
    } on FileSystemException {
      return false;
    }
  }

  /// Bytes on the phone so far (finished files and parts).
  int get bytesHere {
    var n = 0;
    for (final f in spec.files) {
      for (final p in [path(f.name), '${path(f.name)}.part']) {
        final file = File(p);
        if (file.existsSync()) n += file.lengthSync();
      }
    }
    return n;
  }

  bool _cancel = false;
  StreamSubscription<List<int>>? _sub;
  Completer<void>? _current;

  /// Fetches what is missing, checks it, and marks the model ready. [onProgress]: 0..1 over all files. Throws
  /// [ModelDownloadError] (with a plain reason) or [ModelDownloadCancelled] after [cancel]; parts stay for later.
  Future<void> download({void Function(double done)? onProgress}) async {
    _cancel = false;
    dir.createSync(recursive: true);
    if (_checked.existsSync()) _checked.deleteSync();
    final total = spec.bytes;
    var before = 0;
    for (final f in spec.files) {
      final done = File(path(f.name));
      if (!(done.existsSync() && done.lengthSync() == f.bytes && await _matches(done, f))) {
        if (done.existsSync()) done.deleteSync();
        await _fetchOne(f, (n) => onProgress?.call((before + n) / total));
        final part = File('${path(f.name)}.part');
        if (!await _matches(part, f)) {
          part.deleteSync();
          throw ModelDownloadError('${f.name} came damaged (its check did not match), so it was thrown away. Try again.');
        }
        part.renameSync(done.path);
      }
      before += f.bytes;
      onProgress?.call(before / total);
    }
    _checked.writeAsStringSync(_checkedText, flush: true);
  }

  /// Stops a download; what came so far stays as a part.
  void cancel() {
    _cancel = true;
    final c = _current;
    unawaited(_sub?.cancel());
    if (c != null && !c.isCompleted) c.completeError(const ModelDownloadCancelled());
  }

  /// Removes the model and any parts.
  void delete() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  Future<void> _fetchOne(ModelFile f, void Function(int bytes) progress) async {
    final part = File('${path(f.name)}.part');
    var have = part.existsSync() ? part.lengthSync() : 0;
    if (have > f.bytes) {
      part.deleteSync();
      have = 0;
    }
    if (have == f.bytes) return;
    if (_cancel) throw const ModelDownloadCancelled();
    final reply = await _fetch(Uri.parse('${spec.base}${f.name}'), have);
    if (_cancel) throw const ModelDownloadCancelled();
    final sink = part.openWrite(mode: reply.from == have && have > 0 ? FileMode.append : FileMode.write);
    var n = reply.from == have ? have : 0;
    final done = _current = Completer<void>();
    _sub = reply.body.timeout(const Duration(seconds: 60)).listen(
      (chunk) {
        sink.add(chunk);
        n += chunk.length;
        progress(n);
      },
      onError: (Object e) {
        if (!done.isCompleted) {
          done.completeError(e is TimeoutException ? const ModelDownloadError('The download stalled. Try again.') : ModelDownloadError('$e'));
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      _sub = null;
      _current = null;
      await sink.flush();
      await sink.close();
    }
    if (part.lengthSync() != f.bytes) {
      throw ModelDownloadError('${f.name} ended early (${part.lengthSync()} of ${f.bytes} bytes). Try again: it goes on from there.');
    }
  }

  static Future<bool> _matches(File file, ModelFile f) async {
    if (!file.existsSync() || file.lengthSync() != f.bytes) return false;
    final p = file.path;
    // hashing 650 MB takes seconds: off the screen's isolate
    return await Isolate.run(() async => (await sha256.bind(File(p).openRead()).first).toString()) == f.sha256;
  }
}

/// GET with a Range header from [from], following redirects (Hugging Face sends files from its CDN) with the
/// Range kept.
Future<FetchReply> httpFetch(Uri uri, int from) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  var u = uri;
  for (var hop = 0; hop < 6; hop++) {
    final req = await client.getUrl(u);
    req.followRedirects = false;
    if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
    final res = await req.close();
    if (res.isRedirect) {
      final to = res.headers.value(HttpHeaders.locationHeader);
      await res.drain<void>();
      if (to == null) break;
      u = u.resolve(to);
      continue;
    }
    if (res.statusCode == HttpStatus.partialContent) return FetchReply(_closing(res, client), from);
    if (res.statusCode == HttpStatus.ok) return FetchReply(_closing(res, client), 0);
    await res.drain<void>();
    client.close(force: true);
    throw ModelDownloadError('The server answered ${res.statusCode}. Try again later.');
  }
  client.close(force: true);
  throw const ModelDownloadError('Too many redirects. Try again later.');
}

Stream<List<int>> _closing(HttpClientResponse res, HttpClient client) async* {
  try {
    yield* res;
  } finally {
    client.close(force: true);
  }
}

/// A download's failure in plain words.
String downloadProblem(Object e) => switch (e) {
  ModelDownloadError(:final message) => message,
  SocketException() || HttpException() || TlsException() || TimeoutException() =>
    'No connection to the download server. Check Wi-Fi, then try again: it goes on from where it stopped.',
  FileSystemException(:final message, :final osError) => 'Could not save it on the phone (${osError?.message ?? message}). Is the phone full?',
  _ => '$e',
};
