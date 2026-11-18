// The meditation screen's layout from a plain view model, so every state renders in tests without a phone.
// Structure (.impeccable/surfaces/app-lib-ui-meditation-screen-dart.md): status mark and word, the phase
// track, two readouts (time left, bells), then the state's own section; one action pinned at the bottom.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../meditation/controller.dart' show Stage;
import '../meditation/tracker.dart';
import '../recorder/contact.dart';
import '../recorder/nights.dart' show nightLabel;
import '../training/check.dart';
import '../training/control.dart';
import 'check_views.dart';
import 'form_parts.dart';
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
    this.kind = SessionKind.meditation,
    this.checkOn = false,
    this.checkStatus,
    this.lengths = sessionMinutes,
  });

  final SessionKind kind;

  /// The replay check is on: the reminder before the session, no live bells or settled word during it.
  final bool checkOn;
  final String? checkStatus;

  /// Lengths on offer (minutes).
  final List<int> lengths;

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
  SessionKind kind = SessionKind.meditation,
  bool checkOn = false,
  String? checkStatus,
  List<int> lengths = sessionMinutes,
  bool asleepGuard = false,
}) {
  final lengthS = minutes * 60.0;
  final at = kind == SessionKind.alphaTheta;
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
    kind: kind,
    checkOn: checkOn,
    checkStatus: checkStatus,
    lengths: lengths,
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
        'Rest your eyes on the green dot below. Jaw loose, shoulders soft. A low tone tells you to close them.',
        MarkShape.ring,
        Night.live,
        open: 1 - calSecondsLeft / 30,
        live: TrackPart.open,
        timeLeft: calSecondsLeft,
        timeLabel: 'eyes open, left',
      );
    case Stage.running:
      // with the check on, alpha above or under the line is not shown: it would tell a replay from live
      final quiet = checkOn || at;
      final (word, sentence, shape, color) = switch (chip) {
        Moment.settled || Moment.settling when quiet => (
          'In session',
          at
              ? 'Eyes closed. Let the stream and the waves carry you; there is nothing to do.'
              : 'Eyes closed. Nothing to do: just notice the sound.',
          MarkShape.ring,
          Night.inkMuted,
        ),
        Moment.drifting when at && asleepGuard => (
          'Probably asleep',
          'The sound has faded. A soft rising tone brings you back: open your eyes slowly.',
          MarkShape.ringedDot,
          Night.caution,
        ),
        Moment.drifting when at => (
          'Drifting',
          'Near the edge of sleep, where alpha-theta works. If you fall asleep the sound fades and a tone wakes you.',
          MarkShape.ring,
          Night.inkMuted,
        ),
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
        bellCount: checkOn ? null : bells,
      );
    case Stage.ending:
    case Stage.rating:
      return m(
        'Session over',
        message,
        MarkShape.ring,
        Night.inkMuted,
        open: 1,
        closed: 1,
        session: runSeconds / lengthS,
        timeLeft: (lengthS - runSeconds).ceil().clamp(0, 1 << 20),
        bellCount: checkOn ? null : bells,
      );
    case Stage.report:
      final r = report!;
      return m(
        r.complete ? 'Session over' : 'Stopped early',
        comparison,
        MarkShape.ring,
        Night.inkMuted,
        open: 1,
        closed: 1,
        session: r.runS / lengthS,
        timeLeft: at ? r.runS.round() : r.settledS.round(),
        timeLabel: at
            ? 'with sound${r.complete ? '' : ' of $minutes min'}'
            : 'settled: ${(r.settledShare * 100).round()} % of ${_minSecWords(r.runS)}',
        bellCount: checkOn ? null : r.bells,
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
    this.onSettings,
    this.onAlphaTheta,
    this.onRatings,
  });

  final MeditationViewModel model;
  final ValueChanged<int> onMinutes;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onDone;
  final VoidCallback onInfo;

  /// Training settings (the replay check's toggle); shown in the app bar while nothing runs.
  final VoidCallback? onSettings;

  /// Opens alpha-theta training (offered under the meditation's setup).
  final VoidCallback? onAlphaTheta;

  /// Meditation's rating stage: the replay check's answers.
  final ValueChanged<CheckRatings>? onRatings;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    if (m.stage == Stage.rating && onRatings != null) return CheckRatingsView(onDone: onRatings!);
    final idle = m.stage == Stage.setup || m.stage == Stage.failed || m.stage == Stage.report;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          m.kind == SessionKind.alphaTheta ? 'Alpha-theta' : 'Meditation',
          style: text.titleMedium?.copyWith(color: Night.inkMuted),
        ),
        actions: [
          if (onSettings != null && idle)
            IconButton(
              onPressed: onSettings,
              icon: const Icon(Icons.tune),
              tooltip: 'Training settings',
              color: Night.inkMuted,
            ),
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
          if (m.timeLeft != null || m.bells != null) ...[
            const SizedBox(height: 28),
            if (m.checkOn && m.bells == null && m.timeLeft != null)
              Readout(parts: _minSec(m.timeLeft!), label: m.timeLabel)
            else
              _Readouts(m),
          ],
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
      case Stage.failed when m.kind == SessionKind.alphaTheta:
        return const []; // alpha-theta's own setup page holds the length and the notes
      case Stage.setup:
      case Stage.failed:
        return [
          const SectionHeading('Length'),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: [for (final v in m.lengths) ButtonSegment(value: v, label: Text('$v min'))],
              selected: {m.minutes},
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
          if (m.checkOn) ...[
            const SectionHeading('Replay check'),
            const _Note(Icons.shuffle, checkReminder),
            if (m.checkStatus != null) Para(m.checkStatus!, color: Night.inkMuted, top: 0),
          ],
          const SectionHeading('Before you start'),
          const _Note(
            Icons.headphones_outlined,
            'Wired headphones or the phone\'s speaker. Bluetooth headphones add about 0.3 s, so the sound '
            'follows you late.',
          ),
          const _Note(
            Icons.smartphone_outlined,
            'The screen stays on while you meditate. You can lock the phone: the session goes on.',
          ),
          _Note(
            Icons.info_outline,
            'A guided eyes-closed practice, not a treatment. The evidence for sound feedback is weak; the i '
            'button says what the research shows.',
            onTap: onInfo,
          ),
          if (onAlphaTheta != null) ...[
            const SectionHeading('Other practice'),
            _Note(
              Icons.waves_outlined,
              'Alpha-theta training: eyes closed, drifting toward the edge of sleep with a stream and ocean '
              'waves. Its own screen, with questions before the first session.',
              onTap: onAlphaTheta,
              chevron: true,
            ),
          ],
        ];
      case Stage.connecting:
      case Stage.contact:
      case Stage.rating:
        return const [];
      case Stage.calibrating:
      case Stage.running:
      case Stage.ending:
        return [
          if (m.live == TrackPart.open) const _Spot(),
          if (m.contact.isNotEmpty) ...[const SectionHeading('Contact at the start'), _Contact(m.contact)],
        ];
      case Stage.report:
        return _report(context, m.report!);
    }
  }

  List<Widget> _report(BuildContext context, MeditationSummary r) {
    final text = Theme.of(context).textTheme;
    String two(int v) => v.toString().padLeft(2, '0');
    final at = r.kind == SessionKind.alphaTheta ? r.at : null;
    String secs(Object? v) => _minSecWords(v is num ? v.toDouble() : 0);
    final hideBells = model.checkOn;
    return [
      const SectionHeading('This session'),
      if (at != null) ...[
        _Row('Alpha above its line', secs(at['alphaS']), detail: 'awake and clean time'),
        _Row('Theta above its line', secs(at['thetaS'])),
        _Row('Theta above alpha (crossover)', secs(at['crossoverS']), detail: 'awake only; a fact, not a goal'),
        _Row('Probably asleep', secs(at['asleepS']), detail: 'left out of every measure'),
        if (!hideBells) _Row('Chimes · gongs', '${at['chimes']} · ${at['gongs']}'),
      ] else
        _Row('Longest settled stretch', _minSecWords(r.longestSettledS)),
      _Row(
        'Restless moments',
        '${r.restlessTotal}',
        detail:
            'jaw ${r.restless[Restless.jaw]} · blinks ${r.restless[Restless.blinks]} · '
            'movement ${r.restless[Restless.movement]}',
      ),
      if (at == null)
        _Row(
          'Drifting toward sleep',
          '${r.drifting}',
          detail: r.drowsyS > 0 ? '${_minSecWords(r.drowsyS)} in all' : null,
        ),
      _Row('Alpha peak', r.iafHz == null ? 'not clear' : '${(r.iafHz! * 4).round() / 4} Hz', rule: false),
      const SectionHeading('Earlier sessions'),
      if (model.earlier.isEmpty)
        Text('This is the first session on this phone.', style: text.bodyLarge?.copyWith(color: Night.inkMuted))
      else
        for (final (i, e) in model.earlier.take(5).indexed)
          _Row(
            '${nightLabel(e.start)}, ${two(e.start.hour)}:${two(e.start.minute)}',
            at != null ? _minSecWords(e.runS) : '${(e.settledShare * 100).round()} % settled',
            detail: at != null
                ? 'theta above its line ${secs(e.at?['thetaS'])}'
                : hideBells
                ? _minSecWords(e.runS)
                : '${_minSecWords(e.runS)} · ${e.bells} ${e.bells == 1 ? 'bell' : 'bells'}',
            rule: i < math.min(5, model.earlier.length) - 1,
          ),
      Padding(
        padding: const EdgeInsets.only(top: 28),
        child: Text(
          at != null
              ? 'Practice, not treatment. Crossover often means you are falling asleep; it is shown, never aimed for.'
              : 'Practice, not treatment. These numbers say what the headband measured, not how deep the meditation '
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
          label: Text(m.kind == SessionKind.alphaTheta ? 'Start session' : 'Start meditation'),
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
      case Stage.rating:
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

/// The eyes-open spot: one still dot, centred in the screen's middle band, nothing moving near it.
class _Spot extends StatelessWidget {
  const _Spot();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Green dot to look at',
    child: const SizedBox(
      height: 220,
      child: Center(child: StateMark(shape: MarkShape.filled, color: Night.live, size: 28)),
    ),
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
        Text(
          m.kind == SessionKind.alphaTheta ? 'Line: stream (low) to ocean (high)' : 'Line: how calm the sound was',
          style: style,
        ),
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
            label: m.kind == SessionKind.alphaTheta
                ? 'chimes and gongs'
                : m.bells == null
                ? 'bells, once the sound starts'
                : (m.bells == 1 ? 'bell' : 'bells'),
          ),
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {this.onTap, this.chevron = false});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;
  final bool chevron;

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
          if (chevron) ...[
            const SizedBox(width: 12),
            const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.chevron_right, color: Night.inkMuted)),
          ],
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
  const _Row(this.label, this.value, {this.detail, this.rule = true});
  final String label;
  final String value;
  final String? detail;

  /// A hairline under the row; off for the last row of a section (the next heading draws its own).
  final bool rule;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: rule ? const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))) : null,
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
