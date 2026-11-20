// The Archive page's data in one background-isolate call (DECISIONS 700-709): the list, what each recording's kept
// detectors' pass found (only when it was made from the raw files as they are now), and the recordings still to pass
// over, newest first; and the recordings still to get the pulse pass (pulse/pass.dart, DECISIONS 815), any layout.
// Plain Dart.
import 'dart:io';
import 'dart:isolate';

import '../pulse/detector.dart' show pulseDetector;
import '../pulse/pass.dart' show keptPulses, pulseKeyOf, whyNoPulse;
import 'items.dart';
import 'seen.dart';

class ArchivePage {
  const ArchivePage(this.list, {this.found = const {}, this.why = const {}, this.toSee = const [], this.toPulse = const []});
  final ArchiveList list;

  /// Minutes per activity of each recording's current pass, by id.
  final Map<String, Map<String, double>> found;

  /// Why a recording gets no pass (its layout, its rate), by id.
  final Map<String, String> why;

  /// Recordings with raw signal and no current pass, newest first.
  final List<String> toSee;

  /// Recordings with raw signal and no current pulse pass, newest first (after [toSee]).
  final List<String> toPulse;
}

ArchivePage loadArchivePage(Directory filesDir) {
  final list = listArchive(filesDir);
  final kept = keptPasses(filesDir);
  final pulses = keptPulses(filesDir);
  final found = <String, Map<String, double>>{}, why = <String, String>{}, toSee = <String>[], toPulse = <String>[];
  for (final i in list.items) {
    final raw = i.rawFiles(filesDir);
    if (raw.isEmpty) continue;
    final p = pulses[i.id];
    if ((p == null || p.detector != pulseDetector || p.key != pulseKeyOf(raw)) && whyNoPulse(raw) == null) toPulse.add(i.id);
    final k = kept[i.id];
    if (k == null || k.key != seenKeyOf(raw)) {
      final no = whyNotSeen(raw);
      if (no != null) {
        why[i.id] = no;
      } else {
        toSee.add(i.id);
      }
      continue;
    }
    if (k.minutes != null) found[i.id] = k.minutes!;
    if (k.why != null) why[i.id] = k.why!;
  }
  return ArchivePage(list, found: found, why: why, toSee: toSee, toPulse: toPulse);
}

/// [loadArchivePage] in a background isolate (a top-level function: only the path crosses).
Future<ArchivePage> loadArchiveInBackground(String filesPath) =>
    Isolate.run(() => loadArchivePage(Directory(filesPath)), debugName: 'archive-list');
