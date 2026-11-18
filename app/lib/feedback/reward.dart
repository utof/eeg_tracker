// Reward rules: a target line held still for 3-minute blocks, and rare bells (DECISIONS rows 43-44).
// A line-by-line port of scripts/web/sound-reward.js, same constants. Pure: one call per analysis step;
// no clock, no randomness.
//
// Target line: starts at the 35th percentile of the person's eyes-closed baseline (about 65 % of the time
// above it at rest) and is held still for 3-minute blocks. Between blocks: above the line more than 80 % of
// the counted time -> raise it 0.15 robust SD; under 50 % -> lower it 0.15 SD. Gated steps are not counted.
// Bell: at least 3 s above the line within the last 4 s, with no gate anywhere in those 4 s; then at least
// 5 s (training) or 15 s (relax) since the last bell, and at most 6 bells in any minute.
import 'features.dart';

abstract final class LineRule {
  static const double pct = 0.35, sdFloor = 0.1, blockS = 180, raiseAbove = 0.8, lowerBelow = 0.5;
  static const double stepSd = 0.15, minCountedS = 30;
}

abstract final class BellRule {
  static const double windowS = 4, aboveS = 3;
  static const Map<String, double> gapS = {'training': 5, 'relax': 15};
  static const int perMinute = 6;
}

/// The first line and its spread, in log10 µV² units.
typedef FirstLine = ({double line, double sd});

/// [values]: log10 alpha power of clean eyes-closed steps. sd is in the same log units, never under 0.1
/// (a 26 % change), so a very steady signal does not make the sound jumpy.
FirstLine firstLine(List<double> values) {
  final m = median(values), dev = [for (final v in values) (v - m).abs()];
  final sd = 1.4826 * median(dev);
  return (line: percentile(values, LineRule.pct), sd: sd > LineRule.sdFloor ? sd : LineRule.sdFloor);
}

/// The end of a block: how much of the counted time was above the line, and where the line went.
class BlockEnd {
  const BlockEnd({
    required this.block,
    required this.share,
    required this.counted,
    required this.from,
    required this.to,
    required this.moved,
  });
  final int block;

  /// Null when no step was counted.
  final double? share;

  /// Seconds counted (not under a gate).
  final double counted;
  final double from;
  final double to;

  /// -1 lowered, 0 kept, 1 raised.
  final int moved;
}

class TargetLine {
  TargetLine(FirstLine first, [double stepS = 0.1])
    : line = first.line,
      sd = first.sd,
      _blockSteps = (LineRule.blockS / stepS).round(),
      _minCounted = (LineRule.minCountedS / stepS).round();

  double line;
  final double sd;
  int block = 1;
  final int _blockSteps;
  final int _minCounted;
  int _steps = 0;
  int _counted = 0;
  int _above = 0;

  /// [above]: true / false, or null when the step is under a gate (not counted).
  /// Returns null, or the block's result at its end.
  BlockEnd? update(bool? above, [double stepS = 0.1]) {
    _steps++;
    if (above != null) {
      _counted++;
      if (above) _above++;
    }
    if (_steps < _blockSteps) return null;
    final share = _counted != 0 ? _above / _counted : null, from = line;
    var moved = 0;
    if (_counted >= _minCounted) {
      if (share! > LineRule.raiseAbove) {
        moved = 1;
      } else if (share < LineRule.lowerBelow) {
        moved = -1;
      }
    }
    line += moved * LineRule.stepSd * sd;
    final out = BlockEnd(block: block, share: share, counted: _counted * stepS, from: from, to: line, moved: moved);
    block++;
    _steps = 0;
    _counted = 0;
    _above = 0;
    return out;
  }

  /// How far above the line, in robust SDs.
  double z(double alphaLog) => (alphaLog - line) / sd;
}

class Bells {
  Bells([String mode = 'training', double stepS = 0.1])
    : _window = (BellRule.windowS / stepS).round(),
      _need = (BellRule.aboveS / stepS).round(),
      _gap = (BellRule.gapS[mode]! / stepS).round(),
      _minute = (60 / stepS).round();

  final int _window, _need, _gap, _minute;

  /// Above flags of the last clean steps (at most one window).
  List<bool> _recent = [];

  /// Step numbers of the bells of the last minute.
  final List<int> rung = [];
  int _step = 0;

  /// [ok]: no gate and good signal at this step; [above]: alpha above the line. Returns true to ring now.
  bool update(bool ok, bool above) {
    _step++;
    while (rung.isNotEmpty && rung.first <= _step - _minute) {
      rung.removeAt(0);
    }
    if (!ok) {
      _recent = [];
      return false;
    }
    _recent.add(above);
    if (_recent.length > _window) _recent.removeAt(0);
    if (_recent.length < _window) return false;
    if (_recent.where((a) => a).length < _need) return false;
    final tooSoon = rung.isNotEmpty && _step - rung.last < _gap;
    if (tooSoon || rung.length >= BellRule.perMinute) return false;
    rung.add(_step);
    _recent = [];
    return true;
  }

  int get lastMinute => rung.length;
}
