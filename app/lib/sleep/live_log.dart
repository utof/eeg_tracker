// The night's live sleep model, written down for "Sleep so far" (DECISIONS 640-649): while the smart alarm, the lucid
// cues or the memory cues use the one live model (night_scorer.dart, DECISIONS 330), the recorder's isolate appends a
// line when the model starts, one per 30 s epoch it hands out, and one when it is freed, to
// `files/cache/live-stages/<stamp>.live` (one file per recorder process; never exported, like all of `files/cache/`).
// The screen reads it on demand: a model that runs now means "Sleep so far" waits (two models in one app would compete
// for memory and the guard's 700 MB, DECISIONS 236), and its epochs stand in for the minutes the waiting leaves
// unscored. Writing never throws: a full disk costs these lines, never the model or the recording.
//
//   on <unix ms> <who, + between>        the model started for them
//   e <epoch start, unix ms> <W 1 2 3 R -> <top probability>
//   off <unix ms>                       the model was freed
import 'dart:io';

import '../recorder/chunk_writer.dart' show fileStem;
import 'periods.dart' show gapStage;
import 'progress.dart' show cacheDirFor;

/// `files/cache/live-stages/`.
Directory liveStagesDirFor(String recordingsDir) => Directory('${cacheDirFor(recordingsDir).path}/live-stages');

const Map<String, String> _char = {'W': 'W', 'N1': '1', 'N2': '2', 'N3': '3', 'R': 'R', gapStage: '-'};
const Map<String, String> _stage = {'W': 'W', '1': 'N1', '2': 'N2', '3': 'N3', 'R': 'R', '-': gapStage};

/// How long after its last line a model still counts as running (it writes one every 30 s while it scores).
const Duration liveFresh = Duration(minutes: 3);

class LiveStageLog {
  LiveStageLog(this.dir, {DateTime Function()? clock}) : _now = clock ?? DateTime.now;
  final Directory dir;
  final DateTime Function() _now;
  File? _file;

  /// The model started for [who] ("smart alarm", "lucid cues").
  void on(List<String> who) => _add('on ${_now().millisecondsSinceEpoch} ${who.join('+')}');

  /// One epoch it handed out, starting at [epochStartMs] (unix ms).
  void epoch(int epochStartMs, String stage, double confidence) =>
      _add('e $epochStartMs ${_char[stage] ?? '-'} ${confidence.isFinite ? confidence.toStringAsFixed(3) : '0'}');

  /// The model was freed.
  void off() => _add('off ${_now().millisecondsSinceEpoch}');

  void _add(String line) {
    try {
      final f = _file ??= () {
        dir.createSync(recursive: true);
        return File('${dir.path}/${fileStem(_now())}.live');
      }();
      f.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // never worth the model or the recording
    }
  }
}

/// What the live model's lines say for a night: the stage of each epoch it handed out (by its start, unix ms), and who
/// uses it now (null: it is not running).
typedef LiveLook = ({Map<int, String> epochs, String? runningFor});

/// Reads the live model's lines from [fromMs] (the night's first sample) on. A file still ending in `on` or epochs
/// counts as running only while it was written within [fresh] of [nowMs] (a process Android ended leaves no `off`).
/// Files older than [keep] are removed. Unreadable lines are skipped.
LiveLook readLiveStages(
  Directory dir, {
  required int fromMs,
  required int nowMs,
  Duration fresh = liveFresh,
  Duration keep = const Duration(days: 2),
}) {
  final epochs = <int, String>{};
  if (!dir.existsSync()) return (epochs: epochs, runningFor: null);
  String? running;
  var newest = -1;
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.live')) continue;
    final FileStat st;
    try {
      st = f.statSync();
    } on FileSystemException {
      continue;
    }
    final modified = st.modified.millisecondsSinceEpoch;
    if (nowMs - modified > keep.inMilliseconds) {
      try {
        f.deleteSync();
      } on FileSystemException {
        // gone already
      }
      continue;
    }
    if (modified < fromMs) continue; // an earlier night's
    final List<String> lines;
    try {
      lines = f.readAsLinesSync();
    } on FileSystemException {
      continue;
    }
    String? who;
    for (final line in lines) {
      final w = line.split(' ');
      if (w.length >= 3 && w[0] == 'e') {
        final at = int.tryParse(w[1]), s = _stage[w[2]];
        if (at != null && s != null && at >= fromMs - 30000) epochs[at] = s;
      } else if (w.length >= 2 && w[0] == 'on') {
        who = w.length >= 3 ? w.sublist(2).join(' ').replaceAll('+', ' and ') : 'the live sleep model';
      } else if (w.isNotEmpty && w[0] == 'off') {
        who = null;
      }
    }
    if (modified > newest) {
      newest = modified;
      running = who != null && nowMs - modified <= fresh.inMilliseconds ? who : null;
    }
  }
  return (epochs: epochs, runningFor: running);
}
