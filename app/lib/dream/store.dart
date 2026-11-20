// Dream catcher sessions on the phone (DECISIONS rows 112-114): `files/dream-catcher/` next to `files/recordings/`,
// inside the app's private folder (no backup, other apps cannot read it; rows 53, 57). Per session:
//   <stamp>.dream.json    the rounds: when and why each question came, the answer's file, length and end, the
//                         "were you drifting?" tap, your note; the drift-off detector's epochs; how it ended
//   <stamp>-r<n>.wav      your spoken answer to round n (16 kHz mono)
// Your own prompts: `files/dream-catcher/prompts/theme.wav` and `question.wav` (recorded once, re-recordable).
// The EEG of the session is not here: it is a normal recording in `files/recordings/` (its stem is in the JSON),
// so it joins that night, is scored with it and is exported with it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../cache/file_summaries.dart' show firstParsed, newestFirst;
import '../recorder/chunk_writer.dart' show fileStem;
import 'rounds.dart';
import 'voice.dart';

/// The dream catcher's folder for the app's recordings folder.
Directory dreamDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/dream-catcher');

/// The two prompts you record yourself.
enum PromptKind {
  /// Played as you drift off: at lights off and after each answer ("Think of a tree... and drift off").
  theme,

  /// Played at each round's moment ("What is going through your mind?").
  question,
}

/// What happens when the rounds are done or the 45 minutes are up.
enum DreamEnding {
  /// A gentle rising tone; the answers are on the screen.
  wake,

  /// No tone: the night recording starts by itself.
  sleep,
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

double? _num(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;

class DreamRound {
  DreamRound({
    required this.n,
    required this.atS,
    required this.at,
    required this.cause,
    required this.state,
    required this.answerFile,
    required this.answerS,
    required this.voiceS,
    required this.end,
    required this.drifting,
    required this.endS,
    this.note = '',
  });

  /// 1, 2, ...
  final int n;

  /// When the question played: seconds after lights off, and the clock time.
  final double atS;
  final DateTime at;
  final DreamCause cause;

  /// The drift-off detector's state then (`baseline`, `awake`, `drowsy`, `asleep`).
  final String state;

  /// `<stamp>-r<n>.wav` in the session's folder, or null when nothing was recorded.
  final String? answerFile;

  /// Seconds recorded and seconds with a voice.
  final double answerS;
  final double voiceS;
  final AnswerEnd end;

  /// The one-tap answer to "were you drifting?"; null when not answered.
  final bool? drifting;

  /// When the round was over (s after lights off): the next one waits from here.
  final double endS;

  /// Typed afterwards.
  String note;

  Map<String, Object?> toJson() => {
    'n': n,
    'atS': (atS * 10).round() / 10,
    'at': at.toIso8601String(),
    'cause': cause.name,
    'state': state,
    'answerFile': answerFile,
    'answerS': (answerS * 10).round() / 10,
    'voiceS': (voiceS * 10).round() / 10,
    'end': end.name,
    'drifting': drifting,
    'endS': (endS * 10).round() / 10,
    'note': note,
  };

  static DreamRound? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['n'], at = DateTime.tryParse('${j['at']}'), atS = _num(j['atS']);
    final cause = _byName(DreamCause.values, j['cause']), end = _byName(AnswerEnd.values, j['end']);
    final answerS = _num(j['answerS']), voiceS = _num(j['voiceS']), file = j['answerFile'], drifting = j['drifting'];
    final endS = _num(j['endS']);
    final state = j['state'], note = j['note'];
    if (n is! int || n < 1 || at == null || atS == null || cause == null || end == null) return null;
    if (answerS == null || voiceS == null || endS == null || state is! String) return null;
    if (file != null && (file is! String || file.contains('/') || !file.endsWith('.wav'))) return null;
    if (drifting != null && drifting is! bool) return null;
    return DreamRound(
      n: n,
      atS: atS,
      at: at,
      cause: cause,
      state: state,
      answerFile: file as String?,
      answerS: answerS,
      voiceS: voiceS,
      end: end,
      drifting: drifting as bool?,
      endS: endS,
      note: note is String ? note : '',
    );
  }
}

/// How a session ended.
abstract final class DreamEnd {
  static const rounds = 'rounds done', cap = 'time up', stopped = 'stopped', running = 'running';
}

class DreamSession {
  DreamSession({
    required this.start,
    required this.plannedRounds,
    required this.ending,
    required this.prompts,
    required this.recording,
    required this.firstTimerS,
    this.baselineS,
    this.rounds = const [],
    this.endS = 0,
    this.endWhy = DreamEnd.running,
    this.drift = const {},
    this.night,
  });

  static const int version = 1;

  /// Lights off (the first sample).
  final DateTime start;
  final int plannedRounds;
  final DreamEnding ending;

  /// Per prompt: `own` (your recording) or `tone` (the built-in fallback).
  final Map<String, String> prompts;

  /// Stem of the session's EEG in `files/recordings/`, or null when it could not be written.
  final String? recording;

  /// Round 1's timer (s after lights off).
  final int firstTimerS;

  /// When the eyes-closed baseline was complete (s after lights off); null if it never was.
  final int? baselineS;
  final List<DreamRound> rounds;

  /// Seconds after lights off when it ended, and why (`DreamEnd`).
  final double endS;
  final String endWhy;

  /// The drift-off detector: baseline, first drowsy and onset seconds, and one letter per 30 s epoch
  /// (b baseline, a awake, d drowsy, s probably asleep, - skipped).
  final Map<String, Object?> drift;

  /// With the sleep ending: `started`, or why the night recording did not start.
  final String? night;

  String get stem => fileStem(start);
  String get fileName => '$stem.dream.json';

  /// Answers with something recorded.
  int get answers => rounds.where((r) => r.answerFile != null).length;

  Map<String, Object?> toJson() => {
    'version': version,
    'start': start.toIso8601String(),
    'plannedRounds': plannedRounds,
    'ending': ending.name,
    'prompts': prompts,
    'recording': recording,
    'firstTimerS': firstTimerS,
    'baselineS': baselineS,
    'rounds': [for (final r in rounds) r.toJson()],
    'endS': (endS * 10).round() / 10,
    'end': endWhy,
    'drift': drift,
    'night': night,
  };

  static DreamSession? fromJson(Object? j) {
    if (j is! Map || j['version'] != version) return null;
    final start = DateTime.tryParse('${j['start']}'), planned = j['plannedRounds'];
    final ending = _byName(DreamEnding.values, j['ending']), prompts = j['prompts'], rec = j['recording'];
    final timer = j['firstTimerS'], baseline = j['baselineS'], rounds = j['rounds'], endS = _num(j['endS']);
    final end = j['end'], drift = j['drift'], night = j['night'];
    if (start == null || planned is! int || planned < 1 || ending == null || prompts is! Map) return null;
    if (timer is! int || timer < 0 || (baseline != null && baseline is! int) || rounds is! List) return null;
    if (endS == null || end is! String || (rec != null && rec is! String) || (night != null && night is! String)) {
      return null;
    }
    final rs = <DreamRound>[];
    for (final r in rounds) {
      final round = DreamRound.fromJson(r);
      if (round == null) return null;
      rs.add(round);
    }
    return DreamSession(
      start: start,
      plannedRounds: planned,
      ending: ending,
      prompts: {for (final e in prompts.entries) '${e.key}': '${e.value}'},
      recording: rec as String?,
      firstTimerS: timer,
      baselineS: baseline as int?,
      rounds: rs,
      endS: endS,
      endWhy: end,
      drift: drift is Map ? {for (final e in drift.entries) '${e.key}': e.value} : const {},
      night: night as String?,
    );
  }
}

class DreamStore {
  DreamStore(this.dir);
  final Directory dir;

  Directory get promptsDir => Directory('${dir.path}/prompts');

  /// Your recording of [kind], whether or not it exists yet.
  File promptFile(PromptKind kind) => File('${promptsDir.path}/${kind.name}.wav');

  /// Your recording of [kind] when there is one with sound in it, else null (the tone plays).
  String? promptPath(PromptKind kind) {
    final f = promptFile(kind);
    return f.existsSync() && (wavSeconds(f) ?? 0) > 0.2 ? f.path : null;
  }

  /// Where round [n]'s answer of the session [stem] goes.
  File answerFile(String stem, int n) => File('${dir.path}/$stem-r$n.wav');

  /// Writes the session (whole file each time: written after every round and when you type a note).
  void save(DreamSession s) {
    dir.createSync(recursive: true);
    final f = File('${dir.path}/${s.fileName}'), tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(s.toJson()), flush: true);
    tmp.renameSync(f.path);
  }

  /// Every readable session, newest first; damaged or foreign files are skipped.
  List<DreamSession> list() {
    if (!dir.existsSync()) return const [];
    final out = <DreamSession>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.dream.json')) continue;
      try {
        final s = DreamSession.fromJson(jsonDecode(f.readAsStringSync()));
        if (s != null) out.add(s);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return out..sort((a, b) => b.start.compareTo(a.start));
  }

  /// The newest readable session, found by its file name (its start): the night screen's line opens this one file,
  /// and none while it is unchanged (DECISIONS 620-629).
  DreamSession? newest() => firstParsed(newestFirst(dir, '.dream.json'), DreamSession.fromJson);
}

/// Round 1's latency in earlier sessions where the detector, not the timer, asked (minutes after lights off):
/// the dream catcher's own "usual time to drift off" for the timer, once there are 3 (dreamFallbackS).
List<double> earlierLatenciesMin(List<DreamSession> sessions) => [
  for (final s in sessions)
    if (s.rounds.isNotEmpty && s.rounds.first.cause == DreamCause.drowsy) s.rounds.first.atS / 60,
];

/// Seconds of sound in a PCM WAV file (its `fmt ` and `data` chunks), or null when it is not one.
double? wavSeconds(File f) {
  try {
    final raf = f.openSync();
    try {
      final head = raf.readSync(4096);
      return _wavSeconds(ByteData.sublistView(head), raf.lengthSync());
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}

double? _wavSeconds(ByteData b, int fileBytes) {
  String tag(int at) => String.fromCharCodes([for (var i = 0; i < 4; i++) b.getUint8(at + i)]);
  if (b.lengthInBytes < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  int? byteRate;
  var at = 12;
  while (at + 8 <= b.lengthInBytes) {
    final id = tag(at), size = b.getUint32(at + 4, Endian.little);
    if (id == 'fmt ' && at + 16 <= b.lengthInBytes) byteRate = b.getUint32(at + 16, Endian.little);
    if (id == 'data') {
      if (byteRate == null || byteRate == 0) return null;
      // a recorder stopped hard may leave the size unset: count what is in the file
      final data = size == 0 || size == 0xFFFFFFFF || at + 8 + size > fileBytes ? fileBytes - at - 8 : size;
      return data / byteRate;
    }
    at += 8 + size + (size & 1);
  }
  return null;
}
