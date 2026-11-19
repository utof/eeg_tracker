// One guard for a live helper in the night recorder's isolate (the drift-off detector's rule, DECISIONS 182, with the
// smart alarm's memory limit, DECISIONS 236): every call goes through [WatchGuard.run]; any exception, more than its
// share of the recorder's time (checked from a while after it started) or the app growing by more than a limit since
// it started switches the helper off for the rest of the process with one log line. The recording never notices.
// Used by the lucid dream cues (lucid/live_cues.dart, DECISIONS 303).
import 'dart:io';

class GuardLimits {
  const GuardLimits({this.budget = 0.02, this.after = const Duration(minutes: 10), this.memoryMb = 700, this.rss});

  /// The share of the recorder's time the helper may take (its model's own thread and isolates are not counted),
  /// checked once it has run [after].
  final double budget;
  final Duration after;

  /// How much the app may grow (resident memory) since the helper started.
  final int memoryMb;

  /// The process's resident memory in bytes; null: the real one.
  final int Function()? rss;
}

class WatchGuard<W> {
  WatchGuard({required this.limits, required this.onStop});

  final GuardLimits limits;

  /// Called once with the reason and the helper, which the caller closes and logs.
  final void Function(String why, W watch) onStop;

  W? _watch;
  final Stopwatch time = Stopwatch(), wall = Stopwatch();
  int _rss0 = 0;

  /// Whether a helper ran in this process (for the night's cost line).
  bool used = false;

  W? get watch => _watch;
  int _rss() => (limits.rss ?? () => ProcessInfo.currentRss)();

  void start(W w) {
    _watch = w;
    used = true;
    time.reset();
    wall
      ..reset()
      ..start();
    _rss0 = _rss();
  }

  /// Runs [call] on the helper, if there is one; an exception switches it off.
  void run(void Function(W w) call) {
    final w = _watch;
    if (w == null) return;
    time.start();
    try {
      call(w);
    } catch (e) {
      stop(_short(e));
    } finally {
      time.stop();
    }
  }

  /// The 10-second check: its share of the time and the app's growth.
  void checkLimits() {
    if (_watch == null) return;
    if (wall.elapsed >= limits.after) {
      final share = time.elapsedMicroseconds / (wall.elapsedMicroseconds < 1 ? 1 : wall.elapsedMicroseconds);
      if (share > limits.budget) {
        stop(
          'it took ${(share * 100).toStringAsFixed(1)} % of the recorder\'s time '
          '(over ${(limits.budget * 100).toStringAsFixed(1)} %)',
        );
        return;
      }
    }
    final grown = (_rss() - _rss0) ~/ (1 << 20);
    if (grown > limits.memoryMb) stop('the app grew by $grown MB (over ${limits.memoryMb} MB)');
  }

  /// Lets the helper go without a reason (it finished by itself); returns it for closing.
  W? release() {
    final w = _watch;
    _watch = null;
    wall.stop();
    return w;
  }

  void stop(String why) {
    final w = release();
    if (w != null) onStop(why, w);
  }
}

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.length > 160 ? '${s.substring(0, 160)}...' : s;
}
