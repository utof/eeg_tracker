// Memory cues on disk (DECISIONS 506), in the app's private folder next to the recordings (no backup takes it, other
// apps cannot read it; Export data takes the whole folder by its "everything except" rule):
//   files/memory_cues/settings.json          {"on", "changed"}; off by default
//   files/memory_cues/events.jsonl           one line per change: switched on or off, plan frozen
//   files/memory_cues/sessions/<id>.json     one per evening (task.dart `MemorySession`): the objects, their places
//                                            and sounds, the learning, the evening test, each sound's loudness
//   files/memory_cues/sealed.json            the secret, the schedule of sound and silent nights and each night's
//                                            half (hidden until results)
//   files/memory_cues/plan.json              {"plan", "sha256"}: the frozen plan with the schedule's hash
//   files/memory_cues/plays.jsonl            hidden too: one line per sound the phone was asked to play
//   files/memory_cues/nights/<stamp>.json    one per night in the test, written by the night recorder: its number,
//                                            its session, the cue moments (the same on sound and silent nights),
//                                            arousals, the model's state; never which kind of night or which half
//   files/memory_cues/mornings/<stamp>.json  the morning test and "did you hear a sound?"
//   files/memory_cues/sound_a.wav, sound_b.wav  the two sounds (written by the app; the recorder plays them)
// <stamp> is the night's start, yyyy-MM-dd-HHmmss local time. Each JSON file is written under a temporary name and
// then renamed. A missing or damaged file reads as "off", "never" or "none".
import 'dart:convert';
import 'dart:io';

import '../cache/file_summaries.dart' show JsonMemo;
import '../cues/night_cues.dart' show CueMoment;
import '../lucid/store.dart' show nightStamp;
import '../sleep/report.dart' show isoLocal;
import 'plan.dart';
import 'sounds.dart';
import 'task.dart';

const String memoryFolder = 'memory_cues';

/// A session counts for a night that starts at most this long after the session was complete.
const Duration sessionFreshFor = Duration(hours: 3);

/// files/memory_cues for the recordings folder (files/recordings).
Directory memoryDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/$memoryFolder');

/// A night in the test, as the night recorder keeps it.
class MemoryNightRecord {
  const MemoryNightRecord({
    required this.startMs,
    required this.index,
    required this.session,
    required this.cuesFromMs,
    this.phase = 'waiting',
    this.cues = const [],
    this.arousals = const [],
    this.stops = const [],
    this.running = false,
    this.off,
    this.model,
    this.mediaVolume,
  });

  final int startMs;

  /// The night's number in the self-test (from 0) and the evening session it cues.
  final int index;
  final String session;
  final int cuesFromMs;

  /// waiting (before the model's first batch), listening (the model runs), done (the night's cues are over), ended
  /// (the night stopped first), off.
  final String phase;
  final List<CueMoment> cues;
  final List<int> arousals;
  final List<(int, String)> stops;

  /// The live model was running when this was saved: a process that finds it so did not end cleanly while the
  /// model ran, so the cues stay off for the rest of the night.
  final bool running;

  /// Why the cues were switched off, in a sentence.
  final String? off;
  final Map<String, Object?>? model;
  final int? mediaVolume;

  String get stamp => nightStamp(startMs);

  MemoryNightRecord copyWith({
    String? phase,
    int? cuesFromMs,
    List<CueMoment>? cues,
    List<int>? arousals,
    List<(int, String)>? stops,
    bool? running,
    String? off,
    Map<String, Object?>? model,
    int? mediaVolume,
  }) => MemoryNightRecord(
    startMs: startMs,
    index: index,
    session: session,
    cuesFromMs: cuesFromMs ?? this.cuesFromMs,
    phase: phase ?? this.phase,
    cues: cues ?? this.cues,
    arousals: arousals ?? this.arousals,
    stops: stops ?? this.stops,
    running: running ?? this.running,
    off: off ?? this.off,
    model: model ?? this.model,
    mediaVolume: mediaVolume ?? this.mediaVolume,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'start': isoLocal(DateTime.fromMillisecondsSinceEpoch(startMs)),
    'startMs': startMs,
    'index': index,
    'session': session,
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
    'mediaVolume': mediaVolume,
  };

  static MemoryNightRecord? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final s = j['startMs'], i = j['index'], se = j['session'], f = j['cuesFromMs'], c = j['cues'], a = j['arousalsMs'];
    if (s is! int || i is! int || se is! String || f is! int || c is! List || a is! List) return null;
    final st = j['stops'], m = j['model'], mv = j['mediaVolume'];
    return MemoryNightRecord(
      startMs: s,
      index: i,
      session: se,
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
      mediaVolume: mv is int ? mv : null,
    );
  }
}

/// A morning test: where each object was put, and whether a sound was heard in the night (no / yes / woke / unsure).
class MemoryMorning {
  const MemoryMorning({required this.session, required this.made, required this.taps, this.heard});
  final String session;
  final DateTime made;
  final Map<String, BoardPoint> taps;
  final String? heard;

  static const heardWords = ['no', 'yes', 'woke', 'unsure'];

  Map<String, Object?> toJson() => {
    'version': 1,
    'session': session,
    'made': isoLocal(made),
    'taps': {
      for (final e in taps.entries) e.key: [e.value.x, e.value.y],
    },
    'heard': heard,
  };

  static MemoryMorning? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final s = j['session'], m = DateTime.tryParse('${j['made']}')?.toLocal(), h = j['heard'];
    if (s is! String || m == null) return null;
    return MemoryMorning(
      session: s,
      made: m,
      taps: pointsFromJson(j['taps']),
      heard: heardWords.contains(h) ? h as String : null,
    );
  }
}

/// The test's frozen part, as read back.
typedef MemoryTestFiles = ({MemorySealed sealed, MemoryPlan plan, String planSha});

class MemoryStore {
  MemoryStore(this.dir);
  final Directory dir;

  File get _settings => File('${dir.path}/settings.json');
  File get _events => File('${dir.path}/events.jsonl');
  File get _sealed => File('${dir.path}/sealed.json');
  File get _plan => File('${dir.path}/plan.json');
  File get _plays => File('${dir.path}/plays.jsonl');
  Directory get sessionsDir => Directory('${dir.path}/sessions');
  Directory get nightsDir => Directory('${dir.path}/nights');
  Directory get morningsDir => Directory('${dir.path}/mornings');

  /// The two sound files (sound 0, sound 1).
  List<File> get soundFiles => [for (final n in memorySoundFiles) File('${dir.path}/$n')];

  /// Decoded again only when the file changed (the night screen's line, DECISIONS 620-629).
  Object? _read(File f) => JsonMemo.read(f);

  void _write(File f, Object j) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp')..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(j), flush: true);
    tmp.renameSync(f.path);
  }

  void _append(File f, Map<String, Object?> j) {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('${jsonEncode(j)}\n', mode: FileMode.append, flush: true);
  }

  List<T> _all<T>(Directory d, T? Function(Object? j) parse) {
    if (!d.existsSync()) return [];
    return [
      for (final f in d.listSync().whereType<File>())
        if (f.path.endsWith('.json')) ?parse(_read(f)),
    ];
  }

  void event(DateTime at, String text) => _append(_events, {'at': isoLocal(at), 'event': text});

  bool _on() {
    final j = _read(_settings);
    return j is Map && j['on'] == true;
  }

  ({bool on}) settings() => (on: _on());

  void setOn(bool on, DateTime at) {
    _write(_settings, {'on': on, 'changed': isoLocal(at)});
    event(at, on ? 'switched on' : 'switched off');
  }

  File _session(String id) => File('${sessionsDir.path}/$id.json');

  void saveSession(MemorySession s) => _write(_session(s.id), s.toJson());

  MemorySession? session(String id) => MemorySession.fromJson(_read(_session(id)));

  /// Every session, oldest first.
  List<MemorySession> sessions() => _all(sessionsDir, MemorySession.fromJson)..sort((a, b) => a.made.compareTo(b.made));

  /// The session a night starting at [nightStartMs] cues: the newest complete one finished in the
  /// [sessionFreshFor] before the start (or within 10 minutes after it), unless another night already uses it.
  MemorySession? freshSession(int nightStartMs) {
    final used = {
      for (final r in nights())
        if (r.startMs != nightStartMs) r.session,
    };
    MemorySession? best;
    for (final s in sessions()) {
      if (!s.isComplete || used.contains(s.id)) continue;
      final age = nightStartMs - s.completed!.millisecondsSinceEpoch;
      if (age > sessionFreshFor.inMilliseconds || age < -const Duration(minutes: 10).inMilliseconds) continue;
      if (best == null || s.completed!.isAfter(best.completed!)) best = s;
    }
    return best;
  }

  /// The sealed schedule and the frozen plan, when both are there and readable.
  MemoryTestFiles? test() {
    final s = MemorySealed.fromJson(_read(_sealed));
    final j = _read(_plan);
    if (s == null || j is! Map || j['sha256'] is! String) return null;
    final p = MemoryPlan.fromJson(j['plan']);
    return p == null ? null : (sealed: s, plan: p, planSha: j['sha256'] as String);
  }

  /// The schedule and the plan, drawn and frozen once (the first caller writes them; later calls read them back).
  MemoryTestFiles ensureTest(DateTime now, {String? salt}) {
    final have = test();
    if (have != null) return have;
    final sealed = MemorySealed.draw(salt ?? newSalt());
    final plan = MemoryPlan(frozen: now, scheduleSha256: sealed.sha);
    _write(_sealed, sealed.toJson());
    _write(_plan, {'plan': plan.toJson(), 'sha256': plan.sha});
    event(now, 'plan frozen (schedule ${sealed.sha.substring(0, 12)}...)');
    return (sealed: sealed, plan: plan, planSha: plan.sha);
  }

  File nightFile(int startMs) => File('${nightsDir.path}/${nightStamp(startMs)}.json');

  MemoryNightRecord? night(int startMs) => MemoryNightRecord.fromJson(_read(nightFile(startMs)));

  void saveNight(MemoryNightRecord r) => _write(nightFile(r.startMs), r.toJson());

  /// Every night in the test, oldest first.
  List<MemoryNightRecord> nights() =>
      _all(nightsDir, MemoryNightRecord.fromJson)..sort((a, b) => a.startMs.compareTo(b.startMs));

  /// The number the next night gets in the test.
  int nextIndex() => nights().fold(0, (n, r) => r.index >= n ? r.index + 1 : n);

  void addPlay(int atMs, int index, int sound, bool ok, String? error) => _append(_plays, {
    'at': isoLocal(DateTime.fromMillisecondsSinceEpoch(atMs)),
    'night': index,
    'sound': sound,
    'ok': ok,
    'error': ?error,
  });

  File _morning(String stamp) => File('${morningsDir.path}/$stamp.json');

  MemoryMorning? morning(String stamp) => MemoryMorning.fromJson(_read(_morning(stamp)));

  void saveMorning(String stamp, MemoryMorning m) => _write(_morning(stamp), m.toJson());

  /// Writes the two sound files if missing or changed.
  List<File> ensureSounds() => ensureMemorySounds(dir);
}
