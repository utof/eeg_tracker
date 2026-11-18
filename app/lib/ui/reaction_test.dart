// A 1-minute reaction test (alpha-theta's alertness check, DECISIONS row 107): a dark panel, a green dot after a
// random 2-5 s wait, tap the panel as fast as you can. A tap with no dot is a false start. The dot is the
// meditation's still green mark (DESIGN.md): nothing flashes, nothing moves.
import 'dart:async';

import 'package:flutter/material.dart';

import '../alphatheta/rules.dart';
import 'theme.dart';

class ReactionPanel extends StatefulWidget {
  const ReactionPanel({super.key, required this.onDone, this.lengthS = 60, this.seed, this.onTest});

  /// The median reaction (ms), or null with too few taps.
  final ValueChanged<int?> onDone;

  /// The finished test itself (taps, false starts, lapses), for a caller that keeps more than the median.
  final ValueChanged<ReactionTest>? onTest;
  final int lengthS;
  final int? seed;

  @override
  State<ReactionPanel> createState() => _ReactionPanelState();
}

class _ReactionPanelState extends State<ReactionPanel> {
  ReactionTest? _test;
  final Stopwatch _clock = Stopwatch();
  final Stopwatch _shown = Stopwatch();
  Timer? _next, _end, _tick;
  bool _dot = false;
  int? _result;
  bool _done = false;

  void _start() {
    _end?.cancel();
    _tick?.cancel();
    _test = ReactionTest(seed: widget.seed, lengthS: widget.lengthS);
    _clock
      ..reset()
      ..start();
    _done = false;
    _result = null;
    _schedule();
    _end = Timer(Duration(seconds: widget.lengthS), _finish);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() {});
  }

  void _schedule() {
    _next?.cancel();
    _next = Timer(Duration(milliseconds: _test!.nextWaitMs()), () {
      if (!mounted || _done) return;
      _shown
        ..reset()
        ..start();
      setState(() => _dot = true);
    });
  }

  void _tap() {
    final t = _test;
    if (t == null || _done) return;
    if (_dot) {
      t.tap(_shown.elapsedMilliseconds);
      setState(() => _dot = false);
      _schedule();
    } else {
      t.early();
      _schedule(); // a false start waits again from now
      setState(() {});
    }
  }

  void _finish() {
    _next?.cancel();
    _tick?.cancel();
    _clock.stop();
    if (!mounted) return;
    setState(() {
      _done = true;
      _dot = false;
      _result = _test?.median;
    });
    widget.onDone(_result);
    final t = _test;
    if (t != null) widget.onTest?.call(t);
  }

  @override
  void dispose() {
    _next?.cancel();
    _end?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final t = _test;
    final running = t != null && !_done;
    final left = widget.lengthS - _clock.elapsed.inSeconds;
    final words = !running && !_done
        ? 'Tap Start, then tap this panel as soon as the green dot appears. About a minute.'
        : running
        ? '${left.clamp(0, widget.lengthS)} s left · ${t.times.length} taps${t.falseStarts > 0 ? ' · ${t.falseStarts} too early' : ''}'
        : _result == null
        ? 'Too few taps to measure. Try again.'
        : 'Median $_result ms over ${t!.times.length} taps.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: running,
          label: _dot ? 'Green dot: tap now' : 'Reaction test panel',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: running ? (_) => _tap() : null,
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                color: Night.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Night.rule),
              ),
              alignment: Alignment.center,
              child: _dot
                  ? Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Night.live),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          words,
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
        ),
        if (!running)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(_done ? 'Test again' : 'Start the test'),
            ),
          ),
      ],
    );
  }
}
