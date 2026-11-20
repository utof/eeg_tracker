// The phone's own step counter in the night's `.log` (DECISIONS 800-809): once a minute while recording, so a later
// pass can put the headband's walking estimate next to the phone's steps per minute. Optional, off by default.
// The lines (after the time the ChunkWriter puts in front):
//   phone step counter: on | off | no permission | no sensor     once per run (file set), when it is set up
//   phone steps 12345                                            once per clock minute while on: steps since boot
// The switch is the file `files/steps/settings.json` ({"on": true|false, "changed": ...}); the recorder's engine
// reads it when a run starts. Missing or damaged means off.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The phone's hardware step counter (Android TYPE_STEP_COUNTER). A separate small interface, so a probe without
/// steps (and every test fake of the phone) stays as it is.
abstract class StepProbe {
  /// Sets the counter up and says how it went: `on`, `off` (the switch), `no permission` or `no sensor`.
  Future<String> start();

  /// Steps since the phone booted as of the last sensor event, or null while none has arrived.
  Future<int?> read();

  /// Lets the sensor go.
  Future<void> stop();
}

/// The folder of the switch, beside the recordings folder.
Directory stepsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/steps');

/// The switch on disk.
class StepSettings {
  StepSettings(this.dir);
  final Directory dir;

  File get _file => File('${dir.path}/settings.json');

  /// Off unless switched on; never throws.
  bool get on {
    try {
      final j = jsonDecode(_file.readAsStringSync());
      return j is Map && j['on'] == true;
    } catch (_) {
      return false;
    }
  }

  void setOn(bool on, DateTime now) {
    dir.createSync(recursive: true);
    // a temporary file, then a rename: a reader never sees half of it, an export skips *.tmp
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({'on': on, 'changed': now.toIso8601String()}), flush: true);
    tmp.renameSync(_file.path);
  }
}

/// Writes the two lines for one recording's log (through `ChunkWriter.log`, which puts the time in front). A probe that fails or is slow costs the lines, never the recording.
class StepLog {
  StepLog(this.probe, this._now);
  final StepProbe probe;
  final DateTime Function() _now;

  static const Duration _wait = Duration(seconds: 5);

  bool _on = false;

  /// The clock minute (minutes since the epoch) of the last steps line; null: none yet in this run.
  int? _minute;

  /// Once per run: sets the counter up and writes how it went.
  Future<void> setup(void Function(String message) log) async {
    _minute = null;
    var state = 'no sensor';
    try {
      state = await probe.start().timeout(_wait);
    } catch (_) {}
    _on = state == 'on';
    log('phone step counter: $state');
  }

  /// At every 10-second check: the first one in a new clock minute writes the reading, if the sensor has given one.
  Future<void> tick(void Function(String message) log) async {
    if (!_on) return;
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute == _minute) return;
    try {
      final n = await probe.read().timeout(_wait);
      if (n == null) return;
      _minute = minute;
      log('phone steps $n');
    } catch (_) {}
  }

  /// Best effort.
  Future<void> stop() async {
    _on = false;
    try {
      await probe.stop().timeout(_wait);
    } catch (_) {}
  }
}
