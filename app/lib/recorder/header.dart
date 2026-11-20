// The recording header, `<stamp>.header.json` beside `<stamp>.f32` (docs/data-format.md "The recording header";
// DECISIONS 630-639): what a file set's records hold, so a record can carry any number of channels. Owner's rule
// (2026-11-20): "always remember we're making features with custom arrangements and numbers of electrodes in mind".
//
// - Every recording the app writes has one, written when its files open, before the first sample (chunk_writer.dart).
// - A file set from before the header reads as it always did: the `.log`'s format line (the DIY board's files), else
//   the BrainBit's O1 O2 T3 T4 at 250 Hz in 20-byte records. A header that is damaged is an error that names the file:
//   a reader never guesses past it.
// - A feature that needs particular sites (the sleep model's O1 O2 T3 T4, the morning check-in's O1 O2) picks them
//   by name with [RecordingHeader.pick], and says in words when a recording lacks one ([MissingSites]); it never
//   reads another channel in its place.
//
// The laptop's twin is scripts/recording.py; both follow the same rules on the same files.
import 'dart:convert';
import 'dart:io';

import '../signal/layout.dart' show Montage, Site, SiteKind, Vec3, brainBitMontage, standardName, standardSites;
import 'packed.dart' show plainFileOf, rawLength;

const String headerFormat = 'eeg-tracker-recording';
const int headerVersion = 1;
const String headerSuffix = '.header.json';

/// A record carries 1 to this many channels.
const int maxChannels = 64;

/// A channel name: 1 to 32 characters.
const int maxNameLength = 32;

/// The BrainBit's rate, and every recording's without a header or format line.
const int legacySampleRate = 250;

/// The highest rate a header may give (the ADS1299's fastest, 16 kSPS).
const double maxSampleRate = 16000;

/// What the uint32 at the start of each record counts.
const String counterPacket = 'packet number';
const String counterSequence = 'board sequence number';

/// A header that cannot be used, in words that name the file.
class HeaderError implements Exception {
  const HeaderError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A recording lacks a site a feature needs: [message] says which it needs and which channels it has.
class MissingSites implements Exception {
  const MissingSites(this.message, {this.missing = const []});
  final String message;

  /// The sites asked for and not found, as asked.
  final List<String> missing;

  @override
  String toString() => message;
}

/// One recorded channel: its name as the device gives it, its 10-10 site when it is one, its direction on the head.
class HeaderChannel {
  const HeaderChannel(this.name, {this.site, this.xyz});

  final String name;

  /// The 10-10 name ('T3' -> 'T7'), or null.
  final String? site;

  /// A unit vector (right, front, up), or null when its place is not known.
  final List<double>? xyz;

  Map<String, Object?> toJson() => {'name': name, 'site': site, 'xyz': xyz};

  @override
  bool operator ==(Object other) =>
      other is HeaderChannel && other.name == name && other.site == site && _sameList(other.xyz, xyz);

  @override
  int get hashCode => Object.hash(name, site, xyz == null ? null : Object.hashAll(xyz!));
}

/// The reference or the ground (bias): a name, where it is in words, its 10-10 site.
class HeaderSite {
  const HeaderSite(this.name, {this.where, this.site});
  final String name;
  final String? where;
  final String? site;

  Map<String, Object?> toJson() => {'name': name, 'where': where, 'site': site};

  @override
  bool operator ==(Object other) =>
      other is HeaderSite && other.name == name && other.where == where && other.site == site;

  @override
  int get hashCode => Object.hash(name, where, site);
}

/// Where a header came from: its own file, the `.log`'s format line (a DIY file set from before the header), or the
/// BrainBit default (any other file set from before the header).
enum HeaderSource { file, log, legacy, made }

class RecordingHeader {
  const RecordingHeader({
    required this.channels,
    this.sampleRate = legacySampleRate,
    this.device,
    this.layout,
    this.reference,
    this.ground,
    this.counter = counterPacket,
    this.madeBy,
    this.source = HeaderSource.made,
  });

  /// In record order.
  final List<HeaderChannel> channels;
  final num sampleRate;
  final String? device;
  final String? layout;
  final HeaderSite? reference;
  final HeaderSite? ground;
  final String counter;
  final String? madeBy;
  final HeaderSource source;

  int get count => channels.length;
  List<String> get names => [for (final c in channels) c.name];

  /// `.f32` bytes per sample: the uint32 counter and one float32 per channel.
  int get recordBytes => 4 + 4 * count;

  /// `<I4f` for 4 channels.
  String get record => '<I${count}f';

  /// `device: names` for messages (`BrainBit: O1 O2 T3 T4`).
  String get describe => '${device ?? layout ?? 'this recording'}: ${names.join(' ')}';

  Map<String, Object?> toJson() => {
    'format': headerFormat,
    'version': headerVersion,
    'device': device,
    'layout': layout,
    'channels': [for (final c in channels) c.toJson()],
    'reference': reference?.toJson(),
    'ground': ground?.toJson(),
    'sample_rate': sampleRate,
    'unit': 'V',
    'record': record,
    'counter': counter,
    'made_by': madeBy,
  };

  /// The header's file text: one JSON object and a newline.
  String encode() => '${jsonEncode(toJson())}\n';

  /// A header object as written; throws [HeaderError] naming [where] (the file) for anything that breaks a rule.
  static RecordingHeader fromJson(Object? j, {String where = 'the recording header'}) {
    Never bad(String why) => throw HeaderError('$where: $why');
    if (j is! Map) bad('not a JSON object');
    if (j['format'] != headerFormat) bad('not an $headerFormat header (format ${jsonEncode(j['format'])})');
    final version = j['version'];
    if (version is! int || version < 1) bad('version ${jsonEncode(version)} is not a version');
    if (version > headerVersion) {
      bad(
        'written by a newer version of the app (header version $version; this one reads $headerVersion). '
        'Update the app to read it.',
      );
    }
    final raw = j['channels'];
    if (raw is! List || raw.isEmpty || raw.length > maxChannels) bad('needs 1 to $maxChannels channels');
    final channels = <HeaderChannel>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c is! Map) bad('channel ${i + 1} is not an object');
      final name = c['name'];
      if (name is! String || name.trim().isEmpty || name.length > maxNameLength || name.trim() != name) {
        bad('channel ${i + 1} needs a name of 1 to $maxNameLength characters');
      }
      if (!seen.add(name)) bad('channel name $name appears twice');
      final site = c['site'];
      if (site != null && site is! String) bad('channel $name: site must be a 10-10 name or null');
      channels.add(
        HeaderChannel(
          name,
          site: site as String?,
          xyz: _xyz(c['xyz'], () => bad('channel $name: xyz must be three numbers or null')),
        ),
      );
    }
    final rate = j['sample_rate'];
    if (rate is! num || !rate.isFinite || rate <= 0 || rate > maxSampleRate) {
      bad('sample_rate ${jsonEncode(rate)} is not a rate in samples a second');
    }
    if (j['unit'] != 'V') bad('unit ${jsonEncode(j['unit'])}: the records hold volts (V)');
    final want = '<I${channels.length}f';
    if (j['record'] != want)
      bad('record ${jsonEncode(j['record'])} does not match ${channels.length} channels ($want)');
    String? text(String k) {
      final v = j[k];
      if (v != null && v is! String) bad('$k must be text or null');
      return v as String?;
    }

    final counter = text('counter');
    return RecordingHeader(
      channels: List.unmodifiable(channels),
      sampleRate: rate,
      device: text('device'),
      layout: text('layout'),
      reference: _site(j['reference'], 'reference', bad),
      ground: _site(j['ground'], 'ground', bad),
      counter: counter ?? counterPacket,
      madeBy: text('made_by'),
      source: HeaderSource.file,
    );
  }

  /// The header's text read back; throws [HeaderError] naming [where].
  static RecordingHeader decode(String text, {String where = 'the recording header'}) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException catch (e) {
      throw HeaderError('$where: not valid JSON (${e.message})');
    }
    return fromJson(j, where: where);
  }

  /// Indices (in record order) of the channels [wanted] names, matched by exact name first, else by 10-10 site
  /// (`T7` stands for `T3`, in any letter case). Throws [MissingSites] naming [who]'s needs and this recording's
  /// channels when any is missing.
  List<int> pick(List<String> wanted, {required String who}) {
    final out = <int>[];
    final missing = <String>[];
    for (final w in wanted) {
      final i = indexOf(w);
      if (i == null) {
        missing.add(w);
      } else {
        out.add(i);
      }
    }
    if (missing.isNotEmpty) {
      throw MissingSites(
        '$who needs ${wanted.join(' ')}; this recording ($describe) has no ${missing.join(', ')}.',
        missing: missing,
      );
    }
    return out;
  }

  /// The channel [name] by exact name, else by its 10-10 site; null when none.
  int? indexOf(String name) {
    for (var i = 0; i < channels.length; i++) {
      if (channels[i].name == name) return i;
    }
    final want = standardName(name);
    if (want == null) return null;
    for (var i = 0; i < channels.length; i++) {
      final c = channels[i];
      if ((c.site != null && standardName(c.site!) == want) || standardName(c.name) == want) return i;
    }
    return null;
  }

  /// True when the channels are [names] in this order: rows can be read as they are, no mapping needed.
  bool isIn(List<String> names) => _sameList(this.names, names);

  @override
  bool operator ==(Object other) =>
      other is RecordingHeader &&
      _sameList(other.channels, channels) &&
      other.sampleRate == sampleRate &&
      other.device == device &&
      other.layout == layout &&
      other.reference == reference &&
      other.ground == ground &&
      other.counter == counter &&
      other.madeBy == madeBy;

  @override
  int get hashCode => Object.hash(Object.hashAll(channels), sampleRate, device, layout, reference, ground, counter);
}

List<double>? _xyz(Object? v, void Function() bad) {
  if (v == null) return null;
  if (v is! List || v.length != 3 || !v.every((x) => x is num && x.isFinite)) {
    bad();
    return null;
  }
  return List.unmodifiable([for (final x in v) (x as num).toDouble()]);
}

HeaderSite? _site(Object? v, String key, Never Function(String) bad) {
  if (v == null) return null;
  if (v is! Map || v['name'] is! String || (v['name'] as String).isEmpty)
    bad('$key must be an object with a name, or null');
  final where = v['where'], site = v['site'];
  if ((where != null && where is! String) || (site != null && site is! String))
    bad('$key: where and site are text or null');
  return HeaderSite(v['name'] as String, where: where as String?, site: site as String?);
}

bool _sameList<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<double> _round(List<double> v) => [for (final x in v) (x * 1e4).roundToDouble() / 1e4];

HeaderChannel _channelOf(Site s) {
  final at = s.at;
  return HeaderChannel(s.name, site: standardName(s.name), xyz: at == null ? null : _round([at.x, at.y, at.z]));
}

HeaderSite? _otherOf(Montage m, SiteKind kind) {
  final s = m.others.where((o) => o.kind == kind).firstOrNull;
  if (s == null) return null;
  return HeaderSite(s.name, where: s.where, site: standardName(s.name) ?? _siteAt(s.at));
}

/// The 10-10 name of the place [at] when it is exactly one (the BrainBit's reference drawn at Fpz, the earlobes at
/// A1 and A2), else null.
String? _siteAt(Vec3? at) {
  if (at == null) return null;
  for (final e in standardSites.entries) {
    final v = e.value;
    if ((v.x - at.x).abs() < 1e-9 && (v.y - at.y).abs() < 1e-9 && (v.z - at.z).abs() < 1e-9) return e.key;
  }
  return null;
}

/// The header of a recording whose channels, reference and ground are [m]'s.
RecordingHeader headerForMontage(
  Montage m, {
  required String device,
  num sampleRate = legacySampleRate,
  String counter = counterPacket,
  String madeBy = 'eeg_tracker app',
}) => RecordingHeader(
  channels: List.unmodifiable([for (final s in m.channels) _channelOf(s)]),
  sampleRate: sampleRate,
  device: device,
  layout: m.name,
  reference: _otherOf(m, SiteKind.reference),
  ground: _otherOf(m, SiteKind.ground),
  counter: counter,
  madeBy: madeBy,
);

/// The BrainBit's recording: O1 O2 T3 T4 in volts at 250 Hz against its forehead reference. The `.f32` bytes are those
/// of every BrainBit recording before the header.
final RecordingHeader brainBitHeader = headerForMontage(brainBitMontage(), device: 'BrainBit');

/// What a file set from before the header holds (neither a header nor a format line): the BrainBit's record.
final RecordingHeader legacyHeader = RecordingHeader(
  channels: const [
    HeaderChannel('O1', site: 'O1'),
    HeaderChannel('O2', site: 'O2'),
    HeaderChannel('T3', site: 'T7'),
    HeaderChannel('T4', site: 'T8'),
  ],
  device: 'BrainBit',
  layout: 'BrainBit',
  source: HeaderSource.legacy,
);

/// `<stamp>.header.json` for `<stamp>.f32` (plain or packed name).
File headerFileOf(File f32) {
  final p = plainFileOf(f32).path;
  return File('${p.substring(0, p.length - 4)}$headerSuffix');
}

File _logOf(File f32) {
  final p = plainFileOf(f32).path;
  return File('${p.substring(0, p.length - 4)}.log');
}

/// The DIY board's format line in a `.log` from before the header (laptop and phone write the same words).
final RegExp formatLine = RegExp(r'format \.f32 records <I(\d+)f: [^\n]*?then (.*?) in volts; (\d+(?:\.\d+)?) Hz');

/// The header for the file set of [f32] (plain or packed): its `.header.json`, else its `.log`'s format line, else the
/// BrainBit's. Throws [HeaderError] for a header file that cannot be used, naming it.
RecordingHeader readHeader(File f32) {
  final hf = headerFileOf(f32);
  String? text;
  try {
    text = hf.readAsStringSync();
  } on PathNotFoundException {
    text = null;
  } on FileSystemException catch (e) {
    if (hf.existsSync()) throw HeaderError('${hf.path}: cannot be read (${e.message})');
    text = null;
  }
  if (text != null) return RecordingHeader.decode(text, where: hf.path);
  return _fromLog(_logOf(f32)) ?? legacyHeader;
}

RecordingHeader? _fromLog(File log) {
  final String head;
  try {
    final f = log.openSync();
    try {
      head = utf8.decode(f.readSync(64 * 1024), allowMalformed: true);
    } finally {
      f.closeSync();
    }
  } on FileSystemException {
    return null;
  }
  final m = formatLine.firstMatch(head);
  if (m == null) return null;
  final n = int.parse(m[1]!);
  if (n < 1 || n > maxChannels) return null;
  final given = m[2]!.split(' ').where((s) => s.isNotEmpty).toList();
  final names = given.length == n && given.toSet().length == n ? given : [for (var i = 1; i <= n; i++) 'Ch$i'];
  return RecordingHeader(
    channels: [for (final s in names) HeaderChannel(s, site: standardName(s))],
    sampleRate: num.parse(m[3]!),
    device: 'DIY board',
    layout: 'DIY board',
    counter: counterSequence,
    source: HeaderSource.log,
  );
}

/// [readHeader], or null when the file set's header cannot be used (for counts and lists that skip such a set; a
/// reader of its samples calls [readHeader] and says why).
RecordingHeader? tryHeader(File f32) {
  try {
    return readHeader(f32);
  } on HeaderError {
    return null;
  }
}

/// Writes [h] for the file set of [f32] under a temporary name, then renames it into place: a reader never sees half
/// a header.
void writeHeader(File f32, RecordingHeader h) {
  final hf = headerFileOf(f32);
  final tmp = File('${hf.path}.tmp');
  tmp.writeAsStringSync(h.encode(), flush: true);
  tmp.renameSync(hf.path);
}

/// Whole records in [f32] (plain or packed), by its header's record size.
int recordsIn(File f32, [RecordingHeader? header]) => rawLength(f32) ~/ (header ?? readHeader(f32)).recordBytes;

/// The sites a sleep stager and the drift-off detector read, in the order they read them (the BrainBit's).
const List<String> sleepSites = ['O1', 'O2', 'T3', 'T4'];

/// [h]'s channels [sites] as indices, or null when [h] holds them in that order already (rows read as they are).
List<int>? mapping(RecordingHeader h, List<String> sites, {required String who}) {
  final idx = h.pick(sites, who: who);
  for (var i = 0; i < idx.length; i++) {
    if (idx[i] != i) return idx;
  }
  return null;
}
