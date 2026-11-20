// Every start of the app, with why Android ended the process before it (DECISIONS 730-739): the "black box" of the
// 2026-11-20 research. Android keeps the last exits of an app (ApplicationExitInfo, Android 11+: crash, ANR, low
// memory, frozen and killed, user stop, update); the night recorder already writes them into a night's `.log` when it
// resumes a night, and now every engine that starts (the screen's, the recorder's service, the headband watcher)
// writes them into `files/app-starts.log` too, so a Share on Wi-Fi hang or a death in the day leaves evidence on the
// phone with no adb: Export data and Share on Wi-Fi take the file with the rest of `files/`.
//
// Small and rotating: past 256 KB the file becomes `app-starts.1.log` (one older file kept, the one before it
// dropped). Only exits newer than the last start written are added; a second engine of the same process adds only its
// start line. Never throws: a line that cannot be written is lost, and never costs a start.
import 'dart:convert';
import 'dart:io' as io;
import 'dart:io' show Directory, File, FileMode, FileSystemException;

import 'package:flutter/foundation.dart' show debugPrint;

import 'phone.dart';
import 'recorder/chunk_writer.dart' show logTime;

const String startLogName = 'app-starts.log';
const String startLogOlderName = 'app-starts.1.log';

/// Past this size the log moves to [startLogOlderName] before the next line.
const int startLogMaxBytes = 256 * 1024;

/// What the log remembers between starts: `files/cache/app-starts.json` (never exported).
const String _stateName = 'cache/app-starts.json';

/// Writes this start of [engine] (`screen`, `recorder`, `watcher`) and the exits Android recorded since the last
/// start written into `<filesDir>/app-starts.log`; returns the lines written. [exitReasons] is the phone's
/// (`Phone.exitReasons`): one line per exit newer than its argument (unix ms).
Future<List<String>> logStart(
  String filesDir, {
  required String engine,
  required Future<List<String>> Function(int sinceMs) exitReasons,
  DateTime Function()? clock,
  int? processId,
}) async {
  final now = (clock ?? DateTime.now)();
  final me = processId ?? io.pid;
  final state = File('$filesDir/$_stateName');
  var lastMs = 0;
  int? lastPid;
  try {
    final j = jsonDecode(state.readAsStringSync());
    if (j is Map && j['last_ms'] is int && j['pid'] is int) {
      lastMs = j['last_ms'] as int;
      lastPid = j['pid'] as int;
    }
  } on FileSystemException {
    // the first start (or a damaged file): every exit Android still has
  } on FormatException {
    // the same
  }
  final newProcess = lastPid != me;
  final lines = <String>['start: $engine engine, process $me${newProcess ? '' : ' (already running)'}'];
  if (newProcess) {
    List<String> exits;
    try {
      exits = await exitReasons(lastMs);
    } catch (e) {
      exits = const [];
      lines.add('previous process ended: not readable ($e)');
    }
    if (exits.isEmpty && lines.length == 1) lines.add('previous process ended: no record from Android since the last start');
    for (final e in exits) {
      lines.add('previous process ended: $e');
    }
  }
  try {
    Directory(filesDir).createSync(recursive: true);
    final log = File('$filesDir/$startLogName');
    if (log.existsSync() && log.lengthSync() > startLogMaxBytes) log.renameSync('$filesDir/$startLogOlderName');
    log.writeAsStringSync(
      [for (final l in lines) '${logTime(now)} $l\n'].join(),
      mode: FileMode.append,
      flush: true,
    );
    if (newProcess) {
      state.parent.createSync(recursive: true);
      final tmp = File('${state.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({'last_ms': now.millisecondsSinceEpoch, 'pid': me}), flush: true);
      tmp.renameSync(state.path);
    }
  } on FileSystemException {
    // storage full or gone: these lines are lost
  }
  return lines;
}

/// [logStart] for this app: its folder and Android's exits through the phone's channel, each line also in logcat
/// (tag `flutter`, `app start: ...`). Quiet without the channel (tests, a desktop harness).
Future<void> logAppStart(String engine) async {
  try {
    final rec = await Phone.recordingsDir();
    if (rec == null) return;
    final lines = await logStart(Directory(rec).parent.path, engine: engine, exitReasons: Phone.exitReasons);
    for (final l in lines) {
      debugPrint('app start: $l');
    }
  } catch (_) {
    // no channel: nothing to log
  }
}
