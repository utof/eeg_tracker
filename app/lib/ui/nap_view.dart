// The nap coach's layout from a plain view model, so every state renders in tests without a phone.
// Structure (.impeccable/surfaces/app-lib-ui-nap-screen-dart.md): between naps one scrolling column (status, the plan
// drawn on the sleep report's worded ladder, the length, the last nap's ladder and lines, earlier naps) with Lights off
// pinned; during a nap a true-black face with one dim word, the minutes and whether the sleep model is on; at the wake
// a screen-wide "I'm awake".
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../detectors/drift_off.dart' show DriftState;
import '../nap/controller.dart' show NapLive, NapStage;
import '../nap/rules.dart';
import '../nap/store.dart';
import '../recorder/nights.dart' show nightLabel;
import '../sleep/live_stager.dart' show LiveMode;
import 'dream_view.dart' show clock, faceGround, faceInk, faceMuted;
import 'meditation_view.dart' show MarkShape, StateMark;
import 'parts.dart';
import 'theme.dart';

class NapViewModel {
  const NapViewModel({
    required this.stage,
    this.message = '',
    this.lengthMin = NapRule.defaultMin,
    this.seconds = 0,
    this.drift,
    this.live = NapLive.starting,
    this.liveNote,
    this.lightSleep = false,
    this.noData = false,
    this.end,
    this.notes = const [],
    this.nightRunning = false,
    this.latest,
    this.justEnded = false,
    this.earlier = const [],
  });

  final NapStage stage;
  final String message;

  /// The length picked (and of the nap running now), minutes from Lights off.
  final int lengthMin;

  /// Seconds since Lights off.
  final double seconds;

  /// The drift-off detector's state (null during the first minute's baseline).
  final DriftState? drift;
  final NapLive live;
  final String? liveNote;

  /// The sleep model's newest stage is light sleep (N1 or N2).
  final bool lightSleep;
  final bool noData;

  /// Why the wake came (while waking).
  final NapEnd? end;

  /// Plain sentences in amber (the EEG or the nap could not be saved).
  final List<String> notes;

  /// A night is being recorded: the headband is taken.
  final bool nightRunning;

  /// The newest nap (its report comes first), and whether it has just ended.
  final NapSession? latest;
  final bool justEnded;
  final List<NapSession> earlier;

  bool get face => stage.index >= NapStage.connecting.index && stage.index <= NapStage.waking.index;
}

String _num(double m) => m == m.roundToDouble() ? '${m.round()}' : m.toStringAsFixed(1);
String _min(double m) => '${_num(m)} min';

/// Why a nap ended, in a few words.
String endWords(NapSession s) => switch (s.end) {
  NapEnd.deepSleep => 'woke you before deep sleep',
  NapEnd.length => 'woke you at ${s.lengthMin} min',
  NapEnd.stopped => 'stopped',
  null => 'did not finish',
};

/// An earlier nap's line: its length, sleep and why it ended.
String napLine(NapSession s) => [
  '${s.lengthMin} min',
  if (s.onsetS != null) 'asleep after ${_min((s.onsetS! / 60).roundToDouble())}' else 'no sleep seen',
  endWords(s),
].join(' · ');

class NapView extends StatelessWidget {
  const NapView({
    super.key,
    required this.model,
    required this.onLength,
    required this.onLightsOff,
    required this.onStop,
    required this.onAwake,
    required this.onOpen,
    required this.onInfo,
  });

  final NapViewModel model;
  final ValueChanged<int> onLength;
  final VoidCallback onLightsOff;
  final VoidCallback onStop;
  final VoidCallback onAwake;
  final ValueChanged<NapSession> onOpen;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) => model.face
      ? (model.stage == NapStage.waking ? _wake(context) : _face(context))
      : _page(context);

  // ---- between naps ----

  Widget _page(BuildContext context) {
    final m = model, latest = m.latest;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Nap coach', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says', color: Night.inkMuted),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _status(context),
          for (final n in m.notes)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(n, style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4)),
            ),
          if (m.justEnded && latest != null) ...[
            const SectionHeading('This nap'),
            NapReport(session: latest),
          ],
          const SectionHeading('The plan'),
          NapLadder.plan(lengthMin: m.lengthMin),
          const SizedBox(height: 20),
          _lengths(context),
          const SizedBox(height: 14),
          Text(
            'It ends at whichever comes first. The sound is soft, then a little louder every '
            '${NapRule.wakeEveryS} seconds, until you tap "I\'m awake".',
            style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
          ),
          if (!m.justEnded && latest != null) ...[
            const SectionHeading('Last nap'),
            NapReport(session: latest),
          ],
          const SectionHeading('Before you lie down'),
          const _Note(Icons.airline_seat_flat_angled_outlined, 'Lie on your side or half reclined: lying flat on your back presses the back electrodes.'),
          const _Note(Icons.volume_down_outlined, 'The wake sound plays from the phone\'s speaker. Set the media volume to where you would hear an alarm.'),
          const _Note(Icons.dark_mode_outlined, 'The screen stays on, black and dim. Keep the app open: locking the phone can stop the nap.'),
          _Note(Icons.info_outline, 'The sleep stages are a first guess, not yet checked on this headband. The i button says what the research shows.', onTap: onInfo),
          if (m.earlier.isNotEmpty) ...[
            const SectionHeading('Earlier naps'),
            for (final (i, s) in m.earlier.indexed) _earlierRow(context, s, last: i == m.earlier.length - 1),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: FilledButton.icon(
            onPressed: m.nightRunning ? null : onLightsOff,
            icon: Icon(m.stage == NapStage.failed ? Icons.refresh : Icons.bedtime_outlined),
            label: Text(m.stage == NapStage.failed ? 'Try again' : 'Lights off'),
          ),
        ),
      ),
    );
  }

  Widget _status(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme, latest = m.latest;
    final (String word, String sentence, MarkShape mark, Color color) = switch (m.stage) {
      _ when m.nightRunning => (
        'Night recording',
        'The headband is busy recording the night. A nap can start after Stop.',
        MarkShape.ringedDot,
        Night.caution,
      ),
      NapStage.failed => ('Could not start', m.message, MarkShape.dash, Night.problem),
      _ when m.justEnded && latest != null => ('Nap over', _overSentence(latest), MarkShape.ring, Night.inkMuted),
      _ => (
        'Ready',
        'Headband on, lie down, tap Lights off. The nap ends before deep sleep starts, or at ${m.lengthMin} minutes.',
        MarkShape.ring,
        Night.inkMuted,
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StateMark(shape: mark, color: color),
              const SizedBox(width: 14),
              Expanded(child: Text(word, style: text.displaySmall)),
            ],
          ),
          if (sentence.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              sentence,
              style: text.bodyLarge?.copyWith(color: m.stage == NapStage.failed ? Night.problem : Night.inkMuted, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  static String _overSentence(NapSession s) => switch (s.end) {
    NapEnd.deepSleep => 'Deep sleep was starting, so it woke you before it settled.',
    NapEnd.length => 'Your ${s.lengthMin} minutes were up${s.deepEpoch == null ? '; no deep sleep was seen' : ''}.',
    NapEnd.stopped => 'You stopped it after ${(s.endS / 60).round()} min.',
    null => 'The nap did not finish.',
  };

  Widget _lengths(BuildContext context) => SizedBox(
    width: double.infinity,
    child: SegmentedButton<int>(
      segments: [for (final v in NapRule.lengthsMin) ButtonSegment(value: v, label: Text('$v min'))],
      selected: {model.lengthMin},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onLength(s.first),
      style: SegmentedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        selectedBackgroundColor: Night.surfaceHigh,
        selectedForegroundColor: Night.ink,
        foregroundColor: Night.inkMuted,
        side: const BorderSide(color: Night.rule),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
    ),
  );

  Widget _earlierRow(BuildContext context, NapSession s, {required bool last}) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => onOpen(s),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: last ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${nightLabel(s.start)}, ${clock(s.start)}', style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(napLine(s), style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Night.inkMuted),
          ],
        ),
      ),
    );
  }

  // ---- the nap face ----

  Widget _face(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final started = m.stage == NapStage.resting;
    final (String word, String sentence) = switch (m.stage) {
      NapStage.connecting => ('Connecting', m.message),
      NapStage.contact => ('Checking contact', 'Lie still for a few seconds.'),
      _ when m.drift == null => ('Eyes closed', 'The first minute sets your starting level. Then just rest.'),
      _ when m.drift == DriftState.asleep || m.lightSleep => ('Asleep', 'It wakes you before deep sleep, or at ${m.lengthMin} min.'),
      _ when m.drift == DriftState.drowsy => ('Drifting', 'Let it come.'),
      _ => ('Resting', 'Let your thoughts go. Nothing to do.'),
    };
    final minutes = (m.seconds / 60).floor();
    return Scaffold(
      backgroundColor: faceGround,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(flex: 3),
              Semantics(liveRegion: true, child: Text(word, style: text.headlineMedium?.copyWith(color: faceInk))),
              const SizedBox(height: 10),
              Text(sentence, style: text.bodyLarge?.copyWith(color: faceMuted, height: 1.4)),
              if (started) ...[
                const SizedBox(height: 16),
                Text('$minutes of ${m.lengthMin} min', style: text.bodyMedium?.copyWith(color: faceMuted, fontFeatures: tabular)),
                const SizedBox(height: 6),
                _modelLine(context),
              ],
              const Spacer(flex: 4),
              OutlinedButton.icon(
                onPressed: onStop,
                style: OutlinedButton.styleFrom(foregroundColor: faceMuted, side: const BorderSide(color: Night.rule)),
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modelLine(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final dimCaution = Night.caution.withValues(alpha: 0.72);
    final (String line, Color color) = switch (m.live) {
      NapLive.starting when m.liveNote != null => (m.liveNote!, dimCaution),
      NapLive.starting => ('Sleep model: starts after 5 minutes.', faceMuted),
      NapLive.on => ('Sleep model on.', faceMuted),
      NapLive.light => ('Sleep model on, lighter (1 run).', faceMuted),
      NapLive.poor || NapLive.timer => (m.liveNote ?? 'Timer only.', dimCaution),
    };
    return Text(line, style: text.bodyMedium?.copyWith(color: color, height: 1.4));
  }

  /// The wake: the screen at its normal brightness and one target almost as big as the screen.
  Widget _wake(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final why = switch (m.end) {
      NapEnd.deepSleep => 'Deep sleep was starting.',
      _ => 'Your ${m.lengthMin} minutes are up.',
    };
    return Scaffold(
      backgroundColor: Night.ground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(liveRegion: true, child: Text('Time to wake up', style: text.displaySmall)),
              const SizedBox(height: 10),
              Text(
                '$why The sound comes a little louder every ${NapRule.wakeEveryS} seconds until you tap.',
                style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 28),
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onAwake,
                    style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.wb_twilight_outlined, size: 48),
                        const SizedBox(height: 16),
                        Text("I'm awake", style: text.displaySmall?.copyWith(color: Night.onLiveFill)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A nap's report: the ladder of what happened, then label-left / value-right lines.
class NapReport extends StatelessWidget {
  const NapReport({super.key, required this.session});
  final NapSession session;

  @override
  Widget build(BuildContext context) {
    final s = session, text = Theme.of(context).textTheme, mins = s.minutes;
    final light = (mins['1'] ?? 0) + (mins['2'] ?? 0), deep = mins['3'] ?? 0, dream = mins['R'] ?? 0;
    final rows = <(String, String)>[
      ('Lights off', '${nightLabel(s.start)}, ${clock(s.start)}'),
      ('Fell asleep', s.onsetS == null ? 'not seen' : 'after ${_min((s.onsetS! / 60).roundToDouble())}'),
      ('Asleep', _min(s.asleepMin)),
      ('Stages', 'light ${_num(light)}, deep ${_num(deep)}, dream ${_num(dream)} min'),
      ('Woke you', switch (s.end) {
        NapEnd.deepSleep => 'at ${((s.wakeS ?? s.endS) / 60).round()} min, deep sleep starting',
        NapEnd.length => 'at ${s.lengthMin} min, your length',
        NapEnd.stopped => 'stopped at ${(s.endS / 60).round()} min',
        null => 'the nap did not finish',
      }),
      if (s.upS != null && s.wakeS != null) ('Up after', '${(s.upS! - s.wakeS!).round()} s of sound'),
      ('Sleep model', _modelWords(s.live)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NapLadder.record(session: s),
        const SizedBox(height: 8),
        for (final (i, (label, value)) in rows.indexed)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: i == rows.length - 1 ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
                const SizedBox(width: 16),
                Expanded(child: Text(value, textAlign: TextAlign.right, style: text.bodyLarge?.copyWith(fontFeatures: tabular))),
              ],
            ),
          ),
        if (s.live.why != null && s.live.mode != LiveMode.full) ...[
          const SizedBox(height: 10),
          Text(s.live.why!, style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4)),
        ],
        const SizedBox(height: 10),
        Text(
          '"Fell asleep" is the alpha rule\'s onset; the stages are the sleep model read 2 minutes behind, a first guess '
          'not yet checked on this headband.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
      ],
    );
  }

  static String _modelWords(NapLiveInfo l) {
    final per = l.medianMs == null ? '' : ', ${(l.medianMs! / 1000).toStringAsFixed(1)} s a check';
    return switch (l.mode) {
      LiveMode.full => '3 runs$per',
      LiveMode.light => '1 run$per',
      LiveMode.timer => l.calls == 0 ? 'timer only' : 'timer only at the end$per',
    };
  }
}

/// The sleep report's worded ladder (Awake, Dream, Light, Deep on track lanes) for one nap: the plan before it, or
/// what happened.
class NapLadder extends StatelessWidget {
  const NapLadder.plan({super.key, required this.lengthMin}) : session = null;
  const NapLadder.record({super.key, required NapSession this.session}) : lengthMin = 0;

  final int lengthMin;
  final NapSession? session;

  static const List<String> levels = ['Awake', 'Dream', 'Light', 'Deep'];
  static const double lane = 30;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme, scaler = MediaQuery.textScalerOf(context);
    final word = text.bodyMedium!.copyWith(color: Night.inkMuted);
    final tick = text.bodyMedium!.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    final mark = text.bodyMedium!.copyWith(color: Night.ink);
    double h(TextStyle s) => (TextPainter(text: TextSpan(text: '0', style: s), textScaler: scaler, textDirection: TextDirection.ltr)..layout()).height;
    final laneH = math.max(lane, h(word) + 8);
    final s = session;
    final label = s == null
        ? 'The plan: awake, then light sleep; it wakes you when deep sleep starts, or at $lengthMin minutes.'
        : 'What happened: ${s.stages.length ~/ 2} minutes, ${endWords(s)}.';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        width: double.infinity,
        height: 4 * laneH + h(tick) + 10 + (s == null ? 0 : h(mark) + 6),
        child: CustomPaint(
          painter: _LadderPainter(
            lengthMin: s?.lengthMin ?? lengthMin,
            session: s,
            lane: laneH,
            top: s == null ? 0 : h(mark) + 6,
            scaler: scaler,
            word: word,
            tick: tick,
            mark: mark,
          ),
        ),
      ),
    );
  }
}

class _LadderPainter extends CustomPainter {
  _LadderPainter({
    required this.lengthMin,
    required this.session,
    required this.lane,
    required this.top,
    required this.scaler,
    required this.word,
    required this.tick,
    required this.mark,
  });

  final int lengthMin;
  final NapSession? session;
  final double lane, top;
  final TextScaler scaler;
  final TextStyle word, tick, mark;

  TextPainter _tp(String s, TextStyle style) =>
      TextPainter(text: TextSpan(text: s, style: style), textScaler: scaler, textDirection: TextDirection.ltr)..layout();

  static int? _level(String letter) => switch (letter) {
    'W' => 0,
    'R' => 1,
    '1' || '2' => 2,
    '3' => 3,
    _ => null,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final words = [for (final l in NapLadder.levels) _tp(l, word)];
    final left = words.map((t) => t.width).reduce(math.max) + 12;
    final right = size.width - 2;
    final s = session;
    final totalMin = s == null ? lengthMin.toDouble() : math.max(s.lengthMin.toDouble(), s.endS / 60);
    double x(double min) => left + (right - left) * (min / totalMin).clamp(0.0, 1.0);
    double y(int level) => top + level * lane + lane / 2;
    final trackPaint = Paint()..color = Night.track;
    for (var i = 0; i < 4; i++) {
      canvas.drawRect(Rect.fromLTRB(left, top + i * lane + 1, right, top + (i + 1) * lane - 1), trackPaint);
      words[i].paint(canvas, Offset(0, y(i) - words[i].height / 2));
    }
    // minute rules every 10 minutes (every 30 for the long nap), labelled under the ladder
    final step = totalMin > 60 ? 30 : 10;
    final rule = Paint()
      ..color = Night.rule
      ..strokeWidth = 1;
    final bottom = top + 4 * lane;
    for (var mm = 0; mm <= totalMin + 0.01; mm += step) {
      final xx = x(mm.toDouble());
      canvas.drawLine(Offset(xx, top), Offset(xx, bottom), rule);
      final t = _tp(mm == 0 ? '0' : '$mm', tick);
      final at = (xx - t.width / 2).clamp(left, right - t.width);
      t.paint(canvas, Offset(at, bottom + 6));
    }
    if (s == null) {
      _plan(canvas, x, y, bottom);
    } else {
      _record(canvas, s, x, y, bottom);
    }
  }

  /// The plan: a dashed line from Awake falling to Light, a short ink bar on Deep ("wakes you here"), the length's rule.
  void _plan(Canvas canvas, double Function(double) x, double Function(int) y, double bottom) {
    final ink = Paint()
      ..color = Night.ink
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final total = lengthMin.toDouble();
    final fall = math.min(8.0, total * 0.3), deepAt = math.min(total * 0.75, fall + 14);
    final path = [Offset(x(0), y(0)), Offset(x(fall), y(0)), Offset(x(fall), y(2)), Offset(x(deepAt), y(2)), Offset(x(deepAt), y(3) - lane / 4)];
    for (var i = 0; i + 1 < path.length; i++) {
      _dashed(canvas, path[i], path[i + 1], ink);
    }
    final bar = Paint()
      ..color = Night.ink
      ..strokeWidth = 3;
    canvas.drawLine(Offset(x(deepAt) - 10, y(3) - lane / 4), Offset(x(deepAt) + 10, y(3) - lane / 4), bar);
    final here = _tp('wakes you here', word.copyWith(color: Night.ink));
    final hx = math.min(x(deepAt) + 14, x(total) - here.width - 8);
    here.paint(canvas, Offset(hx, y(3) - here.height / 2));
    // the length: an ink rule at the right edge, worded above the lanes' end
    canvas.drawLine(Offset(x(total), y(0) - lane / 2), Offset(x(total), bottom), bar..strokeWidth = 2);
    final or = _tp('or at $lengthMin min', word.copyWith(color: Night.ink));
    or.paint(canvas, Offset(x(total) - or.width - 8, y(1) - or.height / 2));
  }

  /// What happened: the step line of the live stages (gaps hatched amber, unscored left empty) and the wake.
  void _record(Canvas canvas, NapSession s, double Function(double) x, double Function(int) y, double bottom) {
    final ink = Paint()
      ..color = Night.ink
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final hatch = Paint()
      ..color = Night.caution.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    Path? path;
    int? prev;
    for (var e = 0; e < s.stages.length; e++) {
      final letter = s.stages[e];
      final l = _level(letter);
      final x0 = x(e / 2), x1 = x((e + 1) / 2);
      if (letter == 'g') {
        for (var hx = x0; hx < x1; hx += 4) {
          canvas.drawLine(Offset(hx, top + 1), Offset(math.min(hx + 4, x1), bottom - 1), hatch);
        }
      }
      if (l == null) {
        if (path != null) canvas.drawPath(path, ink);
        path = null;
        prev = null;
        continue;
      }
      if (path == null) {
        path = Path()..moveTo(x0, y(l));
      } else if (prev != l) {
        path.lineTo(x0, y(l));
      }
      path.lineTo(x1, y(l));
      prev = l;
    }
    if (path != null) canvas.drawPath(path, ink);
    final wake = s.wakeS ?? (s.end == NapEnd.stopped ? s.endS : null);
    if (wake != null) {
      final xx = x(wake / 60);
      canvas.drawLine(Offset(xx, top - 2), Offset(xx, bottom), Paint()..color = Night.ink..strokeWidth = 2);
      final t = _tp(s.end == NapEnd.stopped ? 'stopped' : 'woke you', mark);
      t.paint(canvas, Offset((xx - t.width / 2).clamp(x(0), x(math.max(s.lengthMin.toDouble(), s.endS / 60)) - t.width), 0));
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint p) {
    final d = (b - a).distance;
    if (d == 0) return;
    const dash = 6.0, gap = 5.0;
    final dir = (b - a) / d;
    for (var t = 0.0; t < d; t += dash + gap) {
      canvas.drawLine(a + dir * t, a + dir * math.min(t + dash, d), p);
    }
  }

  @override
  bool shouldRepaint(_LadderPainter old) => old.lengthMin != lengthMin || old.session != session || old.lane != lane;
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: Night.inkMuted),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
