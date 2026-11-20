// Automatic recording, phase 1 (ROADMAP row 39, DECISIONS 600-609): the owner's choices and what the watcher remembers
// between its checks, app-private beside the recordings (no backup takes it, other apps cannot read it):
//   files/auto-start/settings.json   "When I put the headband on": a choice per kind, the chime switch, the bedtime
//                                    window when set by hand (written whole)
//   files/auto-start/state.json      quiet times after "Not now", the yes streaks, the offers made, the wearing in
//                                    progress (written whole)
//   files/auto-start/log.jsonl       every check, guess, question, answer and outcome (log.dart)
//   files/auto-start/laptop.json     the laptop's latest work signal (laptop.dart; a hook until the phone link sends it)
// Export data and Share on Wi-Fi take the folder with everything else ("everything except", DECISIONS 150). Plain
// Dart: tested on a plain folder.
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;

/// `files/auto-start` for the app's recordings folder.
Directory autoDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/auto-start');

/// What the app thinks you are doing when it finds the headband on.
enum WearKind {
  night('night', 'Night'),
  work('work', 'Work'),
  other('other', 'Other');

  const WearKind(this.wire, this.label);
  final String wire;
  final String label;

  static WearKind? fromWire(Object? v) => values.where((k) => k.wire == v).firstOrNull;
}

/// "When I put the headband on": what the app does for one kind.
enum AutoChoice {
  start('start', 'Start automatically', 'Automatic'),
  ask('ask', 'Ask me', 'Ask me'),
  nothing('nothing', 'Do nothing', 'Do nothing');

  const AutoChoice(this.wire, this.label, this.short);
  final String wire;
  final String label;

  /// The words on the page's three-way switch (one row at the phone's width).
  final String short;

  static AutoChoice? fromWire(Object? v) => values.where((c) => c.wire == v).firstOrNull;
}

/// Planning values of phase 1 (labelled assumptions, DECISIONS 600-609; none is a measured limit).
abstract final class AutoRule {
  /// Answers in a row before the app offers "Start automatically" for that kind.
  static const int offerAfterYes = 10;

  /// No question about a kind for this long after "Not now" (and none for the rest of that wearing).
  static const Duration quietAfterNo = Duration(minutes: 30);

  /// How long a question waits, with the minutes since the check kept in memory, before it counts as no answer.
  static const Duration askFor = Duration(minutes: 15);

  /// Checks inside the bedtime window, this far apart.
  static const Duration bedtimeEvery = Duration(minutes: 10);

  /// The window opens this long before the usual bedtime and closes at the usual wake-up.
  static const Duration beforeBed = Duration(hours: 2);

  /// Until 3 nights are recorded: 23:00 to 07:00 (minutes after midnight).
  static const int defaultBedMin = 23 * 60, defaultWakeMin = 7 * 60;

  /// No check (unless asked by hand) this soon after a recording's last data: a night just stopped is not a new one.
  static const Duration afterRecording = Duration(minutes: 30);
}

/// The owner's choices. Night and work start on "Ask me"; other can only ask or do nothing in phase 1 (there is no
/// daytime recording yet to start automatically).
class AutoSettings {
  const AutoSettings({this.choices = const {}, this.workChime = false, this.bedMin, this.wakeMin});

  final Map<WearKind, AutoChoice> choices;

  /// Automatic work sessions chime with their break hints only when this is on (off by default: a sound needs your
  /// say-so, DECISIONS 604).
  final bool workChime;

  /// The bedtime window set by hand (minutes after midnight); null: from your recorded nights.
  final int? bedMin, wakeMin;

  AutoChoice choice(WearKind k) {
    final c = choices[k] ?? AutoChoice.ask;
    return k == WearKind.other && c == AutoChoice.start ? AutoChoice.ask : c;
  }

  /// Every kind is "Do nothing": the app does not even check.
  bool get allOff => WearKind.values.every((k) => choice(k) == AutoChoice.nothing);

  bool get bedtimeByHand => bedMin != null && wakeMin != null;

  AutoSettings withChoice(WearKind k, AutoChoice c) => AutoSettings(
    choices: {...choices, k: c},
    workChime: workChime,
    bedMin: bedMin,
    wakeMin: wakeMin,
  );

  AutoSettings withChime(bool on) => AutoSettings(choices: choices, workChime: on, bedMin: bedMin, wakeMin: wakeMin);

  /// [bed] and [wake] null: back to the recorded nights.
  AutoSettings withBedtime(int? bed, int? wake) =>
      AutoSettings(choices: choices, workChime: workChime, bedMin: bed, wakeMin: wake);

  Map<String, Object?> toJson() => {
    'version': 1,
    'choices': {for (final k in WearKind.values) k.wire: choice(k).wire},
    'work_chime': workChime,
    'bed_min': bedMin,
    'wake_min': wakeMin,
  };

  /// The defaults for anything missing or not ours.
  static AutoSettings fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return const AutoSettings();
    final c = j['choices'];
    int? clock(Object? v) => v is int && v >= 0 && v < 1440 ? v : null;
    return AutoSettings(
      choices: {
        if (c is Map)
          for (final k in WearKind.values)
            if (AutoChoice.fromWire(c[k.wire]) != null) k: AutoChoice.fromWire(c[k.wire])!,
      },
      workChime: j['work_chime'] == true,
      bedMin: clock(j['bed_min']),
      wakeMin: clock(j['wake_min']),
    );
  }
}

/// What the watcher remembers between checks (each check may run in a new engine, so it lives on disk).
class AutoState {
  const AutoState({
    this.quietUntil = const {},
    this.yesStreak = const {},
    this.offered = const {},
    this.wornSince,
    this.askedThisWearing = const {},
    this.chargeNoticeDay,
  });

  /// No question about the kind before this.
  final Map<WearKind, DateTime> quietUntil;

  /// "Yes" answers in a row per kind; "Not now" sets it back to 0, no answer leaves it.
  final Map<WearKind, int> yesStreak;

  /// The "start it automatically?" offer was made for the current streak.
  final Set<WearKind> offered;

  /// The first check that found the headband on, in the wearing that goes on now; null after a check found it off.
  final DateTime? wornSince;

  /// Kinds already asked about in this wearing (one question per wearing).
  final Set<WearKind> askedThisWearing;

  /// The day (`2026-11-20`) the "charge the headband for tonight" line was last shown: once a day.
  final String? chargeNoticeDay;

  AutoState copyWith({
    Map<WearKind, DateTime>? quietUntil,
    Map<WearKind, int>? yesStreak,
    Set<WearKind>? offered,
    DateTime? Function()? wornSince,
    Set<WearKind>? askedThisWearing,
    String? chargeNoticeDay,
  }) => AutoState(
    quietUntil: quietUntil ?? this.quietUntil,
    yesStreak: yesStreak ?? this.yesStreak,
    offered: offered ?? this.offered,
    wornSince: wornSince == null ? this.wornSince : wornSince(),
    askedThisWearing: askedThisWearing ?? this.askedThisWearing,
    chargeNoticeDay: chargeNoticeDay ?? this.chargeNoticeDay,
  );

  bool quiet(WearKind k, DateTime now) {
    final u = quietUntil[k];
    return u != null && now.isBefore(u);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'quiet_until': {for (final e in quietUntil.entries) e.key.wire: isoLocal(e.value)},
    'yes_streak': {for (final e in yesStreak.entries) e.key.wire: e.value},
    'offered': [for (final k in offered) k.wire],
    'worn_since': wornSince == null ? null : isoLocal(wornSince!),
    'asked_this_wearing': [for (final k in askedThisWearing) k.wire],
    'charge_notice_day': chargeNoticeDay,
  };

  static AutoState fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return const AutoState();
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
    Set<WearKind> kinds(Object? v) => {
      if (v is List)
        for (final x in v)
          if (WearKind.fromWire(x) != null) WearKind.fromWire(x)!,
    };
    final q = j['quiet_until'], y = j['yes_streak'];
    return AutoState(
      quietUntil: {
        if (q is Map)
          for (final k in WearKind.values)
            if (time(q[k.wire]) != null) k: time(q[k.wire])!,
      },
      yesStreak: {
        if (y is Map)
          for (final k in WearKind.values)
            if (y[k.wire] is int && (y[k.wire] as int) >= 0) k: y[k.wire] as int,
      },
      offered: kinds(j['offered']),
      wornSince: time(j['worn_since']),
      askedThisWearing: kinds(j['asked_this_wearing']),
      chargeNoticeDay: j['charge_notice_day'] is String ? j['charge_notice_day'] as String : null,
    );
  }
}

class AutoStore {
  AutoStore(this.dir);
  final Directory dir;

  File _f(String name) => File('${dir.path}/$name');

  Object? _read(String name) {
    final f = _f(name);
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync());
    } on FormatException {
      return null; // half-written or not ours: the defaults
    }
  }

  /// Written whole: a temporary file, then a rename, so a crash leaves the old file or the new one.
  void _write(String name, Map<String, Object?> json) {
    dir.createSync(recursive: true);
    final tmp = _f('$name.tmp')..writeAsStringSync(jsonEncode(json), flush: true);
    tmp.renameSync(_f(name).path);
  }

  AutoSettings settings() => AutoSettings.fromJson(_read('settings.json'));
  void saveSettings(AutoSettings s) => _write('settings.json', s.toJson());

  AutoState state() => AutoState.fromJson(_read('state.json'));
  void saveState(AutoState s) => _write('state.json', s.toJson());
}
