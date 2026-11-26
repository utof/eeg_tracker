// Where the estimates come from today (DECISIONS 865): the sleep report's periods (a night, a nap, and an awake
// recording the model scored as sleep), the walking pass's walks, and eyes closed and still by day (DECISIONS 1105). A new detector adds a function like these and one
// line in [collectEstimates], or calls `ConfirmQuestions.register` itself when it finishes; nothing here knows the
// electrode layout. No eating question: there is no eating detector yet, and "eating or talking?" has no one label a Yes
// could become.
import 'dart:io';

import 'package:shared_labels/shared_labels.dart';

import '../activity/guesses.dart' show restEstimates, usualNightOf;
import '../activity/happened.dart' show HappenedRule;
import '../sleep/report.dart';
import '../walking/detector.dart' show walkDetector;
import '../walking/pass.dart' show WalkResult, keptWalks;
import '../wearer/check.dart' show answerSomeoneElse;


abstract final class SourceRule {
  /// A sleep period with less sleep than this, or a walk with less walking, is not worth a question.
  static const double minAsleepMin = 10, minWalkingMin = 5;

  /// A period under this long that starts in the day is asked as a nap (one rule with the "What happened" lane's Nap).
  static const double napUnderMin = HappenedRule.napUnderMin;
  static const int dayFromHour = HappenedRule.dayFromHour, dayToHour = HappenedRule.dayToHour;

  /// A night with this much found awake inside: a Yes is `likely`, not `certain` (not every minute fits).
  static const double awakeInsideMin = 5;
}

/// The recording a report was made from: its first file's stamp (`2026-11-20-155900`), as the Archive names it.
String? recordingOf(SleepReport r) {
  final names = r.inputs.keys.toList()..sort();
  return names.isEmpty || names.first.length < 17 ? null : names.first.substring(0, 17);
}

/// One estimate per sleep period of a scored report. The confidence is the share of the period the model scored
/// asleep, so a broken-up period is asked about before a solid one.
List<Estimate> sleepEstimates(SleepReport r) {
  if (!r.scored || r.wearerAnswer == answerSomeoneElse) return const [];
  final model = r.json['model'];
  final built = DateTime.tryParse('${r.json['built']}');
  return [
    for (final p in r.periods)
      if (p.asleepMin >= SourceRule.minAsleepMin)
        () {
          final minutes = p.end.difference(p.start).inSeconds / 60;
          final nap =
              minutes < SourceRule.napUnderMin && p.start.hour >= SourceRule.dayFromHour && p.start.hour < SourceRule.dayToHour;
          return Estimate(
            detector: 'sleep-periods',
            version: model is String ? model : 'phone',
            label: nap ? Labels.nap : Labels.asleep,
            start: p.start,
            end: p.end,
            recording: recordingOf(r),
            confidence: minutes <= 0 ? null : (p.asleepMin / minutes).clamp(0.0, 1.0),
            yesMeans: !nap && p.awakeMin >= SourceRule.awakeInsideMin ? YesMeans.likely : YesMeans.certain,
            made: built,
          );
        }(),
  ];
}

const Map<String, double> _walkSure = {'sure': 0.9, 'likely': 0.7, 'unsure': 0.4};

/// One estimate per walk (stretches under 10 minutes apart) of a walking pass.
List<Estimate> walkEstimates(WalkResult w, {String? detector, DateTime? made}) => [
  for (final k in w.walks)
    if (k.walkingMin >= SourceRule.minWalkingMin)
      Estimate(
        detector: 'walking',
        version: detector ?? walkDetector,
        label: Labels.walking,
        start: k.start,
        end: k.end,
        recording: w.recording,
        confidence: _walkSure[_weakest(k.stretches.map((s) => s.confidence)) ?? w.confidence],
        made: made,
      ),
];

/// The least sure word among a walk's stretches.
String? _weakest(Iterable<String?> words) {
  for (final w in const ['unsure', 'likely', 'sure']) {
    if (words.contains(w)) return w;
  }
  return null;
}

/// Every estimate the phone's kept results hold now: the reports in `files/nights/` and the walk files.
List<Estimate> collectEstimates(Directory filesDir, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final out = <Estimate>[];
  for (final r in NightReportStore(Directory('${filesDir.path}/nights')).all()) {
    out.addAll(sleepEstimates(r));
  }
  for (final k in keptWalks(filesDir).values) {
    final w = k.walk;
    if (w != null) out.addAll(walkEstimates(w, detector: k.detector, made: at));
  }
  // eyes closed and still by day: "Meditating or resting?" (activity/guesses.dart; at most one a day)
  try {
    out.addAll(restEstimates(filesDir, usual: usualNightOf(filesDir, at), now: at));
  } on FileSystemException {
    // none this time
  }
  return out;
}
