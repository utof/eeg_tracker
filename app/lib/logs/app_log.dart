// The app log's one-line API (DECISIONS 710; the files and the error hooks are log.dart): a subsystem keeps one
// logger and logs with one line, `final _log = AppLog('packing'); _log.info('packed', {'file': name});`. Plain Dart
// on `package:logging` only, so code the laptop's command-line tools share (recorder/packed.dart, under
// `dart run tool/...`) can log without pulling in Flutter (test/cli_tools_test.dart). log.dart exports it.
import 'package:logging/logging.dart';

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
