// The log of automatic recording (DECISIONS 606): every check, guess, question, answer and outcome, one JSON line
// each in files/auto-start/log.jsonl, so a personal model can learn from your answers later (phase 3) and the
// settings page can say how often the guess was right. Lines (all with `version`, `at` local time with its offset,
// `event`):
//   check     trigger, near, worn, how (resistance / signal), ohms, battery, guess, reasons, choice, phone context
//   skipped   why (busy, quiet after Not now, asked this wearing, every kind off, ...)
//   question  kind, text
//   answer    kind, answer (yes / no / none; for "other": night / work / no / none), after_s
//   start     kind, how (automatic / yes), preroll_s, stem, limit_min, error
//   declined  kind, why (the battery guard)
//   offer, offer_answer   the "start it automatically?" offer after 10 yes in a row
//   released  the headband was let go for a start by hand
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;
import 'store.dart';

class AutoLog {
  AutoLog(this.dir);
  final Directory dir;

  File get _file => File('${dir.path}/log.jsonl');

  /// Never throws: a line that cannot be written (storage full) is lost, the watch goes on.
  void add(DateTime at, String event, [Map<String, Object?> fields = const {}]) {
    try {
      dir.createSync(recursive: true);
      _file.writeAsStringSync(
        '${jsonEncode({'version': 1, 'at': isoLocal(at), 'event': event, ...fields})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// Every line this version wrote, oldest first; a cut or foreign line is skipped.
  List<Map<String, Object?>> events() {
    if (!_file.existsSync()) return const [];
    final out = <Map<String, Object?>>[];
    for (final line in const LineSplitter().convert(_file.readAsStringSync())) {
      if (line.trim().isEmpty) continue;
      try {
        final j = jsonDecode(line);
        if (j is Map<String, Object?> && j['version'] == 1 && j['event'] is String && j['at'] is String) out.add(j);
      } on FormatException {
        // cut off by a crash: skipped
      }
    }
    return out;
  }

  Map<WearKind, KindStats> stats() {
    final s = {for (final k in WearKind.values) k: KindStats(k)};
    for (final e in events()) {
      final k = WearKind.fromWire(e['kind']);
      if (k == null) continue;
      final st = s[k]!;
      if (e['event'] == 'answer') {
        st.asked++;
        switch (e['answer']) {
          case 'yes':
            st.yes++;
          case 'no':
            st.no++;
          case 'night' || 'work':
            st.relabelled++;
          default:
            st.unanswered++;
        }
      } else if (e['event'] == 'start' && e['how'] == 'automatic') {
        st.automatic++;
      }
    }
    return s;
  }
}

/// How the questions about one kind went.
class KindStats {
  KindStats(this.kind);
  final WearKind kind;
  int asked = 0, yes = 0, no = 0, unanswered = 0, automatic = 0;

  /// "Other" answered with night or work: the guess was something else.
  int relabelled = 0;

  int get answered => yes + no + relabelled;

  String get rightText => kind == WearKind.other
      ? '$relabelled of $answered answered: something else'
      : '$yes of ${yes + no} answered: right';
}
