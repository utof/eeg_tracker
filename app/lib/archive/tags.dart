// Your own tags on a recording (the Archive, DECISIONS 700-709): `files/archive/<id>.tags.json`, one file per recording,
// app-private like everything else and exported whole by Export data and Share on Wi-Fi ("everything except", which
// takes `archive/` as it is). `<id>` is the recording's first file set's stem (`2026-11-18-231200`), or a session's own
// stamp for a session without raw signal.
//
//   {"version": 1, "id": "2026-11-18-231200",
//    "tags": [{"start": iso, "end": iso, "label": "walk", "made": iso, "truth": true}]}
//
// A tag is a span of clock time with a word ("sleep", "work", "walk", "meeting", "meditation" or anything typed); times
// are local with their UTC offset. `truth` (written only when true): you ticked "This is what I was doing", so the
// laptop takes the tag as a truth label to check the detectors against (DECISIONS 824); a file without it reads as before. Written whole under a temporary name, then renamed; a file with no tags left is
// removed. A missing or damaged file reads as no tags, and a damaged file is never overwritten.
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;

const int tagsVersion = 1;
const String archiveFolder = 'archive';
const String tagsSuffix = '.tags.json';

/// The words offered first; anything typed is a tag too.
const List<String> presetTags = ['sleep', 'work', 'walk', 'meeting', 'meditation', 'rest'];

/// Longest tag word kept.
const int maxTagLength = 40;

/// The archive's folder in the app's `files/`.
Directory archiveDirFor(Directory filesDir) => Directory('${filesDir.path}/$archiveFolder');

/// A span you tagged by hand.
class ManualTag {
  ManualTag({
    required this.start,
    required this.end,
    required String label,
    DateTime? made,
    this.truth = false,
    this.source,
    this.confidence,
    this.words,
  }) : label = cleanTag(label),
      made = made ?? DateTime.now();

  final DateTime start, end;
  final String label;
  final DateTime made;

  /// "This is what I was doing": the laptop counts the tag as a truth label (DECISIONS 824).
  final bool truth;

  /// Set by the sheet after Stop (Record first, DECISIONS 890): who made it (`owner_stop_sheet`; null: you tagged it
  /// in the Archive), how sure it is (`certain`, `likely`, `within`) and your own words, exactly as typed.
  final String? source, confidence, words;

  Duration get length => end.difference(start);

  ManualTag copyWith({DateTime? start, DateTime? end, String? label, bool? truth}) => ManualTag(
    start: start ?? this.start,
    end: end ?? this.end,
    label: label ?? this.label,
    made: made,
    truth: truth ?? this.truth,
    source: source,
    confidence: confidence,
    words: words,
  );

  Map<String, Object?> toJson() => {
    'start': isoLocal(start),
    'end': isoLocal(end),
    'label': label,
    'made': isoLocal(made),
    if (truth) 'truth': true,
    'source': ?source,
    'confidence': ?confidence,
    'words': ?words,
  };

  /// Null for anything that is not a tag this version can read (no times, end before start, no word).
  static ManualTag? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = DateTime.tryParse('${j['start']}'), e = DateTime.tryParse('${j['end']}'), l = j['label'];
    if (s == null || e == null || l is! String || e.isBefore(s) || cleanTag(l).isEmpty) return null;
    final made = DateTime.tryParse('${j['made']}');
    return ManualTag(
      start: s.toLocal(),
      end: e.toLocal(),
      label: l,
      made: made?.toLocal() ?? s.toLocal(),
      truth: j['truth'] == true,
      source: j['source'] is String ? j['source'] as String : null,
      confidence: j['confidence'] is String ? j['confidence'] as String : null,
      words: j['words'] is String ? j['words'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ManualTag &&
      other.start == start &&
      other.end == end &&
      other.label == label &&
      other.made == made &&
      other.truth == truth &&
      other.source == source &&
      other.confidence == confidence &&
      other.words == words;

  @override
  int get hashCode => Object.hash(start, end, label, made, truth, source, confidence, words);
}

/// A tag's word as kept: trimmed, inner spaces single, lower case for the preset words, at most [maxTagLength].
String cleanTag(String s) {
  final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  final cut = t.length > maxTagLength ? t.substring(0, maxTagLength).trimRight() : t;
  final lower = cut.toLowerCase();
  return presetTags.contains(lower) ? lower : cut;
}

/// One recording's tags file, read back.
class TagsFile {
  const TagsFile({required this.id, this.tags = const []});
  final String id;
  final List<ManualTag> tags;

  Map<String, Object?> toJson() => {
    'version': tagsVersion,
    'id': id,
    'tags': [for (final t in tags) t.toJson()],
  };

  /// Null when [j] is not a tags file this version can read; a tag it cannot read is left out.
  static TagsFile? fromJson(Object? j) {
    if (j is! Map || j['version'] != tagsVersion || j['id'] is! String) return null;
    final raw = j['tags'];
    return TagsFile(
      id: j['id'] as String,
      tags: [
        if (raw is List)
          for (final t in raw) ?ManualTag.fromJson(t),
      ]..sort((a, b) => a.start.compareTo(b.start)),
    );
  }
}

/// `files/archive/`: one tags file per recording.
class TagStore {
  TagStore(this.filesDir);
  final Directory filesDir;

  Directory get dir => archiveDirFor(filesDir);

  File fileFor(String id) => File('${dir.path}/$id$tagsSuffix');

  /// The recording's tags file; null when there is none or it cannot be read.
  TagsFile? read(String id) {
    try {
      return TagsFile.fromJson(jsonDecode(fileFor(id).readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  List<ManualTag> tags(String id) => read(id)?.tags ?? const [];

  /// Writes [tags] for [id]; with none left, the file goes. Refuses (false) when the file exists but cannot be read: a
  /// damaged file is never overwritten by what a read could not see.
  bool saveTags(String id, List<ManualTag> tags) {
    final f = fileFor(id);
    if (read(id) == null && f.existsSync()) return false;
    return _write(TagsFile(id: id, tags: [...tags]..sort((a, b) => a.start.compareTo(b.start))));
  }

  bool _write(TagsFile t) {
    final f = fileFor(t.id);
    try {
      if (t.tags.isEmpty) {
        if (f.existsSync()) f.deleteSync();
        return true;
      }
      dir.createSync(recursive: true);
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(t.toJson()), flush: true);
      tmp.renameSync(f.path);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Adds [tag]; false when it could not be saved.
  bool add(String id, ManualTag tag) => saveTags(id, [...tags(id), tag]);

  /// Replaces [old] by [now]; false when [old] is not there any more or it could not be saved.
  bool replace(String id, ManualTag old, ManualTag now) {
    final list = [...tags(id)];
    final i = list.indexOf(old);
    if (i < 0) return false;
    list[i] = now;
    return saveTags(id, list);
  }

  bool remove(String id, ManualTag tag) {
    final list = [...tags(id)];
    if (!list.remove(tag)) return false;
    return saveTags(id, list);
  }
}
