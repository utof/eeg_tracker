// What the Storage page may delete, and the deleting (DECISIONS 690-699; the owner's rules of 2026-11-20).
//
// Three ways ([ClearMode]):
// - checked: "Clear selected": only what the paired laptop acked as it is now (recorder/acks.dart), and the cache;
// - keep time: by itself between nights, while a laptop is paired: what the laptop acked longer ago than its
//   category's time (3 days unless the owner picked another); only raw recordings and spoken answers;
// - phone only: the Danger zone, by hand and twice confirmed: what is NOT on the laptop. Never by itself.
// In every way:
// - raw recordings go set by set through recorder/remove.dart (never one being read, nothing written in the last hour);
// - a sleep night (`recordings/`) goes whole, and only once its sleep report exists and was made from its recordings
//   as they are, with no scoring of it under way: the newest night never goes before its report, and the phone's
//   statistics (Trends, "Was this you?", the summaries) keep reading that report; a night is never half on the phone;
// - a DIY board's night (`recordings-diy/`, never scored) goes whole too; a work session's raw EEG (its header says
//   `session: work`) and a check-in's raw signal (`mornings/`) go set by set;
// - any other file goes on its own when written over an hour ago; a recorder log stays while its recording's samples
//   are on the phone without a header (an old set's log says what its samples hold); a spoken dream answer stays until
//   it has its words (the transcript, or the owner's own); statistics never go (storage.dart's kept items are never
//   planned).
// [planClear] works out what would go (pure: a background isolate); [runClear] deletes it on the isolate whose readers
// [RawUse] knows, checking each set and file again, and stops before the next as soon as [busy] says something records.
import 'dart:io';

import '../dream/answer_text.dart' show readAnswerText;
import '../recorder/acks.dart';
import '../recorder/nights.dart';
import '../recorder/packed.dart' show isPackedPath, rawExists, rawLength, rawOnDisk, rawSuffix;
import '../recorder/recheck.dart';
import '../recorder/remove.dart';
import '../sleep/progress.dart' show ScoringProgressStore, scoringProgressDirFor;
import '../sleep/report.dart' show NightReportStore, isStale, nightsDirFor;
import 'storage.dart';

enum ClearMode { checked, keepTime, phoneOnly }

/// Why a recording or file left the phone, as its record says it.
const String whyCleared = 'cleared on the Storage page';
const String whyKeepTime = 'deleted from the phone after the laptop had checked it';
const String whyPhoneOnly = 'deleted from the phone only (Danger zone)';

/// Raw sets that go together: a night's, or one set.
typedef RawGroup = ({String item, String? night, List<String> sets, int bytes});

/// What clearing would remove now, and what stays and why.
class ClearPlan {
  ClearPlan(this.mode);
  final ClearMode mode;
  final List<RawGroup> groups = [];
  final List<({String item, String path, int bytes})> files = [];

  /// Item -> bytes and files (or sets) that would go.
  final Map<String, int> bytes = {};
  final Map<String, int> count = {};

  /// Item -> bytes that stay now, and the first reason.
  final Map<String, int> kept = {};
  final Map<String, String> why = {};

  int get total => bytes.values.fold(0, (a, b) => a + b);
  int get items => count.values.fold(0, (a, b) => a + b);

  void _go(String item, int n, [int k = 1]) {
    bytes[item] = (bytes[item] ?? 0) + n;
    count[item] = (count[item] ?? 0) + k;
  }

  void _stay(String item, int n, String reason) {
    kept[item] = (kept[item] ?? 0) + n;
    why.putIfAbsent(item, () => reason);
  }
}

int _size(File f) {
  try {
    return f.lengthSync();
  } on FileSystemException {
    return 0;
  }
}

/// Whether the report of [night] (in `recordings/`) exists, was made from its recordings as they are, and no scoring
/// of it is under way.
bool _reported(Directory dir, NightFiles night) {
  final report = NightReportStore(nightsDirFor(dir.path)).read(night.name);
  if (report == null) return false;
  if (night.removed.isNotEmpty) return true; // a clearing stopped half-way: the report was whole when it began
  final inputs = {
    for (final f in night.recordings)
      if (rawExists(f)) f.uri.pathSegments.last: rawLength(f), // the scorer's own inputs (SleepScorer.inputsOf)
  };
  if (isStale(inputs, report)) return false;
  return ScoringProgressStore(scoringProgressDirFor(dir.path)).read(night.name) == null;
}

/// The stems (`2026-11-18-231200`) with samples or an index in [dir].
List<String> _rawStems(Directory dir) {
  final out = <String>{};
  if (!dir.existsSync()) return const [];
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (stemTime(name) == null) continue;
    if (name.endsWith(rawSuffix) || isPackedPath(name) || name.endsWith('.idx')) out.add(name.substring(0, 17));
  }
  return out.toList()..sort();
}

class _Planner {
  _Planner(this.filesDir, this.plan, this.now, this.before)
    : acks = AckStore(filesDir).load();
  final Directory filesDir;
  final ClearPlan plan;
  final DateTime now;
  final Map<String, DateTime> before;
  final Map<String, LaptopCopy> acks;

  bool get phoneOnly => plan.mode == ClearMode.phoneOnly;

  /// The laptop holds a checked copy of every one of [files] as they are now; with a cut-off, acked before it too.
  bool _onLaptop(List<File> files, String item) {
    final cut = before[item];
    for (final f in files) {
      final c = acks[ackPathOf(relativeRaw(f))];
      if (c == null || !c.matches(f)) return false;
      if (cut != null && c.ackedMs >= cut.millisecondsSinceEpoch) return false;
    }
    return files.isNotEmpty;
  }

  /// Adds one group when it may go in this mode.
  void group(String item, String? night, List<String> sets, {String? notYet}) {
    final files = [for (final s in sets) ...rawFilesOf(File(s))];
    final n = files.fold(0, (m, f) => m + _size(f));
    if (n == 0) return;
    final checked = files.every((f) => ackedNow(acks, relativeRaw(f), f));
    if (phoneOnly ? checked : !checked) {
      if (!phoneOnly) plan._stay(item, n, 'not checked on the laptop yet');
      return; // the phone-only part of a night is the Danger zone's; a night all on the laptop is not
    }
    if (plan.mode == ClearMode.keepTime && !_onLaptop(files, item)) return; // checked, but not long enough ago
    final why = notYet ??
        sets.map((s) => whyNotRemove(File(s), onlyIfOnLaptop: !phoneOnly, acks: acks, now: now)).nonNulls.firstOrNull;
    if (why != null) return plan._stay(item, n, why);
    plan.groups.add((item: item, night: night, sets: sets, bytes: n));
    plan._go(item, n);
  }

  void nights(Directory dir, String item, {required bool scored, required List<NightFiles> Function(Directory) list}) {
    if (!dir.existsSync()) return;
    for (final n in list(dir).reversed) {
      final sets = [
        for (final f in n.recordings)
          if (!scored || sessionOf(f) != 'work') f.path, // a work session's set is the work item's
      ];
      if (sets.isEmpty) continue;
      group(item, n.name, sets, notYet: scored && !_reported(dir, n) ? 'no sleep report yet' : null);
    }
  }

  void sets(Directory dir, String item, bool Function(File f32) take) {
    for (final stem in _rawStems(dir)) {
      final f32 = File('${dir.path}/$stem$rawSuffix');
      if (take(f32)) group(item, null, [f32.path]);
    }
  }

  void single(Set<String> items) {
    for (final f in storedByItem(filesDir)) {
      if (!items.contains(f.item)) continue;
      final item = storageItems[f.item]!;
      if (item.regenerable && phoneOnly) continue; // the cache is cleared the plain way
      final DateTime modified;
      try {
        modified = f.file.statSync().modified;
      } on FileSystemException {
        continue;
      }
      final checked = item.regenerable || ackedNow(acks, f.path, f.file);
      if (phoneOnly == checked) {
        if (!phoneOnly) plan._stay(f.item, f.bytes, 'not checked on the laptop yet');
        continue;
      }
      final cut = before[f.item];
      final ackedAt = acks[ackPathOf(f.path)]?.ackedMs;
      if (cut != null && (ackedAt == null || ackedAt >= cut.millisecondsSinceEpoch)) continue;
      String? why;
      if (!item.regenerable && now.difference(modified) < removeSettled) {
        why = 'written in the last hour';
      } else if (item.id == 'logs.recorder' && _logNeeded(f.file)) {
        why = 'its recording still needs it';
      } else if (item.id == 'dream.audio' && !_written(f.file)) {
        why = 'not turned into words yet';
      }
      if (why != null) {
        plan._stay(f.item, f.bytes, why);
      } else {
        plan.files.add((item: f.item, path: f.path, bytes: f.bytes));
        plan._go(f.item, f.bytes);
      }
    }
  }
}

/// A spoken dream answer whose words exist (the transcript, or the owner's own): the words are what stays.
bool _written(File wav) {
  final t = readAnswerText(wav.parent, wav.uri.pathSegments.last);
  return t != null && (t.machine != null || (t.edited?.trim().isNotEmpty ?? false));
}

/// A recorder log whose recording's samples are on the phone without a header: it says what they hold.
bool _logNeeded(File log) {
  final stem = log.path.substring(0, log.path.length - 4);
  return rawOnDisk(File('$stem$rawSuffix')) != null && !File('$stem.header.json').existsSync();
}

/// What clearing [items] of [filesDir] in [mode] would remove now. [before] (keep time): item -> only what the laptop
/// acked before then. [nights] lists a folder's nights (nightsIn; tests pass their own).
ClearPlan planClear(
  Directory filesDir,
  Set<String> items, {
  required ClearMode mode,
  required DateTime now,
  Map<String, DateTime> before = const {},
  List<NightFiles> Function(Directory dir) nights = nightsIn,
}) {
  final plan = ClearPlan(mode);
  final p = _Planner(filesDir, plan, now, before);
  Directory folder(String name) => Directory('${filesDir.path}/$name');
  final ok = {
    for (final i in items)
      if (storageItems[i] case final item? when !item.kept && (mode != ClearMode.keepTime || item.auto)) i,
  };
  if (ok.contains('nights.raw')) p.nights(folder('recordings'), 'nights.raw', scored: true, list: nights);
  if (ok.contains('diy.raw')) p.nights(folder('recordings-diy'), 'diy.raw', scored: false, list: nights);
  if (ok.contains('work.raw')) p.sets(folder('recordings'), 'work.raw', (f) => sessionOf(f) == 'work');
  if (ok.contains('checkins.raw')) p.sets(folder('mornings'), 'checkins.raw', (_) => true);
  final single = {for (final i in ok) if (!storageItems[i]!.raw) i};
  if (single.isNotEmpty) p.single(single);
  return plan;
}

/// One clearing's outcome.
class ClearRun {
  final List<String> removed = []; // nights, sets and files that went
  final Map<String, String> kept = {}; // what stayed after all (read meanwhile, changed meanwhile), and why
  int freedBytes = 0;
  bool stopped = false;
}

/// Deletes what [plan] says may go, checking each set and file again (see the top of this file); stops before the next
/// group (or every 50 files) as soon as [busy] is true. Never throws.
Future<ClearRun> runClear(
  Directory filesDir,
  ClearPlan plan, {
  required Future<bool> Function() busy,
  String? laptop,
  DateTime Function() clock = DateTime.now,
}) async {
  final run = ClearRun();
  final phoneOnly = plan.mode == ClearMode.phoneOnly;
  final why = switch (plan.mode) {
    ClearMode.checked => whyCleared,
    ClearMode.keepTime => whyKeepTime,
    ClearMode.phoneOnly => whyPhoneOnly,
  };
  try {
    final acks = AckStore(filesDir).load();
    for (final g in plan.groups) {
      if (await busy()) {
        run.stopped = true;
        return run;
      }
      final now = clock();
      final name = g.night ?? g.sets.first.split('/').last;
      final files = [for (final s in g.sets) File(s)];
      final whyNot = files.map((f) => whyNotRemove(f, onlyIfOnLaptop: !phoneOnly, acks: acks, now: now)).nonNulls.firstOrNull;
      if (whyNot != null) {
        run.kept[name] = whyNot; // the whole night stays until every set may go
        continue;
      }
      for (final f in files) {
        final r = removeRaw(f, onlyIfOnLaptop: !phoneOnly, acks: acks, why: why, laptop: laptop, night: g.night, now: now);
        run.freedBytes += r.freedBytes;
        if (!r.removed) run.kept[name] = r.refused ?? 'refused';
      }
      if (!run.kept.containsKey(name)) run.removed.add(name);
    }
    var k = 0;
    for (final f in plan.files) {
      if (k++ % 50 == 0 && await busy()) {
        run.stopped = true;
        return run;
      }
      final file = File('${filesDir.path}/${f.path}');
      final item = storageItems[f.item]!;
      try {
        final st = file.statSync();
        if (st.type != FileSystemEntityType.file) continue;
        if (!item.regenerable && clock().difference(st.modified) < removeSettled) {
          run.kept[f.path] = 'written in the last hour';
          continue;
        }
        if (!phoneOnly && !item.regenerable && !ackedNow(acks, f.path, file)) {
          run.kept[f.path] = 'not checked on the laptop yet';
          continue;
        }
        file.deleteSync();
        run.freedBytes += st.size;
        run.removed.add(f.path);
      } on FileSystemException catch (e) {
        run.kept[f.path] = 'could not delete: ${e.message}';
      }
    }
  } on Object catch (e) {
    run.kept['all'] = '$e';
  }
  return run;
}

/// What the page shows: per item its bytes and files on the phone, what "Clear selected" would free of it now (on the
/// laptop), and what only the Danger zone could (only on this phone).
class StorageUsage {
  StorageUsage({
    required this.bytes,
    required this.files,
    required this.clearable,
    required this.phoneOnly,
    required this.phoneOnlyCount,
    required this.why,
    required this.onLaptop,
  });

  final Map<String, int> bytes;
  final Map<String, int> files;
  final Map<String, int> clearable;
  final Map<String, int> phoneOnly;
  final Map<String, int> phoneOnlyCount;

  /// Item -> why some of it stays (the first reason).
  final Map<String, String> why;

  /// The plain bytes of every file the laptop holds a checked copy of (also of those since deleted here).
  final int onLaptop;

  int get total => bytes.values.fold(0, (a, b) => a + b);
  int categoryBytes(StorageCategory c) => c.items.fold(0, (n, i) => n + (bytes[i.id] ?? 0));
}

/// The usage by category, in the order of [storageCategories]: what the storage bar (ui/storage_bar.dart) and any
/// page showing the app's space draw from.
List<({String id, String label, int bytes})> usageByCategory(StorageUsage u) => [
  for (final c in storageCategories) (id: c.id, label: c.label, bytes: u.categoryBytes(c)),
];

/// Every item that may ever go (not the statistics).
Set<String> get clearableItems => {for (final i in storageItems.values) if (!i.kept) i.id};

/// The usage of [filesDir] (a background isolate: it lists every file and works out the nights).
StorageUsage scanStorage(Directory filesDir, {required DateTime now}) {
  final bytes = <String, int>{}, files = <String, int>{};
  for (final f in storedByItem(filesDir)) {
    bytes[f.item] = (bytes[f.item] ?? 0) + f.bytes;
    files[f.item] = (files[f.item] ?? 0) + 1;
  }
  final checked = planClear(filesDir, clearableItems, mode: ClearMode.checked, now: now);
  final danger = planClear(filesDir, clearableItems, mode: ClearMode.phoneOnly, now: now);
  return StorageUsage(
    bytes: bytes,
    files: files,
    clearable: checked.bytes,
    phoneOnly: danger.bytes,
    phoneOnlyCount: danger.count,
    why: checked.why,
    onLaptop: AckStore(filesDir).load().values.fold(0, (n, c) => n + c.bytes),
  );
}

/// The items the keep times apply to now, each with its cut-off: what the laptop acked before it goes.
Map<String, DateTime> keepCutoffs(StorageSettings s, DateTime now) => {
  for (final c in storageCategories)
    if (s.keepDays(c.id) > 0)
      for (final i in c.items)
        if (i.auto) i.id: now.subtract(Duration(days: s.keepDays(c.id))),
};

/// The automatic deleting between nights, while a laptop is paired: what the laptop checked longer ago than its
/// category's time goes from the phone; nothing that is only on the phone, ever. And only what the laptop proved again
/// in the last 15 minutes that it still holds, byte for byte (recheck.dart, DECISIONS 756): every other due file is
/// asked about now, and goes at a later run once the laptop has answered. [plan] works the plan out (a background
/// isolate on the phone). Never throws; null when nothing was due or something records.
Future<ClearRun?> autoClear(
  Directory filesDir, {
  required Future<bool> Function() busy,
  required bool paired,
  String? laptop,
  DateTime Function() clock = DateTime.now,
  Future<ClearPlan> Function(Directory filesDir, Map<String, DateTime> before)? plan,
}) async {
  try {
    if (!paired) return null;
    final before = keepCutoffs(StorageStore(filesDir).load(), clock());
    if (before.isEmpty || await busy()) return null;
    final p = plan == null
        ? planClear(filesDir, before.keys.toSet(), mode: ClearMode.keepTime, now: clock(), before: before)
        : await plan(filesDir, before);
    if (p.groups.isEmpty && p.files.isEmpty) return ClearRun();
    final store = RecheckStore(filesDir), now = clock();
    List<String> pathsOf(RawGroup g) => [
      for (final s in g.sets)
        for (final f in rawFilesOf(File(s))) ackPathOf(relativeRaw(f)),
    ];
    store.ask([for (final g in p.groups) ...pathsOf(g), for (final f in p.files) ackPathOf(f.path)], now: now);
    final proven = ClearPlan(p.mode);
    final groupPaths = <RawGroup, List<String>>{};
    for (final g in p.groups) {
      final paths = groupPaths[g] = pathsOf(g);
      if (paths.isNotEmpty && paths.every((x) => store.proven(x, now))) proven.groups.add(g);
    }
    for (final f in p.files) {
      if (store.proven(ackPathOf(f.path), now)) proven.files.add(f);
    }
    if (proven.groups.isEmpty && proven.files.isEmpty) return ClearRun(); // asked: the laptop answers at its next look
    final run = await runClear(filesDir, proven, busy: busy, laptop: laptop, clock: clock);
    store.forget([
      for (final g in proven.groups)
        if (run.removed.contains(g.night ?? g.sets.first.split('/').last)) ...?groupPaths[g],
      for (final f in proven.files)
        if (run.removed.contains(f.path)) ackPathOf(f.path),
    ]);
    return run;
  } on Object {
    return null;
  }
}
