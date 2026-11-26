// Sleep experiments on disk, in the app's private folder like the self-experiments (DECISIONS rows 207, 1050-1069).
// One folder per experiment, named by when it was started:
//   files/sleep-experiments/<id>/plan.json   which experiment, the day it started, whether the app picks the nights
//                                            (then also the secret the picks are drawn from); written once
//   files/sleep-experiments/<id>/log.jsonl   one line per tap, added at the end, never rewritten: `answer`, `odd`,
//                                            `pick`, `ended`, `reminder` (the evening reminder's switch). The last
//                                            line about a day wins.
// Export data and Share on Wi-Fi take the folder with everything else (their rule is "everything except"), so the
// laptop gets it under phone/sleep-experiments/ with no new code.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../experiments/experiment.dart' show experimentId;
import '../training/check.dart' show allocate, Arm, newSalt;
import '../trends/days.dart';
import 'kinds.dart';
import 'stats.dart' show StatRule;

/// The folder for the app's recordings folder.
Directory sleepExperimentsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/sleep-experiments');

/// The app's pick for the test night number [index] (from 0), drawn from [salt] alone: blocks of 4 with 2 of each
/// (the replay check's draw).
bool pickAt(String salt, int index) =>
    allocate(salt, index ~/ StatRule.blockSize + 1, size: StatRule.blockSize, live: StatRule.withPerBlock)[index] == Arm.live;

class SleepExperiment {
  const SleepExperiment({required this.id, required this.kind, required this.created, required this.start, this.salt});
  final String id;
  final ExperimentKind kind;
  final DateTime created;

  /// Day key of the first evening that counts.
  final String start;

  /// The secret the picks are drawn from; null when the owner chooses the nights.
  final String? salt;
  bool get picked => salt != null;

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'kind': kind.id,
    'created': created.toIso8601String(),
    'start': start,
    'picked': picked,
    'salt': ?salt,
    'with': kind.withMeans,
    'without': kind.withoutMeans,
    'watched': [for (final w in kind.watched) w.measure.id],
    'day': 'an evening\'s answer is judged by the night that follows (the sleep report of the next day; a day runs 04:00 to 04:00)',
    if (picked)
      'draw': 'test nights in blocks of ${StatRule.blockSize}, ${StatRule.withPerBlock} with and ${StatRule.withPerBlock} without, drawn from the salt',
  };

  static SleepExperiment? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final kind = kindById(j['kind']), created = DateTime.tryParse('${j['created']}');
    final id = j['id'], start = j['start'], salt = j['salt'];
    if (kind == null || created == null || id is! String || !RegExp(r'^[0-9-]{10,20}$').hasMatch(id)) return null;
    if (start is! String || !RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(start)) return null;
    if (salt != null && (salt is! String || salt.isEmpty)) return null;
    return SleepExperiment(id: id, kind: kind, created: created, start: start, salt: salt as String?);
  }
}

/// What is known about one evening.
class DayLog {
  const DayLog({this.answer, this.odd = const {}, this.pickIndex, this.pick});
  final Answer? answer;

  /// Ids of [oddFlags] switched on.
  final Set<String> odd;

  /// The app's pick for this evening (true: with) and its number in the draw; null when none was drawn.
  final int? pickIndex;
  final bool? pick;
}

/// An experiment with everything logged so far.
class ExperimentLog {
  const ExperimentLog(this.plan, this.days, this.ended, {this.remind = false});

  /// The evening reminder is switched on (reminder.dart); off until the owner switches it on.
  final bool remind;
  final SleepExperiment plan;
  final Map<String, DayLog> days;

  /// The day key it was ended on; null while it runs.
  final String? ended;
  bool get running => ended == null;
  DayLog day(String key) => days[key] ?? const DayLog();
  int get picksMade => days.values.where((d) => d.pickIndex != null).length;
}

class SleepExperimentStore {
  SleepExperimentStore(this.dir);
  final Directory dir;

  /// Counts every line this app wrote to an experiment's log (a tap, a start, an end), on any page: the Record tab's
  /// line listens, so an answer given on Trends takes the question away there too.
  static final ValueNotifier<int> written = ValueNotifier<int>(0);

  File _f(String id, String name) => File('${dir.path}/$id/$name');

  void _line(String id, DateTime at, String day, String event, [Map<String, Object?> more = const {}]) {
    _f(id, 'log.jsonl').writeAsStringSync(
      '${jsonEncode({'at': at.toIso8601String(), 'day': day, 'event': event, ...more})}\n',
      mode: FileMode.append,
      flush: true,
    );
    written.value++;
  }

  /// One experiment; null when its plan cannot be read. A damaged log line is skipped.
  ExperimentLog? read(String id) {
    SleepExperiment? plan;
    try {
      plan = SleepExperiment.fromJson(jsonDecode(_f(id, 'plan.json').readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    if (plan == null) return null;
    final answers = <String, Answer>{}, odd = <String, Set<String>>{}, picks = <String, (int, bool)>{};
    String? ended;
    var remind = false;
    var lines = const <String>[];
    try {
      lines = _f(id, 'log.jsonl').readAsLinesSync();
    } on FileSystemException {
      // nothing logged yet
    }
    for (final line in lines) {
      Object? j;
      try {
        j = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (j is! Map || j['day'] is! String) continue;
      final day = j['day'] as String;
      switch (j['event']) {
        case 'answer':
          final a = Answer.byId(j['answer']);
          if (a != null) {
            answers[day] = a;
          } else if (j['answer'] == null) {
            answers.remove(day);
          }
        case 'odd':
          final flag = j['flag'];
          if (flag is String && oddFlags.any((f) => f.$1 == flag)) {
            final set = odd.putIfAbsent(day, () => {});
            j['on'] == true ? set.add(flag) : set.remove(flag);
          }
        case 'pick':
          final i = j['index'], w = j['with'];
          if (i is int && i >= 0 && w is bool) picks.putIfAbsent(day, () => (i, w));
        case 'ended':
          ended ??= day;
        case 'reminder':
          if (j['on'] is bool) remind = j['on'] as bool;
      }
    }
    final days = {...answers.keys, ...odd.keys, ...picks.keys};
    return ExperimentLog(plan, {
      for (final d in days) d: DayLog(answer: answers[d], odd: odd[d] ?? const {}, pickIndex: picks[d]?.$1, pick: picks[d]?.$2),
    }, ended, remind: remind);
  }

  /// Every readable experiment, newest first.
  List<ExperimentLog> all() {
    if (!dir.existsSync()) return const [];
    final ids = [
      for (final e in dir.listSync())
        if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort((a, b) => b.compareTo(a));
    return [for (final id in ids) ?read(id)];
  }

  /// The one that runs, if any.
  ExperimentLog? active() => all().where((e) => e.running).firstOrNull;

  /// Starts an experiment today. [picked]: the app picks the nights (only where the kind allows it). One at a time:
  /// throws while another runs.
  ExperimentLog create({required ExperimentKind kind, required bool picked, required DateTime now, math.Random? random}) {
    if (active() != null) throw StateError('a sleep experiment is still running');
    if (picked && !kind.canPick) throw ArgumentError('the app never picks the nights for ${kind.id}');
    final id = experimentId(now);
    final plan = SleepExperiment(id: id, kind: kind, created: now, start: dayKey(now), salt: picked ? newSalt(random) : null);
    Directory('${dir.path}/$id').createSync(recursive: true);
    // a temporary file, then a rename: an export never copies a half-written file (it skips *.tmp)
    final tmp = File('${_f(id, 'plan.json').path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(plan.toJson()), flush: true);
    tmp.renameSync(_f(id, 'plan.json').path);
    _line(id, now, plan.start, 'started');
    return read(id)!;
  }

  bool _open(ExperimentLog? e, String day, DateTime now) =>
      e != null && e.running && day.compareTo(e.plan.start) >= 0 && day.compareTo(dayKey(now)) <= 0;

  /// Keeps the evening's answer for [day] (today or an earlier day of the experiment); null takes it back. False
  /// when the day is not one of this running experiment's.
  bool answer(String id, String day, Answer? a, DateTime now) {
    if (!_open(read(id), day, now)) return false;
    _line(id, now, day, 'answer', {'answer': a?.id});
    return true;
  }

  /// Switches an odd-night flag for [day] on or off.
  bool odd(String id, String day, String flag, bool on, DateTime now) {
    if (!_open(read(id), day, now) || !oddFlags.any((f) => f.$1 == flag)) return false;
    _line(id, now, day, 'odd', {'flag': flag, 'on': on});
    return true;
  }

  /// The app's pick for today, drawn once: asking again the same day gives the same pick. Null when this
  /// experiment does not pick, or does not run.
  bool? pick(String id, DateTime now) {
    final e = read(id), day = dayKey(now);
    if (e == null || !e.plan.picked || !_open(e, day, now)) return null;
    final had = e.day(day).pick;
    if (had != null) return had;
    final index = e.picksMade, w = pickAt(e.plan.salt!, index);
    _line(id, now, day, 'pick', {'index': index, 'with': w});
    return w;
  }

  /// Switches the evening reminder on or off. False when the experiment does not run.
  bool setReminder(String id, bool on, DateTime now) {
    final e = read(id);
    if (e == null || !e.running) return false;
    _line(id, now, dayKey(now), 'reminder', {'on': on});
    return true;
  }

  /// Ends the experiment: what is logged stays and the result stays readable.
  void end(String id, DateTime now) {
    final e = read(id);
    if (e == null || !e.running) return;
    _line(id, now, dayKey(now), 'ended');
  }
}
