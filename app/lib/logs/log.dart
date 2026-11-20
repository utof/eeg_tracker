// The app's one logging API (DECISIONS 710): the Dart team's `package:logging` (already in the app through
// flutter_soloud, whose own warnings land here too), a line of JSON per entry in `files/logs/` (files.dart), and the
// errors nobody caught. A subsystem keeps one logger and logs with one line:
//
//   final _log = AppLog('recorder');
//   _log.info('connected', {'band': name, 'rssi': rssi});
//   _log.error('scoring failed', error: e, stack: st, data: {'night': night});
//   await _log.timed('score ${n.name}', () => scorer.score(n));   // "took 41.2 s", or the error with its time
//
// Subsystems in use: app, recorder, ble, share, scoring, packing, sessions, auto, sound, export, signal, usage, perf,
// print (every debugPrint), and the libraries' own loggers under their names. Each Flutter engine starts its records
// once ([Logs.start]: `screen` in main(), `recorder` in the night's service, `auto` in the headband watcher); before
// that, and in tests, a line goes nowhere and costs a check.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show ErrorCallback;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'activity.dart';
import 'files.dart';
import 'settings.dart';

/// A log line's extra facts, kept as JSON beside the words.
class LogMessage {
  const LogMessage(this.text, [this.data]);
  final String text;
  final Map<String, Object?>? data;

  @override
  String toString() => text;
}

class AppLog {
  AppLog(this.sub) : _logger = Logger(sub);

  /// The subsystem, as the log page filters it.
  final String sub;
  final Logger _logger;

  void fine(String msg, [Map<String, Object?>? data]) => _logger.fine(LogMessage(msg, data));
  void info(String msg, [Map<String, Object?>? data]) => _logger.info(LogMessage(msg, data));
  void warn(String msg, {Object? error, StackTrace? stack, Map<String, Object?>? data}) =>
      _logger.warning(LogMessage(msg, data), error, stack);
  void error(String msg, {Object? error, StackTrace? stack, Map<String, Object?>? data}) =>
      _logger.severe(LogMessage(msg, data), error, stack);

  /// Runs [work] and logs how long it took (`ms` in the data), or its error with the time it ran. Rethrows.
  Future<T> timed<T>(String what, Future<T> Function() work, {Map<String, Object?>? data}) async {
    final sw = Stopwatch()..start();
    try {
      final r = await work();
      info('$what took ${_secs(sw.elapsed)}', {...?data, 'ms': sw.elapsedMilliseconds});
      return r;
    } catch (e, st) {
      error('$what failed after ${_secs(sw.elapsed)}', error: e, stack: st, data: {...?data, 'ms': sw.elapsedMilliseconds});
      rethrow;
    }
  }
}

String _secs(Duration d) =>
    d.inMilliseconds < 1000 ? '${d.inMilliseconds} ms' : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

/// `fine`, `info`, `warn` or `error`: the four levels the files and the page use.
String levelWord(Level l) => l >= Level.SEVERE
    ? 'error'
    : l >= Level.WARNING
    ? 'warn'
    : l >= Level.INFO
    ? 'info'
    : 'fine';

/// At most this many lines a minute from debugPrint (a loop that prints must not fill the log).
const int printsPerMinute = 120;

/// One engine's records: the writers of its three files, its switches, and what it knows of the screen.
class Logs {
  Logs._(this.engine, this._clock);

  static Logs? _current;

  /// This engine's records, or null before [start] (and in tests that never start them).
  static Logs? get current => _current;

  /// `screen`, `recorder` or `auto`.
  final String engine;
  final DateTime Function() _clock;

  Directory? _dir;
  final Map<LogKind, JsonlWriter> _writers = {};
  final List<(LogKind, Map<String, Object?>)> _early = [];
  static const int _earlyMax = 2000;
  LogSettings _settings = const LogSettings();
  StreamSubscription<LogRecord>? _sub;
  DebugPrintCallback? _print;
  int _printMinute = -1, _printsThisMinute = 0;

  /// The screen shown now (the screen engine's route observer sets it); errors carry it.
  String? screen;

  /// `files/logs/`, once known.
  Directory? get dir => _dir;
  LogSettings get settings => _settings;

  /// Starts this engine's records: every logger's lines, Flutter's errors and the errors nobody caught ([catchErrors];
  /// the handlers before stay in place and still run), and debugPrint ([capturePrint]; widget tests leave both off). [recordingsDir] finds the app's folder; lines
  /// come before it are kept in memory meanwhile. A second call returns the running one.
  static Logs start({
    required String engine,
    required Future<String?> Function() recordingsDir,
    bool catchErrors = true,
    bool capturePrint = true,
    DateTime Function()? clock,
  }) {
    final running = _current;
    if (running != null) return running;
    final logs = _current = Logs._(engine, clock ?? DateTime.now);
    Logger.root.level = Level.INFO;
    logs._sub = Logger.root.onRecord.listen(logs._record);
    if (catchErrors) logs._catch();
    if (capturePrint) logs._capturePrint();
    unawaited(() async {
      try {
        final rec = await recordingsDir();
        if (rec != null) logs.attach(logsDirFor(rec));
      } catch (_) {}
    }());
    return logs;
  }

  /// Writes into [logsDir] from now on: what came before goes first, old files are pruned, the switches are read.
  void attach(Directory logsDir) {
    if (_dir != null) return;
    _dir = logsDir;
    reloadSettings();
    for (final k in LogKind.values) {
      _writers[k] = JsonlWriter(logsDir, k, engine, clock: _clock);
    }
    for (final (k, line) in _early) {
      _writers[k]!.write(line);
    }
    _early.clear();
    pruneLogs(logsDir, _clock());
  }

  /// Reads the switches again (a page changed them).
  void reloadSettings() {
    final d = _dir;
    if (d == null) return;
    _settings = LogSettings.load(d);
    Logger.root.level = _settings.detailed ? Level.ALL : Level.INFO;
  }

  /// Saves new switches and uses them at once.
  void saveSettings(LogSettings s) {
    final d = _dir;
    if (d == null) return;
    s.save(d);
    reloadSettings();
  }

  /// A line of [kind]; the time is added when missing. Usage lines are dropped while "Record how I use the app" is
  /// off ("Measure battery" stops the battery sampler itself, metrics.dart).
  void write(LogKind kind, Map<String, Object?> line) {
    if (kind == LogKind.usage && !_settings.usage) return;
    final full = line.containsKey('t') ? line : {'t': logTime(_clock()), ...line};
    final w = _writers[kind];
    if (w != null) {
      w.write(full);
    } else if (_early.length < _earlyMax) {
      _early.add((kind, full));
    }
  }

  /// Old files go (once a day is enough; the screen engine calls it as the app opens).
  void prune() {
    final d = _dir;
    if (d != null) pruneLogs(d, _clock());
  }

  void _record(LogRecord r) {
    final o = r.object;
    final data = o is LogMessage ? o.data : null;
    final serious = r.level >= Level.WARNING;
    write(LogKind.app, {
      't': logTime(r.time),
      'level': levelWord(r.level),
      'sub': r.loggerName.isEmpty ? 'app' : r.loggerName,
      'msg': r.message,
      if (data != null && data.isNotEmpty) 'data': data,
      if (r.error != null) 'error': _short('${r.error}', 2000),
      if (r.stackTrace != null) 'stack': _stack(r.stackTrace!),
      if (serious && screen != null) 'screen': screen,
      if (serious) 'on': Activity.active,
    });
  }

  bool _caught = false;
  FlutterExceptionHandler? _flutterBefore;
  ErrorCallback? _platformBefore;

  void _catch() {
    final log = AppLog('app');
    final flutter = _flutterBefore = FlutterError.onError;
    _caught = true;
    FlutterError.onError = (details) {
      log.error(
        'Flutter error${details.library == null ? '' : ' in ${details.library}'}',
        error: details.exception,
        stack: details.stack,
        data: {if (details.context != null) 'context': _short('${details.context}', 300)},
      );
      flutter?.call(details);
    };
    final platform = _platformBefore = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      log.error('uncaught error', error: error, stack: stack);
      return platform?.call(error, stack) ?? false; // not handled here: the engine reports it as before
    };
  }

  void _capturePrint() {
    final before = _print = debugPrint;
    final log = AppLog('print');
    debugPrint = (String? message, {int? wrapWidth}) {
      before(message, wrapWidth: wrapWidth);
      if (message == null || message.isEmpty) return;
      final minute = _clock().millisecondsSinceEpoch ~/ 60000;
      if (minute != _printMinute) {
        _printMinute = minute;
        _printsThisMinute = 0;
      }
      if (++_printsThisMinute <= printsPerMinute) log.info(_short(message, 2000));
    };
  }

  /// Stops this engine's records (the night's service ends; tests).
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final p = _print;
    if (p != null) debugPrint = p;
    if (_caught) {
      FlutterError.onError = _flutterBefore;
      PlatformDispatcher.instance.onError = _platformBefore;
    }
    for (final w in _writers.values) {
      w.close();
    }
    if (identical(_current, this)) _current = null;
  }

  /// Tests: forget the running records without touching the error handlers' chain.
  @visibleForTesting
  static Future<void> reset() async => _current?.stop();
}

String _short(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// The first 25 frames: enough to find the place, short enough to keep the log small.
String _stack(StackTrace st) {
  final lines = st.toString().split('\n').where((l) => l.trim().isNotEmpty).toList();
  return lines.length <= 25 ? lines.join('\n') : '${lines.take(25).join('\n')}\n… ${lines.length - 25} more frames';
}

/// The process's memory now, in bytes (resident set; Dart's own number, no channel call).
int processRss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return 0;
  }
}
