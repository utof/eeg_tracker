// What the "Unusual for you" card says (DECISIONS rows 290-299), in plain words, from the detector's verdicts
// (detector.dart). Never a disease name, never "warning": your numbers moved, not why (research early-warning
// pass 2, Q3). Plain Dart, so the words are tested without a phone.
import '../trends/days.dart';
import 'detector.dart';

enum CardKind {
  /// Switched off.
  off,

  /// The silent first 28 days: it only notes what it would have said.
  learning,

  /// On, nothing to say.
  quiet,

  /// A card: a number beyond your usual 2 days in a row.
  alert,

  /// A card ended in the last [backDays] days and its numbers came back.
  back,

  /// "Feeling ill" was tapped: paused, those days kept out of the usual.
  paused,
}

/// What might explain a card (id, label): the research's everyday causes, and "feeling ill", which pauses it.
const List<(String, String)> unusualCauses = [
  ('late night', 'Late night'),
  ('alcohol', 'Alcohol'),
  ('travel', 'Travel'),
  ('stress', 'Stress'),
  ('hard exercise', 'Hard exercise'),
  ('vaccine', 'Vaccine'),
  (feelingIll, 'Feeling ill'),
  ('not sure', 'Not sure'),
];

const String feelingIll = 'feeling ill';

/// Days "back in your usual range" stays after a card.
const int backDays = 3;

class UnusualCard {
  const UnusualCard({
    required this.kind,
    required this.headline,
    this.lines = const [],
    this.status,
    this.episode,
    this.causes = const {},
    this.pausedUntil,
    this.mainLine,
  });

  final CardKind kind;

  /// The sentence the section leads with.
  final String headline;

  /// A card's further numbers (one sentence each), or what an ended card was about.
  final List<String> lines;

  /// What it is based on, its track record, or how far learning is.
  final String? status;

  /// The first day of the card shown, which its noted causes belong to.
  final String? episode;
  final Set<String> causes;

  /// The first day after a pause.
  final String? pausedUntil;

  /// One line for the main screen, only with a card.
  final String? mainLine;
}

/// A number's words: what it is, its two ways as sentences, the unit of its days, and its two ways in short.
class _Words {
  const _Words(this.name, this.up, this.down, this.days, this.shortUp, this.shortDown);
  final String name;
  final String Function(String size, String when) up, down;
  final String days;
  final String shortUp, shortDown;
}

String _hm(double minutes) {
  final t = (minutes / 10).round() * 10;
  if (t < 60) return '$t min';
  final m = t % 60;
  return m == 0 ? '${t ~/ 60} h' : '${t ~/ 60} h $m min';
}

String _of(double v, int top) => '${v.round()} of $top';

final Map<String, _Words> _words = {
  'asleep': _Words(
    'sleep length',
    (size, when) => 'Your sleep has been $size longer than usual $when.',
    (size, when) => 'Your sleep has been $size shorter than usual $when.',
    'nights',
    'sleep longer than usual',
    'sleep shorter than usual',
  ),
  'kss': _Words(
    'sleepiness',
    (size, when) => 'You have felt sleepier than usual $when ($size).',
    (size, when) => 'You have felt more alert than usual $when ($size).',
    'mornings',
    'sleepier than usual',
    'more alert than usual',
  ),
  'mood': _Words(
    'mood',
    (size, when) => 'Your mood has been higher than usual $when ($size).',
    (size, when) => 'Your mood has been lower than usual $when ($size).',
    'mornings',
    'mood higher than usual',
    'mood lower than usual',
  ),
  'tension': _Words(
    'tension',
    (size, when) => 'You have felt more tense than usual $when ($size).',
    (size, when) => 'You have felt less tense than usual $when ($size).',
    'mornings',
    'more tense than usual',
    'less tense than usual',
  ),
  'reaction': _Words(
    'reaction test',
    (size, when) => 'Your reaction test has been slower than usual $when ($size).',
    (size, when) => 'Your reaction test has been quicker than usual $when ($size).',
    'mornings',
    'slower reactions than usual',
    'quicker reactions than usual',
  ),
};

String _size(String id, double mean, double usual) => switch (id) {
  'asleep' => _hm((mean - usual).abs()),
  'kss' => '${_of(mean, 9)}; usual ${_of(usual, 9)}',
  'mood' || 'tension' => '${_of(mean, 5)}; usual ${_of(usual, 5)}',
  'reaction' => '${mean.round()} ms; usual ${usual.round()} ms',
  _ => '',
};

/// "for 2 nights", or "on 2 of the last 3 nights" when the run spans a missing day.
String _when(int run, int span, String unit) => run == span ? 'for $run $unit' : 'on $run of the last $span $unit';

String _join(List<String> items) =>
    items.length <= 1 ? items.join() : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

String _lowerFirst(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

/// What the card watches and when it speaks, in one sentence.
const String unusualRule =
    'A card needs one of your sleep length, sleepiness, mood, tension and reaction time beyond your usual on 2 days '
    'in a row.';

/// The words for number [id] in the card of day [v]: its run's mean against the usual of its last day with a
/// value. Null for numbers the card never words (the headband's) or without a usual.
String? cardSentence(String id, DayVerdict v, Map<String, double> values, Map<String, DayVerdict> byDay) {
  final w = _words[id], a = v.active[id];
  if (w == null || a == null) return null;
  final days = values.keys.where((k) => k.compareTo(v.day) <= 0).toList()..sort();
  if (days.isEmpty) return null;
  final last = days.last;
  final usual = byDay[last]?.streams[id]?.usual;
  if (usual == null) return null;
  final size = _size(id, runMean(values, a.start, last), usual);
  final when = _when(a.run, runSpan(a.start, last), w.days);
  return a.state == StreamState.up ? w.up(size, when) : w.down(size, when);
}

/// Today's card from the verdicts of every day up to [today] (oldest first) and the per-day numbers; [pausedUntil]
/// is the first day after today's pause, when there is one (store.dart works it out from "feeling ill").
UnusualCard unusualCard(
  List<DayVerdict> verdicts,
  Map<String, Map<String, double>> series,
  String today, {
  Map<String, Set<String>> causes = const {},
  String? pausedUntil,
}) {
  final v = verdicts.isEmpty || verdicts.last.day != today ? null : verdicts.last;
  if (v == null || v.phase == UnusualPhase.silent) {
    return UnusualCard(
      kind: CardKind.learning,
      headline: 'Learning your usual: ${v?.validBefore ?? 0} of ${const UnusualSettings().silentDays} days.',
      status: 'Silent until then: it only notes what it would have said. $unusualRule',
    );
  }
  if (v.phase == UnusualPhase.paused) {
    final until = pausedUntil ?? addDays(today, 1);
    return UnusualCard(
      kind: CardKind.paused,
      headline: 'Paused until ${dayLabel(until)}.',
      pausedUntil: until,
      status: 'After feeling ill, your numbers can take a week or two to settle, so these days stay out of your '
          'usual.',
    );
  }
  final byDay = {for (final x in verdicts) x.day: x};
  if (v.ruleCore) return _alert(verdicts, v, series, byDay, causes);
  return _back(verdicts, v, series) ?? _quiet(verdicts);
}

/// The day a run of days with the rule began, walking back from the last verdict.
String _episodeStart(List<DayVerdict> verdicts) {
  var start = verdicts.last.day;
  for (final x in verdicts.reversed) {
    if (!x.ruleCore) break;
    start = x.day;
  }
  return start;
}

UnusualCard _alert(
  List<DayVerdict> verdicts,
  DayVerdict v,
  Map<String, Map<String, double>> series,
  Map<String, DayVerdict> byDay,
  Map<String, Set<String>> causes,
) {
  final sentences = [
    for (final id in v.onCore) ?cardSentence(id, v, series[id] ?? const {}, byDay),
  ];
  if (sentences.isEmpty) return _quiet(verdicts);
  final episode = _episodeStart(verdicts);
  final names = [for (final id in v.onCore) ?_words[id]?.name];
  return UnusualCard(
    kind: CardKind.alert,
    headline: sentences.first,
    lines: sentences.sublist(1),
    episode: episode,
    causes: causes[episode] ?? const {},
    status: 'Based on your ${_join(names)}, each against your usual of the 28 days that end a week before.',
    mainLine: 'Unusual for you: ${_lowerFirst(sentences.first)}',
  );
}

/// "Back in your usual range": a card shown in the last [backDays] days, and a number of it with a value since.
UnusualCard? _back(List<DayVerdict> verdicts, DayVerdict today, Map<String, Map<String, double>> series) {
  final shown = episodes(verdicts, shownOnly: true);
  if (shown.isEmpty) return null;
  final (from, to) = shown.last;
  if (daysBetween(to, today.day) > backDays) return null;
  final cardDays = [
    for (final x in verdicts)
      if (x.day.compareTo(from) >= 0 && x.day.compareTo(to) <= 0) x,
  ];
  final ways = <String, StreamState>{};
  for (final x in cardDays) {
    for (final id in x.onCore) {
      ways.putIfAbsent(id, () => x.active[id]!.state);
    }
  }
  final since = [
    for (final id in ways.keys)
      if ((series[id] ?? const {}).keys.any((d) => d.compareTo(to) > 0 && d.compareTo(today.day) <= 0)) id,
  ];
  if (since.isEmpty) return null;
  final what = _join([
    for (final MapEntry(key: id, value: s) in ways.entries)
      if (_words[id] != null) s == StreamState.up ? _words[id]!.shortUp : _words[id]!.shortDown,
  ]);
  final when = from == to ? 'on ${dayLabel(from)}' : 'from ${dayLabel(from)} to ${dayLabel(to)}';
  return UnusualCard(kind: CardKind.back, headline: 'Back in your usual range.', lines: ['It showed $when: $what.']);
}

String _cards(int n) => n == 1 ? '1 card' : '$n cards';

UnusualCard _quiet(List<DayVerdict> verdicts) {
  final on = verdicts.where((x) => x.phase == UnusualPhase.on).firstOrNull;
  final all = episodes(verdicts);
  final phase = {for (final x in verdicts) x.day: x.phase};
  final shown = all.where((e) => phase[e.$1] == UnusualPhase.on).length;
  final silent = all.where((e) => phase[e.$1] == UnusualPhase.silent).length;
  final record = on == null
      ? ''
      : 'Since ${dayLabel(on.day)}, when it switched on: ${_cards(shown)}. In its silent first '
            '${const UnusualSettings().silentDays} days it would have shown $silent. ';
  return UnusualCard(kind: CardKind.quiet, headline: 'Nothing unusual for you lately.', status: '$record$unusualRule');
}
