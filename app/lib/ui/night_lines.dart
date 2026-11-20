// The night screen's lines from the other features' files, worked out at every app start and return (DECISIONS
// 620-629). Each comes from the newest file of its kind, found by its name (the app names files by their start), and a
// file is read again only when its size or time changed: the screen used to read every nap, dream catcher session,
// check-in and lucid night on its own thread to show one line each.
import '../dream/store.dart';
import '../morning/store.dart';
import '../nap/store.dart';
import '../recorder/nights.dart' show nightLabel;
import 'dream_view.dart' show clock;
import 'lucid_screen.dart' show lucidNightLine;
import 'memory_cues_screen.dart' show memoryNightLine;
import 'morning_screen.dart' show checkedInTodayIn;
import 'nap_view.dart' show endWords;

/// The lines, null where there is nothing to say.
typedef NightLines = ({String? dream, String? nap, String? checkedInAt, String? lucid, String? memory});

/// Every line for the recordings folder [recordingsDir] at [now].
NightLines nightLines(String recordingsDir, DateTime now) => (
  dream: lastDreamLine(recordingsDir, now),
  nap: lastNapLine(recordingsDir, now),
  checkedInAt: checkedInTodayIn(MorningStore(morningsDirFor(recordingsDir)), now),
  lucid: lucidNightLine(recordingsDir, now: now),
  memory: memoryNightLine(recordingsDir, now: now),
);

/// The nap coach's newest nap in a line, when it is under a day old.
String? lastNapLine(String recordingsDir, DateTime now) {
  try {
    final s = NapStore(napDirFor(recordingsDir)).newest();
    if (s == null || now.difference(s.start) > const Duration(hours: 24)) return null;
    return 'Last nap: ${nightLabel(s.start)} ${clock(s.start)}, ${s.lengthMin} min, ${endWords(s)}.';
  } catch (_) {
    return null; // a line of text is never worth breaking the night screen
  }
}

/// The dream catcher's newest session in a line, when it is under a day old.
String? lastDreamLine(String recordingsDir, DateTime now) {
  try {
    final s = DreamStore(dreamDirFor(recordingsDir)).newest();
    if (s == null || now.difference(s.start) > const Duration(hours: 24)) return null;
    final n = s.answers;
    return 'Last session: ${n == 1 ? '1 answer' : '$n answers'}, ${nightLabel(s.start)} ${clock(s.start)}.';
  } catch (_) {
    return null;
  }
}
