// The Archive's "Not sleep" for a recording from before Record first (DECISIONS 889): one `reviewed` line in a spans
// file of its own says which file sets are no sleep. They then join no night; a night left without any recording
// loses its place in the lists, and its report is moved to `nights/not-sleep/`, never deleted. Taking it back writes
// a second line and moves the report home.
import 'dart:io';

import '../recorder/nights.dart';
import 'span.dart';
import 'span_log.dart';

/// Whether [recording] (an old recording's id, its first set's stem) is marked "Not sleep".
bool isNotSleep(Directory filesDir, String recording) =>
    readSpans(spansFileOf(Directory('${filesDir.path}/spans'), recording)).reviewed == 'no_sleep';

/// Marks the old recording [recording], whose file sets are [sets] (stems), as not sleep ([notSleep]) or as sleep
/// again. Returns the nights (evening dates) whose report was hidden or brought back.
List<String> setNotSleep(
  Directory filesDir,
  String recording,
  List<String> sets, {
  required bool notSleep,
  DateTime Function()? clock,
}) {
  final recordings = Directory('${filesDir.path}/recordings');
  final spansDir = Directory('${filesDir.path}/spans');
  final log = SpanLog(spansDir, clock: clock);
  final nights = Directory('${filesDir.path}/nights');
  final hidden = Directory('${nights.path}/not-sleep');
  if (!notSleep) {
    final back = readSpans(log.fileOf(recording)).hides;
    log.reviewed(recording, sleep: true);
    forgetNightSets();
    for (final n in back) {
      final f = File('${hidden.path}/$n.report.json');
      final home = File('${nights.path}/$n.report.json');
      if (f.existsSync() && !home.existsSync()) f.renameSync(home.path);
    }
    return back;
  }
  bool mine(NightFiles n) => n.files.any((f) => sets.any((s) => f.uri.pathSegments.last.startsWith('$s.')));
  final before = [for (final n in nightsIn(recordings, spansDir: spansDir)) if (mine(n)) n.name];
  log.reviewed(recording, sleep: false, sets: sets, hides: before);
  forgetNightSets();
  final left = {for (final n in nightsIn(recordings, spansDir: spansDir)) n.name};
  final gone = [for (final n in before) if (!left.contains(n)) n];
  for (final n in gone) {
    final f = File('${nights.path}/$n.report.json');
    if (!f.existsSync()) continue;
    hidden.createSync(recursive: true);
    f.renameSync('${hidden.path}/$n.report.json');
  }
  return gone;
}
