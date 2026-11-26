// A recording's timeline for the Archive (DECISIONS 700-709): its activity as bands on worded lanes, from what the phone
// already knows of that time, each band saying where it came from:
//   What happened  one best guess per moment with how sure it is (activity/happened.dart; DECISIONS 1101-1104): the
//                  lanes under it are its detail. Never mixed with what you marked or tagged yourself.
//   Sleep        asleep (N1 N2 N3 REM) by the night's sleep report, where the night was scored
//   Eyes closed  awake with eyes closed: the detectors' pass (seen.dart), or the work session's own epochs
//   Drowsy       getting drowsy or drowsy, awake with eyes open: the same
//   Talking      jaw muscle (both sides) in most seconds: talking or chewing awake, jaw clenching asleep
//   Moving       3 or more channels jumping at once for a few seconds
//   Walking      walking or running with the pace: the step rhythm in the signal (walking/pass.dart), steps estimated
//   Signal       no usable signal (the headband away, off or loose), and long stretches read through noise
//   Work         a work session (its breaks left out); Meeting: the meetings its file names
//   Sessions     every session in that time (meditation, a nap, the dream catcher, a sound, a check-in)
//   Your tags    the spans you tagged
// A band is a run of 30 s epochs (bridging one odd epoch), at least the rule's length (seen.dart ActivityRule: planning
// values). Asleep wins: eyes closed, drowsy and talking are not shown asleep. Plain Dart.
import '../activity/happened.dart';
import '../detectors/detectors.dart' show epochS;
import '../walking/detector.dart' show StretchKind;
import '../walking/pass.dart' show WalkResult, WalkSummary;
import 'items.dart';
import 'seen.dart';
import 'tags.dart';

enum Lane {
  happened('What happened'),
  sleep('Sleep'),
  eyes('Eyes closed'),
  drowsy('Drowsy'),
  talking('Talking'),
  moving('Moving'),
  walking('Walking'),
  signal('Signal'),
  work('Work'),
  meeting('Meeting'),
  sessions('Sessions'),
  tags('Your tags');

  const Lane(this.word);
  final String word;
}

/// How a band is drawn (DESIGN.md: a tone always repeats the lane's word).
enum BandTone {
  /// Found: the `saved` tone.
  found,

  /// Weaker: read through noise, a break, getting drowsy (a lighter fill).
  faint,

  /// No signal: `caution` amber, as the watch strip's gaps.
  warn,

  /// Yours: ink.
  yours,
}

class Band {
  const Band(this.lane, this.start, this.end, this.label, {this.source = '', this.tone = BandTone.found, this.tag});
  final Lane lane;
  final DateTime start, end;

  /// "Asleep", "Eyes closed", "Work session", "walk".
  final String label;

  /// Where it comes from, in one sentence.
  final String source;
  final BandTone tone;

  /// Your tag behind a [Lane.tags] band.
  final ManualTag? tag;

  Duration get length => end.difference(start);

  @override
  String toString() => 'Band(${lane.name} $label $start-$end)';
}

/// A sleep report's stages: one character per 30 s from [start] (`W 1 2 3 R -`).
typedef ReportStages = ({DateTime start, String stages});

/// What a work session's file says of its time.
class WorkDetail {
  const WorkDetail({
    required this.start,
    required this.end,
    this.breaks = const [],
    this.meetings = const [],
    this.epochs = const [],
  });
  final DateTime start, end;
  final List<(DateTime, DateTime)> breaks;

  /// Meetings, when the file names them (`meetings`: the laptop tray's, a later phone version's).
  final List<(DateTime, DateTime)> meetings;

  /// Each 30 s epoch: its start, level (`alert`, `getting_drowsy`, `drowsy`, `unknown`) and eyes closed.
  final List<({DateTime at, String level, bool closed})> epochs;
}

/// What the timeline is drawn from.
class TimelineInput {
  const TimelineInput({
    this.seen,
    this.seenWhy,
    this.stages,
    this.work = const [],
    this.sessions = const [],
    this.tags = const [],
    this.walk,
  });
  final RecordingSeen? seen;

  /// The walking pass's result (walking/pass.dart), kept also after the raw signal left the phone; null: none yet.
  final WalkResult? walk;

  /// Why there is no pass ("needs O1 O2 T3 T4", ...); null while it was not tried.
  final String? seenWhy;
  final ReportStages? stages;
  final List<WorkDetail> work;

  /// Every session in the recording's time (its own included).
  final List<SessionFile> sessions;
  final List<ManualTag> tags;
}

class Timeline {
  const Timeline(this.start, this.end, this.bands);
  final DateTime start, end;
  final List<Band> bands;

  Duration get length => end.difference(start);

  List<Band> of(Lane l) => [for (final b in bands) if (b.lane == l) b];

  /// The time a lane covers (overlaps counted once).
  Duration total(Lane l) {
    final spans = [for (final b in of(l)) (b.start, b.end)]..sort((a, b) => a.$1.compareTo(b.$1));
    var sum = Duration.zero;
    DateTime? s, e;
    for (final (a, b) in spans) {
      if (e != null && !a.isAfter(e)) {
        if (b.isAfter(e)) e = b;
        continue;
      }
      if (s != null) sum += e!.difference(s);
      s = a;
      e = b;
    }
    if (s != null) sum += e!.difference(s);
    return sum;
  }
}

/// Runs of epochs where [hit] holds, bridging up to [ActivityRule.joinEpochs] epochs, at least [min] long: (first,
/// last) epoch.
List<(int, int)> runsWhere(int n, bool Function(int i) hit, {required int min}) {
  final out = <(int, int)>[];
  int? a, last;
  for (var i = 0; i < n; i++) {
    if (!hit(i)) continue;
    if (a != null && i - last! - 1 <= ActivityRule.joinEpochs) {
      last = i;
      continue;
    }
    if (a != null && last! - a + 1 >= min) out.add((a, last));
    a = i;
    last = i;
  }
  if (a != null && last! - a + 1 >= min) out.add((a, last));
  return out;
}

String _minutes(Duration d) {
  final m = (d.inSeconds / 60).round();
  return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')}';
}

const Map<String, String> _stageWords = {'1': 'light', '2': 'light', '3': 'deep', 'R': 'dream'};

/// The timeline of [item] from [input] (see the top of the file), clipped to the recording's time.
Timeline timelineOf(ArchiveItem item, TimelineInput input) {
  final from = item.start, to = item.end.isAfter(item.start) ? item.end : item.start.add(const Duration(minutes: 1));
  final bands = <Band>[];
  void add(Band b) {
    final s = b.start.isBefore(from) ? from : b.start, e = b.end.isAfter(to) ? to : b.end;
    if (e.isAfter(s)) bands.add(Band(b.lane, s, e, b.label, source: b.source, tone: b.tone, tag: b.tag));
  }

  // one best guess per moment, with how sure it is
  for (final m in happenedMarks(seen: input.seen, stages: input.stages, walk: input.walk, from: from, to: to)) {
    add(
      Band(
        Lane.happened,
        m.start,
        m.end,
        m.what.word,
        source: '${m.source} How sure: ${m.sure.word}.',
        tone: switch (m.sure) {
          _ when m.what == What.noSignal => BandTone.warn,
          Sure.some || Sure.weak => BandTone.faint,
          _ => BandTone.found,
        },
      ),
    );
  }

  // asleep, by the report
  final asleep = <(DateTime, DateTime)>[];
  final st = input.stages;
  if (st != null) {
    final s = st.stages;
    DateTime at(int i) => st.start.add(Duration(seconds: i * epochS));
    for (final (a, b) in runsWhere(s.length, (i) => _stageWords.containsKey(s[i]), min: ActivityRule.minAsleep)) {
      final counts = <String, int>{};
      for (var i = a; i <= b; i++) {
        final w = _stageWords[s[i]];
        if (w != null) counts[w] = (counts[w] ?? 0) + 1;
      }
      final parts = [
        for (final w in const ['light', 'deep', 'dream'])
          if ((counts[w] ?? 0) > 0) '$w ${_minutes(Duration(seconds: counts[w]! * epochS))}',
      ];
      asleep.add((at(a), at(b + 1)));
      add(Band(Lane.sleep, at(a), at(b + 1), 'Asleep', source: 'The sleep report\'s stages: ${parts.join(', ')}.'));
    }
  }
  bool isAsleep(DateTime t) => asleep.any((p) => !t.isBefore(p.$1) && t.isBefore(p.$2));

  // the detectors' pass
  final seen = input.seen;
  if (seen != null) {
    final n = seen.epochs;
    final sleepAt = List<bool>.generate(n, (i) => isAsleep(seen.epochStart(i)));
    Band band(Lane lane, (int, int) r, String label, String source, {BandTone tone = BandTone.found}) =>
        Band(lane, seen.epochStart(r.$1), seen.epochStart(r.$2 + 1), label, source: source, tone: tone);
    for (final r in runsWhere(n, (i) => seen.quality[i] == 'm', min: ActivityRule.minMissing)) {
      add(band(Lane.signal, r, 'No signal', 'No usable electrode, or no data: the headband away, off or loose.', tone: BandTone.warn));
    }
    for (final r in runsWhere(n, (i) => seen.quality[i] == 'd', min: 4)) {
      add(band(Lane.signal, r, 'Noisy', 'Read through noise: movement, muscle or a poor electrode.', tone: BandTone.faint));
    }
    final awake = [for (var i = 0; i < n; i++) !sleepAt[i] && seen.quality[i] != 'm'];
    for (final r in runsWhere(n, (i) => awake[i] && seen.eyes[i] == 'c', min: ActivityRule.minEyes)) {
      add(band(Lane.eyes, r, 'Eyes closed', 'Back alpha 2 to 3 times this recording\'s eyes-open level, no blinks.'));
    }
    for (final r in runsWhere(
      n,
      (i) => awake[i] && seen.eyes[i] != 'c' && (seen.level[i] == 'g' || seen.level[i] == 'd'),
      min: ActivityRule.minDrowsy,
    )) {
      final deep = [for (var i = r.$1; i <= r.$2; i++) if (seen.level[i] == 'd') i].length * 2 > r.$2 - r.$1 + 1;
      add(
        band(
          Lane.drowsy,
          r,
          deep ? 'Drowsy' : 'Getting drowsy',
          'More back alpha and stiller eyes than this recording\'s first minutes (the work session\'s rule).',
          tone: deep ? BandTone.found : BandTone.faint,
        ),
      );
    }
    for (final r in runsWhere(n, (i) => seen.quality[i] != 'm' && seen.jaw[i] >= ActivityRule.talkingJaw, min: ActivityRule.minTalking)) {
      final slept = sleepAt[r.$1];
      add(
        band(
          Lane.talking,
          r,
          slept ? 'Jaw' : 'Talking or chewing',
          slept ? 'Jaw muscle on both sides while asleep: clenching.' : 'Jaw muscle on both sides in most of these minutes.',
        ),
      );
    }
    for (final r in runsWhere(n, (i) => seen.move[i] >= ActivityRule.movingS, min: ActivityRule.minMoving)) {
      add(band(Lane.moving, r, 'Moving', 'Three or more electrodes jumping at once.'));
    }
  } else {
    // no pass: the time between the file sets is still known
    final sets = [...item.sets]..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < sets.length; i++) {
      final gapFrom = sets[i - 1].last, gapTo = sets[i].start;
      if (gapTo.difference(gapFrom) >= const Duration(minutes: 1)) {
        add(Band(Lane.signal, gapFrom, gapTo, 'No data', source: 'Between two file sets: the headband away or off.', tone: BandTone.warn));
      }
    }
  }

  // walking, by its own pass: a band per walking or running stretch with its pace (stops are the gaps between them)
  for (final w in input.walk?.walks ?? const <WalkSummary>[]) {
    for (final st in w.stretches) {
      if (st.kind == StretchKind.stopped) continue;
      final run = st.kind == StretchKind.running;
      final pace = st.pace == null ? '' : ', ${st.pace!.round()} a minute';
      add(
        Band(
          Lane.walking,
          st.start,
          st.end,
          '${run ? 'Running' : 'Walking'}$pace',
          source: 'The step rhythm in the headband\'s signal: about ${st.steps} steps, estimated'
              '${st.confidence == null ? '' : ' (${st.confidence})'}.',
          tone: st.confidence == 'unsure' ? BandTone.faint : BandTone.found,
        ),
      );
    }
  }

  // work sessions
  for (final w in input.work) {
    var at = w.start;
    final breaks = [...w.breaks]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (bs, be) in breaks) {
      if (bs.isAfter(at)) add(Band(Lane.work, at, bs, 'Work session', source: 'The work session\'s file.'));
      add(Band(Lane.work, bs, be, 'Break', source: 'A break in the work session.', tone: BandTone.faint));
      if (be.isAfter(at)) at = be;
    }
    if (w.end.isAfter(at)) add(Band(Lane.work, at, w.end, 'Work session', source: 'The work session\'s file.'));
    for (final (ms, me) in w.meetings) {
      add(Band(Lane.meeting, ms, me, 'Meeting', source: 'The work session\'s file: a call or a meeting window.'));
    }
    // without the detectors' pass the session's own epochs give eyes closed and drowsy
    if (seen == null && w.epochs.isNotEmpty) {
      final e = w.epochs;
      DateTime endOf(int i) => i + 1 < e.length ? e[i + 1].at : e[i].at.add(const Duration(seconds: epochS));
      for (final r in runsWhere(e.length, (i) => e[i].closed, min: ActivityRule.minEyes)) {
        add(Band(Lane.eyes, e[r.$1].at, endOf(r.$2), 'Eyes closed', source: 'The work session\'s own reading.'));
      }
      for (final r in runsWhere(
        e.length,
        (i) => !e[i].closed && (e[i].level == 'getting_drowsy' || e[i].level == 'drowsy'),
        min: ActivityRule.minDrowsy,
      )) {
        final deep = [for (var i = r.$1; i <= r.$2; i++) if (e[i].level == 'drowsy') i].length * 2 > r.$2 - r.$1 + 1;
        add(
          Band(
            Lane.drowsy,
            e[r.$1].at,
            endOf(r.$2),
            deep ? 'Drowsy' : 'Getting drowsy',
            source: 'The work session\'s own reading.',
            tone: deep ? BandTone.found : BandTone.faint,
          ),
        );
      }
    }
  }

  // sessions
  for (final s in input.sessions) {
    if (s.kind == ArchiveKind.work) continue; // its own lane
    final end = s.end.isAfter(s.start) ? s.end : s.start.add(const Duration(minutes: 1));
    add(Band(Lane.sessions, s.start, end, s.kind.word, source: 'Its session file.'));
  }

  // yours
  for (final t in input.tags) {
    add(Band(Lane.tags, t.start, t.end, t.label, source: 'Your tag.', tone: BandTone.yours, tag: t));
  }
  bands.sort((a, b) {
    final c = a.lane.index.compareTo(b.lane.index);
    return c != 0 ? c : a.start.compareTo(b.start);
  });
  return Timeline(from, to, bands);
}

/// The band of [lane] at [t], or null.
Band? bandAt(Timeline tl, Lane lane, DateTime t) {
  for (final b in tl.of(lane)) {
    if (!t.isBefore(b.start) && t.isBefore(b.end)) return b;
  }
  return null;
}

/// A short summary of what was found, for the list: the largest activities first ("asleep 6 h 12, talking 14 min").
List<String> foundWords({double? asleepMin, Map<String, double>? minutes}) {
  final parts = <(String, double)>[
    if (asleepMin != null && asleepMin > 0) ('asleep', asleepMin),
    if (minutes != null)
      for (final e in const [
        ('eyes', 'eyes closed'),
        ('drowsy', 'drowsy'),
        ('talking', 'talking'),
        ('moving', 'moving'),
        ('walking', 'walking'),
      ])
        if ((minutes[e.$1] ?? 0) >= 1) (e.$2, minutes[e.$1]!),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final p in parts.take(4)) '${p.$1} ${_minutes(Duration(seconds: (p.$2 * 60).round()))}'];
}

/// The minutes of no signal the pass found, for the list ("no signal 42 min"), when at least a minute.
String? noSignalWords(Map<String, double>? minutes) {
  final m = minutes?['nosignal'] ?? 0;
  return m >= 1 ? 'no signal ${_minutes(Duration(seconds: (m * 60).round()))}' : null;
}

/// The lanes a recording's timeline shows: always the same ones, so every value keeps its place (DESIGN.md).
const List<Lane> lanes = Lane.values;

/// Rounds [d] to whole minutes in words ("6 h 12", "14 min").
String durationWords(Duration d) => _minutes(d);
