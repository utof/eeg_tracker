// A replay session's sound (DECISIONS row 101): the control stream of your own earlier live sessions, step
// for step, while the live gates keep acting. A clench, a blink, a lost signal or (meditation) drifting toward
// sleep sounds exactly as it would in a live session: the bed goes neutral with the live jaw roughness, and no
// reward sounds until the gate has been clear as long as a live reward needs. Otherwise a jaw clench would
// give a replay away. Pure: no clock, no randomness.
import '../feedback/reward.dart' show BellRule;
import '../feedback/session.dart' show stepS;
import 'control.dart';

/// Clear steps a reward needs after a gate (meditation: the bell rule's 4 s window; alpha-theta: 1 s).
int cleanStepsFor(SessionKind kind) => ((kind == SessionKind.meditation ? BellRule.windowS : 1.0) / stepS).round();

class Replayer {
  /// [donors]: control streams spliced end to end; when the session outlasts them, they start again.
  Replayer(List<List<Control>> donors, {required this.cleanSteps}) : _stream = [for (final d in donors) ...d] {
    if (_stream.isEmpty) throw ArgumentError.value(donors, 'donors', 'nothing to replay');
  }

  final List<Control> _stream;
  final int cleanSteps;
  int _at = 0;
  int _sinceGate = 1 << 30;

  /// Steps replayed so far.
  int get steps => _at;

  /// The control to play for one live step: [live] is what the live session would play, [gated] whether a
  /// live gate is on now. The donor stream advances one step either way, so it keeps the session's time.
  Control next(Control live, {required bool gated}) {
    final d = _stream[_at % _stream.length];
    _at++;
    if (gated) {
      _sinceGate = 0;
      return (level: live.level, rough: live.rough, reward: null, gated: true);
    }
    _sinceGate++;
    return (level: d.level, rough: live.rough, reward: _sinceGate >= cleanSteps ? d.reward : null, gated: d.gated);
  }
}

/// An earlier live session that could be replayed: its file stem, start, seconds of run and its rewards per
/// minute. Replay sessions are never donors.
typedef DonorCandidate = ({String stem, DateTime start, double runS, double rate});

/// How many recent live sessions are considered, and the share a donor's reward rate may differ from their
/// median before closer ones are preferred (the research report: the last 5-10, ±10 %).
const int donorPool = 10;
const double donorRateBand = 0.1;

/// Donors for a replay of [neededS] seconds: from the newest [donorPool] candidates with at least a minute
/// of run, those within ±10 % of the pool's median reward rate first (then the closest), the least used
/// first ([used]: stem -> times replayed), then the newest. Further donors are spliced on until their run
/// covers [neededS]; when the whole pool is shorter, the replay loops it. Empty when there is no candidate.
List<String> pickDonors(List<DonorCandidate> candidates, double neededS, Map<String, int> used) {
  final pool = [
    for (final c in candidates)
      if (c.runS >= 60) c,
  ]..sort((a, b) => b.start.compareTo(a.start));
  final recent = pool.take(donorPool).toList();
  if (recent.isEmpty) return const [];
  final rates = [for (final c in recent) c.rate]..sort();
  final mid = rates.length.isOdd
      ? rates[rates.length ~/ 2]
      : (rates[rates.length ~/ 2 - 1] + rates[rates.length ~/ 2]) / 2;
  double off(DonorCandidate c) => mid == 0 ? c.rate : (c.rate - mid).abs() / mid;
  int key(DonorCandidate c) => off(c) <= donorRateBand + 1e-9 ? 0 : 1;
  final order = [...recent]
    ..sort((a, b) {
      final k = key(a).compareTo(key(b));
      if (k != 0) return k;
      if (key(a) == 1) {
        final o = off(a).compareTo(off(b));
        if (o != 0) return o;
      }
      final u = (used[a.stem] ?? 0).compareTo(used[b.stem] ?? 0);
      return u != 0 ? u : b.start.compareTo(a.start);
    });
  final out = <String>[];
  var total = 0.0;
  for (final c in order) {
    if (total >= neededS) break;
    out.add(c.stem);
    total += c.runS;
  }
  return out;
}
