// The morning check-in's pages (.impeccable/surfaces/app-lib-ui-morning-screen-dart.md): one page per step, the
// steps logged at the top as state marks, one forward action pinned at the bottom. Built from a plain model, so
// tests render every state without a phone.
import 'package:flutter/material.dart';

import '../alphatheta/rules.dart' show ReactionTest;
import '../morning/controller.dart';
import '../morning/live.dart';
import '../recorder/contact.dart';
import '../trends/trends.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'reaction_test.dart';
import 'theme.dart';
import 'trends_view.dart' show MeasureEntry;

/// The Karolinska Sleepiness Scale's standard labels (scripts/web/morning-core.js `KSS`).
const List<String> kssLabels = [
  'Extremely alert',
  'Very alert',
  'Alert',
  'Rather alert',
  'Neither alert nor sleepy',
  'Some signs of sleepiness',
  'Sleepy, but no effort to keep awake',
  'Sleepy, some effort to keep awake',
  'Very sleepy, great effort to keep awake, fighting sleep',
];

const Map<String, String> electrodePlace = {
  'O1': 'back left',
  'O2': 'back right',
  'T3': 'left side',
  'T4': 'right side',
};

typedef ContactLine = ({String channel, Contact contact, Grade grade, String word, double spread});

/// This morning's result as the page shows it.
typedef MorningOutcome = ({List<TrendRow> rows, String today, String time, double? cleanShare, bool noPeak});

class MorningViewModel {
  const MorningViewModel({
    required this.stage,
    this.message = '',
    this.soundNote,
    this.saveNote,
    this.contact = const [],
    this.rechecking = false,
    this.noSignal = false,
    this.secondsLeft = 0,
    this.nightRunning = false,
    this.doneTodayAt,
    this.outcome,
  });

  final MorningStage stage;
  final String message;
  final String? soundNote, saveNote;

  /// Empty before the contact check.
  final List<ContactLine> contact;
  final bool rechecking, noSignal;
  final int secondsLeft;
  final bool nightRunning;

  /// When today's first check-in was saved ("09:12"), or null.
  final String? doneTodayAt;
  final MorningOutcome? outcome;
}

class MorningView extends StatelessWidget {
  const MorningView({
    super.key,
    required this.model,
    this.onCheckContact,
    this.onRecheck,
    this.onBegin,
    this.onStop,
    this.onSave,
    this.onDone,
    this.onTrends,
    this.onInfo,
  });

  final MorningViewModel model;
  final VoidCallback? onCheckContact, onRecheck, onBegin, onStop, onDone, onTrends, onInfo;
  final ValueChanged<MorningAnswers>? onSave;

  @override
  Widget build(BuildContext context) {
    final m = model;
    return switch (m.stage) {
      MorningStage.intro || MorningStage.failed => _page(context, _intro(context), _action(
        FilledButton.icon(
          onPressed: m.nightRunning ? null : onCheckContact,
          icon: const Icon(Icons.sensors_rounded),
          label: Text(m.stage == MorningStage.failed ? 'Try again' : 'Check contact'),
        ),
      )),
      MorningStage.connecting || MorningStage.contact => _page(context, _contact(context), _action(
        FilledButton.icon(
          onPressed: m.stage == MorningStage.contact && !m.rechecking ? onBegin : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start: eyes closed'),
        ),
      )),
      MorningStage.closed || MorningStage.open => _page(context, _phase(context), _action(
        OutlinedButton.icon(onPressed: onStop, icon: const Icon(Icons.stop_rounded), label: const Text('Stop')),
      ), dim: m.stage == MorningStage.closed),
      MorningStage.questions || MorningStage.saving => _Questions(model: m, onSave: onSave, onInfo: onInfo),
      MorningStage.result => _page(context, _result(context), _action(
        FilledButton.icon(onPressed: onDone, icon: const Icon(Icons.check_rounded), label: const Text('Done')),
      )),
    };
  }

  Widget _action(Widget button) => PinnedAction(child: button);

  Widget _page(BuildContext context, List<Widget> children, Widget action, {bool dim = false}) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Morning check-in', style: text.titleMedium?.copyWith(color: dim ? Night.saved : Night.ink)),
        actions: [
          if (!dim)
            IconButton(onPressed: onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(24, 4, 24, 24), children: children),
      bottomNavigationBar: action,
    );
  }

  List<Widget> _intro(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    return [
      Para(
        m.stage == MorningStage.failed
            ? m.message
            : 'Sit comfortably with the headband on, in a quiet place, sound on: soft tones tell you when to open '
                  'your eyes. Your numbers are compared only with your own earlier mornings.',
        color: m.stage == MorningStage.failed ? Night.caution : Night.inkMuted,
        top: 0,
      ),
      if (m.stage == MorningStage.intro && m.message.isNotEmpty) Para(m.message, color: Night.caution),
      const SectionHeading('The routine, about 6 minutes'),
      for (final (word, length) in const [
        ('Contact check', 'about 30 s'),
        ('Eyes closed', '2 min'),
        ('Eyes open, on a dot', '2 min'),
        ('Five quick questions', 'under 1 min'),
        ('Reaction test, if you like', '1 min'),
      ])
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(word, style: text.bodyLarge)),
              Text(length, style: text.bodyLarge?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
            ],
          ),
        ),
      if (m.nightRunning)
        const Para(
          'A night is being recorded. Stop it first: the headband talks to one thing at a time.',
          color: Night.caution,
          top: 20,
        )
      else if (m.doneTodayAt != null) ...[
        Para(
          'Checked in today at ${m.doneTodayAt}. Another one is kept too; the trends use the first of the day.',
          color: Night.inkMuted,
          top: 20,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onTrends,
            icon: const Icon(Icons.show_chart_rounded),
            label: const Text('See trends'),
          ),
        ),
      ],
    ];
  }

  List<Widget> _contact(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final checking = m.stage == MorningStage.connecting || m.rechecking;
    return [
      const StepMarks(current: 0),
      _title(context, 'Contact'),
      Para(
        m.stage == MorningStage.connecting
            ? m.message
            : m.rechecking
            ? 'Checking contact again. Keep still for a few seconds.'
            : m.noSignal
            ? 'No signal from the headband yet.'
            : 'Contact and signal now, every second:',
        color: m.noSignal && !checking ? Night.caution : Night.inkMuted,
        top: 8,
      ),
      const SizedBox(height: 8),
      for (final c in m.contact) _ContactRow(line: c),
      const Para(
        'Not good: part the hair under that electrode, press it to the skin and sit still. The back two (O1, O2) '
        'matter most here.',
        color: Night.inkMuted,
        top: 16,
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: m.stage == MorningStage.contact && !m.rechecking ? onRecheck : null,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Check contact again'),
        ),
      ),
      if (m.soundNote != null) Para(m.soundNote!, color: Night.caution),
      if (checking) ...[
        const SizedBox(height: 20),
        Text('One moment…', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
      ],
    ];
  }

  List<Widget> _phase(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final closed = m.stage == MorningStage.closed;
    final dimInk = closed ? Night.saved : Night.ink;
    final s = m.secondsLeft;
    return [
      StepMarks(current: closed ? 1 : 2, dim: closed),
      _title(context, closed ? 'Eyes closed' : 'Eyes open', color: dimInk),
      Para(
        closed
            ? 'Close your eyes and rest. A soft rising pair of tones tells you when to open them.'
            : 'Look at the dot. Relax, blink normally.',
        color: closed ? Night.saved : Night.inkMuted,
        top: 8,
      ),
      SizedBox(
        height: 120,
        child: Center(
          child: closed
              ? null
              : Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Night.ink),
                ),
        ),
      ),
      Semantics(
        liveRegion: false,
        label: '$s seconds left',
        excludeSemantics: true,
        child: Text(
          '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
          textAlign: TextAlign.center,
          style: text.displayMedium?.copyWith(color: closed ? Night.rule : Night.inkMuted, fontWeight: FontWeight.w300),
        ),
      ),
      if (m.noSignal)
        Para(
          'No signal: the countdown waits for it.',
          color: closed ? Night.caution.withValues(alpha: 0.7) : Night.caution,
          top: 16,
        ),
    ];
  }

  List<Widget> _result(BuildContext context) {
    final m = model;
    final o = m.outcome;
    final text = Theme.of(context).textTheme;
    return [
      const StepMarks(current: 4),
      _title(context, o == null ? 'Saved' : 'This morning, ${o.time}'),
      if (o != null) ...[
        const SizedBox(height: 8),
        for (final (i, r) in o.rows.indexed) ...[
          if (i > 0) const Divider(height: 29),
          MeasureEntry(row: r, today: o.today),
        ],
        if (o.noPeak)
          const Para(
            'No clear alpha peak with eyes closed today (contact, or an alert or tense start can do this).',
            color: Night.inkMuted,
            top: 16,
          ),
        if (o.cleanShare != null)
          Para('Clean data: ${(o.cleanShare! * 100).round()} % of the signal counted.', color: Night.inkMuted, top: 16),
      ],
      const Para(
        'One morning means little; look at the trend over weeks. These are your own numbers, not norms.',
        color: Night.inkMuted,
      ),
      if (m.saveNote != null) Para(m.saveNote!, color: Night.caution),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: onTrends,
          icon: const Icon(Icons.show_chart_rounded),
          label: Text('See trends', style: text.labelLarge),
        ),
      ),
    ];
  }
}

Widget _title(BuildContext context, String s, {Color color = Night.ink}) => Padding(
  padding: const EdgeInsets.only(top: 20),
  child: Text(s, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w500)),
);

/// The routine's four steps as state marks: filled = done, ringed dot = now, ring = to come (DESIGN.md Shapes).
class StepMarks extends StatelessWidget {
  const StepMarks({super.key, required this.current, this.dim = false});

  /// 0 contact, 1 eyes closed, 2 eyes open, 3 questions, 4 all done.
  final int current;
  final bool dim;

  static const List<String> steps = ['Contact', 'Eyes closed', 'Eyes open', 'Questions'];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: current >= steps.length ? 'All steps done' : 'Step ${current + 1} of ${steps.length}: ${steps[current]}',
      excludeSemantics: true,
      child: Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [
          for (final (i, s) in steps.indexed)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  i < current ? Icons.circle : (i == current ? Icons.adjust : Icons.radio_button_unchecked),
                  size: 14,
                  color: dim ? Night.rule : (i == current ? Night.ink : (i < current ? Night.inkMuted : Night.rule)),
                ),
                const SizedBox(width: 6),
                Text(
                  s,
                  style: text.bodyMedium?.copyWith(
                    color: dim ? Night.rule : (i == current ? Night.ink : Night.inkMuted),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.line});
  final ContactLine line;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = line;
    final (icon, color) = switch (c.grade) {
      Grade.good => (Icons.circle, Night.live),
      Grade.fair => (Icons.adjust, Night.caution),
      Grade.bad => (Icons.radio_button_unchecked, Night.problem),
    };
    final ohms = switch (c.contact) {
      Contact.none => 'no contact reading',
      Contact.good => 'contact good',
      Contact.fair => 'contact fair',
      Contact.poor => 'contact poor',
    };
    return Semantics(
      container: true,
      label: '${c.channel}, ${electrodePlace[c.channel]}: ${c.word}, $ohms',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(width: 44, child: Text(c.channel, style: text.titleMedium)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(electrodePlace[c.channel] ?? '', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
                  Text(
                    '$ohms · ${c.spread.round()}\u00a0µV',
                    style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(c.word, style: text.bodyLarge?.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// The questions after the recording, then the optional reaction test (DESIGN.md Questions).
class _Questions extends StatefulWidget {
  const _Questions({required this.model, required this.onSave, required this.onInfo});
  final MorningViewModel model;
  final ValueChanged<MorningAnswers>? onSave;
  final VoidCallback? onInfo;

  @override
  State<_Questions> createState() => _QuestionsState();
}

class _QuestionsState extends State<_Questions> {
  int? _kss, _mood, _tension, _cups, _drinks;
  bool? _late, _today;
  ReactionTest? _test;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final saving = widget.model.stage == MorningStage.saving;
    final answered = _kss != null &&
        _mood != null &&
        _tension != null &&
        _cups != null &&
        (_cups == 0 || _late != null) &&
        _drinks != null &&
        _today != null;
    final t = _test;
    final median = t?.median;
    List<(int, String)> counts() => [for (var i = 0; i <= 5; i++) (i, i == 5 ? '5+' : '$i')];
    return Scaffold(
      appBar: AppBar(
        title: Text('Morning check-in', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: widget.onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          const StepMarks(current: 3),
          _title(context, 'How do you feel right now?'),
          SliderQuestion(
            question: 'Sleepiness over the last 5 minutes',
            value: _kss,
            min: 1,
            max: 9,
            onChanged: (v) => setState(() => _kss = v),
            ends: ('1 extremely alert', '9 fighting sleep'),
            caption: (v) => '$v · ${kssLabels[v - 1]}',
          ),
          scaleQuestion('Mood', _mood, (v) => setState(() => _mood = v), ('1 very bad', '5 very good')),
          scaleQuestion('Tension', _tension, (v) => setState(() => _tension = v), ('1 none', '5 very much')),
          const SectionHeading('Yesterday'),
          ChoiceQuestion<int>(
            question: 'Cups of coffee, strong tea or energy drinks',
            choices: counts(),
            value: _cups,
            onChanged: (v) => setState(() => _cups = v),
          ),
          if (_cups != null && _cups! > 0)
            ChoiceQuestion<bool>(
              question: 'Any in the 8 hours before you went to sleep?',
              choices: const [(true, 'Yes'), (false, 'No')],
              value: _late,
              onChanged: (v) => setState(() => _late = v),
            ),
          ChoiceQuestion<int>(
            question: 'Drinks of alcohol (a beer, a glass of wine or a shot each)',
            choices: counts(),
            value: _drinks,
            onChanged: (v) => setState(() => _drinks = v),
          ),
          const SectionHeading('This morning'),
          ChoiceQuestion<bool>(
            question: 'Any caffeine before this check-in?',
            choices: const [(true, 'Yes'), (false, 'No')],
            value: _today,
            onChanged: (v) => setState(() => _today = v),
          ),
          const SectionHeading('Reaction test'),
          const Para(
            'If you like, 1 minute: a measured alertness number to set beside your rating.',
            color: Night.inkMuted,
            top: 0,
          ),
          const SizedBox(height: 12),
          ReactionPanel(onDone: (_) {}, onTest: (t) => setState(() => _test = t)),
        ],
      ),
      bottomNavigationBar: PinnedAction(
        child: FilledButton.icon(
          onPressed: answered && !saving
              ? () => widget.onSave?.call(MorningAnswers(
                  kss: _kss!,
                  mood: _mood!,
                  tension: _tension!,
                  cups: _cups!,
                  caffeineLate: _cups == 0 ? false : _late,
                  drinks: _drinks!,
                  caffeineToday: _today!,
                  reaction: t == null
                      ? null
                      : {
                          'median_ms': median,
                          'taps': t.times.length,
                          'lapses': t.lapses,
                          'false_starts': t.falseStarts,
                          'length_s': t.lengthS,
                        },
                ))
              : null,
          icon: const Icon(Icons.check_rounded),
          label: Text(
            saving
                ? 'Working out your numbers…'
                : !answered
                ? 'Answer each question'
                : median == null
                ? 'Save without the reaction test'
                : 'Save',
          ),
        ),
      ),
    );
  }
}
