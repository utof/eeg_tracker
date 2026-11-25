// The Archive's "Not sleep" for a recording from before Record first (DECISIONS 889): one `reviewed` line in a spans
// file of its own says which file sets are no sleep. They then join no night; a night left without any recording
// loses its place in the lists, and its report is moved to `nights/not-sleep/`, never deleted. Taking it back writes
// a second line and moves the report home.
// A recording with an id (Record first) has its marked stretches instead: [setSpanRemoved] takes one away or puts it
// back (DECISIONS 1025).
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

/// Takes the marked stretch [span] of a stopped recording away ([removed] true: "Not sleep", "Remove this mark") or
/// puts it back (DECISIONS 1025). One more line of the same span, with `removed: true` or without it: its times are
/// kept, nothing is deleted. A night or nap left without any stretch loses its place in the lists, and its report is
/// put away as `nights/not-sleep/<span id>.report.json`; putting the stretch back brings that report home unless
/// another one was made there meanwhile. A night that keeps other stretches keeps its report file: it is out of date
/// by its spans and is scored again. Returns the reports (night names, `naps/<stamp>`) put away or brought home.
/// Throws [SpansBusy] for the recording that runs now ([active]: its id), FileSystemException when the phone is full.
List<String> setSpanRemoved(
  Directory filesDir,
  Span span, {
  required bool removed,
  String? Function()? active,
  DateTime Function()? clock,
}) {
  final recordings = Directory('${filesDir.path}/recordings');
  final spansDir = Directory('${filesDir.path}/spans');
  final log = SpanLog.screen(spansDir, active: active ?? () => null, clock: clock);
  final nights = Directory('${filesDir.path}/nights');
  final away = Directory('${nights.path}/not-sleep');
  List<NightFiles> all() {
    forgetNightSets();
    return [...nightsIn(recordings, spansDir: spansDir), ...napsIn(recordings, spansDir: spansDir)];
  }

  File home(String name) => File('${nights.path}/$name.report.json');
  File put([int n = 1]) => File('${away.path}/${span.id}${n == 1 ? '' : '-$n'}.report.json');
  if (!removed) {
    log.write(span.asRemoved(false));
    final back = <String>[];
    for (final n in all().where((n) => n.spanIds.contains(span.id))) {
      if (!put().existsSync() || home(n.name).existsSync()) continue;
      home(n.name).parent.createSync(recursive: true);
      put().renameSync(home(n.name).path);
      back.add(n.name);
    }
    return back;
  }
  final before = [for (final n in all()) if (n.spanIds.contains(span.id)) n.name];
  log.write(span.asRemoved(true));
  final left = {for (final n in all()) n.name};
  final gone = [for (final n in before) if (!left.contains(n)) n];
  for (final n in gone) {
    if (!home(n).existsSync()) continue;
    away.createSync(recursive: true);
    var k = 1;
    while (put(k).existsSync()) {
      k++; // an older one put away under this stretch's name is kept
    }
    home(n).renameSync(put(k).path);
  }
  return gone;
}
