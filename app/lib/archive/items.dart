// The Archive (owner, 2026-11-20: "make an archive page where we can see what data was recorded, was it manual or
// automatic ... we can click inside the recording ... make it easy to delete recordings"; DECISIONS 700-709): every
// recording and session the phone keeps, as one list, newest first. Plain Dart over the app's `files/` folder; the page
// builds it in a background isolate.
//
// A recording is one or more raw file sets (`<stamp>.f32` or `.f32.gz`, `.idx`, `.log`, `.markers.jsonl`,
// `.header.json`) in one raw folder. The night recorder's sets join into one recording when the next one continues the
// one before (its `.log` says it reconnected after a drop, or that Android restarted the service) or starts under 15
// minutes after its last data, up to 24 hours from the first; a session's set (nap, dream catcher, sound, check-in,
// calibration) is a recording of its own. What describes a recording joins it: the session file that names its stem
// (nap, dream catcher, sound) or covers its time (a check-in, a work session), the sleep report most of whose inputs
// are its sets, its tags (archive/tags.dart). A session without raw signal (a work session, a meditation) is an item of
// its own, and so is a recording whose raw signal was removed while its report, session or tags were kept (its tags
// file keeps what it was: archive/delete.dart).
//
// How it started: the night recorder writes "started automatically" or "started after "Yes"" as the first lines of a
// night the headband watcher started (auto/controller.dart), and the watcher's minutes kept while it asked open with
// "auto-start:"; a session's set opens with its own line ("nap coach session", ...). A work session the watcher started
// is in its log (`files/auto-start/log.jsonl`, a `start` line of kind work). Anything else in `recordings/` was started
// with Start night.
//
// Read once (DECISIONS 620): each file set's summary is kept with the size and modified time of every file of the set
// in `files/cache/archive-sets.json`, each session file's and report's through SummaryIndex, so a list after the first
// opens only what is new or changed.
import 'dart:convert';
import 'dart:io';

import '../cache/file_summaries.dart';
import '../export/store.dart' show ExportStore;
import '../recorder/header.dart' show headerFileOf, tryHeader;
import '../recorder/nights.dart' show stemTime;
import '../recorder/packed.dart' show isPackedPath, packedInfo, rawLength, rawOnDisk;
import '../spans/span.dart' show removedSpanIds;
import '../trends/days.dart' show dayKey;
import 'raw_remover.dart';
import 'tags.dart';

/// The raw folders of `files/`, and what their sets are when their `.log` does not say.
const Map<String, String> rawFolders = {
  'recordings': 'night',
  'recordings-diy': 'board',
  'mornings': 'checkin',
  'hands-free/recordings': 'handsfree',
};

/// The files of a raw file set, after its stem.
const List<String> rawSuffixes = ['.f32', '.f32.gz', '.idx', '.log', '.markers.jsonl', '.header.json', removedSuffix];

/// A night's next set joins the recording when it starts this soon after its last data (planning value: a reconnect
/// that found the headband again; the recorder's own continuation lines join any gap).
const Duration joinGap = Duration(minutes: 15);

/// No recording spans more than this from its first set (the nights' rule, DECISIONS 82).
const Duration maxRecording = Duration(hours: 24);

/// Version of the kept summaries (a change drops them).
const int _setsVersion = 4;
const int _sessionsVersion = 4;

enum ArchiveKind {
  night('Night', 'sleep'),
  work('Work session', 'work'),
  meditation('Meditation', 'meditation'),
  alphaTheta('Alpha-theta', 'meditation'),
  nap('Nap', 'nap'),
  dream('Dream catcher', 'dream catcher'),
  sound('Sound', 'sound'),
  checkIn('Morning check-in', 'check-in'),
  handsFree('Hands-free calibration', 'calibration'),
  board('DIY board', 'board test'),
  recording('Recording', null);

  const ArchiveKind(this.word, this.tag);

  /// The list's word.
  final String word;

  /// The tag it gives the whole recording (the button you pressed, or the watcher's guess); null: none.
  final String? tag;

  static ArchiveKind byName(Object? n) => values.firstWhere((k) => k.name == n, orElse: () => recording);
}

enum StartedHow {
  /// You pressed a button (Start night, a session's Start).
  hand,

  /// The headband watcher started it by itself (DECISIONS 604).
  watcher,

  /// The watcher asked and you said Yes.
  watcherYes,

  /// The files do not say (older files, or a writer this list does not know).
  unknown,
}

class Started {
  const Started(this.how, this.words);
  final StartedHow how;

  /// "You: Start night", "By itself: the headband watcher", ...
  final String words;

  /// You decided it (a button, or Yes to the watcher's question); the watcher alone did not.
  bool get byYou => how == StartedHow.hand || how == StartedHow.watcherYes;

  Map<String, Object?> toJson() => {'how': how.name, 'words': words};
}

const Started _watcher = Started(StartedHow.watcher, 'By itself: the headband watcher');
const Started _watcherYes = Started(StartedHow.watcherYes, 'The headband watcher asked; you said Yes');
const Started _unknown = Started(StartedHow.unknown, 'Not known (the files do not say)');

/// The button a recording of [kind] is started with.
Started byHand(ArchiveKind kind) => Started(StartedHow.hand, 'You: ${switch (kind) {
  ArchiveKind.night => 'Record or Sleep',
  ArchiveKind.work => 'Work session',
  ArchiveKind.meditation => 'Meditation',
  ArchiveKind.alphaTheta => 'Alpha-theta',
  ArchiveKind.nap => 'Nap coach',
  ArchiveKind.dream => 'Dream catcher',
  ArchiveKind.sound => 'Sound',
  ArchiveKind.checkIn => 'Morning check-in',
  ArchiveKind.handsFree => 'Calibrate (Settings)',
  ArchiveKind.board => 'Record or Sleep (DIY board)',
  ArchiveKind.recording => 'a start the files do not name',
}}');

/// One raw file set, as the list needs it.
class RawSet {
  const RawSet({
    required this.folder,
    required this.stem,
    required this.start,
    required this.end,
    required this.bytes,
    required this.rawBytes,
    required this.writer,
    required this.files,
    this.continues = false,
    this.auto,
    this.names = const [],
    this.rate,
    this.device,
    this.removed = false,
    this.removedOnLaptop = false,
    this.samplesBytes = 0,
    this.recording,
  });

  /// The recording the set's header names (Record first, DECISIONS 882); null: a set from before, joined by time.
  final String? recording;

  /// Relative to `files/`, `recordings`.
  final String folder;
  final String stem;
  final DateTime start;

  /// Its last data; null when it holds no whole sample.
  final DateTime? end;

  /// Every file of the set on the phone, and the raw signal unpacked.
  final int bytes;
  final int rawBytes;

  /// Who wrote it: night, preroll, nap, dream, sound, checkin, handsfree, board, other.
  final String writer;

  /// Its file names.
  final List<String> files;

  /// It continues the night recorder's set before it (a reconnect after a drop, Android restarting the service).
  final bool continues;

  /// The headband watcher started its night: `automatic` or `yes`.
  final String? auto;

  /// Its channels, rate and device, from its header (empty when it cannot be used).
  final List<String> names;
  final num? rate;
  final String? device;

  /// Its samples and index left the phone (`<stamp>.removed.json` says when and whether the laptop held them); the
  /// rest of the set stays.
  final bool removed;
  final bool removedOnLaptop;

  /// Its samples (as on the phone, packed or not) and index: what removing its raw signal frees.
  final int samplesBytes;

  /// Its samples and index as paths in `files/` (none once removed).
  List<String> get rawPaths => [
    for (final f in files)
      if (f == '$stem.f32' || f == '$stem.f32.gz' || f == '$stem.idx') '$folder/$f',
  ];

  /// Its last data, or its start when it has none.
  DateTime get last => end ?? start;

  Map<String, Object?> toJson() => {
    'folder': folder,
    'stem': stem,
    'end': end?.microsecondsSinceEpoch,
    'bytes': bytes,
    'raw': rawBytes,
    'writer': writer,
    'files': files,
    if (continues) 'continues': true,
    'auto': ?auto,
    'names': names,
    'rate': ?rate,
    'device': ?device,
    if (removed) 'removed': true,
    if (removedOnLaptop) 'removed_on_laptop': true,
    'samples': samplesBytes,
    'recording': ?recording,
  };

  static RawSet? fromJson(Object? j) {
    if (j is! Map) return null;
    final folder = j['folder'], stem = j['stem'], end = j['end'], bytes = j['bytes'], raw = j['raw'];
    final writer = j['writer'], files = j['files'], names = j['names'], rate = j['rate'], device = j['device'];
    final start = stem is String ? stemTime('$stem.') : null;
    if (folder is! String || start == null || (end != null && end is! int) || bytes is! int || raw is! int) return null;
    if (writer is! String || files is! List || names is! List) return null;
    return RawSet(
      folder: folder,
      stem: stem as String,
      start: start,
      end: end == null ? null : DateTime.fromMicrosecondsSinceEpoch(end as int),
      bytes: bytes,
      rawBytes: raw,
      writer: writer,
      files: [for (final f in files) if (f is String) f],
      continues: j['continues'] == true,
      auto: j['auto'] is String ? j['auto'] as String : null,
      names: [for (final n in names) if (n is String) n],
      rate: rate is num ? rate : null,
      device: device is String ? device : null,
      removed: j['removed'] == true,
      removedOnLaptop: j['removed_on_laptop'] == true,
      samplesBytes: j['samples'] is int ? j['samples'] as int : 0,
      recording: j['recording'] is String ? j['recording'] as String : null,
    );
  }
}

/// A session's file (or a check-in's result), as the list needs it.
class SessionFile {
  const SessionFile({
    required this.kind,
    required this.path,
    required this.start,
    required this.end,
    required this.bytes,
    this.recordings = const [],
    this.companions = const [],
    this.rawCompanions = const [],
    this.rawBytes = 0,
    this.span,
  });

  /// The session ran as an activity of the recording it names (its file has a `span`; Record first step 4): it is
  /// listed inside that recording and never says what the recording was.
  bool get rides => span != null;

  /// That mark's id; null: a session with a signal of its own.
  final String? span;

  final ArchiveKind kind;

  /// Relative to `files/`, `naps/2026-11-19-141205.nap.json`.
  final String path;
  final DateTime start, end;

  /// The file and its companions on the phone.
  final int bytes;

  /// Stems of raw file sets it names (`recording`).
  final List<String> recordings;

  /// Files that belong to it (relative to `files/`): a dream catcher's spoken answers, a meditation's whole log.
  final List<String> companions;

  /// Of [companions], those that are its raw signal (a meditation's or alpha-theta's whole session log, every input
  /// sample): removed with "raw signal only".
  final List<String> rawCompanions;

  /// The bytes of [rawCompanions].
  final int rawBytes;

  String get name => path.substring(path.lastIndexOf('/') + 1);

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'path': path,
    'start': start.microsecondsSinceEpoch,
    'end': end.microsecondsSinceEpoch,
    'bytes': bytes,
    'recordings': recordings,
    'companions': companions,
    'raw_companions': rawCompanions,
    'raw_bytes': rawBytes,
    'span': ?span,
  };

  static SessionFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = j['path'], s = j['start'], e = j['end'], b = j['bytes'], r = j['recordings'], c = j['companions'];
    final rc = j['raw_companions'];
    if (p is! String || s is! int || e is! int || b is! int || r is! List || c is! List || rc is! List) return null;
    return SessionFile(
      kind: ArchiveKind.byName(j['kind']),
      path: p,
      start: DateTime.fromMicrosecondsSinceEpoch(s),
      end: DateTime.fromMicrosecondsSinceEpoch(e),
      bytes: b,
      recordings: [for (final x in r) if (x is String) x],
      companions: [for (final x in c) if (x is String) x],
      rawCompanions: [for (final x in rc) if (x is String) x],
      rawBytes: j['raw_bytes'] is int ? j['raw_bytes'] as int : 0,
      span: j['span'] is String ? j['span'] as String : null,
    );
  }
}

/// A sleep report on the phone (`files/nights/<date>.report.json`).
class ReportFile {
  const ReportFile({
    required this.path,
    required this.nightOf,
    required this.start,
    required this.end,
    required this.scored,
    required this.inputs,
    required this.bytes,
    this.asleepMin,
  });

  final String path;
  final String nightOf;
  final DateTime start, end;
  final bool scored;
  final double? asleepMin;

  /// The `.f32` names it was made from.
  final List<String> inputs;
  final int bytes;

  Map<String, Object?> toJson() => {
    'path': path,
    'night_of': nightOf,
    'start': start.microsecondsSinceEpoch,
    'end': end.microsecondsSinceEpoch,
    'scored': scored,
    'asleep_min': asleepMin,
    'inputs': inputs,
    'bytes': bytes,
  };

  static ReportFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = j['path'], n = j['night_of'], s = j['start'], e = j['end'], i = j['inputs'], b = j['bytes'];
    final a = j['asleep_min'];
    if (p is! String || n is! String || s is! int || e is! int || i is! List || b is! int) return null;
    return ReportFile(
      path: p,
      nightOf: n,
      start: DateTime.fromMicrosecondsSinceEpoch(s),
      end: DateTime.fromMicrosecondsSinceEpoch(e),
      scored: j['scored'] == true,
      asleepMin: a is num ? a.toDouble() : null,
      inputs: [for (final x in i) if (x is String) x],
      bytes: b,
    );
  }
}

/// What Export data's index says of a recording: every file of it (or some) reached the export folder unchanged.
class Copied {
  const Copied({required this.all, required this.at, this.folder});

  /// Every file of the recording reached the export folder unchanged; false: some did.
  final bool all;
  final DateTime? at;
  final String? folder;
}

/// One entry of the Archive.
class ArchiveItem {
  const ArchiveItem({
    required this.id,
    required this.kind,
    required this.start,
    required this.end,
    required this.started,
    this.sets = const [],
    this.sessions = const [],
    this.report,
    this.tags,
    this.tagsBytes = 0,
    this.copied,
    this.laptop = OnLaptop.unknown,
  });

  /// The first file set's stem (or the session's own stamp): its tags file's name.
  final String id;
  final ArchiveKind kind;
  final DateTime start, end;
  final Started started;

  /// Its raw file sets, oldest first, also those whose samples were removed (their log, header and record stay).
  final List<RawSet> sets;
  final List<SessionFile> sessions;
  final ReportFile? report;
  final TagsFile? tags;
  final int tagsBytes;

  /// Export data's copy, if any.
  final Copied? copied;

  /// The laptop's word on its raw signal still on the phone (the samples and index of every set, a meditation's whole
  /// log): [OnLaptop.yes] only when it holds a checked copy of every one as it is now.
  final OnLaptop laptop;

  Duration get length => end.difference(start);

  /// Some of its raw signal is on the phone.
  bool get hasRaw => sets.any((s) => !s.removed) || sessions.any((s) => s.rawCompanions.isNotEmpty);

  /// Its raw signal was removed from the phone; what is left (log, report, summaries, tags) is shown.
  bool get rawRemoved => sets.isNotEmpty && sets.every((s) => s.removed);

  /// Every removed set's record says the laptop held it.
  bool get removedToLaptop => rawRemoved && sets.every((s) => s.removedOnLaptop);

  /// The raw folder (relative to `files/`), or null without raw signal.
  String? get folder => sets.isEmpty ? null : sets.first.folder;

  List<String> get stems => [for (final s in sets) s.stem];

  /// The raw signal on the phone, as paths in `files/`: every set's samples and index, a meditation's whole log.
  List<String> get rawPaths => [
    for (final s in sets) ...s.rawPaths,
    for (final s in sessions) ...s.rawCompanions,
  ];

  /// What removing the raw signal frees.
  int get rawBytes => sets.fold(0, (n, s) => n + s.samplesBytes) + sessions.fold(0, (n, s) => n + s.rawBytes);

  /// Everything of it on the phone.
  int get bytes =>
      sets.fold<int>(0, (n, s) => n + s.bytes) +
      sessions.fold<int>(0, (n, s) => n + s.bytes) +
      (report?.bytes ?? 0) +
      tagsBytes;

  /// Every file of it, relative to `files/`.
  List<String> get paths => [
    for (final s in sets)
      for (final f in s.files) '${s.folder}/$f',
    for (final s in sessions) ...[s.path, ...s.companions],
    if (report != null) report!.path,
    if (tags != null) '$archiveFolder/$id$tagsSuffix',
  ];

  /// The `.f32` files of its sets whose samples are on the phone, by their plain names (packed.dart opens either).
  List<File> rawFiles(Directory filesDir) => [
    for (final s in sets)
      if (!s.removed && s.rawBytes > 0) File('${filesDir.path}/${s.folder}/${s.stem}.f32'),
  ];

  /// The day it belongs to (04:00 to 04:00, the trends' day).
  String get day => dayKey(start);

  List<ManualTag> get manualTags => tags?.tags ?? const [];

  ArchiveItem withCopies(Copied? c, OnLaptop l) => ArchiveItem(
    id: id,
    kind: kind,
    start: start,
    end: end,
    started: started,
    sets: sets,
    sessions: sessions,
    report: report,
    tags: tags,
    tagsBytes: tagsBytes,
    copied: c,
    laptop: l,
  );
}

/// The list: items newest first, and what could not be read.
class ArchiveList {
  const ArchiveList(this.items, {this.problems = const []});
  final List<ArchiveItem> items;
  final List<String> problems;

  int get bytes => items.fold(0, (n, i) => n + i.bytes);

  /// Items by day (04:00 to 04:00), newest day first, each day newest first.
  List<(String, List<ArchiveItem>)> get days {
    final out = <(String, List<ArchiveItem>)>[];
    for (final i in items) {
      if (out.isEmpty || out.last.$1 != i.day) out.add((i.day, []));
      out.last.$2.add(i);
    }
    return out;
  }
}

// ---- reading ----

String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

/// The first [max] bytes of [f] as text ('' when it cannot be read).
String _head(File f, {int max = 4096}) {
  try {
    final r = f.openSync();
    try {
      return utf8.decode(r.readSync(max), allowMalformed: true);
    } finally {
      r.closeSync();
    }
  } on FileSystemException {
    return '';
  }
}

/// The night recorder's first line in a set that continues the one before after a drop (night_recorder.dart
/// `_logReconnected`).
final RegExp _continued = RegExp(r'reconnected \([^)]*\) after a drop \(.*?\); previous run ');

/// Who wrote a set, from the first lines of its `.log`, its folder's default otherwise; and whether it continues the
/// set before it, and how the watcher started it.
({String writer, bool continues, String? auto}) _readLog(File log, String folderDefault) {
  final head = _head(log);
  if (head.isEmpty) return (writer: folderDefault == 'night' ? 'other' : folderDefault, continues: false, auto: null);
  bool has(String s) => head.contains(s);
  final continues = _continued.hasMatch(head) || has('service restarted by Android');
  if (folderDefault != 'night') return (writer: folderDefault, continues: continues, auto: null);
  // a session's set names itself on its first line (`<time> nap coach session; headband ...`)
  final nl = head.indexOf('\n');
  final first = nl < 0 ? head : head.substring(0, nl);
  bool opens(String s) => first.contains(' $s');
  if (opens('nap coach session')) return (writer: 'nap', continues: false, auto: null);
  if (opens('sound for states session')) return (writer: 'sound', continues: false, auto: null);
  if (opens('dream catcher session')) return (writer: 'dream', continues: false, auto: null);
  if (opens('hands-free calibration')) return (writer: 'handsfree', continues: false, auto: null);
  if (opens('auto-start: the headband was found on')) return (writer: 'preroll', continues: false, auto: 'yes');
  if (opens('work session')) return (writer: 'work', continues: continues, auto: null);
  final auto = has('started automatically:') ? 'automatic' : (has('started after "Yes"') ? 'yes' : null);
  return (writer: 'night', continues: continues, auto: auto);
}

/// The key of a set: every file's name, size and modified time.
String? _setKey(List<File> files) {
  final parts = <String>[];
  for (final f in files) {
    final k = fileKey(f);
    if (k == null) return null;
    parts.add('${_name(f.path)} ${k.size} ${k.modifiedUs}');
  }
  return (parts..sort()).join('\n');
}

RawSet _readSet(Directory dir, String folder, String stem, List<File> files, RawRemover remover) {
  final f32 = File('${dir.path}/$stem.f32');
  final log = _readLog(File('${dir.path}/$stem.log'), rawFolders[folder] ?? 'other');
  final onDisk = rawOnDisk(f32);
  final gone = onDisk == null ? remover.removedOf(f32) : null;
  final h = onDisk != null && rawLength(f32) > 0 ? tryHeader(f32) : null;
  var bytes = 0, samples = 0;
  for (final f in files) {
    final size = fileKey(f)?.size ?? 0;
    bytes += size;
    final n = _name(f.path);
    if (n == '$stem.f32' || n == '$stem.f32.gz' || n == '$stem.idx') samples += size;
  }
  return RawSet(
    folder: folder,
    stem: stem,
    start: stemTime('$stem.')!,
    end: gone != null ? gone.end : dataEndOf(f32),
    bytes: bytes,
    rawBytes: rawLength(f32),
    writer: log.writer,
    files: [for (final f in files) _name(f.path)]..sort(),
    continues: log.continues,
    auto: log.auto,
    names: h?.names ?? const [],
    rate: h?.sampleRate,
    device: h?.device,
    removed: gone != null,
    removedOnLaptop: gone?.onLaptop ?? false,
    samplesBytes: samples,
    // the header stays on the phone when the samples leave it
    recording: (h ?? (headerFileOf(f32).existsSync() ? tryHeader(f32) : null))?.recording,
  );
}

final Map<String, Map<String, ({String key, RawSet set})>> _keptSets = {};

/// Forgets what this isolate keeps in memory (tests: a new process).
void forgetArchive() {
  _keptSets.clear();
  SummaryIndex.forgetAll();
}

File _setsCache(Directory filesDir) => File('${filesDir.path}/cache/archive-sets.json');

Map<String, ({String key, RawSet set})> _loadSets(Directory filesDir) {
  final kept = _keptSets[filesDir.path];
  if (kept != null) return kept;
  final out = <String, ({String key, RawSet set})>{};
  try {
    final j = jsonDecode(_setsCache(filesDir).readAsStringSync());
    final sets = j is Map && j['version'] == _setsVersion ? j['sets'] : null;
    if (sets is Map) {
      for (final e in sets.entries) {
        final v = e.value;
        if (e.key is! String || v is! Map || v['key'] is! String) continue;
        final s = RawSet.fromJson(v['set']);
        if (s != null) out[e.key as String] = (key: v['key'] as String, set: s);
      }
    }
  } on FileSystemException {
    // no index yet
  } on FormatException {
    // a damaged index is made again
  }
  return _keptSets[filesDir.path] = out;
}

void _saveSets(Directory filesDir, Map<String, ({String key, RawSet set})> sets) {
  final f = _setsCache(filesDir);
  try {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp');
    tmp.writeAsStringSync(
      jsonEncode({
        'version': _setsVersion,
        'sets': {for (final e in sets.entries) e.key: {'key': e.value.key, 'set': e.value.set.toJson()}},
      }),
      flush: true,
    );
    tmp.renameSync(f.path);
  } on FileSystemException {
    // worked out again next time
  }
}

/// Every raw file set in [rawFolders], oldest first per folder. A set is read again only when one of its files is
/// new, changed or gone.
Map<String, List<RawSet>> rawSetsIn(Directory filesDir, {RawRemover? remover}) {
  final rm = remover ?? PhoneRawRemover(filesDir);
  final kept = _loadSets(filesDir);
  final seen = <String>{};
  var changed = false;
  final out = <String, List<RawSet>>{};
  for (final folder in rawFolders.keys) {
    final dir = Directory('${filesDir.path}/$folder');
    final byStem = <String, List<File>>{};
    try {
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        final name = _name(f.path);
        if (stemTime(name) == null || !rawSuffixes.any((x) => name.length == 17 + x.length && name.endsWith(x))) continue;
        byStem.putIfAbsent(name.substring(0, 17), () => []).add(f);
      }
    } on FileSystemException {
      continue;
    }
    final list = <RawSet>[];
    for (final e in byStem.entries) {
      final id = '$folder/${e.key}';
      final key = _setKey(e.value);
      if (key == null) continue; // a file went while listing: the next list sees it
      seen.add(id);
      final k = kept[id];
      if (k != null && k.key == key) {
        list.add(k.set);
        continue;
      }
      final s = _readSet(dir, folder, e.key, e.value, rm);
      kept[id] = (key: key, set: s);
      list.add(s);
      changed = true;
    }
    list.sort((a, b) => a.stem.compareTo(b.stem));
    out[folder] = list;
  }
  final gone = kept.keys.where((k) => !seen.contains(k)).toList();
  if (gone.isNotEmpty) {
    gone.forEach(kept.remove);
    changed = true;
  }
  if (changed) _saveSets(filesDir, kept);
  return out;
}

/// The recordings of one folder's sets: a night's sets join (see the top of the file); every other set stands alone.
List<List<RawSet>> chainSets(List<RawSet> sets) {
  final out = <List<RawSet>>[];
  bool family(RawSet s) => const {'night', 'preroll', 'board', 'other', 'work'}.contains(s.writer);
  for (final s in sets) {
    final last = out.isEmpty ? null : out.last;
    // a set that names its recording belongs to that one and to no other; the rules by time are for sets without
    if (last != null && (s.recording != null || last.last.recording != null)) {
      if (s.recording == last.last.recording) {
        last.add(s);
      } else {
        out.add([s]);
      }
      continue;
    }
    if (last != null && family(s) && family(last.last) && s.writer != 'preroll') {
      final end = last.map((x) => x.last).reduce((a, b) => a.isAfter(b) ? a : b);
      final near = s.continues || s.start.difference(end) < joinGap;
      if (near && s.start.difference(last.first.start) < maxRecording && s.writer == _sameWriter(last, s)) {
        last.add(s);
        continue;
      }
    }
    out.add([s]);
  }
  return out;
}

/// The writer a set must have to join [chain]: a night after the watcher's kept minutes is that night.
String _sameWriter(List<RawSet> chain, RawSet s) {
  final w = chain.last.writer == 'preroll' ? 'night' : chain.last.writer;
  return w == s.writer ? s.writer : '';
}

// ---- sessions ----

typedef SessionSpec = ({String folder, String suffix, ArchiveKind kind});

const List<SessionSpec> sessionSpecs = [
  (folder: 'work-sessions', suffix: '.work.json', kind: ArchiveKind.work),
  (folder: 'meditations', suffix: '.meditation.json', kind: ArchiveKind.meditation),
  (folder: 'alpha-theta', suffix: '.alphatheta.json', kind: ArchiveKind.alphaTheta),
  (folder: 'naps', suffix: '.nap.json', kind: ArchiveKind.nap),
  (folder: 'dream-catcher', suffix: '.dream.json', kind: ArchiveKind.dream),
  (folder: 'sound-states', suffix: '.sound.json', kind: ArchiveKind.sound),
  (folder: 'mornings', suffix: '.morning.json', kind: ArchiveKind.checkIn),
];

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

double? _seconds(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;

/// A session file's summary as JSON (SummaryIndex keeps it), or null when it is not one this list can place.
Object? _summarizeSession(File f, SessionSpec spec, Directory filesDir) {
  final j = jsonDecode(f.readAsStringSync());
  if (j is! Map) return null;
  final start = _time(j['start']);
  if (start == null) return null;
  final endIso = _time(j['end']);
  final s = _seconds(j['endS']) ?? _seconds(j['runS']);
  final end = endIso ?? (s == null ? start : start.add(Duration(milliseconds: (s * 1000).round())));
  final dir = f.parent;
  final name = _name(f.path);
  final stamp = name.substring(0, name.length - spec.suffix.length);
  final companions = <String>[], raw = <String>[];
  final log = j['log'];
  if (log is String && !log.contains('/') && File('${dir.path}/$log').existsSync()) {
    companions.add('${spec.folder}/$log');
    raw.add('${spec.folder}/$log');
  }
  if (spec.kind == ArchiveKind.dream) {
    for (final c in dir.listSync().whereType<File>()) {
      final n = _name(c.path);
      if (n.startsWith('$stamp-r') && !n.endsWith('.tmp')) companions.add('${spec.folder}/$n');
    }
  }
  var bytes = f.lengthSync(), rawBytes = 0;
  for (final c in companions) {
    final size = fileKey(File('${filesDir.path}/$c'))?.size ?? 0;
    bytes += size;
    if (raw.contains(c)) rawBytes += size;
  }
  final rec = j['recording'], recs = j['recordings'];
  return SessionFile(
    kind: spec.kind,
    path: '${spec.folder}/$name',
    start: start,
    end: end.isBefore(start) ? start : end,
    bytes: bytes,
    recordings: [if (rec is String) rec, if (recs is List) ...recs.whereType<String>()],
    companions: companions..sort(),
    rawCompanions: raw,
    rawBytes: rawBytes,
    span: j['span'] is String ? j['span'] as String : null,
  ).toJson();
}

/// Every session file the list knows, by its spec.
List<SessionFile> sessionFilesIn(Directory filesDir) {
  final out = <SessionFile>[];
  // a session whose mark was taken away ("Remove this mark") is in no list (DECISIONS 1042); its file stays
  final gone = removedSpanIds(Directory('${filesDir.path}/spans'));
  for (final spec in sessionSpecs) {
    final dir = Directory('${filesDir.path}/${spec.folder}');
    // a dream catcher's answers are files of their own: the index is keyed by the session file, so a new answer file
    // is seen when the session file itself is rewritten (it is, with every answer)
    final index = SummaryIndex(File('${filesDir.path}/cache/archive-${spec.folder}.json'), version: _sessionsVersion);
    final sums = index.summaries(dir, spec.suffix, (f) => _summarizeSession(f, spec, filesDir));
    for (final v in sums.values) {
      if (SessionFile.fromJson(v) case final s? when !gone.contains(s.span)) out.add(s);
    }
  }
  return out;
}

/// Every sleep report on the phone.
List<ReportFile> reportsIn(Directory filesDir) {
  final index = SummaryIndex(File('${filesDir.path}/cache/archive-reports.json'), version: _sessionsVersion);
  final sums = index.summaries(Directory('${filesDir.path}/nights'), '.report.json', (f) {
    final j = jsonDecode(f.readAsStringSync());
    if (j is! Map || j['night_of'] is! String) return null;
    final s = _time(j['data_start']), e = _time(j['data_end']);
    if (s == null || e == null) return null;
    final total = j['total'];
    final asleep = total is Map ? total['asleep_min'] : null;
    return ReportFile(
      path: 'nights/${_name(f.path)}',
      nightOf: j['night_of'] as String,
      start: s,
      end: e.isBefore(s) ? s : e,
      scored: j['scored'] == true,
      asleepMin: asleep is num ? asleep.toDouble() : null,
      inputs: [
        for (final i in (j['inputs'] is List ? j['inputs'] as List : const <Object?>[]))
          if (i is Map && i['file'] is String) _name(i['file'] as String),
      ],
      bytes: f.lengthSync(),
    ).toJson();
  });
  return [
    for (final v in sums.values) ?ReportFile.fromJson(v),
  ];
}

/// Every tags file, by id, with its size.
Map<String, (TagsFile, int)> tagsIn(Directory filesDir) {
  final out = <String, (TagsFile, int)>{};
  final store = TagStore(filesDir);
  for (final f in newestFirst(store.dir, tagsSuffix)) {
    final name = _name(f.path);
    final id = name.substring(0, name.length - tagsSuffix.length);
    final t = TagsFile.fromJson(JsonMemo.read(f));
    if (t != null && t.id == id) out[id] = (t, fileKey(f)?.size ?? 0);
  }
  return out;
}

/// The watcher's starts of work sessions (`files/auto-start/log.jsonl`): when and how.
List<(DateTime, String)> workStartsIn(Directory filesDir) => [
  for (final l in JsonMemo.lines(File('${filesDir.path}/auto-start/log.jsonl')))
    if (l is Map && l['event'] == 'start' && l['kind'] == 'work' && l['error'] == null && l['how'] is String)
      if (_time(l['at']) case final at?) (at, l['how'] as String),
];

/// How long before a work session's start the watcher's start line may be (it writes the line after the page opened),
/// and after.
const Duration _workStartBefore = Duration(minutes: 2), _workStartAfter = Duration(minutes: 1);

Started _startedWork(DateTime start, List<(DateTime, String)> starts) {
  for (final (at, how) in starts) {
    final d = at.difference(start);
    if (d >= -_workStartBefore && d <= _workStartAfter) return how == 'automatic' ? _watcher : _watcherYes;
  }
  return byHand(ArchiveKind.work);
}

ArchiveKind _kindOfWriter(String writer) => switch (writer) {
  'night' || 'preroll' => ArchiveKind.night,
  'nap' => ArchiveKind.nap,
  'dream' => ArchiveKind.dream,
  'sound' => ArchiveKind.sound,
  'checkin' => ArchiveKind.checkIn,
  'handsfree' => ArchiveKind.handsFree,
  'board' => ArchiveKind.board,
  'work' => ArchiveKind.work,
  _ => ArchiveKind.recording,
};

Started _startedChain(List<RawSet> chain, ArchiveKind kind) {
  final first = chain.first;
  if (first.writer == 'preroll' || first.auto == 'yes') return _watcherYes;
  if (first.auto == 'automatic') return _watcher;
  if (kind == ArchiveKind.recording) return _unknown;
  return byHand(kind);
}

/// A check-in's result covers a set in `mornings/` that overlaps it within this.
const Duration _checkInSlack = Duration(minutes: 10);

/// Everything in [filesDir], newest first. [remover]: the laptop's word and the removed sets' records (the phone's
/// safe-delete helper; [PhoneRawRemover] by default). Nothing is written but the caches.
ArchiveList listArchive(Directory filesDir, {RawRemover? remover}) {
  final rm = remover ?? PhoneRawRemover(filesDir);
  final sets = rawSetsIn(filesDir, remover: rm);
  final sessions = sessionFilesIn(filesDir);
  final reports = reportsIn(filesDir);
  final tags = tagsIn(filesDir);
  final workStarts = workStartsIn(filesDir);

  // recordings with raw signal (or the records of what was removed)
  final chains = <List<RawSet>>[for (final e in sets.entries) ...chainSets(e.value)];
  _joinByReport(chains, reports);
  final byStem = <String, int>{}; // folder/stem -> chain index
  for (var i = 0; i < chains.length; i++) {
    for (final s in chains[i]) {
      byStem['${s.folder}/${s.stem}'] = i;
    }
  }
  final attached = List.generate(chains.length, (_) => <SessionFile>[]);
  final reportOf = List<ReportFile?>.filled(chains.length, null);
  final loose = <SessionFile>[];
  for (final s in sessions) {
    int? home;
    for (final r in s.recordings) {
      home ??= byStem['recordings/$r'];
    }
    if (home == null && s.kind == ArchiveKind.checkIn) {
      home = _overlapping(chains, 'mornings', s.start.subtract(_checkInSlack), s.end.add(_checkInSlack));
    }
    if (home == null && s.kind == ArchiveKind.work) {
      home = _inside(chains, s.start.subtract(_workStartBefore), s.end.add(_workStartBefore));
    }
    if (home != null) {
      attached[home].add(s);
    } else {
      loose.add(s);
    }
  }
  final looseReports = <ReportFile>[];
  for (final r in reports) {
    final home = _reportHome(r, byStem);
    if (home == null) {
      looseReports.add(r);
    } else if (reportOf[home] == null || r.nightOf.compareTo(reportOf[home]!.nightOf) > 0) {
      reportOf[home] = r;
    }
  }

  final items = <ArchiveItem>[];
  for (var i = 0; i < chains.length; i++) {
    items.add(_chainItem(chains[i], attached[i], reportOf[i], tags, workStarts));
  }
  for (final s in loose) {
    final id = _stampOf(s);
    final t = tags[id];
    items.add(
      ArchiveItem(
        id: id,
        kind: s.kind,
        start: s.start,
        end: s.end,
        started: s.kind == ArchiveKind.work ? _startedWork(s.start, workStarts) : byHand(s.kind),
        sessions: [s],
        tags: t?.$1,
        tagsBytes: t?.$2 ?? 0,
      ),
    );
  }
  for (final r in looseReports) {
    final first = r.inputs.where((i) => i.length >= 17).firstOrNull;
    final id = first == null ? 'night-${r.nightOf}' : first.substring(0, 17);
    final t = tags[id];
    items.add(
      ArchiveItem(
        id: id,
        kind: ArchiveKind.night,
        start: r.start,
        end: r.end,
        started: _unknown,
        report: r,
        tags: t?.$1,
        tagsBytes: t?.$2 ?? 0,
      ),
    );
  }
  // a tags file whose recording is gone altogether: listed, so it can be seen and removed
  final used = items.map((i) => i.id).toSet();
  for (final e in tags.entries) {
    if (used.contains(e.key) || e.value.$1.tags.isEmpty) continue;
    final ts = e.value.$1.tags;
    items.add(
      ArchiveItem(
        id: e.key,
        kind: ArchiveKind.recording,
        start: ts.first.start,
        end: ts.map((t) => t.end).reduce((a, b) => a.isAfter(b) ? a : b),
        started: _unknown,
        tags: e.value.$1,
        tagsBytes: e.value.$2,
      ),
    );
  }
  final copies = _copies(filesDir);
  final out = [for (final i in items) i.withCopies(copies(i), _laptopWord(i, rm))]
    ..sort((a, b) {
      final c = b.start.compareTo(a.start);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
  return ArchiveList(out);
}

/// The laptop's word on an item's raw signal still on the phone: yes only when every raw file is checked there.
OnLaptop _laptopWord(ArchiveItem item, RawRemover rm) {
  final paths = item.rawPaths;
  if (paths.isEmpty) return item.removedToLaptop ? OnLaptop.yes : OnLaptop.unknown;
  var unknown = false;
  for (final p in paths) {
    switch (rm.onLaptop(p)) {
      case OnLaptop.yes:
        break;
      case OnLaptop.no:
        return OnLaptop.no;
      case OnLaptop.unknown:
        unknown = true;
    }
  }
  return unknown ? OnLaptop.unknown : OnLaptop.yes;
}

/// The recording most of a report's inputs belong to.
int? _reportHome(ReportFile r, Map<String, int> byStem) {
  final count = <int, int>{};
  for (final i in r.inputs) {
    if (i.length < 17) continue;
    final c = byStem['recordings/${i.substring(0, 17)}'];
    if (c != null) count[c] = (count[c] ?? 0) + 1;
  }
  if (count.isEmpty) return null;
  return count.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// A sleep report scores a night of several recordings (a dream catcher session, the night, a morning nap): they are
/// one item, so the night's raw signal goes or stays together and the scorer never builds the report again from a part
/// of it (DECISIONS 700-709). Joined in place, oldest set first; the first recording's kind stays.
void _joinByReport(List<List<RawSet>> chains, List<ReportFile> reports) {
  for (final r in reports) {
    final stems = {for (final i in r.inputs) if (i.length >= 17) i.substring(0, 17)};
    final hit = [
      for (var i = 0; i < chains.length; i++)
        if (chains[i].first.folder == 'recordings' && chains[i].any((s) => stems.contains(s.stem))) i,
    ];
    if (hit.length < 2) continue;
    final main = hit.reduce((a, b) => _dataBytes(chains[b]) > _dataBytes(chains[a]) ? b : a);
    final joined = [for (final i in hit) ...chains[i]]..sort((a, b) => a.stem.compareTo(b.stem));
    // the main recording leads (its writer names the kind); the others' sets follow in time order
    chains[main] = [...chains[main].take(1), ...joined.where((s) => !identical(s, chains[main].first))];
    for (final i in hit.reversed) {
      if (i != main) chains.removeAt(i);
    }
  }
}

int _dataBytes(List<RawSet> chain) => chain.fold(0, (n, s) => n + s.rawBytes);

ArchiveItem _chainItem(
  List<RawSet> chain,
  List<SessionFile> mine,
  ReportFile? report,
  Map<String, (TagsFile, int)> tags,
  List<(DateTime, String)> workStarts,
) {
  final first = chain.first;
  final work = mine.where((s) => s.kind == ArchiveKind.work && !s.rides).firstOrNull;
  var kind = _kindOfWriter(first.writer);
  // a work session's own raw signal (written beside it by a later version) is the work session
  if (work != null && first.auto == null && (kind == ArchiveKind.recording || kind == ArchiveKind.night)) {
    kind = ArchiveKind.work;
  }
  final start = chain.map((s) => s.start).reduce((a, b) => a.isBefore(b) ? a : b);
  final end = chain.map((s) => s.last).reduce((a, b) => a.isAfter(b) ? a : b);
  final id = chain.map((s) => s.stem).reduce((a, b) => a.compareTo(b) < 0 ? a : b);
  final t = tags[id];
  final started = kind == ArchiveKind.work && first.auto == null
      ? _startedWork(work?.start ?? first.start, workStarts)
      : _startedChain(chain, kind);
  return ArchiveItem(
    id: id,
    kind: kind,
    start: start,
    end: end,
    started: started,
    sets: [...chain]..sort((a, b) => a.stem.compareTo(b.stem)),
    sessions: mine,
    report: report,
    tags: t?.$1,
    tagsBytes: t?.$2 ?? 0,
  );
}

String _stampOf(SessionFile s) {
  final n = s.name;
  return n.length >= 17 && stemTime('${n.substring(0, 17)}.') != null ? n.substring(0, 17) : n.split('.').first;
}

int? _overlapping(List<List<RawSet>> chains, String folder, DateTime from, DateTime to) {
  for (var i = 0; i < chains.length; i++) {
    final c = chains[i];
    if (c.first.folder != folder) continue;
    final end = c.map((s) => s.last).reduce((a, b) => a.isAfter(b) ? a : b);
    if (!c.first.start.isAfter(to) && !end.isBefore(from)) return i;
  }
  return null;
}

/// A chain in `recordings/` lying wholly inside [from]..[to] (a work session's span) that no session's line or watcher's
/// note claims: the headband serves one at a time, so it is the work session's.
int? _inside(List<List<RawSet>> chains, DateTime from, DateTime to) {
  for (var i = 0; i < chains.length; i++) {
    final c = chains[i];
    if (c.first.folder != 'recordings' || c.first.auto != null || !const {'other', 'night', 'work'}.contains(c.first.writer)) {
      continue;
    }
    final end = c.map((s) => s.last).reduce((a, b) => a.isAfter(b) ? a : b);
    if (!c.first.start.isBefore(from) && !end.isAfter(to)) return i;
  }
  return null;
}

/// What Export data's index says of each item's files (DECISIONS 150-156): copied unchanged when its size and modified
/// time are the exported ones; a packed `.f32.gz` also when its `.f32` was exported with the same SHA-256 before it was
/// packed.
Copied? Function(ArchiveItem) _copies(Directory filesDir) {
  final state = ExportStore(filesDir).load();
  if (state.files.isEmpty) return (_) => null;
  return (item) {
    var copied = 0, total = 0;
    DateTime? at;
    for (final p in item.paths) {
      total++;
      final f = File('${filesDir.path}/$p');
      final k = fileKey(f);
      final e = state.files[p];
      var ok = k != null && e != null && !e.recopy && e.bytes == k.size && e.modifiedMs == k.modifiedUs ~/ 1000;
      if (!ok && isPackedPath(p)) {
        final plain = state.files[p.substring(0, p.length - 3)];
        final info = packedInfo(f);
        ok = plain != null && info != null && plain.sha256 == info.sha256;
        if (ok) at = _later(at, DateTime.tryParse(plain.written)?.toLocal());
      } else if (ok) {
        at = _later(at, DateTime.tryParse(e.written)?.toLocal());
      }
      if (ok) copied++;
    }
    if (copied == 0) return null;
    return Copied(all: copied == total, at: at, folder: state.folderLabel);
  };
}

DateTime? _later(DateTime? a, DateTime? b) => a == null ? b : (b == null || a.isAfter(b) ? a : b);

/// [listArchive] for a background isolate: the folder's path in, the list out (plain data).
ArchiveList listArchiveAt(String filesPath) => listArchive(Directory(filesPath));
