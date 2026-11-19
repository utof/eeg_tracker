// Fair tests of two sounds on disk (DECISIONS row 436), beside the sessions in the app's private folder (no backup
// takes it, other apps cannot read it; rows 53, 57), the self-experiments' layout (row 207):
//   files/sound-states/plans/<id>/sealed.json     the secret and the order of days; written once; read only to set a
//                                                 day's sound when that day has come and for the answer
//   files/sound-states/plans/<id>/plan.json       the frozen plan and its SHA-256 (it holds the order's hash);
//                                                 written once, before day 1
//   files/sound-states/plans/<id>/progress.json   a stop, if any
//   files/sound-states/plans/<id>/events.jsonl    plan frozen, stopped: the log
// Export data takes the folder with everything else (its rule is "everything except").
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../experiments/experiment.dart' show Mark, Progress, SealedOrder, experimentId;
import '../training/check.dart' show newSalt;
import '../trends/days.dart';
import 'presets.dart';
import 'trial.dart';
import 'weeks.dart';

/// The tests folder inside the sessions folder (states/store.dart, soundStatesDirFor).
Directory trialsDirFor(Directory soundStatesDir) => Directory('${soundStatesDir.path}/plans');

class TrialStore {
  TrialStore(this.dir);
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
    // a temporary file, then a rename: an export never copies a half-written file (it skips *.tmp)
    final tmp = File('${_f(id, name).path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(json), flush: true);
    tmp.renameSync(_f(id, name).path);
  }

  void _event(String id, DateTime at, String what, [Map<String, Object?> more = const {}]) {
    Directory('${dir.path}/$id').createSync(recursive: true);
    _f(id, 'events.jsonl').writeAsStringSync(
      '${jsonEncode({'at': at.toIso8601String(), 'event': what, ...more})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// One test as of [now]; null when its plan or its order cannot be read.
  TrialState? load(String id, DateTime now) {
    final j = _read(id, 'plan.json');
    if (j is! Map || j['sha256'] is! String) return null;
    final plan = TrialPlan.fromJson(j['plan']), sealed = SealedOrder.fromJson(_read(id, 'sealed.json'));
    if (plan == null || sealed == null) return null;
    return TrialState(
      plan: plan,
      planSha: j['sha256'] as String,
      sealed: sealed,
      progress: Progress.fromJson(_read(id, 'progress.json')),
      today: dayKey(now),
    );
  }

  /// Every readable test, newest first.
  List<TrialState> all(DateTime now) {
    if (!dir.existsSync()) return const [];
    final ids = [
      for (final e in dir.listSync())
        if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort((a, b) => b.compareTo(a));
    return [for (final id in ids) ?load(id, now)];
  }

  /// The test of [state] still under way (waiting, running or waiting for its last number), if any.
  TrialState? active(SoundState state, DateTime now) => all(now).where((s) => s.plan.state == state && !s.open).firstOrNull;

  /// Draws the order and freezes the plan: the sealed file first, then the plan with the order's hash and its own.
  /// Day 1 is the day after [now]. One test per state at a time: throws a StateError when one is still under way,
  /// an ArgumentError for two equal sounds, a sound that plays nothing, a length the state does not offer or a
  /// number of weeks not on offer.
  TrialState create({
    required SoundState state,
    required SoundPick a,
    required SoundPick b,
    required int minutes,
    required int weeks,
    required DateTime now,
    math.Random? random,
  }) {
    if (active(state, now) != null) throw StateError('a test of this state is still under way');
    if (!a.valid || !b.valid) throw ArgumentError('each sound needs a bed or a beat');
    if (a == b) throw ArgumentError('a test needs two different sounds');
    if (!TrialRule.weeks.contains(weeks)) throw ArgumentError.value(weeks, 'weeks', 'one of ${TrialRule.weeks}');
    if (!presets[state]!.minutes.contains(minutes)) throw ArgumentError.value(minutes, 'minutes', 'one of ${presets[state]!.minutes}');
    final days = weeks * 7, id = '${experimentId(now)}-${state.name}';
    final sealed = SealedOrder.draw(newSalt(random), days);
    _write(id, 'sealed.json', sealed.toJson());
    final plan = TrialPlan(
      id: id,
      created: now,
      state: state,
      a: a,
      b: b,
      minutes: minutes,
      start: addDays(dayKey(now), 1),
      days: days,
      allocationSha256: sealed.sha,
    );
    _write(id, 'plan.json', {'plan': plan.toJson(), 'sha256': plan.sha});
    _write(id, 'progress.json', const Progress().toJson());
    _event(id, now, 'plan frozen', {'sha256': plan.sha});
    return load(id, now)!;
  }

  /// Stops the test for good: the days that are over stay counted, the rest are never shown.
  void stop(String id, DateTime now) {
    final s = load(id, now);
    if (s == null || s.open) return;
    final m = Mark(now, s.today, s.daysDone);
    _write(id, 'progress.json', s.progress.stop(m).toJson());
    _event(id, now, 'stopped', {'day': m.day, 'daysDone': m.daysDone});
  }
}
