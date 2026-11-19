// The replay check on disk, in the app's private folder next to the sessions (no backup takes it, other apps
// cannot read it; DECISIONS rows 53, 57):
//   files/settings.json                         {"replayCheck": false}: the toggle, off by default
//   files/replay-check/<kind>/sealed.json       the salt and the schedule; written once, read only to schedule
//                                               and to reveal
//   files/replay-check/<kind>/plan.json         the frozen plan and its SHA-256 (it holds the schedule's hash);
//                                               written once, before the first randomised session
//   files/replay-check/<kind>/records.json      one entry per randomised session, rewritten as answers come in
//   files/replay-check/<kind>/events.jsonl      switched on / off, plan frozen, session kept: the deviation log
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'check.dart';
import 'control.dart';
import 'reveal.dart' as rv;

/// Writes [text] to a new file and renames it over [f]: storage full or a kill mid-write leaves the old [f] whole
/// (a write in place truncates it first).
void writeReplacing(File f, String text) {
  final tmp = File('${f.path}.tmp');
  tmp.writeAsStringSync(text, flush: true);
  tmp.renameSync(f.path);
}

/// The app's files folder for its recordings folder (files/recordings -> files).
Directory filesDirFor(String recordingsDir) => Directory(recordingsDir).parent;

class TrainingSettings {
  const TrainingSettings({this.replayCheck = false});
  final bool replayCheck;

  Map<String, Object?> toJson() => {'replayCheck': replayCheck};
  static TrainingSettings fromJson(Object? j) => TrainingSettings(replayCheck: j is Map && j['replayCheck'] == true);
}

class SettingsStore {
  SettingsStore(this.filesDir);
  final Directory filesDir;
  File get _file => File('${filesDir.path}/settings.json');

  /// The saved settings; a missing or damaged file gives the defaults (check off).
  TrainingSettings load() {
    try {
      return TrainingSettings.fromJson(jsonDecode(_file.readAsStringSync()));
    } on FileSystemException {
      return const TrainingSettings();
    } on FormatException {
      return const TrainingSettings();
    }
  }

  void save(TrainingSettings s) {
    filesDir.createSync(recursive: true);
    writeReplacing(_file, jsonEncode(s.toJson()));
  }
}

/// One kind's check: plan, sealed schedule, records and events.
class CheckStore {
  CheckStore(this.filesDir, this.kind);
  final Directory filesDir;
  final SessionKind kind;

  Directory get dir => Directory('${filesDir.path}/replay-check/${kind.name}');
  File _f(String name) => File('${dir.path}/$name');

  Object? _read(String name) {
    try {
      return jsonDecode(_f(name).readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  ({CheckPlan plan, String sha})? get plan {
    final j = _read('plan.json');
    if (j is! Map || j['sha256'] is! String) return null;
    final p = CheckPlan.fromJson(j['plan']);
    return p == null ? null : (plan: p, sha: j['sha256'] as String);
  }

  Sealed? get sealed => Sealed.fromJson(_read('sealed.json'));

  List<CheckRecord> get records {
    final j = _read('records.json');
    if (j is! List) return const [];
    return [for (final e in j) ?CheckRecord.fromJson(e)]..sort((a, b) => a.index.compareTo(b.index));
  }

  /// Draws the schedule and freezes the plan, once: the sealed file first, then the plan with the schedule's
  /// hash and its own. Does nothing when a plan exists.
  void freeze(DateTime now, {math.Random? random}) {
    if (plan != null && sealed != null) return;
    dir.createSync(recursive: true);
    final s = Sealed.draw(newSalt(random));
    writeReplacing(_f('sealed.json'), jsonEncode(s.toJson()));
    final p = CheckPlan(kind: kind, frozen: now, allocationSha256: s.sha);
    writeReplacing(_f('plan.json'), const JsonEncoder.withIndent(' ').convert({'plan': p.toJson(), 'sha256': p.sha}));
    event(now, 'plan frozen', {'sha256': p.sha});
  }

  void _writeRecords(List<CheckRecord> rs) {
    dir.createSync(recursive: true);
    writeReplacing(_f('records.json'), const JsonEncoder.withIndent(' ').convert([for (final r in rs) r.toJson()]));
  }

  /// Keeps a randomised session (right after it ends, before the answers, so every session is counted).
  void add(CheckRecord r) {
    final rs = [
      for (final e in records)
        if (e.index != r.index) e,
      r,
    ]..sort((a, b) => a.index.compareTo(b.index));
    _writeRecords(rs);
  }

  /// Adds the answers to the session at [index].
  void rate(int index, CheckRatings ratings) =>
      _writeRecords([for (final e in records) e.index == index ? e.withRatings(ratings) : e]);

  void event(DateTime at, String what, [Map<String, Object?> more = const {}]) {
    dir.createSync(recursive: true);
    _f('events.jsonl').writeAsStringSync(
      '${jsonEncode({'at': at.toIso8601String(), 'event': what, ...more})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// The results when a whole set of sessions exists, else null (locked). Null too without a plan.
  rv.Reveal? reveal() {
    final p = plan, s = sealed;
    if (p == null || s == null) return null;
    return rv.reveal(plan: p.plan, planSha: p.sha, sealed: s, records: records);
  }

  /// Sessions left until the next set can be revealed.
  int get untilReveal => CheckRule.revealEvery - records.length % CheckRule.revealEvery;
}

/// The next session of [store]'s kind given the kind's earlier sessions ([candidates]: live ones that could
/// be replayed). Freezes the plan before the first randomised session.
Slot prepareSlot(CheckStore store, List<DonorCandidate> candidates, double neededS, DateTime now) {
  final records = store.records;
  final replayed = {
    for (final r in records)
      if (r.arm == Arm.replay) r.stem,
  };
  final live = [
    for (final c in candidates)
      if (!replayed.contains(c.stem)) c,
  ];
  if (live.where((c) => c.runS >= 60).length >= CheckRule.donorsFirst && store.sealed == null) store.freeze(now);
  return nextSlot(kind: store.kind, sealed: store.sealed, records: records, candidates: live, neededS: neededS);
}

/// The words the setup shows before a session, without freezing anything (the same as the slot will say).
String previewStatus(CheckStore store, List<DonorCandidate> candidates) {
  final records = store.records;
  final replayed = {
    for (final r in records)
      if (r.arm == Arm.replay) r.stem,
  };
  final usable = candidates.where((c) => c.runS >= 60 && !replayed.contains(c.stem)).length;
  if (usable < CheckRule.donorsFirst) return Slot(kind: store.kind, phase: SlotPhase.donor, donorsHave: usable).status;
  if (records.length >= CheckRule.maxSessions) return Slot(kind: store.kind, phase: SlotPhase.finished).status;
  return Slot(kind: store.kind, phase: SlotPhase.randomised, index: records.length).status;
}

/// The control streams of [stems] (their `<stem>.session.json` in [dir]), decoded off the screen's thread.
Future<List<List<Control>>> loadStreams(Directory dir, List<String> stems, SessionKind kind) => Isolate.run(
  () => [
    for (final s in stems)
      controlStream(jsonDecode(File('${dir.path}/$s.session.json').readAsStringSync()) as Map<String, Object?>, kind),
  ],
);
