// The nights kept on the phone, for Export and the sleep report. A night is a chain of recordings, the rule of
// scripts/night_files.py (DECISIONS row 82): a recording joins the night before it when it starts less than
// 3 hours after that night's last data or has the same evening date (its start minus 12 hours, as `night_of` in
// docs/data-format.md), and a night never takes a recording that starts 24 hours or more after its first one.
// The night is named after the evening date of its first recording, so a late-morning sleep lands in the same
// night as the sleep before it. Files of a run without samples (a `.log` alone) join the night they fall in.
// A `.f32` packed after a day (`<stamp>.f32.gz`, packed.dart) counts as the plain one: [NightFiles.recordings] keep
// the plain name, and the readers open either form.
import 'dart:io';
import 'dart:typed_data';

import 'chunk_writer.dart';
import 'header.dart' show legacyHeader, tryHeader;
import 'packed.dart' show isPackedPath, rawLength;

final RegExp _stem = RegExp(r'^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})\.');

const Duration chainGap = Duration(hours: 3);
const Duration maxSpan = Duration(hours: 24);

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
  NightFiles(this.nightOf, this.files, {this.recordings = const [], this.lastData});

  /// The evening's date.
  final DateTime nightOf;

  /// Every file of the night, oldest run first.
  final List<File> files;

  /// The `.f32` files with samples, oldest first: what the sleep report scores. By their plain names, also when
  /// packed (open them with packed.dart's openRaw, measure them with rawLength).
  final List<File> recordings;

  /// Arrival of the night's last data; null without recordings.
  final DateTime? lastData;

  /// `2026-11-18`, the name of its report.
  String get name => dateName(nightOf);

  /// Start of the first run.
  DateTime get start => stemTime(files.first.uri.pathSegments.last)!;

  /// Arrival of the last data (the start when there is none).
  DateTime get end => lastData ?? start;

  /// File sets (one per recorder run: a new one after every drop or restart).
  int get runs => files.where((f) => f.path.endsWith('.f32') || isPackedPath(f.path)).length;

  int get bytes => files.fold(0, (sum, f) => sum + f.lengthSync());

  /// Name of the folder an export creates, e.g. `eeg-night-2026-11-18`.
  String get folderName => 'eeg-night-$name';
}

class _Rec {
  _Rec(this.stem, this.start, this.end);
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

/// The nights in [dir], newest first.
List<NightFiles> nightsIn(Directory dir) {
  if (!dir.existsSync()) return const [];
  final byStem = <String, List<File>>{};
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (stemTime(name) != null) byStem.putIfAbsent(name.substring(0, 17), () => []).add(f);
  }
  final data = <_Rec>[];
  final other = <String>[];
  for (final stem in byStem.keys) {
    final f32 = File('${dir.path}/$stem.f32');
    final size = rawLength(f32);
    final start = stemTime('$stem.')!;
    // its header's record and rate (any number of channels); a set whose header cannot be used counts as the BrainBit's
    // here, for its length only: its readers refuse it in words
    final h = size > 0 ? (tryHeader(f32) ?? legacyHeader) : legacyHeader;
    if (size >= h.recordBytes) {
      data.add(_Rec(stem, start, _lastData(dir, stem, start, size ~/ h.recordBytes, h.sampleRate)));
    } else {
      other.add(stem);
    }
  }
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
  return [
    for (final c in chains)
      NightFiles(
        c.nightOf,
        [for (final s in c.stems) ...byStem[s]!]..sort(byName),
        recordings: [for (final s in c.dataStems) File('${dir.path}/$s.f32')]..sort(byName),
        lastData: c.dataStems.isEmpty ? null : c.end,
      ),
  ]..sort((a, b) {
    final c = b.nightOf.compareTo(a.nightOf);
    return c != 0 ? c : b.start.compareTo(a.start);
  });
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
