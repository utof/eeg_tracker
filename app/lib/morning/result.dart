// A morning check-in from its markers to `<start>.morning.json`, in the laptop's format (scripts/morning_check.py,
// docs/data-format.md): the phases found from the markers, cut as the laptop cuts them (3 s skipped at the start
// of each phase, 1 s at the end), the measures (measures.dart), and the comparison rows (`compared`) worded as
// the laptop words them. The phone adds `app`, `habits`, `reaction` and `contact`. Plain Dart, no Flutter.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../recorder/header.dart' show readHeader;
import '../recorder/packed.dart' show readRaw;
import '../sleep/report.dart' show isoLocal;
import 'measures.dart';
import 'pyfmt.dart';

const String morningVersion = 'morning-v1';
const List<String> recordedChannels = ['O1', 'O2', 'T3', 'T4'];

/// The laptop keeps comparing with the last 14 earlier check-ins and adds a note until 5 exist (DECISIONS row 26).
const int historyN = 14, historyMin = 5;

/// One marker of `<stamp>.markers.jsonl`: unix time, index of the next sample, text.
typedef Marker = ({double t, int i, String text});

Map<String, Object?> markerJson(Marker m) => {'t': m.t, 'i': m.i, 'text': m.text};

/// The marker texts of the laptop page (scripts/web/morning-core.js `marker`).
abstract final class MorningMarker {
  static const start = 'morning:start';
  static String phase(String key, String edge) => 'morning:$key:$edge';
  static String ratings(Map<String, int> r) =>
      'morning:ratings ${jsonEncode({'kss': r['kss'], 'mood': r['mood'], 'tension': r['tension']})}';
  static const end = 'morning:end';
  static const abort = 'morning:abort';
}

/// Markers split into sessions: each starts at `<prefix>:start` (or the first marker of the prefix).
List<List<Marker>> markerSessions(List<Marker> markers, String prefix) {
  final out = <List<Marker>>[];
  for (final m in markers) {
    if (!m.text.startsWith('$prefix:')) continue;
    if (m.text == '$prefix:start' || out.isEmpty) out.add([]);
    out.last.add(m);
  }
  return out;
}

/// One phase between its markers: sample indices and unix times.
typedef PhaseWindow = ({int i0, int i1, double t0, double t1});

/// The usable phases of a session, or null (stopped, or no finished eyes-closed phase): morning_windows.
({Map<String, PhaseWindow> win, Map<String, Object?>? ratings, double t})? morningWindows(List<Marker> sess) {
  if (sess.any((m) => m.text == MorningMarker.abort)) return null;
  final edge = {for (final m in sess) m.text: m};
  final win = <String, PhaseWindow>{};
  for (final ph in ['eyes_closed', 'eyes_open']) {
    final a = edge['morning:$ph:start'], b = edge['morning:$ph:end'];
    if (a != null && b != null && b.i > a.i) win[ph] = (i0: a.i, i1: b.i, t0: a.t, t1: b.t);
  }
  final closed = win['eyes_closed'];
  if (closed == null) return null;
  Map<String, Object?>? ratings;
  for (final m in sess) {
    if (!m.text.startsWith('morning:ratings')) continue;
    final at = m.text.indexOf(' ');
    if (at < 0) continue;
    try {
      final r = jsonDecode(m.text.substring(at + 1));
      if (r is Map) ratings = r.cast<String, Object?>();
    } on FormatException {
      continue;
    }
  }
  return (win: win, ratings: ratings, t: closed.t0);
}

/// The back channels of each phase, cut as morning_check.analyse cuts them (µV).
typedef CheckInPhases = Map<String, Map<String, Float64List>>;

/// Cuts the phases out of whole channels ([channels]: name -> µV, all the same length).
CheckInPhases cutPhases(Map<String, Float64List> channels, Map<String, PhaseWindow> win, {int fs = morningFs}) {
  final n = channels.values.first.length;
  return {
    for (final e in win.entries)
      e.key: {
        for (final ch in backChannels)
          ch: () {
            final a = e.value.i0 + (skipStartS * fs).toInt();
            final b = e.value.i1 - (skipEndS * fs).toInt() < n ? e.value.i1 - (skipEndS * fs).toInt() : n;
            return b > a ? Float64List.sublistView(channels[ch]!, a, b) : Float64List(0);
          }(),
      },
  };
}

/// The measures of a check-in's phases.
({Map<String, ChannelMeasures> channels, Map<String, double?> back}) analyseCheckIn(CheckInPhases phases) {
  final ec = phases['eyes_closed']!, eo = phases['eyes_open'];
  final channels = {for (final ch in backChannels) ch: channelMeasures(ec[ch]!, eo?[ch])};
  return (channels: channels, back: backSummary(channels));
}

/// A recorded check-in read from a recorder file set (`<stamp>.f32` and `.markers.jsonl`): its phases, ratings,
/// markers and phase windows. Null when the file holds no usable check-in. The channels are picked by name from the
/// file's header (header.dart): a recording without O1 O2 T3 T4 is refused in words, never read from other channels.
({
  CheckInPhases phases,
  Map<String, Object?>? ratings,
  Map<String, PhaseWindow> win,
  double t,
})?
readCheckInRecording(File f32) {
  final header = readHeader(f32);
  final cols = header.pick(recordedChannels, who: 'The morning check-in');
  final rb = header.recordBytes;
  final bytes = readRaw(f32); // plain, or packed after a day
  final n = bytes.length ~/ rb;
  final data = ByteData.sublistView(bytes);
  final channels = {for (final ch in recordedChannels) ch: Float64List(n)};
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < recordedChannels.length; c++) {
      // float32 volts to float64 µV, as the laptop's load(): astype(float64) * 1e6
      channels[recordedChannels[c]]![i] = data.getFloat32(i * rb + 4 + 4 * cols[c], Endian.little) * 1e6;
    }
  }
  final mf = File(f32.path.replaceFirst(RegExp(r'\.f32$'), '.markers.jsonl'));
  final markers = mf.existsSync() ? parseMarkers(mf.readAsStringSync()) : const <Marker>[];
  ({Map<String, PhaseWindow> win, Map<String, Object?>? ratings, double t})? best;
  double? bestT;
  for (final s in markerSessions(markers, 'morning')) {
    final w = morningWindows(s);
    if (w != null && (bestT == null || s.first.t > bestT)) {
      best = w;
      bestT = s.first.t;
    }
  }
  if (best == null) return null;
  return (phases: cutPhases(channels, best.win), ratings: best.ratings, win: best.win, t: best.t);
}

/// The lines of a markers file that are markers (others skipped, as the laptop skips them).
List<Marker> parseMarkers(String text) {
  final out = <Marker>[];
  for (final line in const LineSplitter().convert(text)) {
    try {
      final m = jsonDecode(line);
      if (m is Map && m['text'] is String && m['i'] is num && m['t'] is num) {
        out.add((t: (m['t'] as num).toDouble(), i: (m['i'] as num).toInt(), text: m['text'] as String));
      }
    } on FormatException {
      continue;
    }
  }
  return out;
}

// ---------------------------------------------------------------- comparison with earlier check-ins

/// The laptop's rows: label, key, format (morning_check.ROWS).
const List<(String, String, String)> compareRowsSpec = [
  ('Alpha strength, eyes closed (µV²)', 'back.alpha_ec_uv2', '.1f'),
  ('Eyes-closed rise (closed / open)', 'back.ec_rise', '.1fx'),
  ('Alpha speed (Hz)', 'back.iaf_hz', '.2f'),
  ('1/f slope, eyes closed', 'back.aperiodic_slope_ec', '.2f'),
  ('Clean data (%)', 'back.clean_share', '.0f'),
  ('Sleepiness (KSS 1-9)', 'ratings.kss', ''),
  ('Mood (1-5)', 'ratings.mood', ''),
  ('Tension (1-5)', 'ratings.tension', ''),
];

/// A value by a dotted path ('back.iaf_hz'); null when missing or not a number.
num? valueAt(Map<String, Object?> r, String path) {
  Object? v = r;
  for (final k in path.split('.')) {
    v = v is Map ? v[k] : null;
  }
  return v is num && v.isFinite ? v : null;
}

num _scaled(num v, int k) => v is int && k == 1 ? v : pyRound(v * k.toDouble(), 4);

String _format(num v, String fmt) {
  if (fmt.isEmpty) return v is int ? '$v' : pyG3(v.toDouble()); // '{}' of a rating (an int)
  final digits = int.parse(fmt.substring(1, 2));
  return pyFixed(v.toDouble(), digits) + (fmt.endsWith('x') ? 'x' : '');
}

/// morning_check.compare: "your last N: median M, range L-H: within / above / below your range" (+ a note).
String compareText(num? today, List<num> past) {
  if (today == null || past.isEmpty) return '';
  final med = median([for (final v in past) v.toDouble()]);
  final lo = past.reduce((a, b) => a < b ? a : b), hi = past.reduce((a, b) => a > b ? a : b);
  final where = lo <= today && today <= hi
      ? 'within your range'
      : (today > hi ? 'above your range' : 'below your range');
  final note = past.length >= historyMin ? '' : '; only ${past.length} earlier, wait for $historyMin+';
  return 'your last ${past.length}: median ${pyG3(med)}, range ${pyG3(lo.toDouble())}-${pyG3(hi.toDouble())}: '
      '$where$note';
}

/// morning_check.compared: one row per measure for [today] against the earlier results [past] (oldest first).
List<Map<String, Object?>> compareRows(Map<String, Object?> today, List<Map<String, Object?>> past) {
  final out = <Map<String, Object?>>[];
  for (final (label, key, fmt) in compareRowsSpec) {
    final k = key == 'back.clean_share' ? 100 : 1;
    final raw = valueAt(today, key);
    final v = raw == null ? null : _scaled(raw, k);
    final earlier = [
      for (final r in past)
        if (valueAt(r, key) != null) _scaled(valueAt(r, key)!, k),
    ];
    final text = v == null ? (key.startsWith('back') ? 'not enough clean data' : 'not rated') : _format(v, fmt);
    final row = <String, Object?>{
      'key': key,
      'label': label,
      'value': v,
      'text': text,
      'earlier': earlier.length,
      'comparison': compareText(v, earlier),
    };
    if (v != null && earlier.isNotEmpty) {
      final lo = earlier.reduce((a, b) => a < b ? a : b), hi = earlier.reduce((a, b) => a > b ? a : b);
      row.addAll({
        'median': median([for (final e in earlier) e.toDouble()]),
        'low': lo,
        'high': hi,
        'where': lo <= v && v <= hi ? 'within' : (v > hi ? 'above' : 'below'),
      });
    }
    out.add(row);
  }
  return out;
}

// ---------------------------------------------------------------- the result file

DateTime _fromUnix(double t) => DateTime.fromMicrosecondsSinceEpoch((t * 1e6).round());

/// `<start>.morning.json` in the laptop's layout (morning_check.analyse + compared) with the phone's additions:
/// `app` ("phone"), `habits`, `reaction` (null when skipped) and `contact` (ohms at the start, null = none).
/// [past]: earlier results, oldest first (the last 14 are compared with).
Map<String, Object?> buildMorningResult({
  required String source,
  required Map<String, PhaseWindow> win,
  required Map<String, ChannelMeasures> channels,
  required Map<String, double?> back,
  required Map<String, Object?>? ratings,
  required List<Map<String, Object?>> past,
  Map<String, Object?>? habits,
  Map<String, Object?>? reaction,
  Map<String, double?> contact = const {},
  int fs = morningFs,
}) {
  final closed = win['eyes_closed']!;
  final start = _fromUnix(closed.t0);
  final end = _fromUnix(win.values.map((w) => w.t1).reduce((a, b) => a > b ? a : b));
  final iso = isoLocal(start);
  final res = <String, Object?>{
    'version': morningVersion,
    'source': source,
    'start': iso,
    'end': isoLocal(end),
    'date': iso.substring(0, 10),
    'phase_s': {for (final e in win.entries) e.key: pyRound((e.value.i1 - e.value.i0) / fs, 1)},
    'channels': {for (final e in channels.entries) e.key: e.value.toJson()},
    'back': back,
    'ratings': ratings,
    'setup_test': null,
    'method': {
      'segment_s': segS,
      'reject_p2p_uv': p2pUv,
      'reject_rel_spread': relSpread,
      'alpha_band_hz': [alphaBand.$1, alphaBand.$2],
      'iaf': 'centre of gravity of power above the 1/f line, 7-14 Hz',
      'fit_hz': [fitRange.$1, fitRange.$2],
      'fit_excludes_hz': [iafRange.$1, iafRange.$2],
      'skip_s': [skipStartS, skipEndS],
    },
    'device': {'model': 'BrainBit Black', 'channels': recordedChannels},
    'validated': false,
    'app': 'phone',
    'habits': habits,
    'reaction': reaction,
    'contact': {for (final ch in recordedChannels) ch: contact[ch]},
  };
  res['compared'] = compareRows(res, past.length > historyN ? past.sublist(past.length - historyN) : past);
  return res;
}
