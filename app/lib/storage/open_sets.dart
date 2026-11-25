// The file sets being written, for the housekeeping that runs beside a recording (DECISIONS 1039): packing and
// clearing never touch them, whatever their age and acks say.
//
// A recording's newest file set is the one it writes: a new set (after a drop, a restart or a roll-over) is named by
// the moment it opens, later than every set before it. While the headband is away the newest set is closed and none
// is open; it is held all the same. Read from the headers on the phone, so the screen needs nothing from the recorder
// but the id of the recording that runs. Plain dart:io.
import 'dart:io';

import '../recorder/acks.dart' show movableFolders;
import '../recorder/header.dart' show tryHeader;
import '../recorder/nights.dart' show stemTime;

/// The plain `.f32` paths of the newest file set of [recording] in each of the app's recording folders; empty when
/// [recording] is null (nothing records) or names no set.
Set<String> openSets(Directory filesDir, String? recording) {
  if (recording == null) return const {};
  final out = <String>{};
  for (final folder in movableFolders) {
    final dir = Directory('${filesDir.path}/$folder');
    if (!dir.existsSync()) continue;
    final stems = <String>{};
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        // a set is never older than its recording, whose id is its first set's name
        if (stemTime(name) != null && name.substring(0, 17).compareTo(recording) >= 0) stems.add(name.substring(0, 17));
      }
    } on FileSystemException {
      continue;
    }
    for (final stem in stems.toList()..sort((a, b) => b.compareTo(a))) {
      final f32 = File('${dir.path}/$stem.f32');
      if ((stem == recording ? recording : tryHeader(f32)?.recording) == recording) {
        out.add(f32.path);
        break;
      }
    }
  }
  return out;
}
