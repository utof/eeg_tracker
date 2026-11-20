// An estimate: what a detector thinks happened over a stretch of clock time, before you confirmed it (DECISIONS
// 860-869). "Did you sleep 15:59-17:49?" is asked about an estimate; only your Yes or No makes a label of it
// (labels.dart). Its `label` is one of the vocabulary's (vocabulary.dart; the same names in eeg_tracker and
// utof_tracker); a stretch of clock time, never tied to a channel or an electrode layout, so the helmet's
// detectors register theirs unchanged. Plain Dart.
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;

import 'time.dart';
import 'vocabulary.dart';

/// What a Yes is worth, in the vocabulary's confidence words: `certain` (the label holds for the whole stretch) or
/// `likely` (it holds, but not every minute fits: a night the detector itself found wake-ups in).
enum YesMeans { certain, likely }

class Estimate {
  Estimate({
    required this.detector,
    required this.version,
    required this.label,
    required DateTime start,
    required DateTime end,
    this.recording,
    this.confidence,
    this.yesMeans = YesMeans.certain,
    DateTime? made,
  }) : start = _second(start),
       end = _second(end),
       made = _second(made ?? DateTime.now());

  /// The detector's name (`sleep-periods`, `walking`) and the version of its rules or model.
  final String detector, version;
  final Label label;

  /// Local time, to the second.
  final DateTime start, end;

  /// The recording it was found in (`2026-11-20-155900`); null when it has none.
  final String? recording;

  /// How sure the detector is, 0 to 1; null when it does not say.
  final double? confidence;
  final YesMeans yesMeans;

  /// When the estimate was first registered.
  final DateTime made;

  Duration get length => end.difference(start);

  /// Stable: the same detector, label, times and recording give the same id, whatever the detector's version.
  late final String id = 'est:${sha1.convert(utf8.encode([detector, label.id, isoLocal(start), isoLocal(end), recording ?? ''].join('|'))).toString().substring(0, 16)}';

  Map<String, Object?> toJson() => {
    'id': id,
    'detector': detector,
    'version': version,
    'confidence': confidence,
    'start': isoLocal(start),
    'end': isoLocal(end),
    'recording': recording,
    'kind': label.kind,
    'label': label.id,
    'yes_means': yesMeans.name,
    'made': isoLocal(made),
  };

  /// Null for a line this version cannot read (a label it does not know, no times, end before start).
  static Estimate? fromJson(Object? j) {
    if (j is! Map) return null;
    final label = Label.of(j['label']);
    final s = DateTime.tryParse('${j['start']}'), e = DateTime.tryParse('${j['end']}');
    final d = j['detector'], v = j['version'], c = j['confidence'], r = j['recording'];
    if (label == null || s == null || e == null || e.isBefore(s) || d is! String || d.isEmpty || v is! String) return null;
    return Estimate(
      detector: d,
      version: v,
      label: label,
      start: s.toLocal(),
      end: e.toLocal(),
      recording: r is String && r.isNotEmpty ? r : null,
      confidence: c is num && c >= 0 && c <= 1 ? c.toDouble() : null,
      yesMeans: j['yes_means'] == 'likely' ? YesMeans.likely : YesMeans.certain,
      made: DateTime.tryParse('${j['made']}')?.toLocal() ?? e.toLocal(),
    );
  }
}

DateTime _second(DateTime t) {
  final l = t.toLocal();
  return DateTime(l.year, l.month, l.day, l.hour, l.minute, l.second);
}

/// The share of the shorter of two stretches that the other covers, 0 to 1 (a moment inside a stretch: 1).
double overlapShare(DateTime a0, DateTime a1, DateTime b0, DateTime b1) {
  final lo = a0.isAfter(b0) ? a0 : b0, hi = a1.isBefore(b1) ? a1 : b1;
  if (hi.isBefore(lo)) return 0;
  final la = a1.difference(a0).inSeconds, lb = b1.difference(b0).inSeconds;
  final shorter = la < lb ? la : lb;
  if (shorter <= 0) return 1;
  return hi.difference(lo).inSeconds / shorter;
}

const List<String> _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The day word before the times, in your local time at [now]: nothing for a stretch that ended today (a night that
/// began yesterday too), ` yesterday`, else ` on Thu 19 Nov`.
String _dayWord(DateTime end, DateTime now) {
  final today = DateTime(now.year, now.month, now.day), endDay = DateTime(end.year, end.month, end.day);
  final ago = (today.difference(endDay).inHours / 24).round(); // whole days, safe across a clock change
  if (ago <= 0) return '';
  if (ago == 1) return ' yesterday';
  return ' on ${_weekdays[end.weekday - 1]} ${end.day} ${_months[end.month - 1]}';
}

/// "Did you sleep 15:59-17:49?", "Did you walk yesterday 19:08-21:14?": short, the times in your local time.
String questionOf(Estimate e, DateTime now) =>
    '${e.label.ask}${_dayWord(e.end, now)} ${_clock(e.start)}-${_clock(e.end)}?';

/// One question as a screen shows it.
class ConfirmQuestion {
  const ConfirmQuestion(this.estimate, this.text, this.why);
  final Estimate estimate;

  /// "Did you walk 19:08-21:14?"
  final String text;

  /// Why it was picked: `unsure`, `long`, `rare`, `few`.
  final String why;

  String get id => estimate.id;
}
