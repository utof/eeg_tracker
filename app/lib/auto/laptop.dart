// The laptop's work signal for automatic recording (DECISIONS 603): the laptop tray (branch `feat/laptop-tray`,
// scripts/tray.py) knows from ActivityWatch when a work session starts and ends; the phone takes "working" from it
// rather than guessing from the brain. Phase 1 has only the phone's side: [laptopWorkSignal] keeps the latest word in
// files/auto-start/laptop.json and, when work starts, asks the watcher for a check. Share on Wi-Fi or the QR pairing
// call it once the laptop sends the signal; nothing calls it yet.
import 'dart:convert';
import 'dart:io';

import '../phone.dart';
import '../sleep/report.dart' show isoLocal;
import 'channel.dart';
import 'rules.dart';
import 'store.dart';

class LaptopStore {
  LaptopStore(this.dir);

  /// The `files/auto-start` folder.
  final Directory dir;

  File get _file => File('${dir.path}/laptop.json');

  LaptopWork? load() {
    try {
      final Object? j = jsonDecode(_file.readAsStringSync());
      if (j is! Map) return null;
      final at = j['at'] is String ? DateTime.tryParse(j['at'] as String)?.toLocal() : null;
      final working = j['working'];
      if (at == null || working is! bool) return null;
      return LaptopWork(working: working, at: at);
    } catch (_) {
      return null; // none yet, or not ours
    }
  }

  void save(LaptopWork w) {
    dir.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp')
      ..writeAsStringSync(jsonEncode({'version': 1, 'working': w.working, 'at': isoLocal(w.at)}), flush: true);
    tmp.renameSync(_file.path);
  }
}

/// The hook for the laptop: a work session started ([working] true) or ended. Keeps it, and on a start asks for a
/// check (the watcher decides whether one runs). Never throws.
Future<void> laptopWorkSignal({required bool working, DateTime? at}) async {
  try {
    final rec = await Phone.recordingsDir();
    if (rec == null) return;
    LaptopStore(autoDirFor(rec)).save(LaptopWork(working: working, at: at ?? DateTime.now()));
    if (working) await AutoChannel.requestCheck('laptop');
  } catch (_) {}
}
