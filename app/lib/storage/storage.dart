// Storage (DECISIONS 690-699; the owner, 2026-11-20: "like Telegram's Storage Usage", then his final rules): what the
// app keeps on the phone, by category; what may go; and how long a raw recording stays after the laptop checked it.
//
// Every file in `files/` belongs to one item of one category ([classify]). An item is
// - raw ([StorageItem.raw]): a recording's samples and index, removed set by set through recorder/remove.dart, which
//   leaves the set's record, log, header and markers, and every report made from it;
// - automatic ([StorageItem.auto]): what the category's "Delete from the phone" time applies to: the big raw recordings
//   and the spoken dream answers, never anything else. By default 3 days after the laptop checked a file (while a
//   laptop is paired); the owner may pick 1 week, 1 month or Never per category;
// - by hand only: recorder logs and the cache (the app makes the cache again and never shares it);
// - always kept ([StorageItem.kept]): the statistics and everything the app reads to show them (sleep reports,
//   session summaries, check-in results, transcripts, settings, each recording's notes): counted, never offered.
// Clearing by hand and by time deletes only what the paired laptop acked as it is now (recorder/acks.dart): never
// anything that exists only on this phone. That is the Danger zone's alone (by hand, twice confirmed, never by itself).
// The rules of what may go, and the deleting, are clear.dart's. Plain dart:io; tested on a plain folder.
import 'dart:convert';
import 'dart:io';

import '../export/store.dart' show sizeText;
import '../recorder/acks.dart';

/// One kind of file in a category.
class StorageItem {
  const StorageItem(this.id, this.label, {this.note = '', this.raw = false, this.auto = false, this.regenerable = false, this.kept = false});

  final String id;
  final String label;

  /// One muted line under the label; empty for none.
  final String note;
  final bool raw;
  final bool auto;
  final bool regenerable;

  /// Always kept on the phone: never offered.
  final bool kept;
}

class StorageCategory {
  const StorageCategory(this.id, this.label, this.items);
  final String id;
  final String label;
  final List<StorageItem> items;

  /// Whether a "Delete from the phone" time applies to it (it has something that may go by itself).
  bool get keepable => items.any((i) => i.auto);
}

const List<StorageCategory> storageCategories = [
  StorageCategory('nights', 'Sleep nights', [
    StorageItem(
      'nights.raw',
      'Raw recordings',
      note: 'Nights and naps, and the dream catcher and sound sessions that record with the headband',
      raw: true,
      auto: true,
    ),
    StorageItem('nights.reports', 'Sleep reports', note: 'Stages, minutes and what Trends shows', kept: true),
  ]),
  StorageCategory('work', 'Work sessions', [
    StorageItem('work.raw', 'Raw recordings', raw: true, auto: true),
    StorageItem('work.summaries', 'Session summaries', kept: true),
  ]),
  StorageCategory('meditation', 'Meditation and alpha-theta', [
    StorageItem('meditation.sessions', 'Sessions and the journal', kept: true),
  ]),
  StorageCategory('sound', 'Sound sessions', [StorageItem('sound.sessions', 'Sessions and tests', kept: true)]),
  StorageCategory('naps', 'Naps', [StorageItem('naps.sessions', 'Sessions', kept: true)]),
  StorageCategory('dream', 'Dream catcher', [
    StorageItem('dream.audio', 'Spoken answers', note: 'The recordings of your voice', auto: true),
    StorageItem('dream.text', 'Transcripts', note: 'Your answers as words', kept: true),
    StorageItem('dream.sessions', 'Sessions and your prompts', kept: true),
  ]),
  StorageCategory('checkins', 'Morning check-ins', [
    StorageItem('checkins.raw', 'Raw recordings', raw: true, auto: true),
    StorageItem('checkins.results', 'Results', kept: true),
  ]),
  StorageCategory('diy', 'DIY board', [StorageItem('diy.raw', 'Raw recordings', raw: true, auto: true)]),
  StorageCategory('logs', 'Logs', [
    StorageItem('logs.recorder', 'Recorder logs', note: 'What happened during each recording'),
    // the app's own records (lib/logs, DECISIONS 710-719): they keep 7 to 90 days by themselves, and each page under
    // More, How the app runs, deletes its own; counted here, never offered
    StorageItem('logs.app', 'App log, usage and battery', note: 'Kept 7 to 90 days; How the app runs deletes them', kept: true),
  ]),
  StorageCategory('cache', 'Cache', [
    StorageItem('cache.all', 'Working files', note: 'Made again by the app when it needs them', regenerable: true),
  ]),
  StorageCategory('other', 'Settings and notes', [
    StorageItem('other.all', 'Settings, plans, answers and each recording\'s notes', kept: true),
  ]),
];

final Map<String, StorageItem> storageItems = {for (final c in storageCategories) for (final i in c.items) i.id: i};

/// The category of [itemId].
StorageCategory categoryOf(String itemId) => storageCategories.firstWhere((c) => c.items.any((i) => i.id == itemId));

final RegExp _stamped = RegExp(r'^\d{4}-\d{2}-\d{2}-\d{6}\.');
final RegExp _answer = RegExp(r'-r\d+\.wav$');

/// The header's `session` of a recording that is not sleep (a work session's raw EEG writes `work`, DECISIONS 683);
/// null for sleep and for a set without a header.
String? sessionOf(File f32) {
  final p = f32.path;
  final stem = p.endsWith('.f32') ? p.substring(0, p.length - 4) : p;
  try {
    final j = jsonDecode(File('$stem.header.json').readAsStringSync());
    final s = j is Map ? j['session'] : null;
    return s is String && s != 'night' && s != 'nap' ? s : null;
  } catch (_) {
    return null;
  }
}

/// The item of the file at [path] (relative to `files/`, `/`-separated). [session] says what a raw set in
/// `recordings/` was recorded by ([sessionOf]).
String classify(String path, {String? Function(String stemPath)? session}) {
  final parts = path.split('/');
  final top = parts.first, name = parts.last;
  final inSet = parts.length == 2 && _stamped.hasMatch(name);
  final raw = inSet && isRawPath(path);
  final log = inSet && name.endsWith('.log');
  switch (top) {
    case 'recordings':
      if (raw) return session?.call('recordings/${name.substring(0, 17)}') == 'work' ? 'work.raw' : 'nights.raw';
      return log ? 'logs.recorder' : 'other.all';
    case 'recordings-diy':
      if (raw) return 'diy.raw';
      return log ? 'logs.recorder' : 'other.all';
    case 'mornings':
      if (raw) return 'checkins.raw';
      if (log) return 'logs.recorder';
      return name.endsWith('.header.json') || name.endsWith('.markers.jsonl') || name.endsWith('.removed.json')
          ? 'other.all'
          : 'checkins.results';
    case 'nights':
      return name.endsWith('.report.json') || name.endsWith('.png') ? 'nights.reports' : 'other.all';
    case 'work-sessions':
      return 'work.summaries';
    case 'meditations' || 'alpha-theta':
      return 'meditation.sessions';
    case 'sound-states':
      return 'sound.sessions';
    case 'naps':
      return 'naps.sessions';
    case 'dream-catcher':
      if (parts.length == 2 && _answer.hasMatch(name)) return 'dream.audio';
      if (parts.length == 2 && name.endsWith('.text.json')) return 'dream.text';
      return 'dream.sessions';
    case 'cache':
      return 'cache.all';
    case 'logs':
      return 'logs.app';
  }
  return 'other.all';
}

/// "Delete from the phone" choices: days after the laptop checked a file; 0: never.
const List<int> keepChoices = [3, 7, 30, 0];

/// The default while a laptop is paired (the owner, 2026-11-20).
const int defaultKeepDays = 3;

String keepWords(int days) => switch (days) {
  0 => 'Never',
  3 => '3 days',
  7 => '1 week',
  30 => '1 month',
  _ => '$days days',
};

/// The Storage page's settings, `files/transfer/storage.json`: per category, days after the laptop checked a file
/// before the phone deletes it by itself (0: never; missing: [defaultKeepDays]).
class StorageSettings {
  const StorageSettings({this.keep = const {}});

  final Map<String, int> keep;

  int keepDays(String category) => keep[category] ?? defaultKeepDays;

  StorageSettings withKeep(String category, int days) => StorageSettings(keep: {...keep, category: days});

  Map<String, Object?> toJson() => {'keep_days': keep};

  static StorageSettings fromJson(Object? j) {
    if (j is! Map) return const StorageSettings();
    final k = j['keep_days'];
    return StorageSettings(
      keep: {
        if (k is Map)
          for (final e in k.entries)
            if (e.key is String && e.value is int && (e.value as int) >= 0) e.key as String: e.value as int,
      },
    );
  }
}

class StorageStore {
  StorageStore(this.filesDir);
  final Directory filesDir;

  File get _file => File('${filesDir.path}/$transferFolder/storage.json');

  StorageSettings load() {
    try {
      return StorageSettings.fromJson(jsonDecode(_file.readAsStringSync()));
    } catch (_) {
      return const StorageSettings();
    }
  }

  void save(StorageSettings s) {
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(s.toJson()), flush: true);
    tmp.renameSync(_file.path);
  }
}

/// Every file of `files/` with its item, path (relative) and bytes. A file that vanishes while listed is skipped.
List<({String item, String path, File file, int bytes})> storedByItem(Directory filesDir) {
  final out = <({String item, String path, File file, int bytes})>[];
  if (!filesDir.existsSync()) return out;
  final base = filesDir.path.length + 1;
  final sessions = <String, String?>{};
  String? session(String stemPath) =>
      sessions.putIfAbsent(stemPath, () => sessionOf(File('${filesDir.path}/$stemPath.f32')));
  for (final e in filesDir.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    try {
      final path = e.path.substring(base).replaceAll(Platform.pathSeparator, '/');
      out.add((item: classify(path, session: session), path: path, file: e, bytes: e.lengthSync()));
    } on FileSystemException {
      continue;
    }
  }
  return out;
}

/// The raw recordings on the phone: the bytes they take, and the bytes of those the laptop holds no checked copy of
/// as they are now ("waiting": not yet copied, or copied and not yet checked; the one being written is always among
/// them). Reads sizes, times and the acks; a packed file's header.
({int bytes, int waiting}) rawOnPhone(Directory filesDir) {
  final acks = AckStore(filesDir).load();
  var bytes = 0, waiting = 0;
  for (final folder in movableFolders) {
    final dir = Directory('${filesDir.path}/$folder');
    if (!dir.existsSync()) continue;
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final path = '$folder/${f.uri.pathSegments.last}';
        if (!isRawPath(path)) continue;
        final n = f.lengthSync();
        bytes += n;
        if (!ackedNow(acks, path, f)) waiting += n;
      }
    } on FileSystemException {
      continue;
    }
  }
  return (bytes: bytes, waiting: waiting);
}

/// The Record tab's line under "Your data" (DECISIONS 1041): what the recordings take and what waits for the laptop.
/// Null with no recordings on the phone.
String? storageLine(({int bytes, int waiting}) s, {required bool paired}) {
  if (s.bytes <= 0) return null;
  final all = 'Recordings on this phone: ${sizeText(s.bytes)}.';
  if (!paired) return '$all No laptop is paired: nothing is cleared by itself.';
  if (s.waiting <= 0) return '$all The laptop has checked all of it.';
  if (s.waiting >= s.bytes) return '$all All of it waits for the laptop to check it.';
  return '$all ${sizeText(s.waiting)} waits for the laptop to check it.';
}
