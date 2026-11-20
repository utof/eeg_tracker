// Deleting from the Archive (the owner's rules, 2026-11-20; DECISIONS 700-709):
// - **Remove from this phone** ([DeleteMode.rawOnLaptop]): a normal action, offered only while the laptop holds a checked
//   copy of every raw file of the recording as it is now. Removes the raw signal (each set's samples and index, a
//   meditation's whole log) through the phone's safe-delete helper (raw_remover.dart); everything else stays: the sets'
//   logs, headers and markers, the sleep report, the session's results, the tags. It stays on the laptop.
// - **Danger zone** (the page confirms it twice, in red): [DeleteMode.rawOnly] removes the same raw signal without the
//   laptop's copy (the only copy, when there is none); [DeleteMode.everything] also removes what was made from it: every
//   file of its sets, the session files and their companions (a dream catcher's spoken answers), the sleep report, the
//   tags and the Archive's kept activity tags. Statistics go only here, and only when picked.
// - Never while in use ([whyInUse]): a night recording (the newest recording of its folder), a session running (the
//   newest recording), the sleep scoring (unscored recordings of the last two days), or a file written in the last hour
//   (the helper's own rule: still recording, or just stopped).
// Plain dart:io; quick (a few deletes): the page runs it off the screen's thread anyway.
import 'dart:io';

import '../recorder/nights.dart' show stemTime;
import 'items.dart';
import 'raw_remover.dart';
import 'tags.dart';

enum DeleteMode {
  /// The raw signal only, with the laptop's checked copy of every raw file (the normal action).
  rawOnLaptop,

  /// The raw signal only, the only copy or not (Danger zone).
  rawOnly,

  /// Everything of the recording (Danger zone).
  everything,
}

/// What holds recordings now, as the page sees it when Delete is tapped.
class ArchiveBusy {
  const ArchiveBusy({this.nightRecording = false, this.sessionRunning = false, this.scoring = false});

  /// The night recorder runs (Start night, or the headband watcher).
  final bool nightRecording;

  /// A session holds the headband (dream catcher, sound, nap, work, meditation, check-in, ...).
  final bool sessionRunning;

  /// The sleep scoring reads a night's recordings.
  final bool scoring;
}

const Duration _scoringReads = Duration(days: 2);

/// The newest change of [item]'s recorded files on the phone: its sets' and its sessions' (not its tags or report, which
/// the app rewrites by itself); null when none could be read.
DateTime? lastWrite(Directory filesDir, ArchiveItem item) {
  DateTime? last;
  final paths = [
    for (final s in item.sets)
      for (final f in s.files) '${s.folder}/$f',
    for (final s in item.sessions) ...[s.path, ...s.companions],
  ];
  for (final p in paths) {
    try {
      final st = File('${filesDir.path}/$p').statSync();
      if (st.type != FileSystemEntityType.file) continue;
      if (last == null || st.modified.isAfter(last)) last = st.modified;
    } on FileSystemException {
      continue;
    }
  }
  return last;
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Why [item] cannot be deleted now, in words; null when it can. [all]: the whole list (which recording is the newest).
String? whyInUse(Directory filesDir, ArchiveItem item, List<ArchiveItem> all, ArchiveBusy busy, DateTime now) {
  bool newestIn(bool Function(ArchiveItem i) where) {
    final mine = all.where(where).toList();
    if (mine.isEmpty) return false;
    final newest = mine.reduce((a, b) => b.end.isAfter(a.end) ? b : a);
    return newest.id == item.id;
  }

  final folder = item.folder;
  if (busy.nightRecording && (folder == 'recordings' || folder == 'recordings-diy') && newestIn((i) => i.folder == folder)) {
    return 'A night is recording now: the newest recording waits until Stop.';
  }
  if (busy.sessionRunning && newestIn((_) => true)) return 'A session is running: its recording waits until it ends.';
  if (busy.scoring && folder == 'recordings' && item.report == null && now.difference(item.end) < _scoringReads) {
    return 'The phone is making a sleep report from recordings like this one: try again once it is done.';
  }
  final last = lastWrite(filesDir, item);
  if (last != null && now.difference(last) < removeSettled) {
    return 'Written at ${_hm(last)}: it may still be recording, or just stopped. It can go from ${_hm(last.add(removeSettled))}.';
  }
  return null;
}

/// What a delete would remove and keep, for the page's words.
class DeletePlan {
  const DeletePlan({
    required this.mode,
    required this.freedBytes,
    required this.removes,
    required this.keeps,
    required this.onlyCopy,
  });

  final DeleteMode mode;
  final int freedBytes;

  /// What goes and what stays, in words ("the raw signal (6 file sets)", "the sleep report").
  final List<String> removes;
  final List<String> keeps;

  /// Some raw signal it removes is on this phone only (no checked copy on the laptop).
  final bool onlyCopy;
}

String _plural(int n, String one, [String? many]) => n == 1 ? '1 $one' : '$n ${many ?? '${one}s'}';

/// The statistics that stay with the raw-only modes, and go with [DeleteMode.everything].
List<String> _statistics(ArchiveItem item) => [
  if (item.report != null) 'the sleep report',
  for (final s in item.sessions) 'the ${s.kind.word.toLowerCase()}\'s results',
  if (item.manualTags.isNotEmpty) 'your ${_plural(item.manualTags.length, 'tag')}',
  if (item.sets.isNotEmpty) 'each file set\'s log',
];

DeletePlan planDelete(ArchiveItem item, DeleteMode mode) {
  final sets = item.sets.where((s) => !s.removed && s.samplesBytes > 0).length;
  final sessionRaw = item.sessions.where((s) => s.rawCompanions.isNotEmpty).length;
  final raw = [
    if (sets > 0) 'the raw signal (${_plural(sets, 'file set')})',
    if (sessionRaw > 0) 'the whole session log',
  ];
  final stats = _statistics(item);
  final onlyCopy = item.hasRaw && item.laptop != OnLaptop.yes;
  if (mode == DeleteMode.everything) {
    return DeletePlan(mode: mode, freedBytes: item.bytes, removes: [...raw, ...stats], keeps: const [], onlyCopy: onlyCopy);
  }
  return DeletePlan(mode: mode, freedBytes: item.rawBytes, removes: raw, keeps: stats, onlyCopy: onlyCopy);
}

/// What deleting [items] together would remove and keep (a day of the list); one item's own words for one.
DeletePlan planDeleteAll(List<ArchiveItem> items, DeleteMode mode) {
  if (items.length == 1) return planDelete(items.single, mode);
  final plans = [for (final i in items) planDelete(i, mode)];
  final sets = items.fold(0, (n, i) => n + i.sets.where((s) => !s.removed && s.samplesBytes > 0).length);
  final logs = items.any((i) => i.sessions.any((s) => s.rawCompanions.isNotEmpty));
  final reports = items.where((i) => i.report != null).length;
  final sessions = items.fold(0, (n, i) => n + i.sessions.length);
  final tags = items.fold(0, (n, i) => n + i.manualTags.length);
  final raw = [if (sets > 0) 'the raw signal (${_plural(sets, 'file set')})', if (logs) 'the whole session logs'];
  final stats = [
    if (reports > 0) _plural(reports, 'sleep report'),
    if (sessions > 0) 'the results of ${_plural(sessions, 'session')}',
    if (tags > 0) 'your ${_plural(tags, 'tag')}',
    if (items.any((i) => i.sets.isNotEmpty)) "the file sets' logs",
  ];
  final everything = mode == DeleteMode.everything;
  return DeletePlan(
    mode: mode,
    freedBytes: plans.fold(0, (n, p) => n + p.freedBytes),
    removes: everything ? [...raw, ...stats] : raw,
    keeps: everything ? const [] : stats,
    onlyCopy: plans.any((p) => p.onlyCopy),
  );
}

/// What a delete did.
class DeleteOutcome {
  const DeleteOutcome({required this.freedBytes, required this.refused});
  final int freedBytes;

  /// What stayed and why (empty: all done).
  final List<String> refused;

  bool get complete => refused.isEmpty;
}

/// Deletes [item] by [mode] (see the top of the file). [busy]: the page's look at what records now; asked again here so
/// nothing in use goes. Never throws: what could not go is said in [DeleteOutcome.refused].
DeleteOutcome deleteItem(
  Directory filesDir,
  ArchiveItem item,
  DeleteMode mode, {
  required List<ArchiveItem> all,
  required RawRemover remover,
  ArchiveBusy busy = const ArchiveBusy(),
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final inUse = whyInUse(filesDir, item, all, busy, at);
  if (inUse != null) return DeleteOutcome(freedBytes: 0, refused: [inUse]);
  if (mode == DeleteMode.rawOnLaptop && item.laptop != OnLaptop.yes) {
    return const DeleteOutcome(freedBytes: 0, refused: ['the laptop has no checked copy of all of it']);
  }
  final onlyIfOnLaptop = mode == DeleteMode.rawOnLaptop;
  var freed = 0;
  final refused = <String>[];
  for (final s in item.sets) {
    final f32 = File('${filesDir.path}/${s.folder}/${s.stem}.f32');
    if (!s.removed && s.samplesBytes > 0) {
      final r = remover.removeRaw(f32, onlyIfOnLaptop: onlyIfOnLaptop, now: at);
      if (!r.removed) {
        refused.add('${s.stem}: ${r.refused}');
        continue;
      }
      freed += r.freedBytes;
    }
    if (mode == DeleteMode.everything) freed += _removeSet(filesDir, s);
  }
  for (final s in item.sessions) {
    for (final p in s.rawCompanions) {
      if (onlyIfOnLaptop && remover.onLaptop(p) != OnLaptop.yes) {
        refused.add('$p: not checked on the laptop yet');
        continue;
      }
      freed += _remove(File('${filesDir.path}/$p'));
    }
    if (mode == DeleteMode.everything) {
      for (final p in [s.path, ...s.companions]) {
        freed += _remove(File('${filesDir.path}/$p'));
      }
    }
  }
  if (mode == DeleteMode.everything && refused.isEmpty) {
    final r = item.report;
    if (r != null) {
      freed += _remove(File('${filesDir.path}/${r.path}'));
      _remove(File('${filesDir.path}/nights/${r.nightOf}.scoring'));
    }
    freed += _remove(TagStore(filesDir).fileFor(item.id));
    _remove(File('${filesDir.path}/cache/archive-seen/${item.id}.json'));
  }
  return DeleteOutcome(freedBytes: freed, refused: refused);
}

/// Every file of a set (its samples and index already gone or going): log, header, markers, its removed record, and
/// any half-written temporary file of it.
int _removeSet(Directory filesDir, RawSet s) {
  var freed = 0;
  final dir = Directory('${filesDir.path}/${s.folder}');
  try {
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final bare = name.startsWith('.') ? name.substring(1) : name;
      if (bare.length < 18 || bare.substring(0, 17) != s.stem || bare[17] != '.') continue;
      if (stemTime(bare) == null) continue;
      freed += _remove(f);
    }
  } on FileSystemException {
    // the folder is gone: nothing left of the set
  }
  return freed;
}

int _remove(File f) {
  try {
    final n = f.lengthSync();
    f.deleteSync();
    return n;
  } on FileSystemException {
    return 0;
  }
}
