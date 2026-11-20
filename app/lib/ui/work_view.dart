// The work session's page (.impeccable/surfaces/app-lib-ui-work-screen-dart.md; ROADMAP row 35, DECISIONS 440-449).
// One deck-log column in the night-watch world: the status word with its mark, one sentence, the hint when there is
// one, the last hour as twelve of the watch strip's cells, the readouts, the signal line; On a break / Back (the page's
// one filled button) and Stop pinned. Pure: everything comes in through [WorkViewModel]; work_screen.dart wires it.
import 'package:flutter/material.dart';

import '../sharp/store.dart' show sharpWords;
import '../wearer/check.dart' show answerSomeoneElse;
import '../wearer/wearer.dart' show workWearerLine;
import '../work/breaks.dart';
import '../work/controller.dart';
import '../work/drowsiness.dart';
import '../work/store.dart';
import 'form_parts.dart' show PinnedAction, Para;
import 'parts.dart';
import 'device_status.dart';
import 'theme.dart';
import 'wearer_view.dart' show WearerRemark;

class WorkViewModel {
  const WorkViewModel({
    required this.stage,
    this.message = '',
    this.nightRunning = false,
    this.eyesClosedFirst = false,
    this.level = DrowsyLevel.unknown,
    this.eyesClosedNow = false,
    this.noisy = false,
    this.cells = const [],
    this.wornMin = 0,
    this.stretchMin = 0,
    this.hintsToday = 0,
    this.signal = WorkSignal.good,
    this.hint,
    this.rated,
    this.onBreak = false,
    this.breakMin = 0,
    this.afterBreak,
    this.closedLeft = 0,
    this.calibrationLeftMin = 0,
    this.kept = true,
    this.meeting = false,
    this.calibrationWaits = false,
    this.rawNote,
    this.summary,
    this.sessions = const [],
    this.saveNote,
    this.wearerOn = false,
    this.volumeNote,
  });

  final WorkStage stage;
  final String message;
  final bool nightRunning, eyesClosedFirst;
  final DrowsyLevel level;
  final bool eyesClosedNow, noisy;
  final List<WorkCell> cells;
  final double wornMin, stretchMin;
  final int hintsToday;
  final WorkSignal signal;
  final WorkHint? hint;

  /// The rating just given (1-5), shown as saved.
  final int? rated;
  final bool onBreak;
  final double breakMin;
  final String? afterBreak;
  final int closedLeft;
  final double calibrationLeftMin;

  /// The phone may be locked (the session keeper holds it).
  final bool kept;

  /// A meeting now (a call on the phone, or the laptop's meeting): talking expected, no verdict, no hint.
  final bool meeting;

  /// Calibrating, but waiting for a quiet minute (talking?).
  final bool calibrationWaits;

  /// What was kept of the raw EEG (the done page).
  final String? rawNote;

  /// The session that just ended.
  final WorkSummary? summary;
  final List<WorkSummary> sessions;
  final String? saveNote;

  /// "Was this you?" is switched on (Settings): the by-hand "Someone else wore it" is offered (DECISIONS 490).
  final bool wearerOn;

  /// The media volume is off or low, so the chime may not be heard (DECISIONS 496); a quiet line, not a dialog.
  final String? volumeNote;

  bool get live => stage.index >= WorkStage.connecting.index && stage.index <= WorkStage.ending.index;
}

class WorkView extends StatelessWidget {
  const WorkView({
    super.key,
    required this.model,
    this.onStart,
    this.onStop,
    this.onBreak,
    this.onBack,
    this.onSnooze,
    this.onNotNow,
    this.onRate,
    this.onEyesClosedFirst,
    this.onAgain,
    this.onInfo,
    this.onWearer,
    this.onWearerInfo,
  });

  final WorkViewModel model;
  final VoidCallback? onStart, onStop, onBreak, onBack, onSnooze, onNotNow, onAgain, onInfo, onWearerInfo;

  /// The owner's answer for a session: `someone else`, or null to take it back.
  final void Function(WorkSummary session, String? answer)? onWearer;
  final ValueChanged<int>? onRate;
  final ValueChanged<bool>? onEyesClosedFirst;

  @override
  Widget build(BuildContext context) {
    final m = model;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Work session'),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says', color: Night.inkMuted),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: switch (m.stage) {
          WorkStage.setup || WorkStage.failed => _setup(context),
          WorkStage.done => _done(context),
          _ => _live(context),
        },
      ),
      bottomNavigationBar: PinnedAction(child: _action(context)),
    );
  }

  // ---- before ----

  List<Widget> _setup(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final failed = m.stage == WorkStage.failed;
    return [
      _Status(
        mark: failed ? _Mark.problem : _Mark.idle,
        word: failed ? 'Not started' : 'Ready',
        line: failed
            ? m.message
            : m.nightRunning
            ? 'The headband is recording the night. A work session starts between nights.'
            : 'Wear the headband while you work. The phone watches for heavy eyelids and suggests a break now and then.',
      ),
      if (!failed && m.message.isNotEmpty) Para(m.message, color: Night.inkMuted),
      const SharedDeviceCard(top: 24),
      const SectionHeading('How it works'),
      _Rule('First', 'about 4 minutes of your usual work: your awake baseline. Start when you feel fresh.'),
      _Rule('Then', 'alert, getting drowsy or drowsy, from the last 5 minutes against your baseline.'),
      _Rule('Hints', 'a soft chime after an hour worn, or when drowsiness stays up; at most 4 a day, 45 minutes apart, none 23:00-08:00.'),
      _Rule('Breaks', 'tap On a break, or take the headband off for 5 minutes. Talking, chewing and moving are not a break. After it you see if drowsiness went down.'),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: m.eyesClosedFirst,
        onChanged: m.nightRunning ? null : onEyesClosedFirst,
        title: Text('Start with 1 minute eyes closed', style: text.bodyLarge),
        subtitle: Text(
          'Helps tell closed eyes from heavy eyelids later. Optional.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted),
        ),
      ),
      Para('The phone can be locked; the session goes on and the chime still sounds.', color: Night.inkMuted),
      if (m.sessions.isNotEmpty) ...[const SectionHeading('Earlier sessions'), for (final s in m.sessions.take(7)) _SessionRow(s, wearerOn: m.wearerOn, onWearer: onWearer)],
    ];
  }

  // ---- during ----

  List<Widget> _live(BuildContext context) {
    final m = model;
    final (mark, word, line) = _state(m);
    return [
      _Status(mark: mark, word: word, line: line),
      const SharedDeviceCard(top: 20),
      if (m.hint != null) _HintBlock(hint: m.hint!, rated: m.rated, onSnooze: onSnooze, onNotNow: onNotNow, onRate: onRate),
      if (m.afterBreak != null && m.hint == null && !m.onBreak) Para(m.afterBreak!, color: Night.ink, top: 16),
      if (m.stage.index >= WorkStage.calibrating.index) ...[
        const SectionHeading('The last hour'),
        _LevelStrip(cells: m.cells),
        const SizedBox(height: 28),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Readout(parts: _hm(m.wornMin), label: 'worn this session')),
            const SizedBox(width: 16),
            Expanded(
              child: Readout(
                parts: m.onBreak ? _hm(m.breakMin) : _hm(m.stretchMin),
                label: m.onBreak ? 'on this break' : 'since your last break',
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SignalLine(m.signal),
        Para('Hints today: ${m.hintsToday} of ${BreakRule.maxPerDay}.', color: Night.inkMuted),
        if (!m.kept) Para('The phone could not hold the session in the background: keep this screen on.', color: Night.caution),
        if (m.hint == null && m.stage == WorkStage.running) _RateLater(rated: m.rated, onRate: onRate),
      ],
      if (m.volumeNote != null) Para(m.volumeNote!, color: Night.inkMuted),
    ];
  }

  // ---- after ----

  List<Widget> _done(BuildContext context) {
    final m = model, s = m.summary;
    return [
      _Status(mark: _Mark.saved, word: 'Saved', line: m.saveNote ?? 'Your work session is kept on this phone and goes out with Export data.'),
      if (m.rawNote != null) Para(m.rawNote!, color: Night.inkMuted, top: 12),
      if (s != null) ...[
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Readout(parts: _hm(s.wornMin), label: 'worn')),
            const SizedBox(width: 16),
            Expanded(child: Readout(parts: _hm(s.drowsyMin), label: 'getting drowsy or drowsy')),
          ],
        ),
        const SectionHeading('Hints and breaks'),
        _Rule('Hints', s.hints == 0 ? 'none' : '${s.hints}'),
        _Rule('Breaks', s.breaks == 0 ? 'none' : '${s.breaks}'),
        for (final h in s.hintList) Para('${_clock(h.at)}  ${_reasonWords(h)}${_answerWords(h)}', color: Night.inkMuted, top: 8),
      ],
      if (m.afterBreak != null) Para(m.afterBreak!, top: 16),
      if (s != null)
        if (workWearerLine(s.wearerAnswer, on: m.wearerOn) case final line?)
          WearerRemark(line: line, onAnswer: (a) => onWearer?.call(s, a), onInfo: onWearerInfo),
    ];
  }

  Widget _action(BuildContext context) {
    final m = model;
    final big = const Size.fromHeight(64);
    switch (m.stage) {
      case WorkStage.setup:
      case WorkStage.failed:
        return FilledButton.icon(
          onPressed: m.nightRunning ? null : onStart,
          style: FilledButton.styleFrom(minimumSize: big, backgroundColor: Night.liveFill, foregroundColor: Night.onLiveFill),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(m.stage == WorkStage.failed ? 'Try again' : 'Start work session'),
        );
      case WorkStage.done:
        return OutlinedButton(onPressed: onAgain, style: OutlinedButton.styleFrom(minimumSize: big), child: const Text('Done'));
      case WorkStage.ending:
        return OutlinedButton(onPressed: null, style: OutlinedButton.styleFrom(minimumSize: big), child: const Text('Stopping'));
      default:
        final canBreak = m.stage == WorkStage.calibrating || m.stage == WorkStage.running;
        return Row(
          children: [
            if (canBreak) ...[
              Expanded(
                flex: 3,
                child: FilledButton(
                  onPressed: m.onBreak ? onBack : onBreak,
                  style: FilledButton.styleFrom(minimumSize: big, backgroundColor: Night.liveFill, foregroundColor: Night.onLiveFill),
                  child: Text(m.onBreak ? 'Back' : 'On a break'),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              flex: 2,
              child: OutlinedButton(onPressed: onStop, style: OutlinedButton.styleFrom(minimumSize: big), child: const Text('Stop')),
            ),
          ],
        );
    }
  }
}

/// The status word, its mark and one sentence for a live session.
(_Mark, String, String) _state(WorkViewModel m) {
  String left(double min) => min <= 0.5 ? 'under a minute' : 'about ${min.ceil()} min';
  switch (m.stage) {
    case WorkStage.connecting || WorkStage.contact:
      return (_Mark.idle, 'Connecting', m.message);
    case WorkStage.eyesClosed:
      return (_Mark.idle, 'Eyes closed', '${m.closedLeft} s left. Sit still; a higher tone says when to open them.');
    case WorkStage.ending:
      return (_Mark.idle, 'Stopping', m.message);
    default:
      break;
  }
  if (m.onBreak) {
    return (
      _Mark.idle,
      'On a break',
      'Tap Back when you return (on the lock screen too). The headband can stay on or come off; if you forget Back, '
          'the break ends by itself once you are working again.',
    );
  }
  if (m.signal == WorkSignal.lost) {
    return (_Mark.problem, 'No signal', 'The headband is out of reach, off or not sending; the app keeps reconnecting.');
  }
  if (m.stage == WorkStage.calibrating) {
    final line = m.signal == WorkSignal.off
        ? 'Paused: the headband seems off. It goes on once the headband is back on.'
        : m.meeting
        ? 'In a meeting: it waits for a quiet minute after the meeting. Talking is never a break.'
        : m.calibrationWaits
        ? 'Waiting for a quiet minute to calibrate (talking?). Talking is never a break; hourly hints still come.'
        : 'Learning your awake baseline: work as usual, ${left(m.calibrationLeftMin)} left.';
    return (_Mark.idle, 'Calibrating', line);
  }
  if (m.meeting) {
    return (_Mark.none, 'In a meeting', 'Talking is expected: drowsiness is not read and break hints wait until it ends.');
  }
  if (m.eyesClosedNow) return (_Mark.fair, 'Eyes closed', 'Your eyes have been closed for 2 of the last 5 minutes: resting, or nodding off.');
  return switch (m.level) {
    DrowsyLevel.alert => (_Mark.good, 'Alert', 'From the last 5 minutes, against your first minutes of work.'),
    DrowsyLevel.gettingDrowsy => (_Mark.fair, 'Getting drowsy', 'More alpha at the back of the head, and stiller eyes, than at the start.'),
    DrowsyLevel.drowsy => (_Mark.caution, 'Drowsy', 'Clearly more alpha and stiller eyes than at the start. A break may help.'),
    DrowsyLevel.unknown => (
      _Mark.none,
      'Not sure',
      m.noisy ? 'Over half of the last 5 minutes were too noisy to read: talking, chewing or moving.' : 'Reading the last 5 minutes.',
    ),
  };
}

List<(String, bool)> _hm(double minutes) {
  final m = minutes.floor();
  if (m < 60) return [('$m', true), (' min', false)];
  return [('${m ~/ 60}', true), (' h ', false), ((m % 60).toString().padLeft(2, '0'), true), (' min', false)];
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _reasonWords(WorkHint h) => switch (h.reason) {
  HintReason.stretch => 'after ${workMinutes(h.activeMin)} worn',
  HintReason.snooze => 'again after a snooze',
  HintReason.drowsy => 'drowsiness stayed up',
  HintReason.eyesClosed => 'eyes closed a while',
};

String _answerWords(WorkHint h) {
  final a = switch (h.answer) {
    HintAnswer.onBreak => ': you took a break',
    HintAnswer.snoozed => ': snoozed',
    HintAnswer.notNow => ': not now',
    null => '',
  };
  return h.taken && h.answer != HintAnswer.onBreak ? '$a; a break followed' : a;
}

enum _Mark { good, fair, caution, problem, idle, none, saved }

class _Status extends StatelessWidget {
  const _Status({required this.mark, required this.word, required this.line});
  final _Mark mark;
  final String word, line;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color) = switch (mark) {
      _Mark.good => (Icons.circle, Night.live),
      _Mark.fair => (Icons.adjust, Night.caution),
      _Mark.caution => (Icons.circle, Night.caution),
      _Mark.problem => (Icons.radio_button_unchecked, Night.problem),
      _Mark.idle => (Icons.radio_button_unchecked, Night.inkMuted),
      _Mark.saved => (Icons.circle, Night.saved),
      _Mark.none => (Icons.remove, Night.inkMuted),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(word, style: text.displaySmall?.copyWith(color: Night.ink, height: 1.1))),
          ],
        ),
        if (line.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(line, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45)),
        ],
      ],
    );
  }
}

/// A label-left / value-right line in the period log's form.
class _Rule extends StatelessWidget {
  const _Rule(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
          Expanded(child: Text(value, style: text.bodyLarge?.copyWith(height: 1.4))),
        ],
      ),
    );
  }
}

/// The hint: one sentence, why, Snooze and Not now, and the optional "how sharp do you feel?" row.
class _HintBlock extends StatelessWidget {
  const _HintBlock({required this.hint, this.rated, this.onSnooze, this.onNotNow, this.onRate});
  final WorkHint hint;
  final int? rated;
  final VoidCallback? onSnooze, onNotNow;
  final ValueChanged<int>? onRate;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final why = switch (hint.reason) {
      HintReason.stretch => '${workMinutes(hint.activeMin)} worn since your last break.',
      HintReason.snooze => 'You asked to be reminded.',
      HintReason.drowsy => 'Drowsiness read up for most of the last 6 minutes.',
      HintReason.eyesClosed => 'Your eyes were closed for 3 of the last 6 minutes.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),
        Text(hintTitle(hint), style: text.titleLarge?.copyWith(height: 1.3)),
        const SizedBox(height: 8),
        Text('$why Tap On a break if you go.', style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(flex: 3, child: OutlinedButton(onPressed: onSnooze, child: const Text('Snooze 20 min'))),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: TextButton(onPressed: onNotNow, child: const Text('Not now'))),
          ],
        ),
        const SizedBox(height: 16),
        _RateRow(rated: rated, onRate: onRate),
      ],
    );
  }
}

/// "How sharp do you feel?" on the sharp-hours scale, one tap, optional.
class _RateRow extends StatelessWidget {
  const _RateRow({this.rated, this.onRate});
  final int? rated;
  final ValueChanged<int>? onRate;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = rated;
    if (r != null) {
      return Text('Saved: $r, ${sharpWords[r - 1]}. Thank you.', style: text.bodyLarge?.copyWith(color: Night.inkMuted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How sharp do you feel? Optional, one tap.', style: text.bodyLarge),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            segments: [for (var v = 1; v <= 5; v++) ButtonSegment(value: v, label: Text('$v', style: const TextStyle(fontFeatures: tabular)))],
            selected: const {},
            onSelectionChanged: onRate == null ? null : (s) => s.isEmpty ? null : onRate!(s.first),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(sharpWords.first, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
            const Spacer(),
            Text(sharpWords.last, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
          ],
        ),
      ],
    );
  }
}

/// The rating row tucked under the readouts while there is no hint: tap to open it.
class _RateLater extends StatefulWidget {
  const _RateLater({this.rated, this.onRate});
  final int? rated;
  final ValueChanged<int>? onRate;

  @override
  State<_RateLater> createState() => _RateLaterState();
}

class _RateLaterState extends State<_RateLater> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextButton.icon(
            onPressed: () => setState(() => _open = true),
            icon: const Icon(Icons.touch_app_outlined),
            label: const Text('How sharp do you feel?'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: _RateRow(
        rated: widget.rated,
        onRate: (v) {
          widget.onRate?.call(v);
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (mounted) setState(() => _open = false);
          });
        },
      ),
    );
  }
}

/// The last hour: twelve of the watch strip's cells, 5 minutes each, newest right. A cell fills from the bottom
/// with the level (empty = alert, half = getting drowsy, full = drowsy), a dash where the signal was too noisy, a
/// faint outline before the session or for a break (worded under the strip).
class _LevelStrip extends StatelessWidget {
  const _LevelStrip({required this.cells});
  final List<WorkCell> cells;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final list = cells.isEmpty ? List.filled(stripCells, WorkCell.none) : cells;
    final drowsy = list.where((c) => c == WorkCell.drowsy || c == WorkCell.gettingDrowsy).length;
    return Semantics(
      label: 'The last hour in 5-minute cells: $drowsy read getting drowsy or drowsy.',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                for (var i = 0; i < list.length; i++) ...[
                  if (i > 0) SizedBox(width: i % 6 == 0 ? 10 : 4),
                  Expanded(child: _Cell(list[i])),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('1 h ago', style: text.bodySmall?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
              const Spacer(),
              Text('now', style: text.bodySmall?.copyWith(color: Night.inkMuted)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Empty: alert. Half full: getting drowsy. Full: drowsy. Dash: too noisy to read. Faint outline: a break or before the session.',
            style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.cell);
  final WorkCell cell;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(6);
    final fill = switch (cell) {
      WorkCell.gettingDrowsy => 0.5,
      WorkCell.drowsy => 1.0,
      _ => 0.0,
    };
    final faint = cell == WorkCell.none || cell == WorkCell.onBreak;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: faint ? null : Night.track,
        borderRadius: r,
        border: faint ? Border.all(color: Night.rule) : null,
      ),
      child: Stack(
        children: [
          if (fill > 0)
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: fill,
                widthFactor: 1,
                child: DecoratedBox(decoration: BoxDecoration(color: Night.saved, borderRadius: r)),
              ),
            ),
          if (cell == WorkCell.unknown) const Center(child: Icon(Icons.remove, size: 16, color: Night.inkMuted)),
        ],
      ),
    );
  }
}

class _SignalLine extends StatelessWidget {
  const _SignalLine(this.signal);
  final WorkSignal signal;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color, words) = switch (signal) {
      WorkSignal.good => (Icons.circle, Night.live, 'Signal good'),
      WorkSignal.noisy => (Icons.adjust, Night.caution, 'Talking / moving — reading paused'),
      WorkSignal.noEyes => (Icons.adjust, Night.caution, 'An electrode has no contact: eye readings paused'),
      WorkSignal.off => (Icons.radio_button_unchecked, Night.caution, 'The headband seems off: no skin contact in the signal'),
      WorkSignal.lost => (Icons.radio_button_unchecked, Night.problem, 'No signal: reconnecting'),
    };
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(words, style: text.bodyLarge)),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow(this.s, {this.wearerOn = false, this.onWearer});
  final WorkSummary s;
  final bool wearerOn;
  final void Function(WorkSummary session, String? answer)? onWearer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = s.start;
    final date = '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')} ${_clock(d)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(date, style: text.titleMedium?.copyWith(fontFeatures: tabular)),
          Text(
            '${workMinutes(s.wornMin)} worn · drowsy ${workMinutes(s.drowsyMin)} · '
            '${s.hints == 1 ? '1 hint' : '${s.hints} hints'} · ${s.breaks == 1 ? '1 break' : '${s.breaks} breaks'}',
            style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
          ),
          if (wearerOn) ..._wearer(text),
        ],
      ),
    );
  }

  /// The by-hand choice, quiet under the row: the words and Undo once someone else is said to have worn it.
  List<Widget> _wearer(TextTheme text) {
    final said = s.wearerAnswer == answerSomeoneElse;
    final style = TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 48), alignment: Alignment.centerLeft);
    return [
      if (said) Text('Someone else wore the headband: left out of your trends.', style: text.bodyMedium?.copyWith(color: Night.ink)),
      TextButton(
        onPressed: onWearer == null ? null : () => onWearer!(s, said ? null : answerSomeoneElse),
        style: style,
        child: Text(said ? 'Undo' : 'Someone else wore it'),
      ),
    ];
  }
}
