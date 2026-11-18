// Sound-for-states sessions on the phone (DECISIONS row 136): `files/sound-states/<stamp>.sound.json`, next to
// `files/recordings/`, inside the app's private folder (no backup, other apps cannot read it; rows 53, 57). One small
// JSON file per session: the plan (state, bed, beat and its path, pitch, depth, fades, loudness), how the headband was
// used, the quiet minute, when the sound started, faded and stopped and why, the readout per 30 s of sound and for the
// whole session, the drift-off detector's epochs (fall asleep), the events, the audio engine's report and your rating.
// Enough for a later stats engine to compare sounds per state; the format is in docs/data-format.md. The EEG itself
// is kept only for "fall asleep" with the headband, as a normal recording in `files/recordings/` (its stem is here),
// so it joins that night like the dream catcher's.
import 'dart:convert';
import 'dart:io';

import '../recorder/chunk_writer.dart' show fileStem;
import 'presets.dart';
import 'readout.dart';

/// The sessions folder for the app's recordings folder.
Directory soundStatesDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/sound-states');

/// How the headband took part.
abstract final class HeadbandUse {
  static const used = 'headband', soundOnly = 'sound only', nightRecording = 'night recording', notFound = 'not found';
  static const lost = 'lost';
  static const all = [used, soundOnly, nightRecording, notFound, lost];
}

/// How a session ended: the timer, the 45-minute cap, probably asleep, Stop, a failure, or still running.
abstract final class SoundEnd {
  static const time = 'time', cap = 'cap', asleep = 'asleep', stopped = 'stopped', failed = 'failed', running = 'running';
  static const all = [time, cap, asleep, stopped, failed, running];
}

typedef SoundEvent = ({int s, String text});

double? _num(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;
int? _int(Object? v) => v is int && v >= 0 ? v : null;

class SoundSession {
  SoundSession({
    required this.start,
    required this.plan,
    required this.headband,
    this.contact = const {},
    this.recording,
    this.soundStartS,
    this.baselineS = 0,
    this.fadeFromS,
    this.offAtS,
    this.endS = 0,
    this.end = SoundEnd.running,
    this.drift = const {},
    this.epochs = const [],
    this.summary,
    this.events = const [],
    this.stalls = 0,
    this.engine = const {},
    this.night,
    this.rating,
  });

  static const int version = 1;

  /// Lights off: the start of the quiet minute with the headband, the start of the sound without it. Every
  /// `...S` below is in seconds after it.
  final DateTime start;
  final SoundPlan plan;

  /// [HeadbandUse].
  final String headband;

  /// Contact at the start, ohms per channel (null: none).
  final Map<String, double?> contact;

  /// Stem of the session's EEG in `files/recordings/` (fall asleep with the headband), or null.
  final String? recording;

  /// When the sound started (null: it never did).
  final int? soundStartS;

  /// Clean seconds in the quiet minute (the readout compares with these; 0 without the headband).
  final int baselineS;

  /// When the fade started and when the sound was silent (null: stopped before).
  final int? fadeFromS;
  final int? offAtS;
  final double endS;

  /// [SoundEnd].
  final String end;

  /// The drift-off detector (fall asleep with the headband): baseline, drowsy and asleep seconds, one letter per
  /// 30 s epoch (b baseline, a awake, d drowsy, s probably asleep, - skipped).
  final Map<String, Object?> drift;

  /// The readout per 30 s of sound and for the whole sound (ratios to the quiet minute; null without one).
  final List<ReadSummary> epochs;
  final ReadSummary? summary;

  /// What happened when, in plain words (quiet minute, sound on, fading, probably asleep, headband dropped...).
  final List<SoundEvent> events;

  /// Times the sound ran dry for lack of data (a stall of the app); 0 is right.
  final int stalls;
  final Map<String, Object?> engine;

  /// Fall asleep with "then record the night": `started`, or why it did not start.
  final String? night;

  /// Your answer afterwards, 1 (not at all) to 5 (clearly): did it help you get there? Null: not answered.
  int? rating;

  String get stem => fileStem(start);
  String get fileName => '$stem.sound.json';

  Map<String, Object?> toJson() => {
    'version': version,
    'start': start.toIso8601String(),
    'plan': plan.toJson(),
    'headband': headband,
    'contact': contact,
    'recording': recording,
    'soundStartS': soundStartS,
    'baselineS': baselineS,
    'fadeFromS': fadeFromS,
    'offAtS': offAtS,
    'endS': (endS * 10).round() / 10,
    'end': end,
    'drift': drift,
    'epochs': [for (final e in epochs) e.toJson()],
    'summary': summary?.toJson(),
    'events': [for (final e in events) {'s': e.s, 'text': e.text}],
    'stalls': stalls,
    'engine': engine,
    'night': night,
    'rating': rating,
  };

  static SoundSession? fromJson(Object? j) {
    if (j is! Map || j['version'] != version) return null;
    final start = DateTime.tryParse('${j['start']}'), plan = SoundPlan.fromJson(j['plan']);
    final headband = j['headband'], end = j['end'], endS = _num(j['endS']), rating = j['rating'];
    final contact = j['contact'], epochs = j['epochs'], events = j['events'], rec = j['recording'], night = j['night'];
    if (start == null || plan == null || !HeadbandUse.all.contains(headband) || !SoundEnd.all.contains(end)) return null;
    if (endS == null || (rating != null && (rating is! int || rating < 1 || rating > 5))) return null;
    if (contact is! Map || epochs is! List || events is! List) return null;
    if ((rec != null && rec is! String) || (night != null && night is! String)) return null;
    final eps = <ReadSummary>[];
    for (final e in epochs) {
      final r = ReadSummary.fromJson(e);
      if (r == null) return null;
      eps.add(r);
    }
    final evs = <SoundEvent>[];
    for (final e in events) {
      if (e is! Map || e['s'] is! int || e['text'] is! String) return null;
      evs.add((s: e['s'] as int, text: e['text'] as String));
    }
    final summary = j['summary'] == null ? null : ReadSummary.fromJson(j['summary']);
    if (j['summary'] != null && summary == null) return null;
    final drift = j['drift'], engine = j['engine'];
    return SoundSession(
      start: start,
      plan: plan,
      headband: headband as String,
      contact: {for (final e in contact.entries) '${e.key}': e.value is num ? (e.value as num).toDouble() : null},
      recording: rec as String?,
      soundStartS: _int(j['soundStartS']),
      baselineS: _int(j['baselineS']) ?? 0,
      fadeFromS: _int(j['fadeFromS']),
      offAtS: _int(j['offAtS']),
      endS: endS,
      end: end as String,
      drift: drift is Map ? {for (final e in drift.entries) '${e.key}': e.value} : const {},
      epochs: eps,
      summary: summary,
      events: evs,
      stalls: _int(j['stalls']) ?? 0,
      engine: engine is Map ? {for (final e in engine.entries) '${e.key}': e.value} : const {},
      night: night as String?,
      rating: rating as int?,
    );
  }
}

class SoundStore {
  SoundStore(this.dir);
  final Directory dir;

  /// Writes the whole session (at the end, and again when you rate it).
  void save(SoundSession s) {
    dir.createSync(recursive: true);
    final f = File('${dir.path}/${s.fileName}'), tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(s.toJson()), flush: true);
    tmp.renameSync(f.path);
  }

  File get _settings => File('${dir.path}/settings.json');

  /// Your choice "Screen: Stays on" (default: the phone can be locked during a session, DECISIONS row 193).
  bool get screenStaysOn {
    try {
      final j = jsonDecode(_settings.readAsStringSync());
      return j is Map && j['screenStaysOn'] == true;
    } on FormatException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  set screenStaysOn(bool v) {
    dir.createSync(recursive: true);
    _settings.writeAsStringSync(jsonEncode({'screenStaysOn': v}), flush: true);
  }

  /// Every readable session, newest first; damaged or foreign files are skipped.
  List<SoundSession> list() {
    if (!dir.existsSync()) return const [];
    final out = <SoundSession>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.sound.json')) continue;
      try {
        final s = SoundSession.fromJson(jsonDecode(f.readAsStringSync()));
        if (s != null) out.add(s);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return out..sort((a, b) => b.start.compareTo(a.start));
  }
}
