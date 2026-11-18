// Sleep periods from the stages, the rules of scripts/sleep_report.py `periods` (DECISIONS row 82): asleep epochs
// (N1 N2 N3 R) belong to one period unless 60+ minutes of other epochs (wake or missing data) separate them; a
// stretch with under 10 minutes asleep is scorer noise and only counts as stray sleep; a wake-up is a stretch
// between asleep epochs with over 5 minutes scored awake.
const List<String> stageNames = ['W', 'N1', 'N2', 'N3', 'R'];
const Set<String> asleepStages = {'N1', 'N2', 'N3', 'R'};
const String gapStage = 'gap';
const double epochMinutes = 0.5;

const double splitMin = 60;
const double minPeriodSleepMin = 10;
const double wakeUpOverMin = 5;

class WakeUp {
  const WakeUp(this.epoch, this.awakeMin);
  final int epoch;
  final double awakeMin;
}

class SleepPeriod {
  const SleepPeriod({
    required this.first,
    required this.last,
    required this.asleepMin,
    required this.stageMin,
    required this.wakeUps,
    required this.missingMin,
    required this.confidence,
  });

  /// First and last asleep epoch (inclusive).
  final int first;
  final int last;
  final double asleepMin;

  /// Minutes of W N1 N2 N3 R between [first] and [last].
  final Map<String, double> stageMin;
  final List<WakeUp> wakeUps;
  final double missingMin;

  /// The model's mean top probability over the scored epochs of the period (null if none).
  final double? confidence;
}

/// The periods and the asleep minutes left out as too short to count.
({List<SleepPeriod> periods, double straySleepMin}) sleepPeriods(
  List<String> stages, {
  List<double>? confidence,
  double split = splitMin,
  double minSleep = minPeriodSleepMin,
  double wakeOver = wakeUpOverMin,
}) {
  final runs = <List<int>>[];
  for (var i = 0; i < stages.length; i++) {
    if (!asleepStages.contains(stages[i])) continue;
    if (runs.isNotEmpty && (i - runs.last.last - 1) * epochMinutes < split) {
      runs.last.add(i);
    } else {
      runs.add([i]);
    }
  }
  final out = <SleepPeriod>[];
  var stray = 0.0;
  for (final run in runs) {
    final asleep = run.length * epochMinutes;
    if (asleep < minSleep) {
      stray += asleep;
      continue;
    }
    final a = run.first, b = run.last;
    final span = stages.sublist(a, b + 1);
    final sure = [
      for (var i = a; i <= b; i++)
        if (confidence != null && stages[i] != gapStage && stageNames.contains(stages[i])) confidence[i],
    ];
    out.add(
      SleepPeriod(
        first: a,
        last: b,
        asleepMin: asleep,
        stageMin: {for (final s in stageNames) s: span.where((x) => x == s).length * epochMinutes},
        wakeUps: _wakeUps(stages, a, b, wakeOver),
        missingMin: span.where((x) => x == gapStage).length * epochMinutes,
        confidence: sure.isEmpty ? null : round3(sure.reduce((x, y) => x + y) / sure.length),
      ),
    );
  }
  return (periods: out, straySleepMin: stray);
}

List<WakeUp> _wakeUps(List<String> stages, int a, int b, double overMin) {
  final out = <WakeUp>[];
  var k = a;
  while (k <= b) {
    if (asleepStages.contains(stages[k])) {
      k++;
      continue;
    }
    var j = k;
    while (j <= b && !asleepStages.contains(stages[j])) {
      j++;
    }
    final awake = stages.sublist(k, j).where((s) => s == 'W').length * epochMinutes;
    if (awake > overMin) out.add(WakeUp(k, awake));
    k = j;
  }
  return out;
}

/// Python's round(x, 3) for the values met here.
double round3(double v) => (v * 1000).round() / 1000;
