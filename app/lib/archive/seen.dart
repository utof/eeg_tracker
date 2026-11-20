// What the shared detectors see in a recording, for the Archive's activity tags (DECISIONS 700-709). One pass over the
// recording's sets joined on the clock (sleep/night_signal.dart, the sleep report's own join), sample by sample through
// the detectors (detectors/detectors.dart: signal quality, jaw bursts, movement) and the work session's drowsiness level
// (work/drowsiness.dart: eyes closed, getting drowsy, drowsy, against this recording's own first minutes), kept per 30 s
// epoch from the first sample:
//   quality  g good, d degraded (noisy), m missing (no usable electrode, or no data: the headband away or off)
//   eyes     c closed, o open, - not read (too noisy)
//   level    a alert, g getting drowsy, d drowsy, - not known (before its 3-minute baseline, or too noisy)
//   jaw      jaw bursts (both sides) starting in the epoch
//   move     seconds with movement (3 or more channels jumping) in the epoch
// The pass needs O1 O2 T3 T4 (by name or site) at 250 samples a second, like every detector: another layout is told in
// words and gets no activity tags, only its sessions and your tags (DECISIONS 633).
// Kept in `files/cache/archive-seen/<id>.json` with the size and modified time of every raw file it read, so it runs
// again only when one changed (a recording still growing, or packed after a day: the same samples, read again once).
// Plain Dart; the page runs it in a background isolate.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../cache/file_summaries.dart' show SummaryIndex, fileKey;
import '../detectors/detectors.dart';
import '../feedback/features.dart' show fs;
import '../recorder/header.dart' show HeaderError, MissingSites, tryHeader;
import '../recorder/packed.dart' show rawOnDisk;
import '../sleep/night_signal.dart' show joinLayout, sampleRate;
import '../work/drowsiness.dart';

const int seenVersion = 1;

/// The cache folder in `files/`.
const String seenFolder = 'cache/archive-seen';

/// What the pass kept of a recording (see the top of the file).
class RecordingSeen {
  const RecordingSeen({
    required this.startMs,
    required this.quality,
    required this.eyes,
    required this.level,
    required this.jaw,
    required this.move,
  });

  /// The joined recording's first sample, unix ms (a whole second).
  final int startMs;
  final String quality, eyes, level;
  final List<int> jaw, move;

  int get epochs => quality.length;
  DateTime get start => DateTime.fromMillisecondsSinceEpoch(startMs);
  DateTime epochStart(int i) => DateTime.fromMillisecondsSinceEpoch(startMs + i * epochS * 1000);

  Map<String, Object?> toJson() => {
    'start_ms': startMs,
    'quality': quality,
    'eyes': eyes,
    'level': level,
    'jaw': jaw,
    'move': move,
  };

  static RecordingSeen? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['start_ms'], q = j['quality'], e = j['eyes'], l = j['level'], jw = j['jaw'], m = j['move'];
    if (s is! int || q is! String || e is! String || l is! String || jw is! List || m is! List) return null;
    final n = q.length;
    if (e.length != n || l.length != n || jw.length != n || m.length != n) return null;
    if (jw.any((x) => x is! int) || m.any((x) => x is! int)) return null;
    return RecordingSeen(startMs: s, quality: q, eyes: e, level: l, jaw: jw.cast<int>(), move: m.cast<int>());
  }
}

const Map<EpochQuality, String> _q = {EpochQuality.good: 'g', EpochQuality.degraded: 'd', EpochQuality.missing: 'm'};

String _levelChar(WorkEpoch e) => switch (e.level) {
  DrowsyLevel.alert => 'a',
  DrowsyLevel.gettingDrowsy => 'g',
  DrowsyLevel.drowsy => 'd',
  DrowsyLevel.unknown => '-',
};

/// Why the pass cannot read [f32Files], in words; null when it can.
String? whyNotSeen(List<File> f32Files) {
  if (f32Files.isEmpty) return 'No raw signal on the phone.';
  for (final f in f32Files) {
    final h = tryHeader(f);
    if (h == null) return 'A file set\'s header cannot be read.';
    if (h.sampleRate != sampleRate) {
      return 'The detectors read $sampleRate samples a second; this recording has ${h.sampleRate}.';
    }
    try {
      h.pick(const ['O1', 'O2', 'T3', 'T4'], who: 'The activity tags');
    } on MissingSites catch (e) {
      return e.message;
    }
  }
  return null;
}

/// The pass over a recording's `.f32` files (oldest first, plain names); null without a whole second of samples.
/// Throws [MissingSites] or [HeaderError] for a recording it cannot read ([whyNotSeen] says so first).
RecordingSeen? seeRecording(List<File> f32Files) {
  final layout = joinLayout(f32Files, who: 'The activity tags');
  if (layout.samples < fs) return null;
  final drowsy = WorkDrowsiness();
  late final Detectors det;
  var cursor = 0;
  det = Detectors(
    onSecond: (s) {
      var moves = 0;
      while (cursor < det.eyeMoves.length && det.eyeMoves[cursor].i ~/ fs <= s.k) {
        if (det.eyeMoves[cursor].i ~/ fs == s.k) moves++;
        cursor++;
      }
      drowsy.second(workInputOf(s, eyeMoves: moves));
    },
  );
  layout.forEachRow((row, missing) => det.push(row, missing: missing));
  det.finish();
  final n = det.epochs.length;
  final jaw = List<int>.filled(n, 0), move = List<int>.filled(n, 0);
  for (final b in det.bursts) {
    final e = b.start ~/ epochS;
    if (b.kind == BurstKind.jaw && e < n) jaw[e]++;
  }
  for (final (a, b) in det.movement) {
    for (var k = a; k <= b; k++) {
      final e = k ~/ epochS;
      if (e < n) move[e]++;
    }
  }
  final eyes = StringBuffer(), level = StringBuffer();
  for (var i = 0; i < n; i++) {
    final w = i < drowsy.epochs.length ? drowsy.epochs[i] : null;
    eyes.write(w == null ? '-' : (w.eyesClosed ? 'c' : (w.alpha == null ? '-' : 'o')));
    level.write(w == null ? '-' : _levelChar(w));
  }
  return RecordingSeen(
    startMs: layout.startUnix * 1000,
    quality: [for (final e in det.epochs) _q[e.quality]!].join(),
    eyes: eyes.toString(),
    level: level.toString(),
    jaw: jaw,
    move: move,
  );
}

/// The key of what the pass reads: every raw file's name, size and modified time (the samples as on the phone, packed
/// or not, and the index).
String seenKeyOf(List<File> f32Files) {
  final parts = <String>[];
  for (final f in f32Files) {
    final stem = f.path.substring(0, f.path.length - 4);
    for (final g in [rawOnDisk(f), File('$stem.idx')]) {
      if (g == null) continue;
      final k = fileKey(g);
      if (k != null) parts.add('${g.uri.pathSegments.last} ${k.size} ${k.modifiedUs}');
    }
  }
  return parts.join('\n');
}

/// What the Archive keeps of a pass: the epochs, or why there are none.
typedef Seen = ({RecordingSeen? seen, String? why});

File seenFileFor(Directory filesDir, String id) => File('${filesDir.path}/$seenFolder/$id.json');

/// The kept pass of recording [id] when its raw files are those it read; null when there is none or they changed.
Seen? keptSeen(Directory filesDir, String id, List<File> f32Files) {
  try {
    final j = jsonDecode(seenFileFor(filesDir, id).readAsStringSync());
    if (j is! Map || j['version'] != seenVersion || j['key'] != seenKeyOf(f32Files)) return null;
    return (seen: RecordingSeen.fromJson(j['seen']), why: j['why'] is String ? j['why'] as String : null);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Runs the pass when nothing is kept for these files, and keeps it with its minutes per activity (for the list).
Seen seeAndKeep(Directory filesDir, String id, List<File> f32Files) {
  final kept = keptSeen(filesDir, id, f32Files);
  if (kept != null) return kept;
  final key = seenKeyOf(f32Files);
  var why = whyNotSeen(f32Files);
  RecordingSeen? seen;
  if (why == null) {
    try {
      seen = seeRecording(f32Files);
      if (seen == null) why = 'Under a second of signal.';
    } on MissingSites catch (e) {
      why = e.message;
    } on HeaderError catch (e) {
      why = e.message;
    } on FileSystemException catch (e) {
      return (seen: null, why: 'Could not read the recording: ${e.message}'); // not kept: try again next time
    }
  }
  final f = seenFileFor(filesDir, id);
  try {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid.tmp');
    tmp.writeAsStringSync(
      jsonEncode({
        'version': seenVersion,
        'key': key,
        'why': why,
        'seen': seen?.toJson(),
        'minutes': seen == null ? null : seenMinutes(seen),
      }),
      flush: true,
    );
    tmp.renameSync(f.path);
  } on FileSystemException {
    // worked out again next time
  }
  return (seen: seen, why: why);
}

/// [seeAndKeep] in a background isolate: plain paths in, plain data out.
Future<Seen> seeInBackground(String filesPath, String id, List<String> f32Paths) => Isolate.run(
  () => seeAndKeep(Directory(filesPath), id, [for (final p in f32Paths) File(p)]),
  debugName: 'archive-seen',
);

/// Minutes per activity the pass found, by the activity rules (bands.dart): what the list shows.
Map<String, double> seenMinutes(RecordingSeen s) {
  double minutes(int epochs) => epochs * epochS / 60;
  var closed = 0, drowsy = 0, talking = 0, moving = 0, missing = 0;
  for (var i = 0; i < s.epochs; i++) {
    if (s.quality[i] == 'm') {
      missing++;
      continue;
    }
    if (s.eyes[i] == 'c') {
      closed++;
    } else if (s.level[i] == 'g' || s.level[i] == 'd') {
      drowsy++;
    }
    if (s.jaw[i] >= ActivityRule.talkingJaw) talking++;
    if (s.move[i] >= ActivityRule.movingS) moving++;
  }
  return {
    'eyes': minutes(closed),
    'drowsy': minutes(drowsy),
    'talking': minutes(talking),
    'moving': minutes(moving),
    'nosignal': minutes(missing),
  };
}

/// The activity rules (planning values, DECISIONS 700-709): set on no labelled day of the owner's yet.
abstract final class ActivityRule {
  /// An epoch with this many jaw bursts (both sides at once) is talking or chewing when awake: the night's wake had 34-38
  /// an hour (0.3 an epoch, docs/detectors.md), talking is near-continuous jaw muscle.
  static const int talkingJaw = 2;

  /// An epoch with this many seconds of movement is moving (the quality check's own "degraded by movement" line).
  static const int movingS = 3;

  /// Shortest band shown, in epochs, per activity; gaps of up to [joinEpochs] inside one are bridged.
  static const int minEyes = 2, minDrowsy = 2, minTalking = 2, minMoving = 1, minAsleep = 2, minMissing = 1;
  static const int joinEpochs = 1;
}

/// What the list knows of each kept pass, by recording id: the raw files' key it was made for, its minutes per activity
/// (null when it could not run) and why not. Read through a summary index (the passes themselves are tens of KB each).
Map<String, ({String key, Map<String, double>? minutes, String? why})> keptPasses(Directory filesDir) {
  final index = SummaryIndex(File('${filesDir.path}/cache/archive-seen-index.json'), version: seenVersion);
  final out = <String, ({String key, Map<String, double>? minutes, String? why})>{};
  final sums = index.summaries(Directory('${filesDir.path}/$seenFolder'), '.json', (f) {
    final j = jsonDecode(f.readAsStringSync());
    return j is Map && j['version'] == seenVersion ? {'key': j['key'], 'minutes': j['minutes'], 'why': j['why']} : null;
  });
  for (final e in sums.entries) {
    final v = e.value;
    if (v is! Map || v['key'] is! String) continue;
    final id = e.key.substring(0, e.key.length - '.json'.length);
    final m = v['minutes'];
    out[id] = (
      key: v['key'] as String,
      minutes: m is Map
          ? {
              for (final x in m.entries)
                if (x.key is String && x.value is num) x.key as String: (x.value as num).toDouble(),
            }
          : null,
      why: v['why'] is String ? v['why'] as String : null,
    );
  }
  return out;
}
