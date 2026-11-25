// The nights kept on the phone, for Export and the sleep report. A night is a chain of recordings, the rule of
// scripts/night_files.py (DECISIONS row 82): a recording joins the night before it when it starts less than
// 3 hours after that night's last data or has the same evening date (its start minus 12 hours, as `night_of` in
// docs/data-format.md), and a night never takes a recording that starts 24 hours or more after its first one.
// The night is named after the evening date of its first recording, so a late-morning sleep lands in the same
// night as the sleep before it. Files of a run without samples (a `.log` alone) join the night they fall in.
// A `.f32` packed after a day (`<stamp>.f32.gz`, packed.dart) counts as the plain one: [NightFiles.recordings] keep
// the plain name, and the readers open either form.
// What a file set gives the list (its samples' end, from its index, its header or an old set's `.log`) is kept for the
// isolate while none of the set's files changed: the sleep scoring's plan and the bedtime checks ask for the nights on
// the screen's thread at every start and return (DECISIONS 629).
// A file set whose header names a session that is not sleep (a work session's raw EEG, `session: work`, DECISIONS
// 683) is no part of any night, with or without samples: never chained, scored, or exported as a night.
// A set whose raw files left the phone (moved to the laptop, or deleted by hand: remove.dart, DECISIONS 690-699) keeps
// its place by its `<stamp>.removed.json`, which says when its data ended: it is chained as before and listed in
// [NightFiles.removed], never in [NightFiles.recordings], so nothing tries to read samples that are not there.
import 'dart:io';
import 'dart:typed_data';

import '../cache/file_summaries.dart' show fileKey;
import 'chunk_writer.dart';
import 'header.dart' show RecordingHeader, headerFileOf, legacyHeader, tryHeader;
import 'packed.dart' show isPackedPath, plainFileOf, rawLength, rawOnDisk;
import '../spans/span.dart';
import 'remove.dart' show removedRecordOf, removedSuffix;

final RegExp _stem = RegExp(r'^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})\.');

const Duration chainGap = Duration(hours: 3);
const Duration maxSpan = Duration(hours: 24);

/// Sleep stretches of one evening date that lie [chainGap] or more apart are one night only when each side is at
/// least this long: a shorter one (Sleep pressed by mistake in the afternoon, a 4-minute test) is left out of the
/// night instead of moving its start by hours. Alone on its evening date it is still that night, too short to score.
/// A planning value (DECISIONS 1026); the laptop's twin is `STRAY_UNDER_S` in scripts/night_files.py.
const Duration strayUnder = Duration(minutes: 20);

/// Start of the run that wrote [fileName] (`2026-11-18-231200.f32` and its `.idx`, `.log`), or null for any
/// other file.
DateTime? stemTime(String fileName) {
  final m = _stem.firstMatch(fileName);
  if (m == null) return null;
  final p = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  final t = DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
  // DateTime rolls impossible values over (month 13 = next January); such a name is not ours.
  return '${fileStem(t)}.' == m[0] ? t : null;
}

/// The evening's date of a run that started at [t].
DateTime nightOf(DateTime t) {
  final shifted = t.subtract(const Duration(hours: 12));
  return DateTime(shifted.year, shifted.month, shifted.day);
}

/// `2026-11-18`.
String dateName(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

class NightFiles {
  NightFiles(
    this.nightOf,
    this.files, {
    this.recordings = const [],
    this.removed = const [],
    this.lastData,
    this.windows,
    this.spanIds = const [],
    this.recordingIds = const [],
    this.spanFrom,
    this.napStamp,
  });

  /// The stretches of clock time that are this night's sleep, oldest first: its sleep spans (Record first, DECISIONS
  /// 886-888). Only the samples inside them are scored. Null: the whole files, as every night from before.
  final List<(DateTime, DateTime)>? windows;

  /// The sleep spans and their recordings, when it comes from spans; `pressed`, `confirmed` or `auto` for the first
  /// span's source.
  final List<String> spanIds, recordingIds;
  final String? spanFrom;

  /// A nap (a span of kind `nap`): the stamp of its start, the name of its report under `nights/naps/`. Null: a night.
  final String? napStamp;
  bool get isNap => napStamp != null;

  /// The report's `span` field; null for a night from before.
  Map<String, Object?>? get spanField => windows == null || spanIds.isEmpty
      ? null
      : {'recording': recordingIds, 'spans': spanIds, 'kind': isNap ? 'nap' : 'night', 'from': spanFrom ?? 'pressed'};


  /// The evening's date.
  final DateTime nightOf;

  /// Every file of the night, oldest run first.
  final List<File> files;

  /// The `.f32` files with samples, oldest first: what the sleep report scores. By their plain names, also when
  /// packed (open them with packed.dart's openRaw, measure them with rawLength).
  final List<File> recordings;

  /// The `.f32` names (plain) of the sets whose raw files left the phone (remove.dart), oldest first: their samples
  /// count for the night's shape, but there is nothing to read.
  final List<File> removed;

  /// Arrival of the night's last data; null without recordings.
  final DateTime? lastData;

  /// `2026-11-18`, the name of its report; a nap's is `naps/2026-11-21-130000`.
  String get name => napStamp == null ? dateName(nightOf) : 'naps/$napStamp';

  /// Start of the first run, or of the first sleep span.
  DateTime get start => windows?.firstOrNull?.$1 ?? stemTime(files.first.uri.pathSegments.last)!;

  /// Arrival of the last data (the start when there is none).
  DateTime get end => lastData ?? start;

  /// File sets (one per recorder run: a new one after every drop or restart).
  int get runs => files.where((f) => f.path.endsWith('.f32') || isPackedPath(f.path)).length + removed.length;

  int get bytes => files.fold(0, (sum, f) => sum + f.lengthSync());

  /// Name of the folder an export creates, e.g. `eeg-night-2026-11-18`.
  String get folderName => 'eeg-night-$name';
}

class _Rec {
  _Rec(this.stem, this.start, this.end, {this.data = true});

  /// It holds samples.
  final bool data;
  final String stem;
  final DateTime start;
  DateTime end;
}

class _Chain {
  _Chain(this.nightOf, this.first);
  final DateTime nightOf;
  final DateTime first;
  DateTime end = DateTime(0);
  final List<String> stems = [];
  final List<String> dataStems = [];
}

/// The nights in [dir], newest first. [spansDir]: the spans files (the sibling `spans/` unless said). A file set
/// whose header names a recording is never chained by time: its recording's sleep spans of kind `sleep` give the
/// nights (joined by the chain rule applied to spans, named by the evening date of the first span's start), and a
/// recording without one gives none. A set that "Not sleep" names joins no night. An old chain and a span night of
/// the same evening date are one night, whose windows are the spans and the old chain's whole extent (the laptop's
/// rule, scripts/night_files.py).
List<NightFiles> nightsIn(Directory dir, {Directory? spansDir}) => _nightsAndNaps(dir, spansDir).nights;

/// The naps in [dir] (spans of kind `nap`), newest first: each is scored by itself and joins no night.
List<NightFiles> napsIn(Directory dir, {Directory? spansDir}) => _nightsAndNaps(dir, spansDir).naps;

({List<NightFiles> nights, List<NightFiles> naps}) _nightsAndNaps(Directory dir, Directory? spansDir) {
  if (!dir.existsSync()) return (nights: const [], naps: const []);
  final spanFiles = spansIn(spansDir ?? spansDirFor(dir.path));
  final noSleep = {for (final f in spanFiles.values) ...f.sets};
  final inRecording = <String, List<_Rec>>{};
  final byStem = <String, List<File>>{};
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (stemTime(name) != null) byStem.putIfAbsent(name.substring(0, 17), () => []).add(f);
  }
  final data = <_Rec>[];
  final other = <String>[];
  final gone = <String>{};
  final kept = _keptSets[dir.path] ?? const <String, _SetEnd>{};
  final keep = <String, _SetEnd>{};
  for (final stem in byStem.keys) {
    final start = stemTime('$stem.')!;
    final key = _setKey(byStem[stem]!); // taken before reading: a file changed meanwhile is read again next time
    var set = kept[stem];
    if (set == null || key == null || set.key != key) set = _setOf(dir, stem, start, key);
    if (key != null) keep[stem] = set;
    if (!set.sleep) continue; // a work session's raw EEG (also once moved off the phone): not a night
    if (noSleep.contains(stem)) continue; // the owner said it was not sleep (DECISIONS 889)
    if (set.removed) gone.add(stem);
    if (set.recording case final id?) {
      // its recording's spans say what was sleep; a set without samples still belongs to it
      inRecording.putIfAbsent(id, () => []).add(_Rec(stem, start, set.end ?? start, data: set.end != null));
      continue;
    }
    if (set.end case final end?) {
      data.add(_Rec(stem, start, end));
    } else {
      other.add(stem);
    }
  }
  _keptSets[dir.path] = keep;
  data.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.stem.compareTo(b.stem);
  });
  final chains = <_Chain>[];
  for (final r in data) {
    final n = chains.isEmpty ? null : chains.last;
    final near = n != null && (r.start.difference(n.end) < chainGap || nightOf(r.start) == n.nightOf);
    if (n == null || !near || r.start.difference(n.first) >= maxSpan) chains.add(_Chain(nightOf(r.start), r.start));
    final c = chains.last;
    c.stems.add(r.stem);
    c.dataStems.add(r.stem);
    if (r.end.isAfter(c.end)) c.end = r.end;
  }
  for (final stem in other) {
    final t = stemTime('$stem.')!;
    final home = chains.where((c) => nightOf(t) == c.nightOf || (!t.isBefore(c.first) && t.difference(c.end) < chainGap));
    if (home.isNotEmpty) {
      home.first.stems.add(stem);
    } else {
      final same = chains.where((c) => c.dataStems.isEmpty && c.nightOf == nightOf(t));
      (same.isNotEmpty ? same.first : (chains..add(_Chain(nightOf(t), t))).last).stems.add(stem);
    }
  }
  int byName(File a, File b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last);
  final old = [
    for (final c in chains)
      NightFiles(
        c.nightOf,
        [for (final s in c.stems) ...byStem[s]!]..sort(byName),
        recordings: [for (final s in c.dataStems) if (!gone.contains(s)) File('${dir.path}/$s.f32')]..sort(byName),
        removed: [for (final s in c.dataStems) if (gone.contains(s)) File('${dir.path}/$s.f32')]..sort(byName),
        lastData: c.dataStems.isEmpty ? null : c.end,
      ),
  ];
  // ---- the recordings with an id: nights and naps from their sleep spans ----
  NightFiles fromSpans(DateTime nightOf, List<(Span, List<_Rec>, DateTime)> parts, {String? nap}) {
    final windows = [for (final p in parts) (p.$1.start, p.$3)];
    final sets = <String, _Rec>{
      for (final p in parts)
        for (final r in p.$2) r.stem: r,
    };
    bool inside(_Rec r) => r.data && windows.any((w) => r.start.isBefore(w.$2) && r.end.isAfter(w.$1));
    final first = parts.first.$1.source;
    return NightFiles(
      nightOf,
      [for (final s in sets.keys) ...byStem[s]!]..sort(byName),
      recordings: [for (final r in sets.values) if (inside(r) && !gone.contains(r.stem)) File('${dir.path}/${r.stem}.f32')]..sort(byName),
      removed: [for (final r in sets.values) if (inside(r) && gone.contains(r.stem)) File('${dir.path}/${r.stem}.f32')]..sort(byName),
      lastData: windows.last.$2,
      windows: windows,
      spanIds: [for (final p in parts) p.$1.id],
      recordingIds: {for (final p in parts) p.$1.recording}.toList(),
      spanFrom: first == 'owner_confirmed' ? 'confirmed' : first == 'auto_start' ? 'auto' : 'pressed',
      napStamp: nap,
    );
  }

  final sleeps = <(Span, List<_Rec>, DateTime)>[];
  final naps = <NightFiles>[];
  for (final e in inRecording.entries) {
    final dataEnd = e.value.map((r) => r.end).reduce((a, b) => a.isAfter(b) ? a : b);
    for (final s in spanFiles[e.key]?.sleepSpans ?? const <Span>[]) {
      // a span still open (the recording runs, or it ended without a Stop) ends at the recording's last data
      final end = s.end ?? dataEnd;
      if (!end.isAfter(s.start)) continue;
      if (s.kind == 'nap') {
        naps.add(fromSpans(nightOf(s.start), [(s, e.value, end)], nap: fileStem(s.start)));
      } else {
        sleeps.add((s, e.value, end));
      }
    }
  }
  sleeps.sort((a, b) => a.$1.start.compareTo(b.$1.start));
  final groups = <List<(Span, List<_Rec>, DateTime)>>[];
  Duration lengthOf(List<(Span, List<_Rec>, DateTime)> g) =>
      g.fold(Duration.zero, (sum, p) => sum + p.$3.difference(p.$1.start));
  for (final s in sleeps) {
    final g = groups.isEmpty ? null : groups.last;
    final inTime = g != null && s.$1.start.difference(g.first.$1.start) < maxSpan;
    final byGap = g != null && s.$1.start.difference(g.last.$3) < chainGap;
    final byDate = g != null && nightOf(s.$1.start) == nightOf(g.first.$1.start);
    if (g != null && inTime && byDate && !byGap) {
      // joined by the evening date alone, hours apart: a short stray stretch is no part of the night (DECISIONS 1026)
      if (lengthOf(g) < strayUnder) {
        groups
          ..removeLast()
          ..add([s]);
        continue;
      }
      if (s.$3.difference(s.$1.start) < strayUnder) continue;
    }
    if (g == null || !inTime || !(byGap || byDate)) {
      groups.add([s]);
    } else {
      g.add(s);
    }
  }
  final nights = <NightFiles>[];
  final spanNights = [for (final g in groups) fromSpans(nightOf(g.first.$1.start), g)];
  for (final o in old) {
    final same = spanNights.where((n) => n.nightOf == o.nightOf).firstOrNull;
    if (same == null) {
      nights.add(o);
      continue;
    }
    spanNights.remove(same);
    final windows = [...same.windows!, if (o.lastData != null) (o.start, o.lastData!)]..sort((a, b) => a.$1.compareTo(b.$1));
    nights.add(
      NightFiles(
        o.nightOf,
        [...o.files, ...same.files]..sort(byName),
        recordings: [...o.recordings, ...same.recordings]..sort(byName),
        removed: [...o.removed, ...same.removed]..sort(byName),
        lastData: windows.map((w) => w.$2).reduce((a, b) => a.isAfter(b) ? a : b),
        windows: windows,
        spanIds: same.spanIds,
        recordingIds: same.recordingIds,
        spanFrom: same.spanFrom,
      ),
    );
  }
  nights.addAll(spanNights);
  int newestFirst(NightFiles a, NightFiles b) {
    final c = b.nightOf.compareTo(a.nightOf);
    return c != 0 ? c : b.start.compareTo(a.start);
  }

  return (nights: nights..sort(newestFirst), naps: naps..sort((a, b) => b.start.compareTo(a.start)));
}

/// A file set's samples' end ([_lastData]), or null when it holds no whole sample, and whether it is sleep (its
/// header names no other session), with the key it was worked out for; [removed]: its raw files left the phone, and
/// the end is its record's (remove.dart).
typedef _SetEnd = ({String? key, DateTime? end, bool sleep, bool removed, String? recording});

/// What [nightsIn] worked out per folder and file set, for this isolate.
final Map<String, Map<String, _SetEnd>> _keptSets = {};

/// Forgets what [nightsIn] keeps (tests: a new process).
void forgetNightSets() => _keptSets.clear();

/// The size and modified time of every file of a set (its `.f32` or `.f32.gz`, `.idx`, `.header.json`, `.log`, ...),
/// by name; null when one is gone meanwhile.
String? _setKey(List<File> files) {
  final parts = <String>[];
  for (final f in files) {
    final k = fileKey(f);
    if (k == null) return null;
    parts.add('${f.uri.pathSegments.last} ${k.size} ${k.modifiedUs}');
  }
  return (parts..sort()).join('\n');
}

/// The set's samples' end, or null when it holds no whole sample, and whether it is sleep. Its header gives the record,
/// the rate (any number of channels) and the session; a set whose header cannot be used counts as the BrainBit's
/// night here, for its length only: its readers refuse it in words. A set whose samples left the phone ends where its
/// `.removed.json` says (its header stays on the phone, so a work session's still says it is no sleep).
_SetEnd _setOf(Directory dir, String stem, DateTime start, String? key) {
  final f32 = File('${dir.path}/$stem.f32');
  final h = _headerOf(f32);
  if (rawOnDisk(f32) == null && File('${dir.path}/$stem$removedSuffix').existsSync()) {
    final end = removedRecordOf(f32)?.endMs;
    return (
      key: key,
      end: end == null ? null : DateTime.fromMillisecondsSinceEpoch(end),
      sleep: h.isSleep,
      removed: end != null,
      recording: h.recording,
    );
  }
  return (key: key, end: _samplesEnd(dir, stem, start, h), sleep: h.isSleep, removed: false, recording: h.recording);
}

/// The header that describes [f32]'s set: its own (header file, or an old set's `.log`) when it has samples or a
/// header file, else the BrainBit's.
RecordingHeader _headerOf(File f32) =>
    rawLength(f32) > 0 || headerFileOf(f32).existsSync() ? (tryHeader(f32) ?? legacyHeader) : legacyHeader;

DateTime? _samplesEnd(Directory dir, String stem, DateTime start, [RecordingHeader? header]) {
  final f32 = File('${dir.path}/$stem.f32');
  final size = rawLength(f32);
  final h = header ?? _headerOf(f32);
  return size >= h.recordBytes ? _lastData(dir, stem, start, size ~/ h.recordBytes, h.sampleRate) : null;
}

/// When the data of [f32]'s set ended (its last `.idx` row, else its start and length), from the samples on the phone;
/// null when it holds none or its name is not a recording's.
DateTime? dataEndOf(File f32) {
  final plain = plainFileOf(f32);
  final name = plain.uri.pathSegments.last;
  final start = stemTime(name);
  if (start == null) return null;
  return _samplesEnd(plain.parent, name.substring(0, 17), start);
}

/// Arrival time of the last batch (the last `.idx` row); start + samples / rate without an index.
DateTime _lastData(Directory dir, String stem, DateTime start, int samples, num rate) {
  final byLength = start.add(Duration(microseconds: (samples * 1e6 / rate).round()));
  final idx = File('${dir.path}/$stem.idx');
  try {
    final len = idx.existsSync() ? idx.lengthSync() : 0;
    if (len < indexBytes) return byLength;
    final f = idx.openSync();
    try {
      f.setPositionSync((len ~/ indexBytes - 1) * indexBytes);
      final t = ByteData.sublistView(f.readSync(8)).getFloat64(0, Endian.little);
      final at = DateTime.fromMicrosecondsSinceEpoch((t * 1e6).round());
      final ok = !at.isBefore(start) && at.isBefore(start.add(const Duration(days: 7)));
      return ok ? at : byLength;
    } finally {
      f.closeSync();
    }
  } on FileSystemException {
    return byLength;
  }
}

const List<String> _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `Wed 18 Nov`.
String nightLabel(DateTime d) => '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

String _two(int v) => v.toString().padLeft(2, '0');
