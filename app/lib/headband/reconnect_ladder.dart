// The reconnect ladder (DECISIONS 940-945; research 2026-11-24 "Bluetooth all day"): how the app gets a lost headband
// back, by the time since the drop. It replaces "one direct try every 60 s for ever".
//
//   A. Mend, 0-70 s:        the short waits, as before (DECISIONS 49, 213).
//   B. Look, 70 s - 10 min: one direct try every 60 s, as before (every third try a scan).
//   C. Wait, after 10 min:  the 60 s tries stop. ONE waiting connect stays open (the phone's Bluetooth chip listens
//                           for the headband and connects when it shows up; no scan, no time limit), with a safety
//                           try every 15 min: the waiting connect is closed, one direct try is made, and it is
//                           opened again. Where there is no waiting connect (BrainBit's SDK) or it fails: one
//                           direct try every 5 min, every 2 min while the screen is on. (The DIY board's night
//                           never gets here: listening on Wi-Fi costs no radio, [LadderTiming.neverWait].)
//   Hints, at any stage:    the app opened or brought to the front, the phone unlocked, Bluetooth switched on,
//                           "Reconnect now" on the headband-lost notice: one direct try at once.
//
// Nothing here knows a BrainBit, a number of channels or a driver: the ladder decides and waits, and whoever owns the
// real connection makes the tries it names (today the night recorder in its engine, recorder/night_recorder.dart).
// A waiting connect dies with Bluetooth off/on and with the app's process: the "Bluetooth on" hint and a restart
// both end in a direct try, and the step after a failed try opens the waiting connect again.
import 'dart:async';
import 'dart:math' as math;

import '../recorder/headband.dart';

/// Planning values, not measured on the phone (DECISIONS 941): change them here.
/// After this long without the headband the 60 s tries stop and the waiting begins (stage C).
const Duration ladderWaitAfter = Duration(minutes: 10);

/// Stage C with a waiting connect: a safety direct try this often (a waiting connect can die without a word).
const Duration ladderSafetyEvery = Duration(minutes: 15);

/// Stage C without a waiting connect: one direct try this often.
const Duration ladderFallbackEvery = Duration(minutes: 5);

/// The same while the phone's screen is on (the owner is at the phone).
const Duration ladderFallbackEveryScreenOn = Duration(minutes: 2);

/// Until here a drop counts as "mending" (the name in the log only; the waits come from the owner's list).
const Duration ladderMendFor = Duration(seconds: 70);

enum LadderStage { mend, look, wait }

/// Why a try is made right now.
enum ReconnectHint {
  appOpened('opened app'),
  unlocked('phone unlocked'),
  bluetoothOn('Bluetooth on'),
  reconnectNow('Reconnect now'),

  /// Android's companion-device "appeared". Nothing sends it yet (DECISIONS 944): the hook is
  /// `ReconnectHints.hint("cameNear")` in Kotlin.
  cameNear('headband came near'),
  restarted('app restart');

  const ReconnectHint(this.label);

  /// The words in the log's "back by:".
  final String label;

  static ReconnectHint? named(Object? name) {
    for (final h in values) {
      if (h.name == name) return h;
    }
    return null;
  }
}

class LadderTiming {
  const LadderTiming({
    this.mendFor = ladderMendFor,
    this.waitAfter = ladderWaitAfter,
    this.safetyEvery = ladderSafetyEvery,
    this.fallbackEvery = ladderFallbackEvery,
    this.fallbackEveryScreenOn = ladderFallbackEveryScreenOn,
    this.cancelWait = const Duration(seconds: 5),
  });

  final Duration mendFor, waitAfter, safetyEvery, fallbackEvery, fallbackEveryScreenOn;

  /// For a board whose "connection" costs no radio time (the DIY board listens for datagrams on Wi-Fi): stage C
  /// never begins, the owner's own short waits go on for as long as it takes.
  static const LadderTiming neverWait = LadderTiming(waitAfter: Duration(days: 36500));

  /// How long closing a waiting connect may take before the try goes ahead anyway.
  final Duration cancelWait;
}

/// What the owner of the connection does next.
class LadderStep {
  const LadderStep({required this.n, required this.stage, required this.by, this.scanDue = false, this.band});

  /// The try's number since the drop.
  final int n;
  final LadderStage stage;

  /// The road, for the log: `quick try`, `minute try`, `waiting connect`, `safety try`, `timed try`, or a hint's words.
  final String by;

  /// Stages A and B only: this try is the every-third one that scans instead (DECISIONS 49). Never in stage C.
  final bool scanDue;

  /// The headband, already connected by the waiting connect: no try to make.
  final Headband? band;
}

class ReconnectLadder {
  ReconnectLadder({
    required this.waits,
    this.scanEvery = 3,
    this.timing = const LadderTiming(),
    this.waitFor,
    this.screenOn,
    this.log,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// The wait before each try in stages A and B; the last one repeats (the recorder: 2, 5, 10, 30, 60 s).
  final List<Duration> waits;

  /// Every this many-th try of stages A and B is a scan (3: direct, direct, scan); 0 or 1: the ladder never asks.
  final int scanEvery;
  final LadderTiming timing;

  /// Opens a waiting connect, or gives null when the connection in use has none; null: never ([WaitingFinder]).
  final Future<WaitingConnect?> Function(BandId id)? waitFor;

  /// Whether the phone's screen is on now; null or a failure: taken as off.
  final Future<bool> Function()? screenOn;

  /// Lines for the owner's log (stage changes, the waiting connect opening and failing).
  final void Function(String line)? log;
  final DateTime Function() _now;

  DateTime? _lostAt;
  int _tries = 0;
  bool _inTry = false;
  bool _saidWait = false;
  ReconnectHint? _pending;
  Completer<ReconnectHint>? _napHint;

  /// A drop is being recovered from.
  bool get active => _lostAt != null;
  DateTime? get lostAt => _lostAt;
  int get tries => _tries;

  LadderStage get stage {
    final at = _lostAt;
    final away = at == null ? Duration.zero : _now().difference(at);
    if (away >= timing.waitAfter) return LadderStage.wait;
    return away >= timing.mendFor ? LadderStage.look : LadderStage.mend;
  }

  /// The headband was lost at [lostAt]. Nothing changes when a drop is already being recovered from.
  void begin(DateTime lostAt) => _lostAt ??= lostAt;

  /// The headband is back and gave data (or the recording stopped): the next drop starts from the first step.
  void end() {
    _lostAt = null;
    _tries = 0;
    _inTry = false;
    _saidWait = false;
    _pending = null;
  }

  /// A reason to try right now. Ignored while nothing is lost and while a try is already under way.
  void hint(ReconnectHint h) {
    if (!active || _inTry) return;
    final nap = _napHint;
    if (nap != null && !nap.isCompleted) {
      nap.complete(h);
    } else {
      _pending ??= h;
    }
  }

  /// For the "reconnected" line: `waited 3 h 12 min; back by: safety try`.
  String backLine(String by) {
    final at = _lostAt;
    return '${at == null ? '' : 'waited ${awayText(_now().difference(at))}; '}back by: $by';
  }

  /// Waits as the stage says, then names the next step; null when [stop] ended the wait. The caller makes the try
  /// (unless [LadderStep.band] is there) and calls [next] again when it failed, or [end] once data arrives.
  Future<LadderStep?> next(BandId id, {required Future<void> stop}) async {
    _inTry = false;
    final lostAt = _lostAt ??= _now();
    final n = ++_tries;
    final away = _now().difference(lostAt);
    final step = away < timing.waitAfter ? await _early(n, away, stop) : await _waiting(n, id, stop);
    if (step != null) _inTry = step.band == null;
    return step;
  }

  // ---- stages A and B ---------------------------------------------------------------------------------------
  Future<LadderStep?> _early(int n, Duration away, Future<void> stop) async {
    final wait = waits.isEmpty ? Duration.zero : waits[math.min(n, waits.length) - 1];
    final woke = await _nap(wait, stop);
    if (woke.stopped) return null;
    final at = _lostAt;
    final now = at == null ? away : _now().difference(at);
    final stage = now >= timing.mendFor ? LadderStage.look : LadderStage.mend;
    final hint = woke.hint;
    if (hint != null) return LadderStep(n: n, stage: stage, by: hint.label);
    return LadderStep(
      n: n,
      stage: stage,
      by: stage == LadderStage.mend ? 'quick try' : 'minute try',
      scanDue: scanEvery > 1 && n % scanEvery == 0,
    );
  }

  // ---- stage C ----------------------------------------------------------------------------------------------
  Future<LadderStep?> _waiting(int n, BandId id, Future<void> stop) async {
    LadderStep step(String by, {Headband? band}) => LadderStep(n: n, stage: LadderStage.wait, by: by, band: band);
    final early = _pending;
    if (early != null) {
      _pending = null;
      return step(early.label);
    }
    final w = await _open(id);
    if (!_saidWait) {
      _saidWait = true;
      log?.call(
        w != null
            ? 'headband away ${awayText(timing.waitAfter)}: the 60 s tries stop; a waiting connect is open (the phone '
                  'listens for the headband), with a safety try every ${awayText(timing.safetyEvery)}'
            : 'headband away ${awayText(timing.waitAfter)}: the 60 s tries stop; no waiting connect with this '
                  'connection, so one try every ${awayText(timing.fallbackEvery)} '
                  '(${awayText(timing.fallbackEveryScreenOn)} with the screen on)',
      );
    }
    if (w == null) return _fallback(n, stop);
    final nap = _Nap(this, timing.safetyEvery, stop);
    final first = await Future.any<Object?>([
      w.band.then<Object?>((b) => b, onError: (Object e) => _Broke(e)),
      nap.done,
    ]);
    if (first is Headband) {
      nap.cancel();
      return step('waiting connect', band: first);
    }
    if (first is _Broke) {
      nap.cancel();
      await _close(w);
      log?.call(
        'the waiting connect failed (${_short(first.error)}); one try every ${awayText(timing.fallbackEvery)} instead, '
        'then it is opened again',
      );
      return _fallback(n, stop);
    }
    final woke = first! as _Woke;
    // a headband that arrives in the same moment is not kept twice: the try that follows reaches it anew
    unawaited(w.band.then<void>((b) => b.disconnectAndDispose(), onError: (Object _) {}));
    await _close(w);
    if (woke.stopped) return null;
    return step(woke.hint?.label ?? 'safety try');
  }

  Future<WaitingConnect?> _open(BandId id) async {
    final open = waitFor;
    if (open == null) return null;
    try {
      return await open(id);
    } catch (e) {
      log?.call('the waiting connect could not be opened (${_short(e)})');
      return null;
    }
  }

  Future<void> _close(WaitingConnect w) async {
    try {
      await w.cancel().timeout(timing.cancelWait);
    } catch (_) {}
  }

  /// One try every [LadderTiming.fallbackEvery]; the screen is looked at every [LadderTiming.fallbackEveryScreenOn],
  /// and while it is on the try is made then.
  Future<LadderStep?> _fallback(int n, Future<void> stop) async {
    var waited = Duration.zero;
    while (true) {
      final left = timing.fallbackEvery - waited;
      final chunk = left < timing.fallbackEveryScreenOn ? left : timing.fallbackEveryScreenOn;
      final woke = await _nap(chunk, stop);
      if (woke.stopped) return null;
      final hint = woke.hint;
      if (hint != null) return LadderStep(n: n, stage: LadderStage.wait, by: hint.label);
      waited += chunk;
      if (waited >= timing.fallbackEvery || await _screenOn()) {
        return LadderStep(n: n, stage: LadderStage.wait, by: 'timed try');
      }
    }
  }

  Future<bool> _screenOn() async {
    try {
      return await screenOn?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<_Woke> _nap(Duration d, Future<void> stop) => _Nap(this, d, stop).done;

  static String _short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 120 ? '${s.substring(0, 120)}...' : s;
  }
}

/// `45 s`, `12 min`, `3 h 12 min`.
String awayText(Duration d) {
  if (d < const Duration(minutes: 1)) return '${d.inSeconds} s';
  if (d < const Duration(hours: 1)) return '${d.inMinutes} min';
  final m = d.inMinutes % 60;
  return m == 0 ? '${d.inHours} h' : '${d.inHours} h $m min';
}

class _Broke {
  _Broke(this.error);
  final Object error;
}

class _Woke {
  const _Woke({this.hint, this.stopped = false});
  final ReconnectHint? hint;
  final bool stopped;
}

/// One wait of the ladder: over after its time, at a hint, or at Stop.
class _Nap {
  _Nap(this._ladder, Duration d, Future<void> stop) {
    final pending = _ladder._pending;
    if (pending != null) {
      _ladder._pending = null;
      _end(_Woke(hint: pending));
      return;
    }
    final hint = _ladder._napHint = Completer<ReconnectHint>();
    _timer = Timer(d, () => _end(const _Woke()));
    unawaited(hint.future.then((h) => _end(_Woke(hint: h))));
    unawaited(stop.then((_) => _end(const _Woke(stopped: true))));
  }

  final ReconnectLadder _ladder;
  final Completer<_Woke> _done = Completer<_Woke>();
  Timer? _timer;

  Future<_Woke> get done => _done.future;

  void cancel() => _end(const _Woke());

  void _end(_Woke w) {
    if (_done.isCompleted) return;
    _timer?.cancel();
    _ladder._napHint = null;
    _done.complete(w);
  }
}
