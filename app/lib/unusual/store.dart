// "Unusual for you" on disk (DECISIONS rows 290-299), in the app's private folder next to the recordings:
//   files/unusual/settings.json   the switch: {"on": true|false, "changed": ...}; missing or damaged = on
//   files/unusual/events.jsonl    one line per change: switched on / off, causes noted for a card, resumed
//   files/unusual/log.jsonl       the back-test log: one line per finished day, written once, never rewritten:
//                                 what it said (or, while silent, would have said), with and without the
//                                 headband's numbers, and each number against its usual
// Export data takes the folder with everything else (its rule is "everything except").
import 'dart:convert';
import 'dart:io';

import '../trends/days.dart';
import 'card.dart';
import 'detector.dart';

/// The folder for the app's recordings folder.
Directory unusualDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/unusual');

class UnusualStore {
  UnusualStore(this.dir);
  final Directory dir;

  File get _settings => File('${dir.path}/settings.json');
  File get _events => File('${dir.path}/events.jsonl');
  File get log => File('${dir.path}/log.jsonl');

  /// On unless switched off (the assistant's proposal: shown, and the owner can switch it off).
  bool get on {
    try {
      final j = jsonDecode(_settings.readAsStringSync());
      return j is Map && j['on'] is bool ? j['on'] as bool : true;
    } on FileSystemException {
      return true;
    } on FormatException {
      return true;
    }
  }

  void setOn(bool on, DateTime now) {
    dir.createSync(recursive: true);
    // a temporary file, then a rename: an export never copies a half-written file (it skips *.tmp)
    final tmp = File('${_settings.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({'on': on, 'changed': now.toIso8601String()}), flush: true);
    tmp.renameSync(_settings.path);
    _event(now, on ? 'switched on' : 'switched off');
  }

  /// What might explain the card that began on [episode] (ids from card.dart's [unusualCauses]); the latest
  /// choice for a card wins. "feeling ill" pauses the card (DECISIONS row 296).
  void setCauses(String episode, Set<String> causes, DateTime now) =>
      _event(now, 'causes', {'card': episode, 'causes': [...causes]..sort()});

  /// Ends a pause today.
  void resume(DateTime now) => _event(now, 'resumed');

  void _event(DateTime at, String what, [Map<String, Object?> more = const {}]) {
    dir.createSync(recursive: true);
    _events.writeAsStringSync(
      '${jsonEncode({'at': at.toIso8601String(), 'event': what, ...more})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Every readable line of a JSON-lines file; damaged lines are skipped.
  static List<Map<String, Object?>> _lines(File f) {
    final List<String> raw;
    try {
      raw = f.readAsLinesSync();
    } on FileSystemException {
      return const [];
    }
    final out = <Map<String, Object?>>[];
    for (final l in raw) {
      try {
        final j = jsonDecode(l);
        if (j is Map<String, Object?>) out.add(j);
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  static String? _day(Object? at) => at is String ? dayKey(DateTime.tryParse(at) ?? DateTime(0)) : null;

  /// Card's first day -> the causes noted for it last.
  Map<String, Set<String>> causes() {
    final out = <String, Set<String>>{};
    for (final e in _lines(_events)) {
      if (e['event'] == 'causes' && e['card'] is String && e['causes'] is List) {
        out[e['card']! as String] = {...(e['causes']! as List).whereType<String>()};
      }
    }
    return out;
  }

  /// "Feeling ill" for each card it is noted on: tapped the day it was first ticked, resumed at the first
  /// "resumed" after that. Unticking it takes the pause back.
  List<Ill> ill() {
    final tapped = <String, String>{}, resumed = <String, String>{};
    for (final e in _lines(_events)) {
      final day = _day(e['at']);
      if (day == null) continue;
      if (e['event'] == 'causes' && e['card'] is String && e['causes'] is List) {
        final card = e['card']! as String;
        if ((e['causes']! as List).contains(feelingIll)) {
          tapped.putIfAbsent(card, () => day);
        } else {
          tapped.remove(card);
          resumed.remove(card);
        }
      } else if (e['event'] == 'resumed') {
        for (final MapEntry(key: card, value: t) in tapped.entries) {
          if (t.compareTo(day) <= 0) resumed.putIfAbsent(card, () => day);
        }
      }
    }
    return [
      for (final MapEntry(key: card, value: t) in tapped.entries)
        Ill(start: card.compareTo(t) <= 0 ? card : t, tapped: t, resumed: resumed[card]),
    ];
  }

  /// The days already in the back-test log.
  Set<String> loggedDays() => {
    for (final l in _lines(log))
      if (l['day'] is String) l['day']! as String,
  };

  void appendLog(List<Map<String, Object?>> lines) {
    if (lines.isEmpty) return;
    dir.createSync(recursive: true);
    log.writeAsStringSync('${lines.map(jsonEncode).join('\n')}\n', mode: FileMode.append, flush: true);
  }
}

double? _r(double? v) => v == null ? null : double.parse(v.toStringAsFixed(3));

/// One line of the back-test log for a finished day.
Map<String, Object?> logLine(
  DayVerdict v,
  Map<String, Map<String, double>> series,
  Map<String, DayVerdict> byDay,
  DateTime now,
) {
  final words = [
    for (final id in v.onCore) ?cardSentence(id, v, series[id] ?? const {}, byDay),
  ];
  return {
    'day': v.day,
    'judged': now.toIso8601String(),
    'phase': v.phase.name,
    'card': v.ruleCore,
    'shown': v.shown,
    'withHeadband': v.ruleAll,
    'numbers': v.onCore,
    'numbersWithHeadband': v.onAll,
    if (words.isNotEmpty) 'words': words.join(' '),
    'values': {
      for (final MapEntry(key: id, value: s) in v.streams.entries)
        if (s.value != null)
          id: {
            'value': _r(s.value),
            'usual': _r(s.usual),
            'half': _r(s.half),
            'n': s.n,
            'state': stateName(s.state),
            'run': s.run,
          },
    },
  };
}

const UnusualCard offCard = UnusualCard(
  kind: CardKind.off,
  headline: 'Off.',
  status: 'When on, it compares your sleep length and morning ratings with your usual and says when one has been '
      'unusual on 2 days in a row. Nothing is noted while it is off.',
);

/// Today's card from the trends page's per-day numbers (trends.dart's dailySeries); while on, every finished day
/// not yet in the back-test log is added to it.
UnusualCard refreshUnusual(UnusualStore store, Map<String, Map<String, double>> series, DateTime now) {
  if (!store.on) return offCard;
  final today = dayKey(now);
  final ids = {for (final s in unusualStreams) s.id};
  final days = [
    for (final e in series.entries)
      if (ids.contains(e.key))
        for (final d in e.value.keys)
          if (d.compareTo(today) <= 0) d,
  ]..sort();
  final ill = store.ill();
  final verdicts = days.isEmpty ? <DayVerdict>[] : judgeDays(series, days.first, today, ill: ill);
  final logged = store.loggedDays();
  final byDay = {for (final v in verdicts) v.day: v};
  store.appendLog([
    for (final v in verdicts)
      if (v.day.compareTo(today) < 0 && !logged.contains(v.day)) logLine(v, series, byDay, now),
  ]);
  return unusualCard(verdicts, series, today, causes: store.causes(), pausedUntil: pauseEnd(ill, today));
}
