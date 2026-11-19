// The sharp-hours log on disk, in the app's private folder next to the recordings (no backup takes it, other apps
// cannot read it; DECISIONS rows 53, 57, 288):
//   files/sharp-hours/settings.json    the switch, the waking window, how many a day, the secret (written whole)
//   files/sharp-hours/ratings.jsonl    one line per answer to "how sharp do you feel?"
//   files/sharp-hours/reactions.jsonl  one line per 1-minute reaction test, linked to its rating
//   files/sharp-hours/prompts.jsonl    written by the Android side (SharpPrompts.kt): each moment shown, skipped,
//                                      late, postponed or swiped away
//   files/sharp-hours/events.jsonl     each change of the switch, the window or the count
// Times are local with their UTC offset (`2026-11-20T14:05:12+03:00`), so the hour of day survives travel.
// Export data takes the folder with everything else (its rule is "everything except").
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../sleep/report.dart' show isoLocal;
import 'schedule.dart';

/// The sharp-hours folder for the app's recordings folder.
Directory sharpDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/sharp-hours');

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// The words of the 1-5 scale, from 1.
const List<String> sharpWords = ['Foggy', 'Slow', 'Okay', 'Sharp', 'Very sharp'];

/// One answer to "how sharp do you feel right now?".
class SharpRating {
  const SharpRating({required this.at, required this.sharp, this.prompt, this.shown, this.testAsked = false});

  /// When it was answered: the moment the rating is about.
  final DateTime at;

  /// 1 (foggy) to 5 (very sharp).
  final int sharp;

  /// The planned moment it answers and when its notification appeared; both null when rated from the page.
  final DateTime? prompt, shown;

  /// The question suggested the reaction test.
  final bool testAsked;

  bool get prompted => prompt != null;

  Map<String, Object?> toJson() => {
    'version': 1,
    'at': isoLocal(at),
    'sharp': sharp,
    'scale': '1-5',
    'prompt': prompt == null ? null : isoLocal(prompt!),
    'shown': shown == null ? null : isoLocal(shown!),
    'test_asked': testAsked,
  };

  static SharpRating? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1 || j['scale'] != '1-5') return null;
    final at = _time(j['at']), sharp = j['sharp'];
    if (at == null || sharp is! int || sharp < 1 || sharp > 5) return null;
    if ((j['prompt'] != null && _time(j['prompt']) == null) || (j['shown'] != null && _time(j['shown']) == null)) {
      return null;
    }
    return SharpRating(
      at: at,
      sharp: sharp,
      prompt: _time(j['prompt']),
      shown: _time(j['shown']),
      testAsked: j['test_asked'] == true,
    );
  }
}

int _medianInt(List<int> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : ((s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2).round();
}

/// One 1-minute reaction test (alpha-theta's, DECISIONS rows 107 and 285).
class SharpReaction {
  const SharpReaction({required this.at, required this.ratingAt, required this.timesMs, this.falseStarts = 0, this.lengthS = 60});
  final DateTime at;

  /// The rating it followed.
  final DateTime ratingAt;

  /// Each tap's delay after the dot, ms (100-1500; faster taps were false starts).
  final List<int> timesMs;
  final int falseStarts, lengthS;

  /// The median of the taps, or null with fewer than 5 (the test's own rule).
  int? get medianMs => timesMs.length < 5 ? null : _medianInt(timesMs);

  /// Taps slower than 500 ms.
  int get lapses => timesMs.where((t) => t > 500).length;

  Map<String, Object?> toJson() => {
    'version': 1,
    'at': isoLocal(at),
    'rating_at': isoLocal(ratingAt),
    'length_s': lengthS,
    'median_ms': medianMs,
    'taps': timesMs.length,
    'false_starts': falseStarts,
    'lapses': lapses,
    'times_ms': timesMs,
  };

  static SharpReaction? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final at = _time(j['at']), ratingAt = _time(j['rating_at']), times = j['times_ms'];
    final fs = j['false_starts'], len = j['length_s'];
    if (at == null || ratingAt == null || times is! List || fs is! int || fs < 0 || len is! int || len <= 0) return null;
    final t = <int>[];
    for (final x in times) {
      if (x is! int || x < 100 || x > 1500) return null;
      t.add(x);
    }
    return SharpReaction(at: at, ratingAt: ratingAt, timesMs: t, falseStarts: fs, lengthS: len);
  }
}

enum PromptEventKind { shown, skipped, late, snoozed, dismissed }

/// One line of the Android side's prompt log.
class PromptEvent {
  const PromptEvent({required this.planned, required this.at, required this.event, this.reason, this.test = false});
  final DateTime planned, at;
  final PromptEventKind event;

  /// Why a moment was skipped: `night recording`, `sound session`, `session on screen`, `notifications off`.
  final String? reason;
  final bool test;

  static PromptEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final planned = _time(j['planned']), at = _time(j['at']);
    final kind = PromptEventKind.values.where((k) => k.name == j['event']).firstOrNull;
    if (planned == null || at == null || kind == null) return null;
    return PromptEvent(
      planned: planned,
      at: at,
      event: kind,
      reason: j['reason'] is String ? j['reason'] as String : null,
      test: j['test'] == true,
    );
  }
}

class SharpStore {
  SharpStore(this.dir);
  final Directory dir;

  File _f(String name) => File('${dir.path}/$name');

  List<T> _lines<T>(String name, T? Function(Object?) parse) {
    final f = _f(name);
    if (!f.existsSync()) return const [];
    final out = <T>[];
    for (final line in const LineSplitter().convert(f.readAsStringSync())) {
      if (line.trim().isEmpty) continue;
      try {
        final v = parse(jsonDecode(line));
        if (v != null) out.add(v);
      } on FormatException {
        // a line cut off by a crash, or not ours: skipped, never guessed at
      }
    }
    return out;
  }

  void _append(String name, Map<String, Object?> json) {
    dir.createSync(recursive: true);
    _f(name).writeAsStringSync('${jsonEncode(json)}\n', mode: FileMode.append, flush: true);
  }

  SharpSettings? settings() {
    try {
      return SharpSettings.fromJson(jsonDecode(_f('settings.json').readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void saveSettings(SharpSettings s) {
    dir.createSync(recursive: true);
    // a temporary file, then a rename: an export never copies a half-written file (it skips *.tmp)
    final tmp = File('${_f('settings.json').path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(s.toJson()), flush: true);
    tmp.renameSync(_f('settings.json').path);
  }

  void addRating(SharpRating r) => _append('ratings.jsonl', r.toJson());
  List<SharpRating> ratings() => _lines('ratings.jsonl', SharpRating.fromJson);

  void addReaction(SharpReaction t) => _append('reactions.jsonl', t.toJson());
  List<SharpReaction> reactions() => _lines('reactions.jsonl', SharpReaction.fromJson);

  List<PromptEvent> promptEvents() => _lines('prompts.jsonl', PromptEvent.fromJson);

  void logEvent(DateTime at, String event, [Map<String, Object?> more = const {}]) =>
      _append('events.jsonl', {'at': isoLocal(at), 'event': event, ...more});

  /// Removes every sharp-hours file (the owner's "delete my data").
  void deleteAll() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// A new secret for the moments: 16 random bytes from the phone's secure generator, as hex.
  static String newSeed([math.Random? random]) {
    final r = random ?? math.Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }
}
