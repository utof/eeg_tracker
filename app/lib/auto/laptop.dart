// The laptop's work signal for automatic recording (DECISIONS 603): the laptop tray (branch `feat/laptop-tray`,
// scripts/tray.py) knows from ActivityWatch when a work session starts and ends; the phone takes "working" from it
// rather than guessing from the brain. [laptopWorkSignal] keeps the latest word in files/auto-start/laptop.json and,
// when work starts, asks the watcher for a check. The tray sends it to the phone paired by its QR code when a session
// starts or ends (scripts/laptop_work.py `phone_work_signal`): Share on Wi-Fi's `POST /work`, with its token, taken by
// the app's own server between recordings (share/control.dart) and by the recorder's while it records
// (recorder/recorder_service.dart, DECISIONS 1107: the watcher then starts or offers the work session on the recording).
// The word may say whether the laptop's session is in a meeting (`meeting`, DECISIONS 666 and 685): the tray sends it
// at the session's start and end and whenever a meeting starts or ends inside it. A word that only changes the meeting
// asks for no check; the work session on the phone reads it ([laptopMeetingNow]) to label its meeting minutes.
import 'dart:convert';
import 'dart:io';

import '../phone.dart';
import '../sleep/report.dart' show isoLocal;
import 'channel.dart';
import 'log.dart';
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
      final working = j['working'], meeting = j['meeting'];
      if (at == null || working is! bool) return null;
      return LaptopWork(working: working, at: at, meeting: meeting is bool ? meeting : null);
    } catch (_) {
      return null; // none yet, or not ours
    }
  }

  void save(LaptopWork w) {
    dir.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp')
      ..writeAsStringSync(
        jsonEncode({'version': 1, 'working': w.working, 'at': isoLocal(w.at), 'meeting': ?w.meeting}),
        flush: true,
      );
    tmp.renameSync(_file.path);
  }
}

/// A laptop meeting word is believed this long at most (a tray that died mid-meeting never says it ended): the
/// tray's own limit for backdating a call (scripts/laptop_work.py `BACKDATE_MAX_H`).
const Duration laptopMeetingMax = Duration(hours: 3);

/// A word that only changes the meeting of a session the laptop already reported (working before and now, the word
/// says `meeting`, the one before is under 12 hours old) asks for no headband check.
bool asksForCheck(LaptopWork? before, LaptopWork word) {
  if (!word.working) return false;
  if (before == null || !before.working || word.meeting == null) return true;
  return word.at.difference(before.at) >= const Duration(hours: 12);
}

/// The laptop's latest word in this app process (null: none since the app started and none read from the file).
LaptopWork? lastLaptopWord;

/// The laptop says its work session is in a meeting now (the word under [laptopMeetingMax] old).
bool laptopMeetingNow([DateTime? now]) {
  final w = lastLaptopWord;
  if (w == null || !w.working || w.meeting != true) return false;
  final age = (now ?? DateTime.now()).difference(w.at);
  return !age.isNegative && age < laptopMeetingMax;
}

/// The kept word for [lastLaptopWord] when this process has none yet (the app was started during the meeting).
void seedLaptopWord(String recordingsDir) {
  if (lastLaptopWord != null) return;
  try {
    lastLaptopWord = LaptopStore(autoDirFor(recordingsDir)).load();
  } catch (_) {}
}

/// Keeps [word] as the latest in [autoDir] (`files/auto-start`) and writes it as one `laptop` line of the auto log
/// (every word, DECISIONS 1113); true when it asks for a headband check ([asksForCheck]).
bool keepLaptopWord(Directory autoDir, LaptopWork word) {
  final store = LaptopStore(autoDir);
  final before = store.load();
  store.save(word);
  AutoLog(autoDir).add(word.at, 'laptop', {'working': word.working, 'meeting': ?word.meeting});
  return asksForCheck(before, word);
}

/// The hook for the laptop: a work session started ([working] true) or ended, and whether it is in a meeting
/// ([meeting]; null: not said). Keeps it, and when work starts asks for a check (the watcher decides whether one
/// runs). Never throws.
Future<void> laptopWorkSignal({required bool working, bool? meeting, DateTime? at}) async {
  final word = LaptopWork(working: working, at: at ?? DateTime.now(), meeting: meeting);
  lastLaptopWord = word;
  try {
    final rec = await Phone.recordingsDir();
    if (rec == null) return;
    if (keepLaptopWord(autoDirFor(rec), word)) await AutoChannel.requestCheck('laptop');
  } catch (_) {}
}
