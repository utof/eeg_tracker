// An estimate: what a detector thinks happened over a stretch of clock time, before you confirmed it (DECISIONS
// 860-869). "Did you sleep 15:59-17:49?" is asked about an estimate; only your Yes or No makes a label of it
// (labels.dart). Its `label` is one of the vocabulary's (vocabulary.dart; the same names in eeg_tracker and
// utof_tracker); a stretch of clock time, never tied to a channel or an electrode layout, so the helmet's
// detectors register theirs unchanged. Plain Dart.
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;

import 'store.dart' show CardKind;
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
/// began yesterday too), `yesterday`, else `Thu 19 Nov`.
String _dayWord(DateTime end, DateTime now) {
  final today = DateTime(now.year, now.month, now.day), endDay = DateTime(end.year, end.month, end.day);
  final ago = (today.difference(endDay).inHours / 24).round(); // whole days, safe across a clock change
  if (ago <= 0) return '';
  if (ago == 1) return 'yesterday';
  return '${_weekdays[end.weekday - 1]} ${end.day} ${_months[end.month - 1]}';
}

DateTime _halfHour(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute).add(Duration(minutes: ((t.minute + 15) ~/ 30) * 30 - t.minute));

/// The stretch in words, your local time at [now]: `15:59-17:49`, `yesterday 15:59-17:49`, `Thu 19 Nov 15:59-17:49`.
/// Not [exact] (the times are no longer asked about, asking.md): to the half hour, `yesterday, about 16:00 to 18:00`.
String spanWords(Estimate e, DateTime now, {bool exact = true}) {
  final day = _dayWord(e.end, now);
  if (exact) return '${day.isEmpty ? '' : '$day '}${_clock(e.start)}-${_clock(e.end)}';
  final a = _clock(_halfHour(e.start)), b = _clock(_halfHour(e.end));
  final about = a == b ? 'about $a' : 'about $a to $b';
  return day.isEmpty ? about : '$day, $about';
}

String _capital(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// The words of a card that shows the guess: the stretch first, the guess second, as [who]'s opinion, then the
/// question: "15:59-17:49. The headband thinks you slept. Did you?" (asking.md: naming the stretch first and the guess
/// as an opinion pulls less toward Yes than "Did you sleep 15:59-17:49?").
String questionOf(Estimate e, DateTime now, {String who = 'The headband', bool exact = true}) =>
    '${_capital(spanWords(e, now, exact: exact))}. $who thinks ${e.label.thinks}. ${e.label.asks}';

/// The words of a blind card, which does not show the guess: "What were you doing 19:08-21:14?"
String blindQuestionOf(Estimate e, DateTime now, {bool exact = true}) => 'What were you doing ${spanWords(e, now, exact: exact)}?';

/// The labels a blind card offers, in the vocabulary's order, so the guess's place gives nothing away: a fixed short
/// list, and the guess's own label when it is not on it. Sleep, a nap and night sleep are one chip.
List<Label> blindChips(Estimate e) {
  const base = {'asleep', 'walking', 'working', 'eating', 'resting', 'vehicle', 'exercise', 'talking'};
  final guess = e.label;
  return [
    for (final l in Labels.all)
      if (base.contains(l.id) || (l == guess && !base.any((b) => Label.of(b)!.sameAs(guess)))) l,
  ];
}

/// Whether [id]'s card is a blind one: 1 card in [oneIn], picked by the estimate's id and [seed], so the same card is
/// blind on the card, in the notification and in a test, and nothing is rolled at run time.
bool blindByDraw(String id, {String seed = blindSeed, int oneIn = blindOneIn}) {
  if (oneIn <= 0) return false;
  final b = sha1.convert(utf8.encode('$seed|$id')).bytes;
  return ((b[0] << 16) | (b[1] << 8) | b[2]) % oneIn == 0;
}

/// Planning values (asking.md): 1 card in 5 is blind; the seed of the draw.
const int blindOneIn = 5;
const String blindSeed = 'blind-1';

/// One question as a screen shows it.
class ConfirmQuestion {
  const ConfirmQuestion(this.estimate, this.text, this.why, {this.kind = CardKind.normal, this.exactTimes = true, String? guessText})
    : _guessText = guessText; // ignore: prefer_initializing_formals
  final Estimate estimate;

  /// What the card says: "15:59-17:49. The headband thinks you slept. Did you?", or a blind card's "What were you
  /// doing 19:08-21:14?"
  final String text;

  /// Why it was picked: `newest`, `unsure`, `long`, `rare`, `few`.
  final String why;

  /// A blind card does not show the guess; it offers [chips] and words of your own.
  final CardKind kind;

  /// The times are still asked about ("Yes, but the times are off"): only on the day of the stretch (asking.md).
  final bool exactTimes;
  final String? _guessText;

  /// The words with the guess shown, for a screen that cannot draw a blind card.
  String get guessText => _guessText ?? text;

  String get id => estimate.id;

  /// The two buttons that name the thing ("I slept", "I was awake").
  String get yes => estimate.label.yesWord;
  String get no => estimate.label.noWord;

  /// A blind card's choices.
  List<Label> get chips => blindChips(estimate);
}
