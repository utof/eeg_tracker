// The Usage page's numbers (DECISIONS 714), plain Dart over the usage and metrics lines (usage.dart, metrics.dart)
// and the headband watcher's log (auto/log.dart): time in the app, time on each screen, features, most-tapped
// controls, what was not opened, scrolling, hints and questions, smoothness, start-up and storage.
import 'activity.dart' show featureLabel;

/// The app's screens the owner can open, with their words: a screen not seen in the period is "not opened".
const Map<String, String> knownScreens = {
  'tab:Record': 'Record tab',
  'tab:Sessions': 'Sessions tab',
  'tab:Signal': 'Signal tab',
  'tab:Trends': 'Trends tab',
  'tab:More': 'More tab',
  'SleepReportScreen': 'Sleep report',
  'MorningScreen': 'Morning check-in',
  'TrendsScreen': 'Trends',
  'TryTheseScreen': 'Try these',
  'MeditationScreen': 'Meditation',
  'AlphaThetaScreen': 'Alpha-theta',
  'DreamScreen': 'Dream catcher',
  'NapScreen': 'Nap coach',
  'LucidScreen': 'Lucid dreams',
  'MemoryCuesScreen': 'Memory cues',
  'WorkScreen': 'Work session',
  'StatesScreen': 'Sound for states',
  'ExportScreen': 'Export data',
  'SettingsScreen': 'Settings',
  'ExperimentsScreen': 'Self-experiments',
  'SleepExperimentsScreen': 'Sleep experiments',
  'SleepExperimentSetup': 'New sleep experiment',
  'SharpHoursScreen': 'Sharp hours',
  'StudyScreen': 'Study reminders',
  'TrainingSettingsScreen': 'Training settings',
  'AutoStartScreen': 'When I put the headband on',
  'OwnBleScreen': 'Headband connection',
  'LogsScreen': 'App log',
  'UsageScreen': 'How I use the app',
  'BatteryScreen': 'Battery',
};

/// Screens an older build wrote under another name: the first tab was `Night` before Record first (DECISIONS 880).
const Map<String, String> renamedScreens = {'tab:Night': 'tab:Record'};

/// [e] as the current names say it: an old log's `tab:Night` is `tab:Record`, in `screen` of any line.
Map<String, Object?> _current(Map<String, Object?> e) {
  final now = renamedScreens[e['screen']];
  return now == null ? e : {...e, 'screen': now};
}

/// A screen's words: the known ones by name, any other page's widget name split into words.
String screenLabel(String name) {
  final screen = renamedScreens[name] ?? name;
  final known = knownScreens[screen];
  if (known != null) return known;
  if (screen.startsWith('tab:')) return '${screen.substring(4)} tab';
  final bare = screen.endsWith('Screen') && screen.length > 6 ? screen.substring(0, screen.length - 6) : screen;
  final words = bare.replaceAllMapped(RegExp(r'(?<=[a-z])(?=[A-Z])'), (_) => ' ').toLowerCase();
  return words.isEmpty ? screen : '${words[0].toUpperCase()}${words.substring(1)}';
}

/// A span with no event at all for this long ends there (the app was killed, or left open on a table).
const Duration spanMax = Duration(hours: 3);

typedef ScreenTime = ({String screen, Duration time, int visits});
typedef FeatureUse = ({String feature, int times, Duration total});
typedef TapCount = ({String screen, String control, int taps});
typedef ScrollUse = ({String screen, int scrolls, int px, double reach});
typedef HintUse = ({String kind, int shown, Map<String, int> answers, int ignored, Duration? medianAfter});
typedef Smoothness = ({String screen, int frames, int slow, int janky, int worstMs});
typedef StorageUse = ({String category, int bytes, double? perDay});

class UsageSummary {
  const UsageSummary({
    required this.inApp,
    required this.opens,
    required this.perDay,
    required this.screens,
    required this.features,
    required this.taps,
    required this.notOpened,
    required this.scrolls,
    required this.drags,
    required this.hints,
    required this.breakHints,
    required this.breaksAfter,
    required this.autoGuesses,
    required this.autoRight,
    required this.smooth,
    required this.startups,
    required this.storage,
  });

  final Duration inApp;
  final int opens;

  /// Time in the app per day, oldest first (`2026-11-20`).
  final List<(String, Duration)> perDay;
  final List<ScreenTime> screens;
  final List<FeatureUse> features;
  final List<TapCount> taps;
  final List<String> notOpened;
  final List<ScrollUse> scrolls;
  final int drags;
  final List<HintUse> hints;

  /// Break hints shown, and how many a break followed within 15 minutes.
  final int breakHints, breaksAfter;

  /// The headband watcher's guesses that got an answer, and how many of them the answer agreed with.
  final int autoGuesses, autoRight;
  final List<Smoothness> smooth;

  /// Start-up times (process start to the first frame, ms), oldest first.
  final List<int> startups;
  final List<StorageUse> storage;

  bool get empty => opens == 0 && screens.isEmpty && features.isEmpty && taps.isEmpty;
}

DateTime? _t(Map<String, Object?> e) => DateTime.tryParse('${e['t']}');
String _day(DateTime t) => t.toIso8601String().substring(0, 10);

/// The summary of [usage] and [metrics] lines (any engine, any order) from [since] on, and the watcher's [auto] log.
UsageSummary usageSummary(
  List<Map<String, Object?>> usage,
  List<Map<String, Object?>> metrics, {
  required DateTime since,
  required DateTime now,
  List<Map<String, Object?>> auto = const [],
}) {
  metrics = [for (final m in metrics) _current(m)];
  final ev = [
    for (final e in usage)
      if (_t(e) case final t? when !t.isBefore(since) && !t.isAfter(now)) (t, _current(e)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final screens = _screens(ev, now);
  final perDay = <String, Duration>{};
  var inApp = Duration.zero;
  for (final (_, from, to) in screens.spans) {
    inApp += to.difference(from);
    perDay[_day(from)] = (perDay[_day(from)] ?? Duration.zero) + to.difference(from);
  }
  final seen = {for (final s in screens.spans) s.$1};
  final (breakHints, breaksAfter) = _breaks(ev);
  final (guesses, right) = _auto(auto, since, now);
  return UsageSummary(
    inApp: inApp,
    opens: screens.opens,
    perDay: (perDay.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => (e.key, e.value)).toList(),
    screens: _screenTimes(screens.spans),
    features: _features(ev),
    taps: _taps(ev),
    notOpened: [
      for (final k in knownScreens.keys)
        if (!seen.contains(k)) k,
    ],
    scrolls: _scrolls(ev),
    drags: ev.where((e) => e.$2['ev'] == 'drag').length,
    hints: _hints(ev),
    breakHints: breakHints,
    breaksAfter: breaksAfter,
    autoGuesses: guesses,
    autoRight: right,
    smooth: _smooth(metrics, since, now),
    startups: _startups(metrics, since, now),
    storage: _storage(metrics, now),
  );
}

/// Each stretch on one screen with the app in front: `view` changes the screen, `app` back ends a stretch and `app`
/// front starts one on the last screen.
({List<(String, DateTime, DateTime)> spans, int opens}) _screens(List<(DateTime, Map<String, Object?>)> ev, DateTime now) {
  final spans = <(String, DateTime, DateTime)>[];
  String? screen;
  DateTime? from;
  var front = false, opens = 0;
  void close(DateTime at) {
    final s = screen, f = from;
    if (front && s != null && f != null) {
      final to = at.difference(f) > spanMax ? f.add(spanMax) : at;
      if (to.isAfter(f)) spans.add((s, f, to));
    }
    from = at;
  }

  for (final (t, e) in ev) {
    switch (e['ev']) {
      case 'view':
        close(t);
        screen = '${e['screen']}';
        if (!front) {
          front = true; // a view means the app is in front, also when its "front" line is missing
          opens++;
        }
        from = t;
      case 'app':
        final nowFront = e['state'] == 'front';
        if (nowFront && !front) {
          front = true;
          opens++;
          from = t;
        } else if (!nowFront && front) {
          close(t);
          front = false;
        }
      default:
        // any other event while in front keeps the stretch alive; a long silence ends it at spanMax
        if (front && from != null && t.difference(from!) > spanMax) close(t);
    }
  }
  if (front) close(now);
  return (spans: spans, opens: opens);
}

List<ScreenTime> _screenTimes(List<(String, DateTime, DateTime)> spans) {
  final time = <String, Duration>{};
  final visits = <String, int>{};
  String? last;
  for (final (s, a, b) in spans) {
    time[s] = (time[s] ?? Duration.zero) + b.difference(a);
    if (s != last) visits[s] = (visits[s] ?? 0) + 1;
    last = s;
  }
  final out = [for (final e in time.entries) (screen: e.key, time: e.value, visits: visits[e.key] ?? 1)];
  out.sort((a, b) => b.time.compareTo(a.time));
  return out;
}

List<FeatureUse> _features(List<(DateTime, Map<String, Object?>)> ev) {
  final times = <String, int>{};
  final total = <String, Duration>{};
  for (final (_, e) in ev) {
    if (e['ev'] != 'feature' || e['name'] is! String) continue;
    final name = e['name']! as String;
    if (name == 'app-open') continue; // the time in the app says it
    if (e['on'] == true) {
      times[name] = (times[name] ?? 0) + 1;
    } else if (e['s'] is num) {
      total[name] = (total[name] ?? Duration.zero) + Duration(seconds: (e['s']! as num).toInt());
      times.putIfAbsent(name, () => 1); // started before the period
    }
  }
  final out = [
    for (final e in times.entries) (feature: e.key, times: e.value, total: total[e.key] ?? Duration.zero),
  ];
  out.sort((a, b) => b.total.compareTo(a.total) != 0 ? b.total.compareTo(a.total) : b.times.compareTo(a.times));
  return out;
}

/// The control's name in the log: its words, else its key, else its kind.
String _control(Map<String, Object?> e) {
  final label = e['label'], id = e['id'], kind = e['control'];
  if (label is String && label.isNotEmpty) return label;
  if (id is String && id.isNotEmpty) return id;
  return '$kind';
}

List<TapCount> _taps(List<(DateTime, Map<String, Object?>)> ev, {int top = 10}) {
  final n = <(String, String), int>{};
  for (final (_, e) in ev) {
    if (e['ev'] != 'tap') continue;
    final k = ('${e['screen'] ?? '?'}', _control(e));
    n[k] = (n[k] ?? 0) + 1;
  }
  final out = [for (final e in n.entries) (screen: e.key.$1, control: e.key.$2, taps: e.value)];
  out.sort((a, b) => b.taps.compareTo(a.taps));
  return out.take(top).toList();
}

List<ScrollUse> _scrolls(List<(DateTime, Map<String, Object?>)> ev) {
  final n = <String, int>{}, px = <String, int>{};
  final reach = <String, double>{};
  for (final (_, e) in ev) {
    if (e['ev'] != 'scroll') continue;
    final s = '${e['screen'] ?? '?'}';
    n[s] = (n[s] ?? 0) + 1;
    px[s] = (px[s] ?? 0) + (e['px'] is num ? (e['px']! as num).toInt() : 0);
    if (e['reach'] is num) reach[s] = [(reach[s] ?? 0), (e['reach']! as num).toDouble()].reduce((a, b) => a > b ? a : b);
  }
  final out = [for (final s in n.keys) (screen: s, scrolls: n[s]!, px: px[s]!, reach: reach[s] ?? 0)];
  out.sort((a, b) => b.scrolls.compareTo(a.scrolls));
  return out;
}

List<HintUse> _hints(List<(DateTime, Map<String, Object?>)> ev) {
  final shown = <String, int>{}, ignored = <String, int>{};
  final answers = <String, Map<String, int>>{};
  final after = <String, List<int>>{};
  for (final (_, e) in ev) {
    if (e['ev'] != 'hint') continue;
    final k = '${e['kind']}';
    switch (e['step']) {
      case 'shown':
        shown[k] = (shown[k] ?? 0) + 1;
      case 'answered':
        final a = answers[k] ??= {};
        final w = '${e['answer'] ?? '?'}';
        a[w] = (a[w] ?? 0) + 1;
        if (e['after_s'] is num) (after[k] ??= []).add((e['after_s']! as num).toInt());
      case 'ignored':
        ignored[k] = (ignored[k] ?? 0) + 1;
    }
  }
  final kinds = {...shown.keys, ...answers.keys, ...ignored.keys}.toList()..sort();
  return [
    for (final k in kinds)
      (
        kind: k,
        shown: shown[k] ?? 0,
        answers: answers[k] ?? const {},
        ignored: ignored[k] ?? 0,
        medianAfter: after[k] == null ? null : Duration(seconds: (after[k]!..sort())[after[k]!.length ~/ 2]),
      ),
  ];
}

/// Break hints (`hint` `work-break` `shown`) and how many a break (`hint` `work-break` `break`: tapped On a break, or
/// the headband came off) came after within 15 minutes.
(int, int) _breaks(List<(DateTime, Map<String, Object?>)> ev) {
  final shown = <DateTime>[];
  final breaks = <DateTime>[];
  for (final (t, e) in ev) {
    if (e['ev'] == 'hint' && e['kind'] == 'work-break') {
      if (e['step'] == 'shown') shown.add(t);
      if (e['step'] == 'break') breaks.add(t);
    }
  }
  var followed = 0;
  for (final s in shown) {
    if (breaks.any((b) => !b.isBefore(s) && b.difference(s) <= const Duration(minutes: 15))) followed++;
  }
  return (shown.length, followed);
}

/// The watcher's questions about its guess (`answer` lines of `auto-start/log.jsonl` for a night or work guess): yes,
/// or the guess's own kind, is right; no, or the other kind, is wrong; no answer is left out. A question about an
/// "other" guess asks which it was, so it has no right or wrong.
(int, int) _auto(List<Map<String, Object?>> log, DateTime since, DateTime now) {
  var n = 0, right = 0;
  for (final e in log) {
    if (e['event'] != 'answer') continue;
    final t = DateTime.tryParse('${e['at']}');
    if (t == null || t.isBefore(since) || t.isAfter(now)) continue;
    final kind = '${e['kind']}', a = '${e['answer']}';
    if (kind != 'night' && kind != 'work') continue;
    if (a == 'none' || a == 'null') continue;
    n++;
    if (a == 'yes' || a == kind) right++;
  }
  return (n, right);
}

List<Smoothness> _smooth(List<Map<String, Object?>> metrics, DateTime since, DateTime now) {
  final acc = <String, List<int>>{};
  for (final m in metrics) {
    if (m['kind'] != 'frames') continue;
    final t = _t(m);
    if (t == null || t.isBefore(since) || t.isAfter(now)) continue;
    int i(String k) => m[k] is num ? (m[k]! as num).toInt() : 0;
    final a = acc['${m['screen'] ?? '?'}'] ??= [0, 0, 0, 0];
    a[0] += i('n');
    a[1] += i('slow');
    a[2] += i('janky');
    if (i('worst_ms') > a[3]) a[3] = i('worst_ms');
  }
  final out = [
    for (final e in acc.entries) (screen: e.key, frames: e.value[0], slow: e.value[1], janky: e.value[2], worstMs: e.value[3]),
  ];
  out.sort((a, b) => (b.frames == 0 ? 0 : b.janky / b.frames).compareTo(a.frames == 0 ? 0 : a.janky / a.frames));
  return out;
}

/// Cold starts only: a process older than a minute at the first frame was started earlier for something else (the
/// night's service, the headband watcher), so the screen's opening is no start-up.
List<int> _startups(List<Map<String, Object?>> metrics, DateTime since, DateTime now) => [
  for (final m in metrics)
    if (m['kind'] == 'startup' && m['process_ms'] is num && (m['process_ms']! as num) <= 60000)
      if (_t(m) case final t? when !t.isBefore(since) && !t.isAfter(now)) (m['process_ms']! as num).toInt(),
];

/// Each folder's size at the newest `storage` line, and its growth a day from the oldest line of the last 7 days.
List<StorageUse> _storage(List<Map<String, Object?>> metrics, DateTime now) {
  final lines = [
    for (final m in metrics)
      if (m['kind'] == 'storage' && m['cats'] is Map)
        if (_t(m) case final t? when !t.isAfter(now) && now.difference(t) <= const Duration(days: 8)) (t, m['cats']! as Map),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  if (lines.isEmpty) return const [];
  final (t1, last) = lines.last;
  final (t0, first) = lines.first;
  final days = t1.difference(t0).inHours / 24;
  final out = <StorageUse>[];
  for (final e in last.entries) {
    final now = e.value is num ? (e.value as num).toInt() : 0;
    final was = first[e.key] is num ? (first[e.key] as num).toInt() : 0;
    out.add((category: '${e.key}', bytes: now, perDay: days >= 0.9 ? (now - was) / days : null));
  }
  out.sort((a, b) => b.bytes.compareTo(a.bytes));
  return out;
}

/// `1 h 05 min`, `12 min`, `40 s`.
String spanWords(Duration d) {
  if (d.inMinutes >= 60) return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
  if (d.inMinutes >= 1) return '${d.inMinutes} min';
  return '${d.inSeconds} s';
}

/// A feature's words for the page.
String featureWords(String f) => featureLabel(f);
