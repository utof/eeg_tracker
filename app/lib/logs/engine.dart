// Starting an engine's records (DECISIONS 710-715): one call per Flutter engine.
//
//   ScreenRecords.start(...)   main(): the log, the usage log, the power sampler while the app is open or a feature
//                              runs, frame timings, start-up time, the day's storage, old files pruned once a day
//   EngineRecords.start(...)   the night's service and the headband watcher: the log and the power sampler
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';

import 'activity.dart';
import 'files.dart';
import 'log.dart';
import 'metrics.dart';
import 'usage.dart';
import 'usage_watch.dart';

typedef PowerRead = Future<Map<Object?, Object?>?> Function();

/// A background engine's records: the log, and battery samples while it works.
class EngineRecords {
  EngineRecords._(this.logs, this.sampler);
  final Logs logs;
  final PowerSampler sampler;

  static EngineRecords start({
    required String engine,
    required Future<String?> Function() recordingsDir,
    required PowerRead power,
  }) {
    final logs = Logs.start(engine: engine, recordingsDir: recordingsDir);
    Usage.followActivity();
    final s = PowerSampler(read: power)..start();
    return EngineRecords._(logs, s);
  }

  /// The last sample; the log keeps running until the engine ends.
  Future<void> stop() => sampler.stop();
}

/// The screen engine's records, from main() until the process ends.
class ScreenRecords {
  ScreenRecords._(this.logs, this.sampler, this.frames);

  final Logs logs;
  final PowerSampler sampler;
  final FrameWatch frames;
  AppLifecycleListener? _life;
  bool _front = true;
  String? _day;
  static ScreenRecords? _current;
  static ScreenRecords? get current => _current;

  /// [mainStarted]: when main() began (for the start-up time); [processAgeMs]: how long ago Android started the
  /// process (PhoneChannel `processAge`), read once at the first frame.
  static ScreenRecords start({
    required Future<String?> Function() recordingsDir,
    required PowerRead power,
    required Stopwatch mainStarted,
    Future<int?> Function()? processAgeMs,
  }) {
    final running = _current;
    if (running != null) return running;
    final logs = Logs.start(engine: 'screen', recordingsDir: recordingsDir);
    Usage.followActivity();
    final r = _current = ScreenRecords._(logs, PowerSampler(read: power), FrameWatch());
    Activity.begin('app-open');
    Usage.app(front: true);
    r.sampler.start();
    r.frames.start();
    Activity.listen(r._changed);
    r._life = AppLifecycleListener(onStateChange: r._state);
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) async {
      final mainMs = mainStarted.elapsedMilliseconds;
      int? processMs;
      try {
        processMs = await processAgeMs?.call().timeout(const Duration(seconds: 3));
      } catch (_) {}
      Metrics.write({
        'kind': 'startup',
        'main_ms': mainMs,
        'process_ms': ?processMs,
        'rss': processRss(),
      });
      AppLog('app').info('first frame $mainMs ms after main()', {'process_ms': processMs});
    });
    unawaited(r._daily(recordingsDir));
    return r;
  }

  void _state(AppLifecycleState s) {
    final front = s == AppLifecycleState.resumed;
    final back = s == AppLifecycleState.paused || s == AppLifecycleState.hidden || s == AppLifecycleState.detached;
    if (front && !_front) {
      _front = true;
      Usage.app(front: true);
      Activity.begin('app-open');
      sampler.start();
      final dir = logs.dir;
      if (dir != null) unawaited(_daily(() async => '${dir.parent.path}/recordings'));
    } else if (back && _front) {
      _front = false;
      frames.flush();
      Usage.app(front: false);
      Activity.end('app-open');
    }
  }

  /// In the back with nothing on: the sampler rests (its last sample says nothing is on); something starts in the
  /// back (a session from the notification): it samples again.
  void _changed(String feature, bool on, Duration? lasted) {
    if (_front) return;
    if (Activity.active.isEmpty) {
      unawaited(sampler.stop(why: 'back'));
    } else if (!sampler.running) {
      sampler.start();
    }
  }

  /// Once a day: old files pruned, the size of each folder of the app's files measured (off the screen's thread).
  Future<void> _daily(Future<String?> Function() recordingsDir) async {
    final today = logDay(DateTime.now());
    if (_day == today) return;
    _day = today;
    try {
      final rec = await recordingsDir();
      if (rec == null) return;
      final files = Directory(rec).parent.path;
      logs.prune();
      final cats = await _sizesInBackground(files);
      Metrics.write({'kind': 'storage', 'cats': cats, 'total': cats.values.fold<int>(0, (a, b) => a + b)});
    } catch (e) {
      AppLog('app').warn('could not measure the storage', error: e);
    }
  }

  @visibleForTesting
  void dispose() {
    _life?.dispose();
    Activity.unlisten(_changed);
    frames.stop();
    unawaited(sampler.stop());
    if (identical(_current, this)) _current = null;
  }
}

/// Top-level, so the isolate's closure holds only the folder's path.
Future<Map<String, int>> _sizesInBackground(String filesDir) =>
    Isolate.run(() => storageByCategory(Directory(filesDir)), debugName: 'storage-sizes');
