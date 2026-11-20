// Nap coach sessions on the phone: `files/naps/<stamp>.nap.json` next to `files/recordings/`, inside the app's
// private folder (no backup; DECISIONS rows 53, 57), one per nap: the length you picked, how and why it ended, the
// drift-off detector's onset, the live stages (one letter per 30 s epoch) and how the sleep model ran. The nap's EEG
// is a normal recording in `files/recordings/` (its stem is in the file), so it joins that day's "night" by the
// chain rule, is scored in full afterwards and exported with it.
import 'dart:convert';
import 'dart:io';

import '../cache/file_summaries.dart' show firstParsed, newestFirst;
import '../recorder/chunk_writer.dart' show fileStem;
import '../sleep/live_stager.dart' show LiveMode;
import 'rules.dart';

/// The naps folder for the app's recordings folder.
Directory napDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/naps');

/// One letter per live stage in [NapSession.stages].
const Map<String, String> stageLetters = {'W': 'W', 'N1': '1', 'N2': '2', 'N3': '3', 'R': 'R', 'gap': 'g'};

/// An epoch the live scorer never gave a stage (the first minutes, the last 2, timer only).
const String unscored = '.';

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

double? _num(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;
int? _int(Object? v) => v is int && v >= 0 ? v : null;

/// How the sleep model ran during the nap.
class NapLiveInfo {
  const NapLiveInfo({
    required this.mode,
    this.why,
    this.calls = 0,
    this.medianMs,
    this.maxMs,
    this.waited = 0,
    this.poorEpochs = 0,
  });

  /// At the end: full (3 runs), light (1 run) or timer (no model).
  final LiveMode mode;

  /// Why it stepped down, in a sentence; null when it never did.
  final String? why;
  final int calls;

  /// Time per check (preparing and the model), ms.
  final int? medianMs;
  final int? maxMs;

  /// Checks that waited for last night's scoring to finish.
  final int waited;

  /// Epochs scored as `gap` (over 5 s of signal lost).
  final int poorEpochs;

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'why': why,
    'calls': calls,
    'medianMs': medianMs,
    'maxMs': maxMs,
    'waited': waited,
    'poorEpochs': poorEpochs,
  };

  static NapLiveInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final mode = _byName(LiveMode.values, j['mode']), why = j['why'];
    final calls = _int(j['calls']), waited = _int(j['waited']), poor = _int(j['poorEpochs']);
    if (mode == null || calls == null || waited == null || poor == null || (why != null && why is! String)) return null;
    return NapLiveInfo(
      mode: mode,
      why: why as String?,
      calls: calls,
      medianMs: _int(j['medianMs']),
      maxMs: _int(j['maxMs']),
      waited: waited,
      poorEpochs: poor,
    );
  }
}

class NapSession {
  NapSession({
    required this.start,
    required this.lengthMin,
    required this.recording,
    required this.live,
    this.endS = 0,
    this.end,
    this.wakeS,
    this.upS,
    this.baselineS,
    this.drowsyS,
    this.onsetS,
    this.deepEpoch,
    this.stages = '',
    this.contact = const {},
  });

  static const int version = 1;

  /// Lights off (the first sample).
  final DateTime start;
  final int lengthMin;

  /// Stem of the nap's EEG in `files/recordings/`, or null when it could not be written.
  final String? recording;
  final NapLiveInfo live;

  /// Seconds after lights off when it ended, and why (null: still running, or the app stopped).
  final double endS;
  final NapEnd? end;

  /// When the wake cue began, and when you tapped "I'm awake" (s after lights off); null if it never did.
  final double? wakeS;
  final double? upS;

  /// The drift-off detector (s after lights off): eyes-closed baseline done, first drowsy, the onset of "probably
  /// asleep" (the first of its 6 faded epochs).
  final int? baselineS;
  final int? drowsyS;
  final int? onsetS;

  /// The epoch (from lights off) that completed the deep-sleep run; null if none.
  final int? deepEpoch;

  /// One letter per 30 s epoch from lights off: W 1 2 3 R, g (signal lost), . (not scored).
  final String stages;

  /// Contact at the start: ohms per channel, null where there was none.
  final Map<String, double?> contact;

  String get stem => fileStem(start);
  String get fileName => '$stem.nap.json';

  /// Minutes per stage letter in [stages] (0.5 each).
  Map<String, double> get minutes {
    final out = <String, double>{};
    for (final ch in stages.split('')) {
      out[ch] = (out[ch] ?? 0) + 0.5;
    }
    return out;
  }

  /// The sleep model scored at least one epoch (W N1 N2 N3 R); false for a nap the timer alone ran.
  bool get scored => stages.contains(RegExp('[W123R]'));

  /// Minutes asleep by the live stages (N1 N2 N3 R): 0 when nothing was scored ([scored]), and never the last
  /// 2 minutes and the wake (the model reads 2 minutes behind).
  double get asleepMin => [for (final k in ['1', '2', '3', 'R']) minutes[k] ?? 0].fold(0.0, (a, b) => a + b);

  Map<String, Object?> toJson() => {
    'version': version,
    'start': start.toIso8601String(),
    'lengthMin': lengthMin,
    'recording': recording,
    'endS': (endS * 10).round() / 10,
    'end': end?.name,
    'wakeS': wakeS == null ? null : (wakeS! * 10).round() / 10,
    'upS': upS == null ? null : (upS! * 10).round() / 10,
    'baselineS': baselineS,
    'drowsyS': drowsyS,
    'onsetS': onsetS,
    'deepEpoch': deepEpoch,
    'stages': stages,
    'live': live.toJson(),
    'contact': contact,
  };

  static NapSession? fromJson(Object? j) {
    if (j is! Map || j['version'] != version) return null;
    final start = DateTime.tryParse('${j['start']}'), length = _int(j['lengthMin']), rec = j['recording'];
    final endS = _num(j['endS']), end = _byName(NapEnd.values, j['end']), live = NapLiveInfo.fromJson(j['live']);
    final stages = j['stages'], contact = j['contact'];
    if (start == null || length == null || length == 0 || endS == null || live == null || stages is! String) return null;
    if ((rec != null && rec is! String) || (j['end'] != null && end == null)) return null;
    if (!RegExp(r'^[W123Rg.]*$').hasMatch(stages)) return null;
    return NapSession(
      start: start,
      lengthMin: length,
      recording: rec as String?,
      live: live,
      endS: endS,
      end: end,
      wakeS: _num(j['wakeS']),
      upS: _num(j['upS']),
      baselineS: _int(j['baselineS']),
      drowsyS: _int(j['drowsyS']),
      onsetS: _int(j['onsetS']),
      deepEpoch: _int(j['deepEpoch']),
      stages: stages,
      contact: contact is Map
          ? {for (final e in contact.entries) '${e.key}': e.value is num ? (e.value as num).toDouble() : null}
          : const {},
    );
  }
}

class NapStore {
  NapStore(this.dir);
  final Directory dir;

  /// Writes the session whole (at lights off, once a minute, and at the end).
  void save(NapSession s) {
    dir.createSync(recursive: true);
    final f = File('${dir.path}/${s.fileName}'), tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(s.toJson()), flush: true);
    tmp.renameSync(f.path);
  }

  /// Every readable nap, newest first; damaged or foreign files are skipped.
  List<NapSession> list() {
    if (!dir.existsSync()) return const [];
    final out = <NapSession>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.nap.json')) continue;
      try {
        final s = NapSession.fromJson(jsonDecode(f.readAsStringSync()));
        if (s != null) out.add(s);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return out..sort((a, b) => b.start.compareTo(a.start));
  }

  /// The newest readable nap, found by its file name (its start): the night screen's line opens this one file, and
  /// none while it is unchanged (DECISIONS 620-629).
  NapSession? newest() => firstParsed(newestFirst(dir, '.nap.json'), NapSession.fromJson);
}
