// Electrode layouts for the Signal view (DECISIONS 590-599): any number of channels, each with a name and, when known,
// a position on the head; the reference and the ground (bias) with theirs. Never four hard-wired: the BrainBit is one
// layout (O1 O2 T3 T4 and its forehead reference), the DIY board another (its channel names from the setting, the
// reference and bias on the earlobes), a helmet any other (the 10-10 names placed by themselves, other sites from a
// positions file given as angles or x/y/z).
//
// Head coordinates: x toward the right ear, y toward the nose, z up; the 10-20 sphere has radius 1 and its centre on
// the line between the ears. A position is a direction from that centre (unit length).
import 'dart:io';
import 'dart:math' as math;

/// A point or a direction in head coordinates.
class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) => Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  Vec3 get unit {
    final l = length;
    return l == 0 ? this : this * (1 / l);
  }

  /// The same site on the other side of the head.
  Vec3 get mirrored => Vec3(-x, y, z);

  @override
  String toString() => '(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// [polar]: degrees down from the top of the head (Cz 0; the ring through Fpz, T7, Oz and T8 at 90; the ears' level
/// 112.5). [azimuth]: degrees around from the nose toward the right ear (Fp2 18, T8 90, O2 162, Oz 180; the left
/// side negative: Fp1 -18, T7 -90).
Vec3 fromAngles(double polar, double azimuth) {
  final p = _rad(polar), a = _rad(azimuth);
  return Vec3(math.sin(p) * math.sin(a), math.sin(p) * math.cos(a), math.cos(p));
}

/// The angles of [fromAngles] for a direction (azimuth in -180..180).
({double polar, double azimuth}) toAngles(Vec3 v) {
  final u = v.unit;
  return (polar: _deg(math.acos(u.z.clamp(-1.0, 1.0))), azimuth: _deg(math.atan2(u.x, u.y)));
}

/// The arc from [from] to [to] on the circle through [from], [to] and [third] (all on the unit sphere), at [t]
/// (0 = from, 1 = to). The 10-20 system's rows are such circles, divided in equal steps.
Vec3 _alongCircle(Vec3 from, Vec3 to, Vec3 third, double t) {
  // the circumcentre of the triangle (from, to, third): on the circle's plane, so on the sphere's circle too
  final ab = to - from, ac = third - from;
  final n = ab.cross(ac);
  final c = from + (n.cross(ab) * ac.dot(ac) + ac.cross(n) * ab.dot(ab)) * (1 / (2 * n.dot(n)));
  final axis = n.unit, u = from - c, w = to - c;
  final angle = math.atan2(axis.dot(u.cross(w)), u.dot(w));
  final a = angle * t, cos = math.cos(a), sin = math.sin(a);
  // Rodrigues: u turned by a about the axis
  final turned = u * cos + axis.cross(u) * sin + axis * (axis.dot(u) * (1 - cos));
  return (c + turned).unit;
}

/// The old 10-20 names that the 10-10 system renamed.
const Map<String, String> standardAliases = {'T3': 'T7', 'T4': 'T8', 'T5': 'P7', 'T6': 'P8'};

/// Sites placed by estimate rather than by the 10-10 construction (earlobes and mastoids sit off the 10-20 sphere).
const Set<String> approximateSites = {'A1', 'A2', 'M1', 'M2'};

/// Every 10-10 site (and the 10-5 rows' odd steps, the ears and mastoids) by its name, on the ideal sphere: the midline
/// in 10 % steps and the ring at 90 degrees in 5 % steps, each row from its side to the midline in four equal arcs of the circle
/// through both sides and the midline (the construction of Oostenveld and Praamstra 2001).
final Map<String, Vec3> standardSites = _standard();

Map<String, Vec3> _standard() {
  final s = <String, Vec3>{};
  const mid = ['Nz', 'Fpz', 'AFz', 'Fz', 'FCz', 'Cz', 'CPz', 'Pz', 'POz', 'Oz', 'Iz'];
  for (var i = 0; i < mid.length; i++) {
    final polar = 112.5 - 22.5 * i;
    s[mid[i]] = fromAngles(polar.abs(), polar >= 0 ? 0 : 180);
  }
  // the ring at 90 degrees in 5 % steps of its circumference (18 degrees), left side (the right is its mirror)
  const ring = ['Fp1', 'AF7', 'F7', 'FT7', 'T7', 'TP7', 'P7', 'PO7', 'O1'];
  for (var i = 0; i < ring.length; i++) {
    s[ring[i]] = fromAngles(90, -18.0 - 18 * i);
  }
  // the lower ring at the ears' level
  const low = ['F9', 'FT9', 'T9', 'TP9', 'P9', 'PO9', 'O9'];
  for (var i = 0; i < low.length; i++) {
    s[low[i]] = fromAngles(112.5, -54.0 - 18 * i);
  }
  // the rows: side point, midline point; steps 1-3 are 5, 3, 1 on the left
  const rows = [
    ('AF', 'AF7', 'AFz'),
    ('F', 'F7', 'Fz'),
    ('FC', 'FT7', 'FCz'),
    ('C', 'T7', 'Cz'),
    ('CP', 'TP7', 'CPz'),
    ('P', 'P7', 'Pz'),
    ('PO', 'PO7', 'POz'),
  ];
  for (final (prefix, side, midline) in rows) {
    final from = s[side]!, to = s[midline]!;
    for (var k = 1; k <= 3; k++) {
      s['$prefix${7 - 2 * k}'] = _alongCircle(from, to, from.mirrored, k / 4);
    }
  }
  // estimates off the sphere: the earlobes below the ear canal, the mastoids behind and below it
  s['A1'] = fromAngles(125, -95);
  s['M1'] = fromAngles(120, -118);
  // the right side: every left name (odd number) mirrored to its even number
  for (final e in s.entries.toList()) {
    final m = RegExp(r'^([A-Za-z]+)(\d+)$').firstMatch(e.key);
    if (m == null) continue;
    final n = int.parse(m.group(2)!);
    if (n.isOdd) s['${m.group(1)}${n + 1}'] = e.value.mirrored;
  }
  return s;
}

final Map<String, String> _byUpper = {for (final k in standardSites.keys) k.toUpperCase(): k};

/// The 10-10 name for [name] in any letter case ('fp1' -> 'Fp1', the old 'T3' -> 'T7'), or null when it is none.
String? standardName(String name) {
  final up = name.trim().toUpperCase();
  final alias = standardAliases.entries.where((e) => e.key == up).firstOrNull?.value;
  return alias ?? _byUpper[up];
}

/// Where the 10-10 site [name] is (any case, old names too), or null.
Vec3? standardPosition(String name) {
  final n = standardName(name);
  return n == null ? null : standardSites[n];
}

enum SiteKind { channel, reference, ground }

/// One electrode: a recorded channel, the reference or the ground (bias).
class Site {
  const Site({
    required this.name,
    this.kind = SiteKind.channel,
    this.at,
    this.where,
    this.approximate = false,
    this.custom = false,
  });

  /// As the device names it ('T3', 'CH5', 'Ref').
  final String name;
  final SiteKind kind;

  /// Its direction on the head; null: not known, so it is listed but not drawn.
  final Vec3? at;

  /// In words, when that says more than the name ('forehead', 'an earlobe').
  final String? where;

  /// Placed by estimate (earlobes, mastoids, the BrainBit's forehead pads).
  final bool approximate;

  /// Placed from the positions file, not from its name.
  final bool custom;

  Site withAt(Vec3? at, {bool custom = false, bool? approximate}) =>
      Site(name: name, kind: kind, at: at, where: where, approximate: approximate ?? this.approximate, custom: custom);
}

/// A device's electrodes: its channels in the order it sends them, then the reference and the ground.
class Montage {
  const Montage({required this.name, required this.channels, this.others = const [], this.note});

  /// 'BrainBit', 'DIY board', 'Helmet plan (8)'.
  final String name;
  final List<Site> channels;
  final List<Site> others;

  /// One sentence about where the layout comes from, when it is a plan.
  final String? note;

  List<String> get names => [for (final s in channels) s.name];
  int get count => channels.length;
  List<Site> get all => [...channels, ...others];

  /// Channels with no known position (listed under the head, not drawn on it).
  List<Site> get unplaced => [
    for (final s in channels)
      if (s.at == null) s,
  ];

  Site? site(String name) => all.where((s) => s.name == name).firstOrNull;

  Montage copyWith({String? name, List<Site>? channels, List<Site>? others, String? note}) => Montage(
    name: name ?? this.name,
    channels: channels ?? this.channels,
    others: others ?? this.others,
    note: note ?? this.note,
  );
}

/// A channel named [name], placed by its 10-10 name when it has one.
Site channelSite(String name) {
  final at = standardPosition(name);
  final std = standardName(name);
  return Site(name: name, at: at, approximate: std != null && approximateSites.contains(std));
}

/// Channels by their names (in the device's order), placed by the 10-10 names where they are such.
Montage montageFromNames(String title, List<String> names, {List<Site> others = const [], String? note}) =>
    Montage(name: title, channels: [for (final n in names) channelSite(n)], others: others, note: note);

/// BrainBit's channel names, in the order the headband sends them.
const List<String> brainBitNames = ['O1', 'O2', 'T3', 'T4'];

/// The BrainBit: O1 O2 T3 T4 against its forehead reference (DECISIONS 78: each channel is its electrode minus the
/// forehead). The pads sit around the middle of the forehead, drawn at Fpz.
Montage brainBitMontage() => montageFromNames(
  'BrainBit',
  brainBitNames,
  others: [Site(name: 'Ref', kind: SiteKind.reference, at: standardSites['Fpz'], where: 'forehead', approximate: true)],
);

/// The DIY board: its channels named by the setting (headband/diy/settings.dart), the reference on an earlobe (the
/// chip's SRB1) and the bias on the other (BIASOUT), as scripts/montages/diy-breadboard-4.json plans it.
Montage diyBoardMontage(List<String> names) => montageFromNames(
  'DIY board',
  names,
  others: [
    Site(name: 'Ref', kind: SiteKind.reference, at: standardSites['A1'], where: 'an earlobe', approximate: true),
    Site(name: 'Bias', kind: SiteKind.ground, at: standardSites['A2'], where: 'the other earlobe', approximate: true),
  ],
  note: 'A plan: the board records its test signal until its firmware has an electrode mode.',
);

Site _forehead() => Site(name: 'Ref', kind: SiteKind.reference, at: standardSites['Fpz'], where: 'mid-forehead');

/// The helmet's planned 8 sites (ROADMAP "Helmet layout", docs/evidence/helmet.md): a planning assumption.
Montage helmetPlan8() => montageFromNames(
  'Helmet plan (8)',
  const ['M1', 'M2', 'F7', 'F8', 'Fz', 'C3', 'C4', 'Pz'],
  others: [_forehead()],
  note: 'A plan: nobody has tested this exact layout.',
);

/// One 16-site extension of the plan that keeps the headband's O1 O2 T7 T8 (docs/evidence/helmet.md); an example.
Montage helmetPlan16() => montageFromNames(
  'Helmet plan (16)',
  const ['M1', 'M2', 'F7', 'F8', 'Fz', 'C3', 'C4', 'Pz', 'O1', 'O2', 'T7', 'T8', 'F3', 'F4', 'P3', 'P4'],
  others: [_forehead()],
  note: 'An example of a 16-site helmet, not a decided layout.',
);

/// Positions typed by hand for sites a helmet has outside the 10-10 names (files/signal/positions.txt; DECISIONS 592).
/// One site a line; `#` starts a comment:
///
///     X1 60 30            polar and azimuth in degrees (as [fromAngles])
///     X2 0.30 0.52 0.80   x y z (right, front, up; any length, only the direction counts)
///     C3                  a 10-10 name alone: its own place
///     ref Fpz             the reference (or `ground`, `bias`) at a 10-10 site, or with numbers like a channel
class CustomPositions {
  const CustomPositions({this.sites = const {}, this.reference, this.ground});

  /// Channel name -> where it is.
  final Map<String, Vec3> sites;
  final Site? reference;
  final Site? ground;

  bool get isEmpty => sites.isEmpty && reference == null && ground == null;
}

/// Why a positions text cannot be used, with its line.
class PositionsError implements Exception {
  const PositionsError(this.line, this.message);
  final int line;
  final String message;

  @override
  String toString() => 'Line $line: $message';
}

final RegExp _siteName = RegExp(r'^[A-Za-z0-9_.\-]{1,16}$');

/// Reads a positions text (see [CustomPositions]); throws [PositionsError] for the first line it cannot use.
CustomPositions parsePositions(String text) {
  final sites = <String, Vec3>{};
  Site? reference, ground;
  final lines = text.split('\n');
  if (lines.length > 300) throw const PositionsError(301, 'too many lines (300 at most).');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].split('#').first.trim();
    if (line.isEmpty) continue;
    final words = line.split(RegExp(r'[\s,;]+')).where((w) => w.isNotEmpty).toList();
    final first = words.first.toLowerCase();
    final kind = switch (first) {
      'ref' || 'reference' => SiteKind.reference,
      'ground' || 'gnd' || 'bias' => SiteKind.ground,
      _ => SiteKind.channel,
    };
    final rest = kind == SiteKind.channel ? words : words.sublist(1);
    if (rest.isEmpty) throw PositionsError(i + 1, 'give a name after "${words.first}".');
    final name = rest.first;
    if (!_siteName.hasMatch(name)) {
      throw PositionsError(i + 1, '"$name" is not a name: letters, digits, _ . or - only, up to 16.');
    }
    final at = _position(i + 1, name, rest.sublist(1));
    if (kind == SiteKind.channel) {
      if (sites.containsKey(name)) throw PositionsError(i + 1, '$name is given twice.');
      if (sites.length >= 128) throw PositionsError(i + 1, '128 channels at most.');
      sites[name] = at;
    } else {
      final site = Site(name: name, kind: kind, at: at, custom: true);
      if (kind == SiteKind.reference) {
        if (reference != null) throw PositionsError(i + 1, 'the reference is given twice.');
        reference = site;
      } else {
        if (ground != null) throw PositionsError(i + 1, 'the ground is given twice.');
        ground = site;
      }
    }
  }
  return CustomPositions(sites: sites, reference: reference, ground: ground);
}

Vec3 _position(int line, String name, List<String> numbers) {
  final v = [for (final w in numbers) double.tryParse(w)];
  if (v.any((x) => x == null || !x.isFinite)) {
    throw PositionsError(line, 'after $name only numbers: polar and azimuth, or x y z.');
  }
  switch (v.length) {
    case 0:
      final at = standardPosition(name);
      if (at == null) throw PositionsError(line, '$name is not a 10-10 name: give polar and azimuth, or x y z.');
      return at;
    case 2:
      final polar = v[0]!, azimuth = v[1]!;
      if (polar < 0 || polar > 180) throw PositionsError(line, 'polar is 0 (top of the head) to 180.');
      if (azimuth < -360 || azimuth > 360) throw PositionsError(line, 'azimuth is -360 to 360.');
      return fromAngles(polar, azimuth);
    case 3:
      final p = Vec3(v[0]!, v[1]!, v[2]!);
      if (p.length < 1e-6) throw PositionsError(line, 'x y z cannot all be 0.');
      return p.unit;
    default:
      throw PositionsError(line, 'give 2 numbers (polar azimuth) or 3 (x y z), not ${v.length}.');
  }
}

/// [device] with the positions file's places: a channel named there takes that place, the reference and the ground
/// replace the device's when given. Channels the file does not name keep their own.
Montage withPositions(Montage device, CustomPositions custom) {
  if (custom.isEmpty) return device;
  final channels = [
    for (final s in device.channels)
      if (custom.sites.containsKey(s.name)) s.withAt(custom.sites[s.name], custom: true, approximate: false) else s,
  ];
  final others = [
    for (final s in device.others)
      if (s.kind == SiteKind.reference && custom.reference != null)
        custom.reference!
      else if (s.kind == SiteKind.ground && custom.ground != null)
        custom.ground!
      else
        s,
    if (custom.reference != null && !device.others.any((s) => s.kind == SiteKind.reference)) custom.reference!,
    if (custom.ground != null && !device.others.any((s) => s.kind == SiteKind.ground)) custom.ground!,
  ];
  return device.copyWith(channels: channels, others: others);
}

/// `files/signal/` beside the recordings: the positions file (it leaves the phone with Export data).
Directory signalDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/signal');

/// The positions file, read and written whole.
class PositionsStore {
  PositionsStore(this.dir);
  final Directory dir;

  File get file => File('${dir.path}/positions.txt');

  /// The text, or '' when there is none.
  String read() {
    try {
      return file.existsSync() ? file.readAsStringSync() : '';
    } catch (_) {
      return '';
    }
  }

  /// Checks [text] first ([parsePositions] throws), then writes it whole (a temporary name, then a rename).
  void write(String text) {
    parsePositions(text);
    dir.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsStringSync(text, flush: true);
    tmp.renameSync(file.path);
  }

  /// The places in the file, or none when it is missing or cannot be used.
  CustomPositions load() {
    try {
      return parsePositions(read());
    } catch (_) {
      return const CustomPositions();
    }
  }
}

/// Where a site is, in a few words ('back left', 'top', 'forehead'), from its direction.
String placeWords(Vec3 at) {
  final a = toAngles(at);
  if (a.polar < 25) return 'top';
  final az = a.azimuth;
  final side = az.abs() < 15 || az.abs() > 165 ? '' : (az > 0 ? ' right' : ' left');
  final part = az.abs() <= 60 ? 'front' : (az.abs() < 110 ? 'side' : 'back');
  if (part == 'side') return side.trim().isEmpty ? 'side' : '${side.trim()} side';
  final low = a.polar > 100 ? 'low ' : '';
  return '$low$part$side';
}
