// Self-experiments on disk, in the app's private folder next to the recordings (no backup takes it, other apps
// cannot read it; DECISIONS rows 53, 57, 205). One folder per experiment, named by when it was made:
//   files/experiments/<id>/sealed.json     the secret and the order of days; written once; read only to show a
//                                          day that has come and for the results
//   files/experiments/<id>/plan.json       the frozen plan and its SHA-256 (it holds the order's hash); written
//                                          once, before day 1
//   files/experiments/<id>/progress.json   the answers to "did you keep to it?", early looks, a stop
//   files/experiments/<id>/events.jsonl    plan frozen, each answer, early look, stopped: the log
// Export data takes the folder with everything else (its rule is "everything except").
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../training/check.dart' show newSalt;
import '../trends/days.dart';
import 'experiment.dart';

/// The experiments folder for the app's recordings folder.
Directory experimentsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/experiments');

class ExperimentStore {
  ExperimentStore(this.dir);
  final Directory dir;

  File _f(String id, String name) => File('${dir.path}/$id/$name');

  Object? _read(String id, String name) {
    try {
      return jsonDecode(_f(id, name).readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void _write(String id, String name, Object? json) {
    Directory('${dir.path}/$id').createSync(recursive: true);
    _f(id, name).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(json), flush: true);
  }

  void _event(String id, DateTime at, String what, [Map<String, Object?> more = const {}]) {
    Directory('${dir.path}/$id').createSync(recursive: true);
    _f(id, 'events.jsonl').writeAsStringSync(
      '${jsonEncode({'at': at.toIso8601String(), 'event': what, ...more})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// One experiment as of [now]; null when its plan or its order cannot be read.
  ExperimentState? load(String id, DateTime now) {
    final j = _read(id, 'plan.json');
    if (j is! Map || j['sha256'] is! String) return null;
    final plan = ExperimentPlan.fromJson(j['plan']), sealed = SealedOrder.fromJson(_read(id, 'sealed.json'));
    if (plan == null || sealed == null) return null;
    return ExperimentState(
      plan: plan,
      planSha: j['sha256'] as String,
      sealed: sealed,
      progress: Progress.fromJson(_read(id, 'progress.json')),
      today: dayKey(now),
    );
  }

  /// Every readable experiment, newest first.
  List<ExperimentState> all(DateTime now) {
    if (!dir.existsSync()) return const [];
    final ids = [
      for (final e in dir.listSync())
        if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort((a, b) => b.compareTo(a));
    return [for (final id in ids) ?load(id, now)];
  }

  /// The one still under way (waiting, running or waiting for its last number), if any.
  ExperimentState? active(DateTime now) => all(now).where((s) => !s.open).firstOrNull;

  /// Draws the order and freezes the plan: the sealed file first, then the plan with the order's hash and its
  /// own. Day 1 is the day after [now]. One experiment at a time: throws when one is still under way.
  ExperimentState create({
    required String preset,
    required String doText,
    required String dontText,
    required Outcome outcome,
    required int weeks,
    required DateTime now,
    math.Random? random,
  }) {
    if (active(now) != null) throw StateError('an experiment is still under way');
    final doLine = cleanLine(doText), dontLine = cleanLine(dontText);
    if (doLine.isEmpty || dontLine.isEmpty) throw ArgumentError('both kinds of day need a line');
    if (weeks < 1 || weeks.isOdd) throw ArgumentError('an even number of days is needed');
    final days = weeks * 7, id = experimentId(now);
    final sealed = SealedOrder.draw(newSalt(random), days);
    _write(id, 'sealed.json', sealed.toJson());
    final plan = ExperimentPlan(
      id: id,
      created: now,
      preset: preset,
      doText: doLine,
      dontText: dontLine,
      outcome: outcome,
      start: addDays(dayKey(now), 1),
      days: days,
      allocationSha256: sealed.sha,
    );
    _write(id, 'plan.json', {'plan': plan.toJson(), 'sha256': plan.sha});
    _write(id, 'progress.json', const Progress().toJson());
    _event(id, now, 'plan frozen', {'sha256': plan.sha});
    return load(id, now)!;
  }

  void _save(ExperimentState s, Progress p) => _write(s.plan.id, 'progress.json', p.toJson());

  /// Keeps the answer to "did you keep to it?" for a past day (it can be corrected until the results open).
  /// False when the day is not a past day of a running experiment.
  bool answer(String id, String day, bool kept, DateTime now) {
    final s = load(id, now);
    if (s == null || s.open || !s.pastDays.any((d) => d.day == day)) return false;
    _save(s, s.progress.answer(day, kept));
    _event(id, now, 'answer', {'day': day, 'kept': kept});
    return true;
  }

  /// Marks a look at the results before the planned end. The mark stays and is shown with the results.
  void earlyLook(String id, DateTime now) {
    final s = load(id, now);
    if (s == null || s.open) return;
    final m = Mark(now, s.today, s.daysDone);
    _save(s, s.progress.look(m));
    _event(id, now, 'early look', {'day': m.day, 'daysDone': m.daysDone});
  }

  /// Stops the experiment for good: the days that are over stay counted, the rest are never shown.
  void stop(String id, DateTime now) {
    final s = load(id, now);
    if (s == null || s.open) return;
    final m = Mark(now, s.today, s.daysDone);
    _save(s, s.progress.stop(m));
    _event(id, now, 'stopped', {'day': m.day, 'daysDone': m.daysDone});
  }
}
