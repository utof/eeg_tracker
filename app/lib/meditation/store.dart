// Meditation sessions on the phone: `files/meditations/` next to `files/recordings/`, inside the app's private
// folder (DECISIONS rows 53, 57 and 74: other apps cannot read it, no backup takes it). Per session:
//   <stamp>.meditation.json  the small summary the report and the comparison read
//   <stamp>.session.json     the whole session log (control stream and every input sample), replayable by
//                            the Dart core and by the laptop page's core (same format)
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../feedback/session_log.dart';
import '../recorder/chunk_writer.dart' show fileStem;
import 'tracker.dart';

/// The meditations folder for the app's recordings folder.
Directory meditationsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/meditations');

class MeditationStore {
  MeditationStore(this.dir);
  final Directory dir;

  /// The stem a session started at [start] gets.
  String stemFor(DateTime start) => fileStem(start);

  /// Writes the session log, then the summary (the summary last, so a listed summary always has its log).
  /// The log is encoded off the screen's thread: 20 minutes are about 8 MB of JSON.
  Future<void> save(MeditationSummary summary, SessionLog log) async {
    dir.createSync(recursive: true);
    final logPath = '${dir.path}/${summary.logFile}';
    final summaryPath = '${dir.path}/${stemFor(summary.start)}.meditation.json';
    final json = log.toJson();
    await Isolate.run(() => File(logPath).writeAsStringSync(jsonEncode(json), flush: true));
    File(summaryPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary.toJson()), flush: true);
  }

  /// Every readable summary, newest first. Damaged or foreign files are skipped.
  List<MeditationSummary> list() {
    if (!dir.existsSync()) return const [];
    final out = <MeditationSummary>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.meditation.json')) continue;
      try {
        final s = MeditationSummary.fromJson(jsonDecode(f.readAsStringSync()));
        if (s != null) out.add(s);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return out..sort((a, b) => b.start.compareTo(a.start));
  }
}
