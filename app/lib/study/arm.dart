// Handing the phone every reminder ahead, the sharp-hours questions and the study reminders together: the phone
// keeps ONE list and one alarm chain (SharpPrompts.kt), so whoever arms must give it everything (DECISIONS row 401).
import '../sharp/hours.dart' show sharpDayNumbers;
import '../sharp/prompts.dart';
import '../sharp/schedule.dart';
import '../sharp/store.dart';
import '../sleep/report.dart';
import '../wearer/wearer.dart' show ownNightReports;
import 'page.dart';
import 'schedule.dart';
import 'store.dart';

/// Every moment ahead of [now] from the saved settings, oldest first: none when both are off or never set up.
List<PlannedPrompt> plannedPrompts({
  required DateTime now,
  SharpSettings? sharp,
  StudySettings? study,
  List<SleepReport> reports = const [],
  List<StudyAnswer> answers = const [],
}) => [
  if (sharp != null) ...upcomingPrompts(now, sharp),
  if (study != null) ...upcomingStudy(now, study, timesFor(study, sharp, reports, now), answers),
]..sort((a, b) => a.at.compareTo(b.at));

/// Reads the app's folders (beside [recordingsDir]) and hands the phone the moments ahead. Called at every app
/// start and return (the night screen), and after each change on the sharp-hours and study pages.
Future<void> rearmPrompts(String recordingsDir, SharpPhone phone, DateTime now) async {
  final sharp = SharpStore(sharpDirFor(recordingsDir)).settings();
  final store = StudyStore(studyDirFor(recordingsDir));
  final study = store.settings();
  final on = study?.on == true;
  await phone.arm(
    plannedPrompts(
      now: now,
      sharp: sharp,
      study: study,
      // the nights the owner wore ("Was this you?", DECISIONS 377), as Sharp hours reads them
      reports: on ? ownNightReports(recordingsDir) : const [],
      answers: on ? store.answers() : const [],
    ),
  );
}

/// The day numbers the Trends page and the self-experiments read from the app's own logs (sharp hours, study),
/// by measure id.
Map<String, Map<String, double>> readOwnDayNumbers(String recordingsDir) => {
  ...sharpDayNumbers(
    SharpStore(sharpDirFor(recordingsDir)).ratings(),
    SharpStore(sharpDirFor(recordingsDir)).reactions(),
  ),
  ...studyDayNumbers(StudyStore(studyDirFor(recordingsDir)).answers()),
};
