// The headband's battery as one number for every screen (DECISIONS 853). The BrainBit's gauge reads whole percent and
// sticks while it streams (0-2 % and 100 %, DECISIONS 40; 6 % for nine hours on 2026-11-19), and it moved 99 -> 79 %
// over a 1.8-hour session on 2026-11-20: 11 % an hour, the laptop's rule too
// (scripts/battery.py, DECISIONS 766). So the number shown is an estimate: the last reading we believe, minus
// 11 % for every hour streamed since. A reading is believed when the gauge moved and landed near the estimate, when it
// is the first one ever, or when a new connection reads higher than the estimate (it was charged). A reading far from
// the estimate (99 % one moment, 6 % the next) is the gauge sticking: the estimate goes on and the screen says so.
import 'dart:convert';
import 'dart:io';

/// The one battery rule for the headband (DECISIONS 946): the card's estimate, the battery guard (auto/
/// battery_guard.dart) and the Battery page (logs/battery_report.dart) all count with these.
abstract final class BandBatteryRule {
  /// What an hour of streaming takes, in percent: 99 % to 79 % in 1.8 h on the owner's headband (2026-11-20), the
  /// laptop's number too (scripts/battery.py, DECISIONS 766). The maker's "up to 10 hours" would be 10.
  static const double drainPctPerHour = 11;

  /// Values the gauge sticks at while streaming (DECISIONS 40).
  static const Set<int> stuckLevels = {0, 1, 2, 100};

  /// A value that does not move for this long while streaming is stuck too (at the drain above a working gauge moves
  /// 11 points in that time; the laptop's 60 minutes, DECISIONS 766).
  static const Duration flatStuck = Duration(minutes: 60);
}

class BandBattery {
  const BandBattery({this.gauge, this.estimate, this.stuck = false, this.at});

  /// What the headband's gauge said last (null: never read).
  final int? gauge;

  /// Our estimate in percent (null: nothing believable yet).
  final int? estimate;

  /// The gauge is far from the estimate: it sticks.
  final bool stuck;

  /// When the gauge was last read.
  final DateTime? at;

  /// The number to show: the estimate, else the gauge.
  int? get percent => estimate ?? gauge;

  /// Hours of streaming left at the rated drain (null: unknown).
  double? get hoursLeft => percent == null ? null : percent! / BandBatteryRule.drainPctPerHour;

  /// `about 62 %`, or `–`.
  String get words => percent == null ? '–' : 'about $percent %';

  /// The line under the number, or null: why it is an estimate when the gauge disagrees.
  String? get note => stuck && gauge != null ? 'The headband\'s own gauge says $gauge %; it sticks while streaming.' : null;

  /// Estimated empty (5 % or less).
  bool get empty => estimate != null && estimate! <= BandBatteryTrack.emptyPct;
}

/// The readings of one headband over time, as plain values (kept in a file between app runs).
class BandBatteryTrack {
  BandBatteryTrack({
    this.anchorPct,
    this.anchorAtMs = 0,
    this.streamedMs = 0,
    this.lastGauge,
    this.lastAtMs = 0,
    this.lastStreaming = false,
    this.emptyTold = false,
  });

  /// A reading within this many points of the estimate is in line with it.
  static const int nearPct = 8;
  static const int emptyPct = 5;

  /// Two readings further apart than this are not one stretch of streaming.
  static const Duration maxStep = Duration(minutes: 2);

  /// After this long without any reading a new connection's reading replaces the estimate.
  static const Duration staleAfter = Duration(hours: 12);

  /// The reading the estimate counts down from.
  int? anchorPct;
  int anchorAtMs;

  /// Time streamed since the anchor.
  int streamedMs;
  int? lastGauge;
  int lastAtMs;
  bool lastStreaming;

  /// The "battery empty" notice went out for this anchor.
  bool emptyTold;

  /// A gauge reading at [at]; [streaming]: the signal ran when it was read (false: a new connection's first reading).
  void note(int gauge, DateTime at, {required bool streaming}) {
    final ms = at.millisecondsSinceEpoch;
    final longAgo = lastAtMs > 0 && ms - lastAtMs > staleAfter.inMilliseconds;
    _advance(ms, streaming);
    final est = _estimate();
    final moved = lastGauge != null && gauge != lastGauge;
    final low = gauge <= 2;
    final bool believed;
    if (est == null) {
      believed = !low && !(streaming && gauge == 100);
    } else if (!streaming && gauge > est + nearPct && !low) {
      believed = true; // charged since
    } else if (!streaming && longAgo && !BandBatteryRule.stuckLevels.contains(gauge)) {
      believed = true; // half a day without a reading: the old estimate says little, a fresh connection's reading more
    } else {
      believed = (moved || !streaming) && (gauge - est).abs() <= nearPct && !(low && est > nearPct);
    }
    if (believed) {
      if (anchorPct == null || gauge > (est ?? 0) + nearPct) emptyTold = false;
      anchorPct = gauge;
      anchorAtMs = ms;
      streamedMs = 0;
    }
    lastGauge = gauge;
    lastAtMs = ms;
    lastStreaming = streaming;
  }

  /// The stream is known to run (or not) at [at], with no gauge reading.
  void streamingAt(DateTime at, {required bool streaming}) {
    final ms = at.millisecondsSinceEpoch;
    _advance(ms, streaming);
    lastAtMs = ms;
    lastStreaming = streaming;
  }

  void _advance(int ms, bool streaming) {
    final dt = ms - lastAtMs;
    if (lastStreaming && streaming && dt > 0 && anchorPct != null) {
      streamedMs += dt > maxStep.inMilliseconds ? maxStep.inMilliseconds : dt;
    }
  }

  double? _estimate() {
    final a = anchorPct;
    if (a == null) return null;
    return (a - BandBatteryRule.drainPctPerHour * streamedMs / 3600000).clamp(0, 100).toDouble();
  }

  BandBattery get now {
    final est = _estimate();
    final g = lastGauge;
    return BandBattery(
      gauge: g,
      estimate: est?.round(),
      stuck: est != null && g != null && ((g - est).abs() > nearPct || (BandBatteryRule.stuckLevels.contains(g) && (g - est).abs() > 2)),
      at: lastAtMs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(lastAtMs),
    );
  }

  /// True once per anchor, when the estimate first reaches empty after counting down from a real charge.
  bool takeEmpty() {
    final a = anchorPct;
    if (emptyTold || a == null || a < 15 || !now.empty) return false;
    emptyTold = true;
    return true;
  }

  Map<String, Object?> toJson() => {
    'anchorPct': anchorPct,
    'anchorAtMs': anchorAtMs,
    'streamedMs': streamedMs,
    'lastGauge': lastGauge,
    'lastAtMs': lastAtMs,
    'lastStreaming': lastStreaming,
    'emptyTold': emptyTold,
  };

  static BandBatteryTrack fromJson(Object? j) {
    if (j is! Map) return BandBatteryTrack();
    int? i(Object? v) => v is num ? v.toInt() : null;
    return BandBatteryTrack(
      anchorPct: i(j['anchorPct']),
      anchorAtMs: i(j['anchorAtMs']) ?? 0,
      streamedMs: i(j['streamedMs']) ?? 0,
      lastGauge: i(j['lastGauge']),
      lastAtMs: i(j['lastAtMs']) ?? 0,
      lastStreaming: j['lastStreaming'] == true,
      emptyTold: j['emptyTold'] == true,
    );
  }
}

/// The track in `files/headband/battery.json`, shared by the screen's engine and the recorder's (whichever reads the
/// gauge writes; a read-change-write per reading, the file swapped in whole).
class BandBatteryStore {
  BandBatteryStore(this.file);
  final File file;

  static BandBatteryStore forRecordings(String recordingsDir) =>
      BandBatteryStore(File('${Directory(recordingsDir).parent.path}/headband/battery.json'));

  BandBatteryTrack load() {
    try {
      return BandBatteryTrack.fromJson(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return BandBatteryTrack();
    }
  }

  void save(BandBatteryTrack t) {
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(t.toJson()));
      tmp.renameSync(file.path);
    } catch (_) {}
  }

  /// One reading through the file; returns the track after it.
  BandBatteryTrack note(int gauge, DateTime at, {required bool streaming}) {
    final t = load()..note(gauge, at, streaming: streaming);
    save(t);
    return t;
  }
}
