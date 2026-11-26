// "What happened" in a recording (automatic recording, phase 2; DECISIONS 1101-1104; the research is
// _local/research/2026-11-20-00-auto-activity.md): one best guess per 30 seconds, each with how sure it is, kept apart
// from what you marked yourself and from your tags. From what the phone already keeps of a finished recording:
//   the detectors' pass (archive/seen.dart: signal quality, eyes, drowsiness, jaw, movement per 30 s)
//   the sleep report's stages
//   the walking pass's stretches
// One state per epoch, the first that applies:
//   No signal             no usable electrode, or no data                                near certain
//   Asleep / Nap          a sleep stage in the report (Nap: its sleep begun by day and under 3 hours)  good
//   Walking / Running     a stretch of the walking pass                                   good; some when it is unsure
//   Moving                3 or more seconds of movement in the epoch                      good
//   Talking or chewing    2 or more jaw bursts in the epoch (which of the two: not told)  weak
//   Eyes closed, resting  eyes closed, awake, no movement second, under 2 jaw bursts      strong
//   Drowsy                getting drowsy or drowsy with eyes open                         some
// A mark is a run of epochs of one state, bridging one epoch that has no state, at least the rule's length. Marks
// never overlap. Not live: it needs the kept pass, which is made after the recording (DECISIONS 1102).
// Any electrode layout: the pass picks its sites by name (DECISIONS 633); without a pass (other sites, or the raw
// signal left the phone) the states that need none are still marked: asleep and walking.
// Plain Dart: no Flutter, no files.
import '../archive/seen.dart';
import '../detectors/detectors.dart' show epochS;
import '../walking/detector.dart' show StretchKind;
import '../walking/pass.dart' show WalkResult, WalkSummary;

/// How sure a guess is, in the research's words.
enum Sure {
  nearCertain('near certain'),
  strong('strong'),
  good('good'),
  some('some'),
  weak('weak');

  const Sure(this.word);
  final String word;
}

/// What a moment can be, in the order they are tried.
enum What {
  noSignal('No signal', 'no_signal'),
  asleep('Asleep', 'asleep'),
  nap('Nap', 'nap'),
  running('Running', 'running'),
  walking('Walking', 'walking'),
  moving('Moving', 'moving'),
  talking('Talking or chewing', 'talking_or_chewing'),
  resting('Eyes closed, resting', 'eyes_closed_resting'),
  drowsy('Drowsy', 'drowsy');

  const What(this.word, this.wire);

  /// The word on the lane, and the word the files hold.
  final String word, wire;

  static What? of(Object? wire) => values.where((w) => w.wire == wire).firstOrNull;
}

/// The planning values (set on no labelled day of the owner's yet).
abstract final class HappenedRule {
  /// The shortest mark, in 30 s epochs.
  static const int minDefault = 2, minNoSignal = 1, minMoving = 1;

  /// "Eyes closed, resting" needs 3 minutes (the research: "eyes closed and still for 3 minutes").
  static const int minResting = 6;

  /// One epoch without a state inside a run is bridged.
  static const int joinEpochs = 1;

  /// A sleep under this long that began by day is a nap (the questions' own rule, confirm/sources.dart).
  static const double napUnderMin = 180;
  static const int dayFromHour = 9, dayToHour = 20;

  static int minOf(What w) => switch (w) {
    What.noSignal => minNoSignal,
    What.moving => minMoving,
    What.resting => minResting,
    _ => minDefault,
  };
}

/// A sleep of [minutes] that began at [start] is a nap, not a night.
bool isDayNap(DateTime start, double minutes) =>
    minutes < HappenedRule.napUnderMin && start.hour >= HappenedRule.dayFromHour && start.hour < HappenedRule.dayToHour;

/// One guess: what, from when to when, how sure, and where it comes from in one sentence.
class Mark {
  const Mark(this.what, this.start, this.end, this.sure, this.source);
  final What what;
  final DateTime start, end;
  final Sure sure;
  final String source;

  Duration get length => end.difference(start);

  @override
  String toString() => 'Mark(${what.wire} $start-$end ${sure.word})';
}

const Map<What, (Sure, String)> _said = {
  What.noSignal: (Sure.nearCertain, 'No usable electrode, or no data: the headband away, off or loose.'),
  What.asleep: (Sure.good, 'The sleep report scored these minutes as sleep. The stages inside are a first guess.'),
  What.nap: (Sure.good, 'The sleep report scored these minutes as sleep, by day and under 3 hours.'),
  What.moving: (Sure.good, 'Three or more electrodes jumping at once.'),
  What.talking: (
    Sure.weak,
    'Jaw muscle on both sides in most of these minutes. The muscle is clear; talking and chewing are not told apart.',
  ),
  What.resting: (
    Sure.strong,
    'Back alpha 2 to 3 times this recording\'s eyes-open level, no blinks, no movement. About 1 person in 10 shows '
        'little of this rise.',
  ),
  What.drowsy: (
    Sure.some,
    'More back alpha and stiller eyes than this recording\'s first minutes, eyes open (the work session\'s rule).',
  ),
};

/// The marks of a recording from [from] to [to] (see the top of the file). [stages]: a sleep report's stages, one
/// character per 30 s from its start (`W 1 2 3 R -`).
List<Mark> happenedMarks({
  RecordingSeen? seen,
  ({DateTime start, String stages})? stages,
  WalkResult? walk,
  required DateTime from,
  required DateTime to,
}) {
  final grid = seen?.start ?? from;
  final n = seen?.epochs ?? (to.difference(from).inSeconds / epochS).ceil();
  if (n <= 0) return const [];
  DateTime at(int i) => grid.add(Duration(seconds: i * epochS));

  // asleep, by the report: the epoch's middle falls on a sleep stage
  // a nap: begun by day, and from the report's first to its last sleep under 3 hours (the time awake before and after
  // it in the recording does not make a nap a night)
  var nap = false;
  if (stages != null) {
    final sleep = RegExp('[123R]');
    final first = stages.stages.indexOf(sleep), last = stages.stages.lastIndexOf(sleep);
    nap = first >= 0 && isDayNap(stages.start.add(Duration(seconds: first * epochS)), (last - first + 1) * epochS / 60);
  }
  bool asleepAt(int i) {
    if (stages == null) return false;
    final k = at(i).add(const Duration(seconds: epochS ~/ 2)).difference(stages.start).inSeconds;
    if (k < 0) return false;
    final e = k ~/ epochS;
    return e < stages.stages.length && const {'1', '2', '3', 'R'}.contains(stages.stages[e]);
  }

  // walking, by its pass: a stretch covers half the epoch or more
  final steps = [
    for (final w in walk?.walks ?? const <WalkSummary>[])
      for (final s in w.stretches)
        if (s.kind != StretchKind.stopped) s,
  ];
  (What, bool)? walkAt(int i) {
    final a = at(i), b = at(i + 1);
    for (final s in steps) {
      final lo = s.start.isAfter(a) ? s.start : a, hi = s.end.isBefore(b) ? s.end : b;
      if (hi.difference(lo).inSeconds * 2 >= epochS) {
        return (s.kind == StretchKind.running ? What.running : What.walking, s.confidence == 'unsure');
      }
    }
    return null;
  }

  final state = List<What?>.filled(n, null);
  final unsure = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    if (seen != null && seen.quality[i] == 'm') {
      state[i] = What.noSignal;
    } else if (asleepAt(i)) {
      state[i] = nap ? What.nap : What.asleep;
    } else if (walkAt(i) case final w?) {
      state[i] = w.$1;
      unsure[i] = w.$2;
    } else if (seen == null) {
      continue;
    } else if (seen.move[i] >= ActivityRule.movingS) {
      state[i] = What.moving;
    } else if (seen.jaw[i] >= ActivityRule.talkingJaw) {
      state[i] = What.talking;
    } else if (seen.eyes[i] == 'c' && seen.move[i] == 0) {
      state[i] = What.resting;
    } else if (seen.eyes[i] != 'c' && (seen.level[i] == 'g' || seen.level[i] == 'd')) {
      state[i] = What.drowsy;
    }
  }

  // runs of one state, bridging epochs that have no state
  final out = <Mark>[];
  void close(What w, int a, int b) {
    if (b - a + 1 < HappenedRule.minOf(w)) return;
    final s = at(a).isBefore(from) ? from : at(a), e = at(b + 1).isAfter(to) ? to : at(b + 1);
    if (!e.isAfter(s)) return;
    if (w == What.walking || w == What.running) {
      final weak = [for (var i = a; i <= b; i++) if (unsure[i]) i].length * 2 > b - a + 1;
      out.add(Mark(w, s, e, weak ? Sure.some : Sure.good, 'The step rhythm in the headband\'s signal${weak ? ', not a clear one' : ''}.'));
    } else {
      final (sure, source) = _said[w]!;
      out.add(Mark(w, s, e, sure, source));
    }
  }

  What? run;
  var first = 0, last = 0;
  for (var i = 0; i < n; i++) {
    final w = state[i];
    if (w == null) continue;
    if (run == w && i - last - 1 <= HappenedRule.joinEpochs && !_between(state, last, i)) {
      last = i;
      continue;
    }
    if (run != null) close(run, first, last);
    run = w;
    first = i;
    last = i;
  }
  if (run != null) close(run, first, last);
  return out;
}

/// Another state lies between epochs [a] and [b] (then the run is not bridged over it).
bool _between(List<What?> state, int a, int b) {
  for (var i = a + 1; i < b; i++) {
    if (state[i] != null) return true;
  }
  return false;
}

/// The numbers behind [m] that the pass holds, for the guesses table (DECISIONS 1113): the share of its epochs with
/// eyes closed and with a good signal, jaw bursts and movement seconds a minute, and the mean back alpha against the
/// recording's eyes-open level when the pass kept it (`back_alpha`; null: not known).
Map<String, double?> markNumbers(Mark m, RecordingSeen seen) {
  final a = (m.start.difference(seen.start).inSeconds / epochS).round().clamp(0, seen.epochs);
  final b = (m.end.difference(seen.start).inSeconds / epochS).round().clamp(a, seen.epochs);
  final n = b - a;
  if (n <= 0) return const {};
  var closed = 0, good = 0, jaw = 0, move = 0, alphaN = 0;
  var alpha = 0.0;
  final kept = seen.alpha;
  for (var i = a; i < b; i++) {
    if (seen.eyes[i] == 'c') closed++;
    if (seen.quality[i] == 'g') good++;
    jaw += seen.jaw[i];
    move += seen.move[i];
    final v = kept != null && i < kept.length ? kept[i] : null;
    if (v != null) {
      alpha += v;
      alphaN++;
    }
  }
  final minutes = n * epochS / 60;
  return {
    'eyes_closed_share': closed / n,
    'good_signal_share': good / n,
    'jaw_bursts_per_min': jaw / minutes,
    'movement_s_per_min': move / minutes,
    'back_alpha': alphaN == 0 ? null : alpha / alphaN,
  };
}
