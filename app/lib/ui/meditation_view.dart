// The meditation screen's layout from a plain view model, so every state renders in tests without a phone.
// Structure (.impeccable/surfaces/app-lib-ui-meditation-screen-dart.md): status mark and word, the phase
// track, two readouts (time left, bells), then the state's own section; one action pinned at the bottom.
import 'package:flutter/material.dart';

import '../meditation/controller.dart' show Stage;
import '../meditation/tracker.dart';
import '../recorder/contact.dart';
import '../recorder/nights.dart' show nightLabel;
import 'parts.dart';
import 'phase_track.dart';
import 'theme.dart';

/// Session lengths on offer (minutes).
const List<int> sessionMinutes = [5, 10, 20];

enum MarkShape { filled, ringedDot, ring, dash }

class MeditationViewModel {
  const MeditationViewModel({
    required this.stage,
    required this.minutes,
    required this.title,
    required this.sentence,
    required this.mark,
    required this.markColor,
    this.sentenceColor = Night.inkMuted,
    this.openDone = 0,
    this.closedDone = 0,
    this.sessionDone = 0,
    this.live,
    this.timeLeft,
    this.timeLabel = 'left',
    this.bells,
    this.contact = const {},
    this.notes = const [],
    this.report,
    this.comparison = '',
    this.earlier = const [],
    this.nightRunning = false,
  });

  final Stage stage;
  final int minutes;
  final String title;
  final String sentence;
  final Color sentenceColor;
  final MarkShape mark;
  final Color markColor;
  final double openDone, closedDone, sessionDone;
  final TrackPart? live;

  /// Seconds left in the current part; null = no readout yet.
  final int? timeLeft;
  final String timeLabel;
  final int? bells;
  final Map<String, double?> contact;

  /// Plain sentences shown under the readouts in amber (sound off, not saved).
  final List<String> notes;
  final MeditationSummary? report;
  final String comparison;
  final List<MeditationSummary> earlier;

  /// A night is being recorded: the headband is taken, so Start is off.
  final bool nightRunning;
}

/// The model for the controller's state (pure; the screen passes the controller's fields).
MeditationViewModel meditationModel({
  required Stage stage,
  required int minutes,
  String message = '',
  Moment chip = Moment.calibrating,
  String? calPhase,
  int calSecondsLeft = 0,
  bool calNeedsClean = false,
  double runSeconds = 0,
  int bells = 0,
  Map<String, double?> contact = const {},
  String? soundNote,
  String? saveNote,
  MeditationSummary? report,
  String comparison = '',
  List<MeditationSummary> earlier = const [],
  bool nightRunning = false,
}) {
  final lengthS = minutes * 60.0;
  final notes = [?soundNote, ?saveNote];
  MeditationViewModel m(
    String title,
    String sentence,
    MarkShape mark,
    Color color, {
    Color sentenceColor = Night.inkMuted,
    double open = 0,
    double closed = 0,
    double session = 0,
    TrackPart? live,
    int? timeLeft,
    String timeLabel = 'left',
    int? bellCount,
  }) => MeditationViewModel(
    stage: stage,
    minutes: minutes,
    title: title,
    sentence: sentence,
    sentenceColor: sentenceColor,
    mark: mark,
    markColor: color,
    openDone: open,
    closedDone: closed,
    sessionDone: session,
    live: live,
    timeLeft: timeLeft,
    timeLabel: timeLabel,
    bells: bellCount,
    contact: contact,
    notes: notes,
    report: report,
    comparison: comparison,
    earlier: earlier,
    nightRunning: nightRunning,
  );

  switch (stage) {
    case Stage.setup:
      if (nightRunning) {
        return m(
          'Night recording',
          'A night is being recorded, and the headband connects to one thing at a time. Stop the night first.',
          MarkShape.ringedDot,
          Night.caution,
          sentenceColor: Night.caution,
        );
      }
      return m(
        'Ready',
        message.isNotEmpty
            ? message
            : 'Headband on, headphones in. First 1½ minutes in silence: 30 s eyes open, then a low tone and '
                  '60 s eyes closed. Then the sound follows you.',
        MarkShape.ring,
        Night.inkMuted,
      );
    case Stage.connecting:
      return m('Connecting', message, MarkShape.ring, Night.inkMuted);
    case Stage.contact:
      return m('Checking contact', 'Keep still for a few seconds.', MarkShape.ring, Night.inkMuted);
    case Stage.calibrating:
      if (calPhase == 'closed') {
        return m(
          'Eyes closed',
          calNeedsClean
              ? 'Keep your eyes closed: a little more quiet signal is needed (jaw loose, few blinks).'
              : 'Relax and let the eyes rest. When the tone sounds again, the sound begins.',
          MarkShape.ring,
          Night.live,
          open: 1,
          closed: calNeedsClean ? 1 : 1 - calSecondsLeft / 60,
          live: TrackPart.closed,
          timeLeft: calSecondsLeft,
          timeLabel: calNeedsClean ? 'of quiet signal still needed' : 'eyes closed, left',
        );
      }
      return m(
        'Eyes open',
        'Look at the green dot. Jaw loose, shoulders soft. A low tone tells you to close your eyes.',
        MarkShape.filled,
        Night.live,
        open: 1 - calSecondsLeft / 30,
        live: TrackPart.open,
        timeLeft: calSecondsLeft,
        timeLabel: 'eyes open, left',
      );
    case Stage.running:
      final (word, sentence, shape, color) = switch (chip) {
        Moment.settled => ('Settled', 'Eyes closed. Nothing to do: just notice the sound.', MarkShape.filled, Night.live),
        Moment.restless => (
          'Restless',
          'Jaw, eyes or head moving. The bells wait until it is quiet again.',
          MarkShape.ringedDot,
          Night.caution,
        ),
        Moment.drifting => (
          'Drifting',
          'Alpha slowed: drifting toward sleep, or eyes open. The rain brightens a little.',
          MarkShape.ring,
          Night.problem,
        ),
        Moment.noSignal => (
          'No signal',
          'Nothing from the headband. The session pauses until it is back.',
          MarkShape.dash,
          Night.problem,
        ),
        Moment.settling || Moment.calibrating => (
          'Settling',
          'Eyes closed. Nothing to do: just notice the sound.',
          MarkShape.ring,
          Night.inkMuted,
        ),
      };
      return m(
        word,
        sentence,
        shape,
        color,
        sentenceColor: chip == Moment.noSignal ? Night.problem : Night.inkMuted,
        open: 1,
        closed: 1,
        session: runSeconds / lengthS,
        live: TrackPart.session,
        timeLeft: (lengthS - runSeconds).ceil().clamp(0, 1 << 20),
        bellCount: bells,
      );
    case Stage.ending:
      return m(
        'Session over',
        message,
        MarkShape.filled,
        Night.live,
        open: 1,
        closed: 1,
        session: runSeconds / lengthS,
        timeLeft: (lengthS - runSeconds).ceil().clamp(0, 1 << 20),
        bellCount: bells,
      );
    case Stage.report:
      final r = report!;
      return m(
        r.complete ? 'Session over' : 'Stopped early',
        comparison,
        MarkShape.filled,
        Night.live,
        open: 1,
        closed: 1,
        session: r.runS / lengthS,
        timeLeft: r.settledS.round(),
        timeLabel: 'settled, of ${_minSecWords(r.runS)}',
        bellCount: r.bells,
      );
    case Stage.failed:
      return m('Could not start', message, MarkShape.dash, Night.problem, sentenceColor: Night.problem);
  }
}

String _minSecWords(double s) {
  final t = s.round();
  if (t < 60) return '$t s';
  return t % 60 == 0 ? '${t ~/ 60} min' : '${t ~/ 60} min ${t % 60} s';
}

List<(String, bool)> _minSec(int s) {
  if (s < 60) return [('$s', true), (' s', false)];
  return [('${s ~/ 60}', true), (' min ', false), ((s % 60).toString().padLeft(2, '0'), true), (' s', false)];
}

class MeditationView extends StatelessWidget {
  const MeditationView({
    super.key,
    required this.model,
    required this.onMinutes,
    required this.onStart,
    required this.onStop,
    required this.onDone,
    required this.onInfo,
  });

  final MeditationViewModel model;
  final ValueChanged<int> onMinutes;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onDone;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Meditation', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(
            onPressed: onInfo,
            icon: const Icon(Icons.info_outline),
            tooltip: 'What the research says',
            color: Night.inkMuted,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _Status(m),
          const SizedBox(height: 28),
          PhaseTrack(
            sessionSeconds: m.minutes * 60.0,
            openDone: m.openDone,
            closedDone: m.closedDone,
            sessionDone: m.sessionDone,
            live: m.live,
            calm: m.stage == Stage.report ? m.report?.calm : null,
            marks: m.stage == Stage.report ? m.report?.marks ?? const [] : const [],
          ),
          const SizedBox(height: 10),
          _Legend(m),
          if (m.timeLeft != null || m.bells != null) ...[const SizedBox(height: 28), _Readouts(m)],
          for (final n in m.notes)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(n, style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4)),
            ),
          ..._body(context),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 16), child: _action()),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final m = model;
    switch (m.stage) {
      case Stage.setup:
      case Stage.failed:
        return [
          const SectionHeading('Length'),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: [for (final v in sessionMinutes) ButtonSegment(value: v, label: Text('$v min'))],
              selected: {m.minutes},
              showSelectedIcon: false,
              onSelectionChanged: (s) => onMinutes(s.first),
              style: SegmentedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                selectedBackgroundColor: Night.surfaceHigh,
                selectedForegroundColor: Night.ink,
                foregroundColor: Night.inkMuted,
                side: const BorderSide(color: Night.rule),
              ),
            ),
          ),
          const SectionHeading('Before you start'),
          const _Note(
            Icons.headphones_outlined,
            'Wired headphones or the phone\'s speaker. Bluetooth headphones add about 0.3 s, so the sound '
            'follows you late.',
          ),
          const _Note(
            Icons.smartphone_outlined,
            'The screen stays on while you meditate. Keep the app open: locking the phone can stop the session.',
          ),
          _Note(
            Icons.info_outline,
            'A guided eyes-closed practice, not a treatment. The evidence for sound feedback is weak; the i '
            'button says what the research shows.',
            onTap: onInfo,
          ),
        ];
      case Stage.connecting:
      case Stage.contact:
        return const [];
      case Stage.calibrating:
      case Stage.running:
      case Stage.ending:
        return [if (m.contact.isNotEmpty) ...[const SectionHeading('Contact at the start'), _Contact(m.contact)]];
      case Stage.report:
        return _report(context, m.report!);
    }
  }

  List<Widget> _report(BuildContext context, MeditationSummary r) {
    final text = Theme.of(context).textTheme;
    final pct = (r.settledShare * 100).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return [
      const SectionHeading('This session'),
      _Row('Settled', '${_minSecWords(r.settledS)} · $pct %'),
      _Row('Longest settled stretch', _minSecWords(r.longestSettledS)),
      _Row(
        'Restless moments',
        '${r.restlessTotal}',
        detail:
            'jaw ${r.restless[Restless.jaw]} · blinks ${r.restless[Restless.blinks]} · '
            'movement ${r.restless[Restless.movement]}',
      ),
      _Row(
        'Drifting toward sleep',
        '${r.drifting}',
        detail: r.drowsyS > 0 ? '${_minSecWords(r.drowsyS)} in all' : null,
      ),
      _Row('Alpha peak', r.iafHz == null ? 'not clear' : '${(r.iafHz! * 4).round() / 4} Hz'),
      const SectionHeading('Earlier sessions'),
      if (model.earlier.isEmpty)
        Text('This is the first session on this phone.', style: text.bodyLarge?.copyWith(color: Night.inkMuted))
      else
        for (final e in model.earlier.take(5))
          _Row(
            '${nightLabel(e.start)}, ${two(e.start.hour)}:${two(e.start.minute)}',
            '${(e.settledShare * 100).round()} % settled',
            detail: '${_minSecWords(e.runS)} · ${e.bells} ${e.bells == 1 ? 'bell' : 'bells'}',
          ),
      Padding(
        padding: const EdgeInsets.only(top: 28),
        child: Text(
          'Practice, not treatment. These numbers say what the headband measured, not how deep the meditation '
          'was: no such signal exists at these electrodes.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
      ),
    ];
  }

  Widget _action() {
    final m = model;
    switch (m.stage) {
      case Stage.setup:
        return FilledButton.icon(
          onPressed: m.nightRunning ? null : onStart,
          icon: const Icon(Icons.self_improvement),
          label: const Text('Start meditation'),
        );
      case Stage.failed:
        return FilledButton.icon(onPressed: onStart, icon: const Icon(Icons.refresh), label: const Text('Try again'));
      case Stage.connecting:
      case Stage.contact:
        return OutlinedButton.icon(onPressed: onStop, icon: const Icon(Icons.close), label: const Text('Cancel'));
      case Stage.calibrating:
      case Stage.running:
        return OutlinedButton.icon(onPressed: onStop, icon: const Icon(Icons.stop_rounded), label: const Text('Stop'));
      case Stage.ending:
        return OutlinedButton.icon(onPressed: null, icon: const Icon(Icons.stop_rounded), label: const Text('Saving…'));
      case Stage.report:
        return OutlinedButton.icon(onPressed: onDone, icon: const Icon(Icons.check), label: const Text('Done'));
    }
  }
}

class _Status extends StatelessWidget {
  const _Status(this.m);
  final MeditationViewModel m;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StateMark(shape: m.mark, color: m.markColor),
              const SizedBox(width: 14),
              Expanded(child: Text(m.title, style: text.displaySmall)),
            ],
          ),
          if (m.sentence.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(m.sentence, style: text.bodyLarge?.copyWith(color: m.sentenceColor, height: 1.4)),
          ],
        ],
      ),
    );
  }
}

/// The DESIGN.md state marks: filled (good, live), ringed dot (caution), ring (idle or poor), dash (no reading).
/// Still, never breathing: during the eyes-open minute the filled dot is the spot to look at.
class StateMark extends StatelessWidget {
  const StateMark({super.key, required this.shape, required this.color, this.size = 14});
  final MarkShape shape;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: switch (shape) {
      MarkShape.filled => DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      MarkShape.ring => DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
      ),
      MarkShape.ringedDot => DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
        child: Center(
          child: Container(
            width: size * 0.36,
            height: size * 0.36,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
      ),
      MarkShape.dash => Center(
        child: Container(
          width: size,
          height: 2.5,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
      ),
    },
  );
}

class _Legend extends StatelessWidget {
  const _Legend(this.m);
  final MeditationViewModel m;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Night.inkMuted);
    if (m.stage != Stage.report) {
      return Text('30 s eyes open · 60 s eyes closed · ${m.minutes} min with sound', style: style);
    }
    Widget tick(Color c) => Container(
      width: 3,
      height: 10,
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(1.5)),
    );
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Line: how calm the sound was', style: style),
        Row(mainAxisSize: MainAxisSize.min, children: [tick(Night.caution), const SizedBox(width: 6), Text('restless', style: style)]),
        Row(mainAxisSize: MainAxisSize.min, children: [tick(Night.problem), const SizedBox(width: 6), Text('drifting', style: style)]),
      ],
    );
  }
}

class _Readouts extends StatelessWidget {
  const _Readouts(this.m);
  final MeditationViewModel m;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Readout(parts: m.timeLeft == null ? [('–', true)] : _minSec(m.timeLeft!), label: m.timeLabel),
        ),
        const VerticalDivider(width: 33),
        Expanded(
          child: Readout(
            parts: [(m.bells == null ? '–' : '${m.bells}', true)],
            label: m.bells == null ? 'bells, once the sound starts' : (m.bells == 1 ? 'bell' : 'bells'),
          ),
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 22, color: Night.inkMuted)),
          const SizedBox(width: 16),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: row);
  }
}

class _Contact extends StatelessWidget {
  const _Contact(this.contact);
  final Map<String, double?> contact;

  @override
  Widget build(BuildContext context) => Row(
    children: [for (final n in channelNames) Expanded(child: ContactCell(n, classifyOhms(contact[n])))],
  );
}

/// One line of the report: a muted label, the value right-aligned, an optional detail under the value.
class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.detail});
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  textAlign: TextAlign.end,
                  style: text.titleMedium?.copyWith(fontFeatures: tabular, color: Night.ink),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    textAlign: TextAlign.end,
                    style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
