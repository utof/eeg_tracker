// A night's scoring in progress, kept on disk so that a restart (an app update, Android ending the app, a night that
// starts) goes on from the last finished model call instead of starting over (DECISIONS rows 580-582):
// `files/cache/scoring/<night>.progress`. It names what it was made from (the recordings' names and sizes, the
// model) and is used only for exactly that; anything else, or a damaged file, is dropped and the night starts over.
// `files/cache/` holds what the app can always make again: it is never exported or shared (export/store.dart).
// Plain Dart: tested on a plain folder.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'model.dart';

/// `files/cache/`: what the app can make again (scoring progress, Share on Wi-Fi's SHA-256 list); never exported.
Directory cacheDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/cache');

/// `files/cache/scoring/`.
Directory scoringProgressDirFor(String recordingsDir) => Directory('${cacheDirFor(recordingsDir).path}/scoring');

/// What the report needs from the night's preparation, kept so that a night whose model is done needs no second
/// preparation: the first epoch's start (unix seconds), the joined night's samples and how many were filled in, and
/// the epochs with over 5 s missing.
typedef PreparedFacts = ({int startUnix, int recordedSamples, int missingSamples, List<bool> gap});

/// One night's scoring under way, or asked for again ("Score again").
class NightProgress {
  NightProgress({
    required this.inputs,
    required this.model,
    this.tries = 0,
    this.requested = false,
    this.seconds = 0,
    this.prepared,
    this.progress,
  });

  /// The recordings' names and sizes it was made from.
  final Map<String, int> inputs;

  /// The scorer's model.
  final String model;

  /// Goes in a row that ended before a model call was saved: the app stopped while preparing, or a failure. After
  /// [maxTries] the night waits for "Try again" instead of starting by itself again.
  int tries;

  /// The owner asked for this night to be scored again (its report is from an older scorer).
  bool requested;

  /// Working time over every go, for the report's `scoring_s`.
  double seconds;

  /// Set once the night was prepared.
  PreparedFacts? prepared;

  /// The model's progress after its last saved call; null before the first.
  ModelProgress? progress;

  /// Whether it was made from these [files] by this [model].
  bool matches(Map<String, int> files, String model) =>
      model == this.model && files.length == inputs.length && files.entries.every((e) => inputs[e.key] == e.value);

  /// Model calls done, and of how many (0 of 0 before the night was prepared).
  ({int done, int of}) calls(int runCount) {
    final p = prepared, m = progress;
    if (p == null) return (done: 0, of: 0);
    return (done: m?.calls ?? 0, of: modelCalls(p.gap.length, runCount));
  }
}

/// How many goes in a row may end before a saved model call before the night waits for "Try again".
const int maxTries = 3;

const String _magic = 'EEGNP1';

/// `files/cache/scoring/`: one `<night>.progress` per night under way, replaced whole at every saved call (written to
/// a temporary file, then renamed).
class ScoringProgressStore {
  ScoringProgressStore(this.dir);
  final Directory dir;

  File fileFor(String night) => File('${dir.path}/$night.progress');

  /// The night's progress, or null when there is none or it cannot be read.
  NightProgress? read(String night) {
    final f = fileFor(night);
    try {
      if (!f.existsSync()) return null;
      return decodeProgress(f.readAsBytesSync());
    } on Object {
      return null;
    }
  }

  void write(String night, NightProgress p) {
    dir.createSync(recursive: true);
    final tmp = File('${dir.path}/$night.progress.tmp');
    tmp.writeAsBytesSync(encodeProgress(p), flush: true);
    tmp.renameSync(fileFor(night).path);
  }

  void delete(String night) {
    final f = fileFor(night);
    if (f.existsSync()) f.deleteSync();
  }

  /// Nights with a progress file.
  List<String> nights() {
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.progress')) f.uri.pathSegments.last.replaceAll('.progress', ''),
    ]..sort();
  }
}

/// The file's bytes: a magic word, the header's length, the header as JSON, then the model's progress.
Uint8List encodeProgress(NightProgress p) {
  final pr = p.prepared;
  final head = utf8.encode(
    jsonEncode({
      'inputs': p.inputs,
      'model': p.model,
      'tries': p.tries,
      'requested': p.requested,
      'seconds': p.seconds,
      if (pr != null)
        'prepared': {
          'start_unix': pr.startUnix,
          'recorded_samples': pr.recordedSamples,
          'missing_samples': pr.missingSamples,
          'gap': pr.gap.map((g) => g ? '1' : '0').join(),
        },
    }),
  );
  final len = ByteData(4)..setUint32(0, head.length, Endian.little);
  final b = BytesBuilder(copy: false)
    ..add(_magic.codeUnits)
    ..add(len.buffer.asUint8List())
    ..add(head);
  final m = p.progress;
  if (m != null) b.add(m.toBytes());
  return b.takeBytes();
}

/// Reads [encodeProgress]'s bytes; null when they are not a progress file or do not hang together.
NightProgress? decodeProgress(Uint8List b) {
  if (b.length < 10 || String.fromCharCodes(b.sublist(0, 6)) != _magic) return null;
  final n = ByteData.sublistView(b).getUint32(6, Endian.little);
  if (10 + n > b.length) return null;
  final h = jsonDecode(utf8.decode(b.sublist(10, 10 + n)));
  if (h is! Map<String, dynamic>) return null;
  final inputs = h['inputs'], model = h['model'], tries = h['tries'], requested = h['requested'];
  final seconds = h['seconds'];
  if (inputs is! Map || model is! String || tries is! int || requested is! bool || seconds is! num) return null;
  final files = <String, int>{};
  for (final e in inputs.entries) {
    if (e.key is! String || e.value is! int) return null;
    files[e.key as String] = e.value as int;
  }
  PreparedFacts? prepared;
  final pr = h['prepared'];
  if (pr is Map) {
    final s = pr['start_unix'], rec = pr['recorded_samples'], miss = pr['missing_samples'], gap = pr['gap'];
    if (s is! int || rec is! int || miss is! int || gap is! String || gap.isEmpty) return null;
    if (gap.split('').any((c) => c != '0' && c != '1')) return null;
    prepared = (
      startUnix: s,
      recordedSamples: rec,
      missingSamples: miss,
      gap: [for (final c in gap.split('')) c == '1'],
    );
  }
  ModelProgress? progress;
  if (10 + n < b.length) {
    progress = ModelProgress.fromBytes(Uint8List.sublistView(b, 10 + n));
    if (progress == null || prepared == null || progress.epochs != prepared.gap.length) return null;
  }
  return NightProgress(
    inputs: files,
    model: model,
    tries: tries,
    requested: requested,
    seconds: seconds.toDouble(),
    prepared: prepared,
    progress: progress,
  );
}
