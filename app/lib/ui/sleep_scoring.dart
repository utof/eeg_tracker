// Runs the sleep scorer for the screens: every due night in turn, one run at a time, with the current step for
// the night screen and the report screen. Started after Stop and whenever the app comes to the front with no
// night recording (DECISIONS row 97).
import 'package:flutter/foundation.dart';

import '../sleep/report.dart';
import '../sleep/scorer.dart';

/// Last night's scoring runs now (its models take memory): the nap coach's live checks wait meanwhile.
bool nightScoringBusy = false;

class SleepScoring extends ChangeNotifier {
  SleepScoring(this.scorer);
  final SleepScorer scorer;

  /// The night being scored and its step, or null.
  String? night;
  String? step;

  /// Nights whose last scoring did not finish, with the reason.
  Map<String, String> blocked = const {};
  Future<void>? _running;

  bool get busy => _running != null;

  NightReportStore get store => scorer.store;

  List<SleepReport>? _reports;

  /// Every report, newest night first (read again after each night is scored).
  List<SleepReport> get reports => _reports ??= store.all();

  /// Scores every night that is due, unless a run is already going. Never throws.
  Future<void> run() => _running ??= _all().whenComplete(() {
    _running = null;
    nightScoringBusy = false;
  });

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
          await scorer.score(n, progress: (s) {
            step = s;
            notifyListeners();
          });
          _reports = null;
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

  /// "Try again" for a night whose scoring stopped.
  Future<void> retry(String nightOf) async {
    scorer.unblock(nightOf);
    await (_running ?? Future<void>.value());
    await run();
  }
}
