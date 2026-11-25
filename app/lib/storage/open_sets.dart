// The file sets being written, for the housekeeping that runs beside a recording (DECISIONS 1039): packing and
// clearing never touch them, whatever their age and acks say.
//
// Of the file sets of the recording that runs, the one whose samples were written last is the one it writes: a new set
// (after a drop, a restart or a roll-over) is written after every set before it. By the files' own times and not by
// their names, which follow the phone's clock (a clock set back would name a new set before an old one). While the
// headband is away the newest set is closed and none is open; it is held all the same. Read from the headers on the
// phone, so the screen needs nothing from the recorder but the id of the recording that runs. Plain dart:io.
import 'dart:io';

import '../recorder/acks.dart' show movableFolders;
import '../recorder/header.dart' show tryHeader;
import '../recorder/nights.dart' show stemTime;

/// The plain `.f32` paths of the last-written file set of [recording] in each of the app's recording folders; empty
/// when [recording] is null (nothing records) or names no set with a plain `.f32` (a packed one is a day old: closed).
Set<String> openSets(Directory filesDir, String? recording) {
  if (recording == null) return const {};
  final out = <String>{};
  for (final folder in movableFolders) {
    final dir = Directory('${filesDir.path}/$folder');
    if (!dir.existsSync()) continue;
    final sets = <(DateTime, String)>[];
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.f32') && stemTime(name) != null) sets.add((f.statSync().modified, f.path));
      }
    } on FileSystemException {
      continue;
    }
    // newest first; of two written in the same instant, the later name
    sets.sort((a, b) {
      final c = b.$1.compareTo(a.$1);
      return c != 0 ? c : b.$2.compareTo(a.$2);
    });
    for (final (_, path) in sets) {
      final stem = path.substring(path.lastIndexOf('/') + 1, path.length - 4);
      if (stem == recording || tryHeader(File(path))?.recording == recording) {
        out.add(path);
        break;
      }
    }
  }
  return out;
}
