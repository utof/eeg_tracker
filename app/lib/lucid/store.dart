// Lucid dream cues on disk (DECISIONS 307), in the app's private folder next to the recordings (no backup takes it,
// other apps cannot read it; Export data takes the whole folder by its "everything except" rule):
//   files/lucid/settings.json          {"on", "level" (the evening's loudness, 0-1 of the media volume), "mediaVolume",
//                                      "mediaVolumeMax", "levelSet", "changed"}; off by default
//   files/lucid/events.jsonl           one line per change: switched on or off, loudness set, plan frozen
//   files/lucid/practice.jsonl         one line per evening practice
//   files/lucid/sealed.json            the secret and the schedule of cue and silent nights (hidden until results)
//   files/lucid/plan.json              {"plan", "sha256"}: the frozen plan with the schedule's hash, before night 1
//   files/lucid/plays.jsonl            hidden too: one line per cue the phone was asked to play, with how it went
//   files/lucid/nights/<stamp>.json    one per night with the cues on, written by the night recorder: its number in
//                                      the test, the cue moments (the same on cue and silent nights), arousals, the
//                                      model's state; never which kind of night it is
//   files/lucid/mornings/<stamp>.json  the morning's answers
//   files/lucid/signals/<stamp>.json   the morning's search for dream signals over the night
//   files/lucid/cue.wav                the cue (written by the app; the night recorder plays it)
// <stamp> is the night's start (the recorder's first Start of the night), yyyy-MM-dd-HHmmss local time.
// Each JSON file is written under a temporary name and then renamed. A missing or damaged file reads as "off",
// "never" or "none".
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;
import 'plan.dart';

const String lucidFolder = 'lucid';

/// files/lucid for the recordings folder (files/recordings).
Directory lucidDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/$lucidFolder');

/// A night's name: its start, local time.
String nightStamp(int startMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(startMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

class LucidSettings {
  const LucidSettings({this.on = false, this.level, this.mediaVolume, this.mediaVolumeMax, this.levelSet});
  final bool on;

  /// The loudness heard in the evening practice, as a share of the phone's media volume; null until set.
  final double? level;
  final int? mediaVolume, mediaVolumeMax;
  final DateTime? levelSet;

  Map<String, Object?> toJson(DateTime changed) => {
    'on': on,
    'level': level,
    'mediaVolume': mediaVolume,
    'mediaVolumeMax': mediaVolumeMax,
    'levelSet': levelSet == null ? null : isoLocal(levelSet!),
    'changed': isoLocal(changed),
  };

  static LucidSettings fromJson(Object? j) {
    if (j is! Map) return const LucidSettings();
    final l = j['level'], mv = j['mediaVolume'], mm = j['mediaVolumeMax'];
    final level = l is num && l > 0 && l <= 1 ? l.toDouble() : null;
    return LucidSettings(
      on: j['on'] == true,
      level: level,
      mediaVolume: mv is int ? mv : null,
      mediaVolumeMax: mm is int ? mm : null,
      levelSet: DateTime.tryParse('${j['levelSet']}')?.toLocal(),
    );
  }
}

/// One cue moment of a night: when, its step (dB over the evening's level), its dream-sleep period, the live
/// reading that allowed it, and whether an arousal followed.
class CueMoment {
  const CueMoment({
    required this.atMs,
    required this.step,
    required this.period,
    required this.confidence,
    this.aroused = false,
  });
  final int atMs, step, period;
  final double confidence;
  final bool aroused;

  Map<String, Object?> toJson() => {
    'at': isoLocal(DateTime.fromMillisecondsSinceEpoch(atMs)),
    'atMs': atMs,
    'step': step,
    'period': period,
    'confidence': (confidence * 1000).round() / 1000,
    'aroused': aroused,
  };

  static CueMoment? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['atMs'], s = j['step'], p = j['period'], c = j['confidence'];
    if (a is! int || s is! int || p is! int || c is! num) return null;
    return CueMoment(atMs: a, step: s, period: p, confidence: c.toDouble(), aroused: j['aroused'] == true);
  }
}

/// A night with the cues on, as the night recorder keeps it.
class LucidNightRecord {
  const LucidNightRecord({
    required this.startMs,
    required this.index,
    required this.cuesFromMs,
    this.phase = 'waiting',
    this.cues = const [],
    this.arousals = const [],
    this.stops = const [],
    this.running = false,
    this.off,
    this.model,
    this.level,
    this.mediaVolume,
  });

  final int startMs;

  /// The night's number in the self-test (from 0).
  final int index;
  final int cuesFromMs;

  /// waiting (before the model's hour), listening (the model runs), done (the night's cues are over), off.
  final String phase;
  final List<CueMoment> cues;
  final List<int> arousals;
  final List<(int, String)> stops;

  /// The live model was running when this was saved: a process that finds it so did not end cleanly while the
  /// model ran, so the cues stay off for the rest of the night.
  final bool running;

  /// Why the cues were switched off, in a sentence.
  final String? off;

  /// The model's state: mode, calls, median and largest time.
  final Map<String, Object?>? model;
  final double? level;
  final int? mediaVolume;

  String get stamp => nightStamp(startMs);

  LucidNightRecord copyWith({
    String? phase,
    List<CueMoment>? cues,
    List<int>? arousals,
    List<(int, String)>? stops,
    bool? running,
    String? off,
    Map<String, Object?>? model,
    int? cuesFromMs,
    double? level,
    int? mediaVolume,
  }) => LucidNightRecord(
    startMs: startMs,
    index: index,
    cuesFromMs: cuesFromMs ?? this.cuesFromMs,
    phase: phase ?? this.phase,
    cues: cues ?? this.cues,
    arousals: arousals ?? this.arousals,
    stops: stops ?? this.stops,
    running: running ?? this.running,
    off: off ?? this.off,
    model: model ?? this.model,
    level: level ?? this.level,
    mediaVolume: mediaVolume ?? this.mediaVolume,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'start': isoLocal(DateTime.fromMillisecondsSinceEpoch(startMs)),
    'startMs': startMs,
    'index': index,
    'cuesFrom': isoLocal(DateTime.fromMillisecondsSinceEpoch(cuesFromMs)),
    'cuesFromMs': cuesFromMs,
    'phase': phase,
    'cues': [for (final c in cues) c.toJson()],
    'arousalsMs': arousals,
    'stops': [
      for (final (ms, why) in stops) {'atMs': ms, 'why': why},
    ],
    'running': running,
    'off': off,
    'model': model,
    'level': level,
    'mediaVolume': mediaVolume,
  };

  static LucidNightRecord? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final s = j['startMs'], i = j['index'], f = j['cuesFromMs'], c = j['cues'], a = j['arousalsMs'];
    if (s is! int || i is! int || f is! int || c is! List || a is! List) return null;
    final st = j['stops'];
    final l = j['level'], mv = j['mediaVolume'], m = j['model'];
    return LucidNightRecord(
      startMs: s,
      index: i,
      cuesFromMs: f,
      phase: '${j['phase'] ?? 'waiting'}',
      cues: [for (final x in c) ?CueMoment.fromJson(x)],
      arousals: [for (final x in a) ?(x is int ? x : null)],
      stops: [
        if (st is List)
          for (final x in st)
            if (x is Map && x['atMs'] is int && x['why'] is String) (x['atMs'] as int, x['why'] as String),
      ],
      running: j['running'] == true,
      off: j['off'] as String?,
      model: m is Map ? m.cast<String, Object?>() : null,
      level: l is num ? l.toDouble() : null,
      mediaVolume: mv is int ? mv : null,
    );
  }
}

/// One evening practice.
class PracticeRecord {
  const PracticeRecord({required this.start, required this.end, required this.cues, required this.completed});
  final DateTime start, end;
  final int cues;
  final bool completed;

  Map<String, Object?> toJson() => {
    'start': isoLocal(start),
    'end': isoLocal(end),
    'cues': cues,
    'completed': completed,
  };

  static PracticeRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = DateTime.tryParse('${j['start']}')?.toLocal(), e = DateTime.tryParse('${j['end']}')?.toLocal();
    final c = j['cues'];
    if (s == null || e == null || c is! int) return null;
    return PracticeRecord(start: s, end: e, cues: c, completed: j['completed'] == true);
  }
}

/// A dream signal found in the morning: when, what (lrlr or clench), the full-night scoring's stage there, and how
/// long after the nearest earlier cue moment (seconds; null when none within 2 minutes).
class FoundSignal {
  const FoundSignal({required this.atMs, required this.kind, this.pairs, this.stage, this.afterCueS});
  final int atMs;
  final String kind;
  final int? pairs;
  final String? stage;
  final int? afterCueS;

  Map<String, Object?> toJson() => {
    'at': isoLocal(DateTime.fromMillisecondsSinceEpoch(atMs)),
    'atMs': atMs,
    'kind': kind,
    'pairs': pairs,
    'stage': stage,
    'afterCueS': afterCueS,
  };

  static FoundSignal? fromJson(Object? j) {
    if (j is! Map || j['atMs'] is! int || (j['kind'] != 'lrlr' && j['kind'] != 'clench')) return null;
    final p = j['pairs'], a = j['afterCueS'];
    return FoundSignal(
      atMs: j['atMs'] as int,
      kind: j['kind'] as String,
      pairs: p is int ? p : null,
      stage: j['stage'] as String?,
      afterCueS: a is int ? a : null,
    );
  }

  bool get inDreamSleep => stage == 'R';
}

/// The morning's search over a night.
class NightSignals {
  const NightSignals({
    required this.made,
    required this.signals,
    required this.sweepUv,
    this.clenchX,
    this.staged = true,
  });
  final DateTime made;
  final List<FoundSignal> signals;
  final double sweepUv;

  /// The calibrated clench line used (null: no hands-free calibration with a double clench, no clench search).
  final double? clenchX;

  /// Stages came from the night's sleep report (false: not scored yet, stages unknown).
  final bool staged;

  int get inDreamSleep => signals.where((s) => s.inDreamSleep).length;

  Map<String, Object?> toJson() => {
    'version': 1,
    'made': isoLocal(made),
    'sweepUv': sweepUv,
    'clenchX': clenchX,
    'staged': staged,
    'signals': [for (final s in signals) s.toJson()],
  };

  static NightSignals? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final m = DateTime.tryParse('${j['made']}')?.toLocal(), s = j['signals'], w = j['sweepUv'], c = j['clenchX'];
    if (m == null || s is! List || w is! num) return null;
    return NightSignals(
      made: m,
      signals: [for (final x in s) ?FoundSignal.fromJson(x)],
      sweepUv: w.toDouble(),
      clenchX: c is num ? c.toDouble() : null,
      staged: j['staged'] != false,
    );
  }
}

/// The test's frozen part, as read back.
typedef LucidTestFiles = ({LucidSealed sealed, LucidPlan plan, String planSha});

class LucidStore {
  LucidStore(this.dir);
  final Directory dir;

  File get _settings => File('${dir.path}/settings.json');
  File get _events => File('${dir.path}/events.jsonl');
  File get _practice => File('${dir.path}/practice.jsonl');
  File get _sealed => File('${dir.path}/sealed.json');
  File get _plan => File('${dir.path}/plan.json');
  File get _plays => File('${dir.path}/plays.jsonl');
  Directory get nightsDir => Directory('${dir.path}/nights');
  Directory get morningsDir => Directory('${dir.path}/mornings');
  Directory get signalsDir => Directory('${dir.path}/signals');
  File get cueWav => File('${dir.path}/cue.wav');

  Object? _read(File f) {
    try {
      return jsonDecode(f.readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void _write(File f, Object j) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp')..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(j), flush: true);
    tmp.renameSync(f.path);
  }

  void _append(File f, Map<String, Object?> j) {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('${jsonEncode(j)}\n', mode: FileMode.append, flush: true);
  }

  void event(DateTime at, String text) => _append(_events, {'at': isoLocal(at), 'event': text});

  LucidSettings settings() => LucidSettings.fromJson(_read(_settings));

  void saveSettings(LucidSettings s, DateTime at) => _write(_settings, s.toJson(at));

  void setOn(bool on, DateTime at) {
    final s = settings();
    saveSettings(
      LucidSettings(
        on: on,
        level: s.level,
        mediaVolume: s.mediaVolume,
        mediaVolumeMax: s.mediaVolumeMax,
        levelSet: s.levelSet,
      ),
      at,
    );
    event(at, on ? 'switched on' : 'switched off');
  }

  void setLevel(double level, DateTime at, {int? mediaVolume, int? mediaVolumeMax}) {
    final s = settings();
    saveSettings(
      LucidSettings(on: s.on, level: level, mediaVolume: mediaVolume, mediaVolumeMax: mediaVolumeMax, levelSet: at),
      at,
    );
    event(
      at,
      'loudness set to ${level.toStringAsFixed(3)} of the media volume'
      '${mediaVolume == null ? '' : ' (media volume $mediaVolume of $mediaVolumeMax)'}',
    );
  }

  /// The sealed schedule and the frozen plan, when both are there and readable.
  LucidTestFiles? test() {
    final s = LucidSealed.fromJson(_read(_sealed));
    final j = _read(_plan);
    if (s == null || j is! Map || j['sha256'] is! String) return null;
    final p = LucidPlan.fromJson(j['plan']);
    return p == null ? null : (sealed: s, plan: p, planSha: j['sha256'] as String);
  }

  /// The schedule and the plan, drawn and frozen once (the first caller writes them; later calls read them back).
  LucidTestFiles ensureTest(DateTime now, {String? salt}) {
    final have = test();
    if (have != null) return have;
    final sealed = LucidSealed.draw(salt ?? newSalt());
    final plan = LucidPlan(frozen: now, scheduleSha256: sealed.sha);
    _write(_sealed, sealed.toJson());
    _write(_plan, {'plan': plan.toJson(), 'sha256': plan.sha});
    event(now, 'plan frozen (schedule ${sealed.sha.substring(0, 12)}...)');
    return (sealed: sealed, plan: plan, planSha: plan.sha);
  }

  File nightFile(int startMs) => File('${nightsDir.path}/${nightStamp(startMs)}.json');

  LucidNightRecord? night(int startMs) => LucidNightRecord.fromJson(_read(nightFile(startMs)));

  void saveNight(LucidNightRecord r) => _write(nightFile(r.startMs), r.toJson());

  /// Every night with the cues on, oldest first.
  List<LucidNightRecord> nights() {
    if (!nightsDir.existsSync()) return const [];
    final out = [
      for (final f in nightsDir.listSync().whereType<File>())
        if (f.path.endsWith('.json')) ?LucidNightRecord.fromJson(_read(f)),
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));
    return out;
  }

  /// The number the next night gets in the test.
  int nextIndex() => nights().fold(0, (n, r) => r.index >= n ? r.index + 1 : n);

  void addPlay(int atMs, int index, bool ok, String? error) => _append(_plays, {
    'at': isoLocal(DateTime.fromMillisecondsSinceEpoch(atMs)),
    'night': index,
    'ok': ok,
    'error': ?error,
  });

  void addPractice(PracticeRecord p) => _append(_practice, p.toJson());

  List<PracticeRecord> practices() {
    try {
      return [
        for (final l in _practice.readAsLinesSync())
          if (l.trim().isNotEmpty) ?PracticeRecord.fromJson(_decode(l)),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  static Object? _decode(String line) {
    try {
      return jsonDecode(line);
    } on FormatException {
      return null;
    }
  }

  File _morning(String stamp) => File('${morningsDir.path}/$stamp.json');

  LucidAnswers? answers(String stamp) {
    final j = _read(_morning(stamp));
    return j is Map ? LucidAnswers.fromJson(j['answers']) : null;
  }

  void saveAnswers(String stamp, LucidAnswers a, DateTime at) =>
      _write(_morning(stamp), {'night': stamp, 'answered': isoLocal(at), 'answers': a.toJson()});

  File _signals(String stamp) => File('${signalsDir.path}/$stamp.json');

  NightSignals? signals(String stamp) => NightSignals.fromJson(_read(_signals(stamp)));

  void saveSignals(String stamp, NightSignals s) => _write(_signals(stamp), s.toJson());
}
