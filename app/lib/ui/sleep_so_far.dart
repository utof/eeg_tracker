// "Sleep so far" for the screens (DECISIONS 640-649): one look at a time at the night that records (so_far.dart), the
// last look's result for the night screen's line, and the page that looks when it opens, when the app comes back
// with it showing, and every 15 minutes while it shows; never with the screen off, so no extra wake-ups. A look stops
// at its next model call when the page closes or the night stops; what it scored stays for the next one.
import 'dart:async';

import 'package:flutter/material.dart';

import '../recorder/header.dart' show MissingSites;
import '../sleep/scorer.dart' show ScoringPaused;
import '../sleep/so_far.dart';
import 'sleep_so_far_view.dart';

/// How often the open page looks again (battery: one look is about 3 to 6 model calls).
const Duration soFarEvery = Duration(minutes: 15);

class SleepSoFar extends ChangeNotifier {
  SleepSoFar(this.scorer, {required this.nightStartMs, this.sleepMarked, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final SoFarScorer scorer;

  /// Whether the running recording has an open sleep stretch (null: not known, so yes). A recording started with
  /// Record has none until Sleep is pressed: then there is no sleep so far, and nothing is scored.
  final bool Function()? sleepMarked;

  /// When the night that records now started (unix ms; the recorder's status), null while not known.
  final int? Function() nightStartMs;
  final DateTime Function() _now;

  SoFarResult? result;
  String? step;
  String? waiting;
  String? failed;
  String? refused;
  bool ended = false;

  /// When the last look ended, and whether it was cut short (the page closed, the screen went off).
  DateTime? lookedAt;
  bool cut = false;
  int? _forNight;
  Future<void>? _running;
  bool _halted = false;

  bool get busy => _running != null;

  /// The recording has no open sleep stretch: "no sleep marked".
  bool get noSleep => !(sleepMarked?.call() ?? true);

  SoFarState get state => SoFarState(
    step: step,
    waiting: waiting,
    failed: failed,
    refused: refused,
    ended: ended,
    busy: busy,
    noSleep: noSleep,
  );

  /// The last look's result for tonight (read once from the cache); never throws.
  SoFarResult? cached() {
    if (noSleep) return result = null;
    final since = nightStartMs();
    if (since == null) return null;
    if (_forNight != since) {
      _forNight = since;
      result = null;
      try {
        result = scorer.cached(sinceMs: since);
      } catch (_) {
        result = null;
      }
    }
    return result;
  }

  /// A new night started: nothing of the last one is shown.
  void reset() {
    halt();
    _forNight = null;
    result = null;
    step = waiting = failed = refused = null;
    ended = false;
    lookedAt = null;
    notifyListeners();
  }

  /// One look, unless one runs (then that one); never throws.
  Future<void> update() {
    final going = _running;
    if (going != null) return going;
    _halted = false;
    ended = false;
    return _running = _look().whenComplete(() {
      _running = null;
      notifyListeners();
    });
  }

  Future<void> _look() async {
    if (noSleep) {
      result = null;
      step = waiting = failed = refused = null;
      lookedAt = _now();
      return;
    }
    cached();
    step = 'Looking at the recordings';
    waiting = failed = refused = null;
    cut = false;
    notifyListeners();
    try {
      result = await scorer.update(
        sinceMs: nightStartMs(),
        progress: (s) {
          step = s;
          result = scorer.latest ?? result;
          notifyListeners();
        },
        between: () async {
          if (_halted) throw const ScoringPaused('the page closed or the night stopped');
        },
      );
    } on ScoringPaused catch (e) {
      result = scorer.latest ?? result;
      if (!_halted) waiting = e.why;
      cut = _halted;
    } on MissingSites catch (e) {
      refused = e.message; // the recording lacks O1 O2 T3 or T4: said in words, never read from another channel
    } catch (e) {
      result = scorer.latest ?? result;
      failed = '$e';
      debugPrint('sleep so far: $e');
    } finally {
      step = null;
      lookedAt = _now();
    }
  }

  /// The page closed: a look stops at its next model call.
  void halt() {
    if (_running != null) _halted = true;
  }

  /// Stop: the night's report comes next; this one stays as it was.
  void nightEnded() {
    halt();
    ended = true;
    notifyListeners();
  }
}

class SleepSoFarScreen extends StatefulWidget {
  const SleepSoFarScreen({super.key, required this.soFar, this.onInfo, this.every = soFarEvery});
  final SleepSoFar soFar;
  final VoidCallback? onInfo;
  final Duration every;

  @override
  State<SleepSoFarScreen> createState() => _SleepSoFarScreenState();
}

class _SleepSoFarScreenState extends State<SleepSoFarScreen> with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.soFar.cached();
    if (!widget.soFar.ended) unawaited(widget.soFar.update());
    _timer = Timer.periodic(widget.every, (_) {
      final resumed = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (resumed && !widget.soFar.ended) unawaited(widget.soFar.update());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !widget.soFar.ended) {
      final last = widget.soFar.lookedAt;
      if (last == null || widget.soFar.cut || DateTime.now().difference(last) > const Duration(minutes: 1)) {
        unawaited(widget.soFar.update());
      }
    } else if (state == AppLifecycleState.paused) {
      widget.soFar.halt(); // the screen went off: the look stops at its next call, nothing wakes the phone for it
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.soFar.halt();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.soFar,
    builder: (context, _) => SleepSoFarView(
      result: widget.soFar.result,
      state: widget.soFar.state,
      everyMinutes: widget.every.inMinutes,
      onUpdate: () => unawaited(widget.soFar.update()),
      onInfo: widget.onInfo,
    ),
  );
}
