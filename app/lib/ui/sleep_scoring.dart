// Runs the sleep scorer for the screens: every due night in turn, one at a time, with the current step for the night
// screen and the report screen (DECISIONS rows 97 and 580-589). The night screen starts it after Stop and whenever
// the app comes to the front with no night recording, a short while after the app opens ([runSoon]: the screen and
// Share on Wi-Fi come up first). Before every model call it checks that nothing more important runs: a night or a
// session stops the go (its progress is kept, the night goes on from there later); while the laptop copies files
// over Wi-Fi it waits.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sleep/report.dart';
import '../sleep/scorer.dart';

/// Last night's scoring runs now (its models take memory): the nap coach's live checks wait meanwhile.
bool nightScoringBusy = false;

/// How long after the app opens (or comes back) a go starts.
const Duration scoringSettle = Duration(seconds: 45);

class SleepScoring extends ChangeNotifier {
  SleepScoring(
    this.scorer, {
    this.stopFor,
    this.waitFor,
    this.settle = scoringSettle,
    this.poll = const Duration(seconds: 5),
  });

  final SleepScorer scorer;

  /// Why a go must stop now ("a night records"), or null: checked before every model call. It may ask Android (a
  /// night the headband watcher started from its own engine, DECISIONS 604, shows in no flag of the screen's).
  final FutureOr<String?> Function()? stopFor;

  /// Why a go should wait a moment ("the laptop copies"), or null: checked before every model call.
  final String? Function()? waitFor;

  /// The wait before a go that [runSoon] asked for.
  final Duration settle;

  /// How often a waiting go looks again.
  final Duration poll;

  /// The night being scored and its step, or null.
  String? night;
  String? step;

  /// Nights whose scoring did not finish and wait for "Try again", with the reason.
  Map<String, String> blocked = const {};
  Future<void>? _running;
  Timer? _soon;
  bool _halted = false;

  /// What [runSoon] was asked to do once the go has ended (packing old recordings, DECISIONS 540-549).
  void Function()? _then;

  bool get busy => _running != null;

  /// A go is asked for and starts in a moment.
  bool get starting => _soon != null;

  NightReportStore get store => scorer.store;

  List<SleepReport>? _reports;

  /// Every report, newest night first (read again after each night is scored and at each go).
  List<SleepReport> get reports => _reports ??= store.all();

  /// Scores every night that is due, unless a go is already running. Never throws.
  Future<void> run() {
    _soon?.cancel();
    _soon = null;
    final going = _running;
    if (going != null) return going;
    _halted = false;
    return _running = _all().whenComplete(() {
      _running = null;
      nightScoringBusy = false;
      final then = _then;
      _then = null;
      if (then != null) {
        try {
          then();
        } catch (e) {
          debugPrint('after sleep scoring: $e');
        }
      }
    });
  }

  /// [run] after [settle], so the screen and Share on Wi-Fi answer first; a call while one waits or runs starts
  /// nothing more. [then] runs once that go (or the one running) has ended; the latest call's [then] replaces an
  /// earlier one, and [halt] drops it.
  void runSoon({void Function()? then}) {
    if (then != null) _then = then;
    if (_running != null || _soon != null) return;
    _soon = Timer(settle, () {
      _soon = null;
      unawaited(run());
    });
  }

  /// A night or a session starts: a waiting go is called off, a running one stops at its next model call.
  void halt() {
    _soon?.cancel();
    _soon = null;
    _then = null;
    if (_running != null) _halted = true;
  }

  Future<void> _all() async {
    nightScoringBusy = true;
    try {
      _reports = null;
      blocked = scorer.blocked();
      notifyListeners();
      for (final n in scorer.due()) {
        night = n.name;
        step = 'Starting';
        notifyListeners();
        try {
          await scorer.score(n, progress: _say, between: _between);
          _reports = null;
        } on ScoringPaused catch (e) {
          debugPrint('sleep scoring of ${n.name}: $e'); // its progress is kept: it goes on from there next time
          break;
        } catch (e) {
          debugPrint('sleep scoring of ${n.name} failed: $e'); // the night's marker keeps the reason
        }
      }
    } catch (e) {
      debugPrint('sleep scoring stopped: $e');
    } finally {
      night = null;
      step = null;
      try {
        blocked = scorer.blocked();
      } catch (_) {}
      notifyListeners();
    }
  }

  void _say(String s) {
    step = s;
    notifyListeners();
  }

  /// Before every model call: stop for a night or a session, wait while the laptop copies.
  Future<void> _between() async {
    final was = step;
    for (;;) {
      final stop = _halted ? 'a night or a session started' : await stopFor?.call();
      if (stop == null && _halted) throw const ScoringPaused('a night or a session started'); // halted meanwhile
      if (stop != null) throw ScoringPaused(stop);
      final wait = waitFor?.call();
      if (wait == null) break;
      if (step == was) _say('Waiting while $wait');
      await Future<void>.delayed(poll);
    }
    if (step != was) _say(was ?? 'Starting');
  }

  /// "Try again" for a night whose scoring stopped.
  Future<void> retry(String nightOf) async {
    scorer.unblock(nightOf);
    await (_running ?? Future<void>.value());
    await run();
  }

  /// "Score again" for a night scored by an older scorer.
  Future<void> rescore(String nightOf) async {
    await (_running ?? Future<void>.value());
    scorer.request(nightOf);
    await run();
  }

  @override
  void dispose() {
    _soon?.cancel();
    super.dispose();
  }
}
