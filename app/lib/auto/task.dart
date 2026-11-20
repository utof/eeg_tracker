// The watcher's own engine (DECISIONS 600): AutoWatchService.kt runs [runAutoWatch] in a Flutter engine of its own,
// inside a short foreground service ("Checking whether the headband is on"), whenever Android says the headband came
// near, a bedtime check rings, the laptop says work started, or the app is opened. It takes the triggers one by one,
// runs the watcher (controller.dart) with the real headband, phone and starters, arms the next bedtime checks, and
// ends. A question keeps it (and the headband) for up to 15 minutes; the screen's engine never holds the watcher.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart' show ServiceRequestFailure;

import '../phone.dart';
import '../start_log.dart';
import '../recorder/brainbit.dart';
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/recorder_service.dart';
import 'channel.dart';
import 'controller.dart';
import 'probe.dart';
import 'rules.dart';
import 'store.dart';

const MethodChannel _task = MethodChannel('eeg_tracker/auto_task');

/// The engine's body; its entry point is `autoWatchMain` in main.dart (an entry point must sit in a library the app's
/// main reaches, or the build leaves it out).
Future<void> runAutoWatch() async {
  WidgetsFlutterBinding.ensureInitialized();
  initRecorderService(); // the night recorder's options, in case this engine starts it
  unawaited(logAppStart('watcher')); // files/app-starts.log (DECISIONS 734)
  await AutoTask().run();
}

class AutoTask {
  final List<AutoTrigger> _waiting = [];
  AutoWatch? _watch;

  Future<void> run() async {
    _task.setMethodCallHandler(_onCall);
    String? rec;
    try {
      rec = await Phone.recordingsDir();
    } catch (_) {}
    if (rec == null) return _end();
    final finder = BrainBitFinder();
    final watch = _watch = AutoWatch(
      recordings: rec,
      check: BandCheck(finder),
      phone: _TaskPhone(),
      starter: _TaskStarter(rec),
      simulate: kDebugMode ? (fake) => SimulatedCheck(worn: fake == 'worn') : null,
    );
    do {
      for (var t = await _take(); t != null; t = await _take()) {
        try {
          await watch.handle(t);
        } catch (e) {
          watch.log.add(DateTime.now(), 'skipped', {'trigger': t.reason, 'why': 'error: $e'});
        }
      }
      try {
        await AutoChannel.armBedtime(watch.nextChecks());
      } catch (_) {}
    } while (!await _finish());
    finder.dispose(anyLost: false);
  }

  /// The next trigger: one Kotlin queued, else null.
  Future<AutoTrigger?> _take() async {
    if (_waiting.isNotEmpty) return _waiting.removeAt(0);
    final m = await _task.invokeMapMethod<String, Object?>('takeTrigger');
    final reason = m?['reason'];
    if (reason is! String) return null;
    return AutoTrigger(reason, force: m?['force'] == true, fake: m?['fake'] as String?);
  }

  /// True when the service may end now; false when a trigger came meanwhile.
  Future<bool> _finish() async => await _task.invokeMethod<bool>('finish') ?? true;

  Future<void> _end() async {
    try {
      await _task.invokeMethod<bool>('finish', {'force': true});
    } catch (_) {}
  }

  Future<Object?> _onCall(MethodCall call) async {
    final w = _watch;
    final a = call.arguments;
    switch (call.method) {
      case 'answer':
        if (w != null && a is Map) w.answer('${a['id']}', '${a['answer']}');
      case 'release':
        await w?.release();
    }
    return null;
  }
}

class _TaskPhone implements AutoPhone {
  @override
  Future<PhoneContext> context(DateTime now) async {
    final m = await _task.invokeMapMethod<String, Object?>('context') ?? const {};
    DateTime? ms(Object? v) => v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    return PhoneContext(
      now: now,
      charging: m['charging'] == true,
      screenOn: m['screenOn'] != false,
      screenOffSince: ms(m['screenOffAt']),
      dnd: m['dnd'] == true,
      nextAlarm: ms(m['nextAlarm']),
    );
  }

  @override
  Future<String?> busy() => _task.invokeMethod<String>('busy');

  @override
  Future<void> ask(AutoQuestion q) => _task.invokeMethod<void>('ask', q.toChannel());

  @override
  Future<void> withdraw() => _task.invokeMethod<void>('withdraw');

  @override
  Future<void> notice(String title, String text) => _task.invokeMethod<void>('notice', {'title': title, 'text': text});

  @override
  Future<void> offer(WearKind kind) => _task.invokeMethod<void>('offer', {
    'kind': kind.wire,
    'title': kind == WearKind.night ? 'Start the night by itself from now on?' : 'Start work sessions by themselves from now on?',
    'text': 'You said yes ${AutoRule.offerAfterYes} times in a row. Tap to choose; nothing changes until you do.',
  });
}

class _TaskStarter implements AutoStarter {
  _TaskStarter(this.recordings);
  final String recordings;

  @override
  Future<String?> startNight({required List<String> notes}) async {
    try {
      final r = await startRecorderService(recordings, autoNotes: notes, fromWatcher: true);
      return r is ServiceRequestFailure ? '${r.error}' : null;
    } catch (e) {
      return '$e';
    }
  }

  @override
  Future<bool> openWork({required bool quiet, Duration? limit}) async =>
      await _task.invokeMethod<bool>('openWork', {'quiet': quiet, 'limitMin': limit?.inMinutes}) ?? false;
}

/// Debug builds only: a headband that is on (or off) the head, for the emulator smoke test (no Bluetooth there).
/// On the head it streams a 10 Hz wave on four channels, 8 samples every 32 ms, until let go.
class SimulatedCheck implements HeadbandCheck {
  SimulatedCheck({required this.worn});
  final bool worn;
  Timer? _timer;

  @override
  bool get holding => _timer != null;

  @override
  Future<ProbeResult> check({required bool keepIfWorn, required void Function(DateTime, List<Sample>) onBatch}) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    final ohms = {for (final c in ['O1', 'O2', 'T3', 'T4']) c: worn ? 600e3 : null};
    if (worn && keepIfWorn) {
      var pack = 0;
      _timer = Timer.periodic(const Duration(milliseconds: 32), (_) {
        final rows = <Sample>[
          for (var i = 0; i < 8; i++)
            Sample.four(
              pack: pack + i,
              o1: 20e-6 * math.sin(2 * math.pi * 10 * (pack + i) / 250),
              o2: 18e-6 * math.sin(2 * math.pi * 10 * (pack + i) / 250),
              t3: 5e-6,
              t4: -5e-6,
            ),
        ];
        pack += 8;
        onBatch(DateTime.now(), rows);
      });
    }
    return ProbeResult(near: true, worn: worn, how: 'simulated', ohms: ohms, battery: 90, name: 'Simulated headband');
  }

  @override
  Future<void> release() async {
    _timer?.cancel();
    _timer = null;
  }
}
