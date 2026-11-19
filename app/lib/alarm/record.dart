// What a night's smart alarm did, for the morning report (DECISIONS 237): `files/alarms/<endMs>.alarm.json`, written by
// the live scorer in the night recorder (the plan, when the model ran, the wake and why, the live stages), and
// `files/alarms/rings.jsonl`, one line per event of the phone's ringer (set, ring, loud, I'm awake, gave up, off),
// appended by WakeAlarm.kt. Both are keyed by the window's end, so the report finds the alarm of a night even when
// the app was gone at the ring. Plain Dart; Export data takes the folder like everything else.
import 'dart:convert';
import 'dart:io';

import 'rule.dart';

const int alarmRecordVersion = 1;

/// The alarms folder for the app's recordings folder.
Directory alarmsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/alarms');

/// One event of the ringer (rings.jsonl).
typedef RingEvent = ({int endMs, String event, int atMs, String? by, int? windowMin});

/// A night's alarm as the report shows it.
class AlarmNight {
  const AlarmNight({required this.plan, this.record, this.rings = const []});
  final AlarmPlan plan;

  /// The live scorer's file; null when the recorder never started the model (e.g. the night ended before).
  final Map<String, dynamic>? record;
  final List<RingEvent> rings;

  RingEvent? _first(String event) => rings.where((r) => r.event == event).firstOrNull;

  /// When the ringer started, and why (`smart`, `window end`, `backup`).
  RingEvent? get ring => _first('ring');
  int? get loudMs => _first('loud')?.atMs;
  int? get awakeMs => _first('awake')?.atMs;
  int? get gaveUpMs => _first('gave up')?.atMs;

  /// Turned off before it rang.
  int? get offMs => _first('cancel')?.atMs;

  Map<String, dynamic>? get wake => (record?['wake'] as Map?)?.cast<String, dynamic>();
  AlarmWhy? get why => alarmWhyFromName(wake?['why'] as String?);

  /// Why the live model stopped early, in a sentence; null when it ran to the wake.
  String? get modelOff => record?['off'] as String?;
}

class AlarmStore {
  AlarmStore(this.dir);
  final Directory dir;

  File fileFor(int endMs) => File('${dir.path}/$endMs.alarm.json');
  File get rings => File('${dir.path}/rings.jsonl');

  /// Replaces the live scorer's file (a temporary file, then a rename).
  void write(int endMs, Map<String, Object?> record) {
    dir.createSync(recursive: true);
    final tmp = File('${dir.path}/$endMs.alarm.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert({'version': alarmRecordVersion, ...record}), flush: true);
    tmp.renameSync(fileFor(endMs).path);
  }

  Map<String, dynamic>? read(int endMs) {
    try {
      final d = jsonDecode(fileFor(endMs).readAsStringSync());
      return d is Map<String, dynamic> ? d : null;
    } on Object {
      return null;
    }
  }

  /// Every ringer event, oldest first; damaged lines are skipped.
  List<RingEvent> ringEvents() {
    if (!rings.existsSync()) return const [];
    final out = <RingEvent>[];
    for (final line in rings.readAsLinesSync()) {
      try {
        final m = jsonDecode(line);
        if (m is! Map || m['endMs'] is! int || m['event'] is! String || m['atMs'] is! int) continue;
        out.add((
          endMs: m['endMs'] as int,
          event: m['event'] as String,
          atMs: m['atMs'] as int,
          by: m['by'] is String ? m['by'] as String : null,
          windowMin: m['windowMin'] is int ? m['windowMin'] as int : null,
        ));
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  /// The alarm of the night whose data ran from [from] to [to]: the latest plan whose window ends between the
  /// night's start and 3 hours after its last data (the ringer's "set" line, or the scorer's file).
  AlarmNight? forNight(DateTime from, DateTime to) {
    final lo = from.millisecondsSinceEpoch, hi = to.add(const Duration(hours: 3)).millisecondsSinceEpoch;
    final events = ringEvents();
    final plans = <int, int>{}; // endMs -> window minutes
    for (final e in events.where((e) => e.event == 'set')) {
      final w = e.windowMin;
      if (w != null && w > 0) plans[e.endMs] = w;
    }
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        final m = RegExp(r'/(\d+)\.alarm\.json$').firstMatch(f.path);
        if (m == null) continue;
        final plan = AlarmPlan.fromJson(read(int.parse(m[1]!))?['plan']);
        if (plan != null) plans[plan.endMs] = plan.windowMin;
      }
    }
    final ends = plans.keys.where((e) => e >= lo && e <= hi).toList()..sort();
    if (ends.isEmpty) return null;
    final end = ends.last;
    return AlarmNight(
      plan: AlarmPlan(endMs: end, windowMin: plans[end]!),
      record: read(end),
      rings: [for (final e in events) if (e.endMs == end) e],
    );
  }
}
