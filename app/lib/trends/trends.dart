// The trends page's content from the phone's own files (DECISIONS rows 120-129, 155, 287): one number per day per
// measure, from the sleep reports (files/nights; jaw muscle bursts from their extras), the morning check-ins
// (files/mornings), the sharp-hours log (files/sharp-hours), the work sessions (files/work-sessions, rows 480-489)
// and the meditation and alpha-theta reports; each with yesterday's value ("same as yesterday"), your
// usual and an arrow when the day is beyond your normal spread (usual.dart); the last 14 days as a line; sleep
// pressure from the sleep log (pressure.dart); and the hidden forecast (forecast.dart). Plain Dart: the screen only
// lays it out.
import '../meditation/tracker.dart' show MeditationSummary;
import '../morning/store.dart' show MorningRecord;
import '../sleep/extras.dart' show ExtrasAsleep;
import '../sleep/report.dart' show SleepReport;
import '../training/control.dart' show SessionKind;
import 'days.dart';
import 'forecast.dart';
import 'pressure.dart';
import 'usual.dart';

/// Days a line shows, and how old the newest value may be to be shown as "now".
const int lineDays = 14;

/// [day]: the sharp-hours log's numbers (DECISIONS row 287) and the study reminders' recall (row 401), shown only
/// once something is logged. [work]: the work sessions' day numbers (rows 480-489), the same.
enum TrendGroup { sleep, morning, day, work, practice, noted }

class MeasureSpec {
  const MeasureSpec({
    required this.id,
    required this.label,
    required this.group,
    required this.scale,
    required this.format,
    this.up = 'higher than usual',
    this.down = 'lower than usual',
    this.note,
    this.min = 0,
    this.max,
  });

  final String id;
  final String label;
  final TrendGroup group;
  final Scale scale;

  /// The value as words and units ("7 h 10 min", "4 of 9").
  final String Function(double v) format;
  final String up, down;

  /// One plain line under the label, when the measure needs it.
  final String? note;

  /// The ends of the measure's own scale: a normal range shown is kept inside them.
  final double min;
  final double? max;
}

/// `7 h 05 min`, `42 min`, with no-break spaces so a duration never splits across lines.
String _hm(double minutes) {
  final t = minutes.round();
  return t < 60 ? '$t\u00a0min' : '${t ~/ 60}\u00a0h\u00a0${(t % 60).toString().padLeft(2, '0')}\u00a0min';
}

String _n(double v, String one, String many) => v.round() == 1 ? '1\u00a0$one' : '${v.round()}\u00a0$many';

String _of(double v, int top) => '${v.round()}\u00a0of\u00a0$top';
String _count(double v, String one, String many) {
  final n = v.round();
  return n >= 5 ? '5+\u00a0$many' : (n == 1 ? '1\u00a0$one' : '$n\u00a0$many');
}

const String _together = 'Seen together, not tested.';

final List<MeasureSpec> measureSpecs = [
  MeasureSpec(
    id: 'asleep',
    label: 'Asleep',
    group: TrendGroup.sleep,
    scale: Scale.minutes,
    format: _hm,
    up: 'longer than usual',
    down: 'shorter than usual',
    note: 'The sleep model is a first guess on this headband.',
  ),
  MeasureSpec(
    id: 'jaw',
    label: 'Jaw muscle bursts',
    group: TrendGroup.sleep,
    scale: Scale.rate,
    format: (v) => '${v.toStringAsFixed(1)}\u00a0an\u00a0hour',
    up: 'more than usual',
    down: 'fewer than usual',
    note: 'An hour asleep. A trend to compare your nights, not a test for teeth grinding.',
  ),
  MeasureSpec(
    id: 'kss',
    label: 'Sleepiness',
    group: TrendGroup.morning,
    scale: Scale.rating,
    format: (v) => _of(v, 9),
    min: 1,
    max: 9,
    up: 'sleepier than usual',
    down: 'more alert than usual',
  ),
  MeasureSpec(
    id: 'reaction',
    label: 'Reaction time',
    group: TrendGroup.morning,
    scale: Scale.reaction,
    format: (v) => '${v.round()}\u00a0ms',
    up: 'slower than usual',
    down: 'quicker than usual',
  ),
  MeasureSpec(
    id: 'mood',
    label: 'Mood',
    group: TrendGroup.morning,
    scale: Scale.rating,
    format: (v) => _of(v, 5),
    min: 1,
    max: 5,
  ),
  MeasureSpec(
    id: 'tension',
    label: 'Tension',
    group: TrendGroup.morning,
    scale: Scale.rating,
    format: (v) => _of(v, 5),
    min: 1,
    max: 5,
    up: 'more tense than usual',
    down: 'less tense than usual',
  ),
  MeasureSpec(
    id: 'iaf',
    label: 'Alpha speed',
    group: TrendGroup.morning,
    scale: Scale.plain,
    format: (v) => '${v.toStringAsFixed(2)}\u00a0Hz',
    up: 'faster than usual',
    down: 'slower than usual',
    note: 'Eyes closed. It does not tell tiredness.',
  ),
  MeasureSpec(
    id: 'alpha',
    label: 'Alpha strength',
    group: TrendGroup.morning,
    scale: Scale.log,
    format: (v) => '${v.toStringAsFixed(1)}\u00a0µV²',
    up: 'stronger than usual',
    down: 'weaker than usual',
    note: 'Eyes closed.',
  ),
  MeasureSpec(
    id: 'rise',
    label: 'Eyes-closed rise',
    group: TrendGroup.morning,
    scale: Scale.log,
    format: (v) => '${v.toStringAsFixed(1)}×',
    up: 'larger than usual',
    down: 'smaller than usual',
    note: 'Alpha with eyes closed over eyes open.',
  ),
  MeasureSpec(
    id: 'sharp',
    label: 'Sharpness in the day',
    group: TrendGroup.day,
    scale: Scale.meanRating,
    format: (v) => '${v.toStringAsFixed(1)}\u00a0of\u00a05',
    min: 1,
    max: 5,
    up: 'sharper than usual',
    down: 'less sharp than usual',
    note: 'The mean of the day\'s sharp-hours ratings.',
  ),
  MeasureSpec(
    id: 'dayrt',
    label: 'Reaction time in the day',
    group: TrendGroup.day,
    scale: Scale.reaction,
    format: (v) => '${v.round()}\u00a0ms',
    up: 'slower than usual',
    down: 'quicker than usual',
    note: 'The middle of the day\'s sharp-hours reaction tests.',
  ),
  MeasureSpec(
    id: 'recall',
    label: 'Recall of what you studied',
    group: TrendGroup.day,
    scale: Scale.meanRating,
    format: (v) => '${v.toStringAsFixed(1)}\u00a0of\u00a03',
    min: 1,
    max: 3,
    up: 'better than usual',
    down: 'worse than usual',
    note: 'The morning answer of the study reminders: 1 a little, 2 some, 3 well.',
  ),
  MeasureSpec(
    id: 'worktime',
    label: 'Work with a signal',
    group: TrendGroup.work,
    scale: Scale.noArrows,
    format: _hm,
    note: 'Work-session time the level could be read: no breaks, noise or closed eyes. $_together',
  ),
  MeasureSpec(
    id: 'workdrowsy',
    label: 'Work time drowsy',
    group: TrendGroup.work,
    scale: Scale.plain,
    format: (v) => '${v.round()}\u00a0%',
    max: 100,
    up: 'drowsier than usual',
    down: 'less drowsy than usual',
    note: 'The share of that time at getting drowsy or drowsy. $_together',
  ),
  MeasureSpec(
    id: 'workfirst',
    label: 'Work until first drowsy stretch',
    group: TrendGroup.work,
    scale: Scale.plain,
    format: _hm,
    up: 'later than usual',
    down: 'sooner than usual',
    note: 'Worked minutes until the level read getting drowsy or drowsy for 8 of 12 half minutes. Only days with '
        'one. $_together',
  ),
  MeasureSpec(
    id: 'workhints',
    label: 'Break hints shown',
    group: TrendGroup.work,
    scale: Scale.noArrows,
    format: (v) => _n(v, 'hint', 'hints'),
    note: 'In work sessions. $_together',
  ),
  MeasureSpec(
    id: 'workfollowed',
    label: 'Hints followed by a break',
    group: TrendGroup.work,
    scale: Scale.noArrows,
    format: (v) => _n(v, 'hint', 'hints'),
    note: 'A break of 5 minutes or more within 30 minutes of the hint. $_together',
  ),
  MeasureSpec(
    id: 'workbreaks',
    label: 'Work breaks',
    group: TrendGroup.work,
    scale: Scale.noArrows,
    format: (v) => _n(v, 'break', 'breaks'),
    note: 'Of 5 minutes or more, tapped or the headband off. $_together',
  ),
  MeasureSpec(
    id: 'worksharp',
    label: 'Sharpness at work',
    group: TrendGroup.work,
    scale: Scale.meanRating,
    format: (v) => '${v.toStringAsFixed(1)}\u00a0of\u00a05',
    min: 1,
    max: 5,
    up: 'sharper than usual',
    down: 'less sharp than usual',
    note: 'The mean of your "how sharp" taps in work sessions. $_together',
  ),
  MeasureSpec(
    id: 'settled',
    label: 'Settled in meditation',
    group: TrendGroup.practice,
    scale: Scale.plain,
    format: (v) => '${v.round()}\u00a0%',
    max: 100,
    up: 'more settled than usual',
    down: 'less settled than usual',
  ),
  MeasureSpec(
    id: 'practice',
    label: 'Practice',
    group: TrendGroup.practice,
    scale: Scale.noArrows,
    format: _hm,
    note: 'Meditation and alpha-theta, minutes of signal.',
  ),
  MeasureSpec(
    id: 'caffeine',
    label: 'Caffeine the day before',
    group: TrendGroup.noted,
    scale: Scale.noArrows,
    format: (v) => _count(v, 'cup', 'cups'),
  ),
  MeasureSpec(
    id: 'alcohol',
    label: 'Alcohol the day before',
    group: TrendGroup.noted,
    scale: Scale.noArrows,
    format: (v) => _count(v, 'drink', 'drinks'),
  ),
];

typedef TrendInputs = ({List<SleepReport> nights, List<MorningRecord> mornings, List<MeditationSummary> sessions});

/// The end of a night's last sleep period (its data end without periods): the night counts for that day.
DateTime finalWake(SleepReport r) {
  final p = r.periods;
  return p.isEmpty ? r.dataEnd : p.map((x) => x.end).reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Day -> value per measure id. [extra]: day numbers worked out elsewhere, by measure id (the sharp-hours log's
/// `sharp` and `dayrt`, sharp/hours.dart; the work sessions' `work...`, work/days.dart); ids that are not measures are ignored.
Map<String, Map<String, double>> dailySeries(TrendInputs inputs, {Map<String, Map<String, double>> extra = const {}}) {
  final out = {for (final m in measureSpecs) m.id: <String, double>{}};
  for (final MapEntry(key: id, value: days) in extra.entries) {
    out[id]?.addAll({
      for (final MapEntry(key: d, value: v) in days.entries)
        if (v.isFinite) d: v,
    });
  }
  // jaw muscle bursts an hour asleep (the report's extras, version 2): the night's own number, or over the hours
  // asleep of all the day's nights together
  final jaw = <String, List<ExtrasAsleep>>{};
  for (final r in inputs.nights) {
    if (!r.scored) continue;
    final d = wakeDay(finalWake(r));
    out['asleep']![d] = (out['asleep']![d] ?? 0) + r.asleepMin;
    final a = r.extras?.asleep;
    if (a != null && a.jawPerHour != null && a.min > 0) jaw.putIfAbsent(d, () => []).add(a);
  }
  for (final MapEntry(key: d, value: a) in jaw.entries) {
    out['jaw']![d] = a.length == 1
        ? a.single.jawPerHour!
        : (a.fold(0, (n, x) => n + x.jawBursts) / (a.fold(0.0, (m, x) => m + x.min) / 60) * 10).round() / 10;
  }
  // a check-in's values: the first of the day that has each one (a later one is not a morning)
  final mornings = [...inputs.mornings]..sort((a, b) => a.start.compareTo(b.start));
  void first(String id, String day, num? v) {
    if (v != null && v.isFinite) out[id]!.putIfAbsent(day, () => v.toDouble());
  }

  for (final m in mornings) {
    final d = m.day;
    first('kss', d, m.kss);
    first('reaction', d, m.reactionMs);
    first('mood', d, m.mood);
    first('tension', d, m.tension);
    first('iaf', d, m.iafHz);
    first('alpha', d, m.alphaEc);
    first('rise', d, m.ecRise);
    first('caffeine', d, m.caffeineCups);
    first('alcohol', d, m.alcoholDrinks);
  }
  final settled = <String, (double, double)>{};
  for (final s in inputs.sessions) {
    if (s.runS <= 0) continue;
    final d = dayKey(s.start);
    out['practice']![d] = (out['practice']![d] ?? 0) + s.runS / 60;
    if (s.kind == SessionKind.meditation) {
      final (a, b) = settled[d] ?? (0.0, 0.0);
      settled[d] = (a + s.settledS, b + s.runS);
    }
  }
  for (final e in settled.entries) {
    out['settled']![e.key] = e.value.$1 / e.value.$2 * 100;
  }
  return out;
}

class TrendRow {
  const TrendRow({
    required this.spec,
    required this.usual,
    required this.line,
    this.day,
    this.value,
    this.yesterday,
    this.arrow = Arrow.none,
  });

  final MeasureSpec spec;

  /// The newest day with a value in the last [lineDays] days (null: none), its value and the day before's.
  final String? day;
  final double? value;
  final double? yesterday;

  /// Your usual for [day] (or for today when there is no value).
  final Usual usual;
  final Arrow arrow;

  /// The last [lineDays] days up to today, oldest first; null where there is no value.
  final List<double?> line;

  bool get hasData => value != null;
}

class TrendsModel {
  const TrendsModel({
    required this.today,
    required this.now,
    required this.rows,
    required this.pressure,
    required this.forecast,
    required this.nights,
    required this.mornings,
    required this.sessions,
    required this.daysWithData,
  });

  final String today;
  final DateTime now;
  final List<TrendRow> rows;
  final PressureModel pressure;
  final Forecast forecast;
  final int nights, mornings, sessions, daysWithData;

  List<TrendRow> group(TrendGroup g) => [
    for (final r in rows)
      if (r.spec.group == g) r,
  ];
}

TrendsModel buildTrends(TrendInputs inputs, DateTime now, {Map<String, Map<String, double>> extra = const {}}) {
  final today = dayKey(now);
  final series = dailySeries(inputs, extra: extra);
  final days = lastDays(today, lineDays);
  final rows = <TrendRow>[];
  for (final spec in measureSpecs) {
    final s = series[spec.id]!;
    String? day;
    for (final d in days.reversed) {
      if (s[d] != null) {
        day = d;
        break;
      }
    }
    final usual = usualOf(s, day ?? today, spec.scale);
    final v = day == null ? null : s[day];
    rows.add(TrendRow(
      spec: spec,
      day: day,
      value: v,
      yesterday: day == null ? null : yesterdayOf(s, day),
      usual: usual,
      arrow: v == null ? Arrow.none : usual.arrow(v),
      line: [for (final d in days) s[d]],
    ));
  }
  final spans = <SleepSpan>[
    for (final r in inputs.nights)
      if (r.scored)
        for (final p in r.periods) (start: p.start, end: p.end),
  ];
  final all = {for (final s in series.values) ...s.keys};
  return TrendsModel(
    today: today,
    now: now,
    rows: rows,
    pressure: PressureModel(spans),
    forecast: sleepinessForecast(series['kss']!, today),
    nights: inputs.nights.where((r) => r.scored).length,
    mornings: inputs.mornings.length,
    sessions: inputs.sessions.where((s) => s.runS > 0).length,
    daysWithData: all.length,
  );
}
