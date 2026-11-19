// The smart alarm's wake sound as a file for the phone's ringer (WakeService.kt plays it on the alarm stream): the
// nap coach's three rising notes (alpha-theta's wake tone), made in the app like every other sound, written once to
// `files/alarm/wake-notes.wav`. Without the file the ringer goes straight to the phone's own alarm sound.
import 'dart:io';
import 'dart:isolate';

import '../sound/alpha_theta_sound.dart' show wakeTone;
import '../sound/synth.dart' show wav16;

/// The notes file for the app's recordings folder.
File wakeNotesFor(String recordingsDir) => File('${Directory(recordingsDir).parent.path}/alarm/wake-notes.wav');

/// Writes the notes unless they are there already (made in a background isolate: about 0.1 s of work).
Future<File> writeWakeNotes(String recordingsDir) async {
  final f = wakeNotesFor(recordingsDir);
  if (f.existsSync() && f.lengthSync() > 44) return f;
  final bytes = await Isolate.run(() => wav16([wakeTone()]));
  f.parent.createSync(recursive: true);
  final tmp = File('${f.path}.tmp')..writeAsBytesSync(bytes, flush: true);
  tmp.renameSync(f.path);
  return f;
}
