// Sleep experiments (DECISIONS rows 838, 1050-1069): the page and its setup, laid out from what
// sleep_experiments_screen.dart read. Tonight's one-tap answer first, then what counts, then the honest result:
// how many nights are in, the two averages from 5 of each, a verdict only from the nights needed.
import 'package:flutter/material.dart';

import '../sleep_experiments/kinds.dart';
import '../sleep_experiments/result.dart';
import '../sleep_experiments/stats.dart' show StatRule;
import '../sleep_experiments/store.dart';
import '../trends/days.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'theme.dart';

/// Past days without an answer that the page still asks about.
const int askBackDays = 2;

/// One experiment as shown at [today] (a day key).
class SleepExperimentPage {
  const SleepExperimentPage({required this.result, required this.today});
  final ExperimentResult result;
  final String today;
  ExperimentLog get log => result.log;
  ExperimentKind get kind => log.plan.kind;

  /// Days before today, newest first, that still lack an answer (never before the start).
  List<String> get unanswered => [
    for (var k = 1; k <= askBackDays; k++)
      if (addDays(today, -k).compareTo(log.plan.start) >= 0 && log.day(addDays(today, -k)).answer == null) addDays(today, -k),
  ];
}

/// "3 with, 6 without so far" for the one line on Trends.
String pilesLine(Piles p) => '${p.nWith} with, ${p.nWithout} without so far';

/// The evening's question with its three one-tap answers. [dense]: the Record tab's line (less air above, a muted
/// question).
class AnswerQuestion extends StatelessWidget {
  const AnswerQuestion({super.key, required this.kind, required this.question, required this.value, required this.onChanged, this.dense = false});
  final ExperimentKind kind;
  final String question;
  final Answer? value;
  final ValueChanged<Answer>? onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(top: dense ? 0 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            style: dense ? text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35) : text.bodyLarge?.copyWith(height: 1.4),
          ),
          SizedBox(height: dense ? 6 : 10),
          AnswerButtons(
            choices: [(Answer.withIt, kind.withLabel), (Answer.without, kind.withoutLabel), (Answer.neither, kind.neitherLabel)],
            value: value,
            onChanged: onChanged ?? (_) {},
            minHeight: dense ? 44 : 52,
          ),
        ],
      ),
    );
  }
}

/// Three answers as one control (DECISIONS 1082). Side by side, each as wide as its words need, so a longer label
/// ("None after noon") never breaks in two; when the three do not fit the width (large text, a narrow phone) they
/// stand under each other. A label is always one line.
class AnswerButtons extends StatelessWidget {
  const AnswerButtons({super.key, required this.choices, required this.value, required this.onChanged, this.minHeight = 52});
  final List<(Answer, String)> choices;
  final Answer? value;
  final ValueChanged<Answer> onChanged;
  final double minHeight;

  /// Air on each side of a label, and what the measuring may be off by.
  static const double _pad = 10, _slack = 2;

  @override
  Widget build(BuildContext context) {
    final style = (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(height: 1.2);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final needs = [
          for (final (_, label) in choices)
            () {
              final p = TextPainter(text: TextSpan(text: label, style: style), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)..layout();
              final w = p.width + 2 * _pad + _slack;
              p.dispose();
              return w;
            }(),
        ];
        // the frame and the two rules between the three
        final sideBySide = needs.fold(0.0, (a, b) => a + b) + choices.length + 1 <= box.maxWidth;
        Widget one(int i) {
          final (answer, label) = choices[i];
          final on = answer == value;
          return Semantics(
            button: true,
            inMutuallyExclusiveGroup: true,
            checked: on,
            child: Material(
              color: on ? Night.surfaceHigh : Colors.transparent,
              child: InkWell(
                onTap: () => onChanged(answer),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight, minWidth: sideBySide ? 0 : double.infinity),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: _pad),
                      child: Text(label, maxLines: 1, softWrap: false, style: style.copyWith(color: on ? Night.ink : Night.inkMuted)),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final radius = BorderRadius.circular(sideBySide ? minHeight / 2 : 16);
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(border: Border.all(color: Night.rule), borderRadius: radius),
          child: ClipRRect(
            borderRadius: radius,
            child: sideBySide
                ? IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < choices.length; i++) ...[
                          if (i > 0) const VerticalDivider(width: 1, thickness: 1, color: Night.rule),
                          // the spare width is shared out by what each label needs
                          Expanded(flex: (needs[i] * 10).ceil(), child: one(i)),
                        ],
                      ],
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < choices.length; i++) ...[
                        if (i > 0) const Divider(height: 1, thickness: 1, color: Night.rule),
                        one(i),
                      ],
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class SleepExperimentView extends StatelessWidget {
  const SleepExperimentView({
    super.key,
    required this.page,
    this.earlier = const [],
    this.onAnswer,
    this.onOdd,
    this.onPick,
    this.onEnd,
    this.onNew,
    this.onInfo,
    this.onOpen,
  });

  /// The experiment shown; null: none yet.
  final SleepExperimentPage? page;
  final List<ExperimentLog> earlier;
  final void Function(String day, Answer answer)? onAnswer;
  final void Function(String day, String flag, bool on)? onOdd;
  final VoidCallback? onPick, onEnd, onNew, onInfo;
  final void Function(String id)? onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = page;
    final canStart = onNew != null && (p == null || !p.log.running);
    return Scaffold(
      appBar: AppBar(
        title: Text('Sleep experiments', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          if (p == null) ..._none(context) else ..._one(context, p),
          if (earlier.isNotEmpty) ...[
            const SectionHeading('Earlier'),
            for (final e in earlier)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.plan.kind.title, style: text.bodyLarge),
                subtitle: Text(
                  'From ${dayLabel(e.plan.start)}${e.ended == null ? '' : ' to ${dayLabel(e.ended!)}'}',
                  style: text.bodyMedium?.copyWith(color: Night.inkMuted),
                ),
                trailing: const Icon(Icons.chevron_right, color: Night.inkMuted),
                onTap: onOpen == null ? null : () => onOpen!(e.plan.id),
              ),
          ],
        ],
      ),
      bottomNavigationBar: canStart ? PinnedAction(child: FilledButton(onPressed: onNew, child: const Text('Start an experiment'))) : null,
    );
  }

  List<Widget> _none(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      Text('None running', style: text.displaySmall),
      const Para(
        'Find out what a habit does to your own sleep. Each evening you tap whether it happened. The app then '
        'compares the nights with and the nights without.',
        color: Night.inkMuted,
      ),
      const Para(
        'It takes weeks, not days. Until there are enough nights the app says "too early to say" and nothing more.',
        color: Night.inkMuted,
      ),
      const SectionHeading('What you can try'),
      for (final k in experimentKinds) ...[
        Text(k.title, style: text.titleMedium),
        Para(k.studies, color: Night.inkMuted, top: 4),
        const SizedBox(height: 16),
      ],
    ];
  }

  List<Widget> _one(BuildContext context, SleepExperimentPage p) {
    final text = Theme.of(context).textTheme;
    final k = p.kind, log = p.log, res = p.result, today = log.day(p.today);
    final running = log.running;
    return [
      Text(k.title, style: text.displaySmall),
      Para(
        running ? 'Since ${dayLabel(log.plan.start)}.' : 'From ${dayLabel(log.plan.start)} to ${dayLabel(log.ended!)}. Ended.',
        color: Night.inkMuted,
        top: 6,
      ),
      if (running) ...[
        const SectionHeading('Today'),
        if (log.plan.picked) ..._pick(context, p, today),
        AnswerQuestion(
          kind: k,
          question: k.question,
          value: today.answer,
          onChanged: onAnswer == null ? null : (a) => onAnswer!(p.today, a),
        ),
        const SizedBox(height: 4),
        for (final (id, label) in oddFlags)
          CheckboxListTile(
            value: today.odd.contains(id),
            onChanged: onOdd == null ? null : (v) => onOdd!(p.today, id, v == true),
            title: Text(label, style: text.bodyLarge?.copyWith(height: 1.3)),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: Night.inkMuted,
            checkColor: Night.ground,
            side: const BorderSide(color: Night.inkMuted, width: 1.5),
          ),
        const Para('An ill night or a night away is left out.', color: Night.inkMuted, top: 0),
        for (final d in p.unanswered)
          AnswerQuestion(
            kind: k,
            question: '${d == addDays(p.today, -1) ? 'Yesterday' : dayLabel(d)}: not answered',
            value: null,
            onChanged: onAnswer == null ? null : (a) => onAnswer!(d, a),
          ),
      ],
      const SectionHeading('What counts'),
      _Pair(label: k.withLabel, detail: k.withMeans),
      const SizedBox(height: 12),
      _Pair(label: k.withoutLabel, detail: k.withoutMeans),
      const SizedBox(height: 12),
      _Pair(label: k.neitherLabel, detail: 'Anything else. That night is left out.'),
      if (k.rule != null) Para(k.rule!, color: Night.inkMuted),
      SectionHeading(running ? 'So far' : 'Result'),
      Text('${res.piles.nWith} with · ${res.piles.nWithout} without', style: text.headlineSmall?.copyWith(fontFeatures: tabular)),
      Para(
        'Nights that count. A night counts when the headband was on and the app made a sleep report for it.',
        color: Night.inkMuted,
        top: 6,
      ),
      if (leftOutLine(res.piles) case final line?) Para(line, color: Night.inkMuted),
      if (res.tested && res.keptTo.answered > 0)
        Para('You did as picked on ${res.keptTo.kept} of ${res.keptTo.answered} nights. Every picked night is counted as picked.', color: Night.inkMuted),
      for (final (i, r) in res.measures.indexed) ...[
        const SizedBox(height: 24),
        Text(i == 0 ? '${r.measure.label} (the main number)' : r.measure.label, style: text.titleMedium),
        Para(sentence(res, r), top: 6),
        if (matchedLine(res, r) case final line?) Para(line, color: Night.inkMuted),
        if (r.stage != Stage.verdict) Para(neededLine(r), color: Night.inkMuted),
        if (r.measure.note != null) Para(r.measure.note!, color: Night.inkMuted),
      ],
      const SizedBox(height: 24),
      Para(
        res.tested
            ? 'The app picked the nights by chance, so a clear result here is a fair test. One run is still wrong '
                  'about 1 time in 20: run it again before you rely on it.'
            : 'You chose the nights, so this can only say what was seen together, never what caused it. A late night '
                  'out differs from a quiet evening in more than one way.',
        color: Night.inkMuted,
        top: 0,
      ),
      if (running && onEnd != null) ...[
        const SizedBox(height: 24),
        OutlinedButton(onPressed: onEnd, child: const Text('End this experiment')),
      ],
    ];
  }

  List<Widget> _pick(BuildContext context, SleepExperimentPage p, DayLog today) {
    final text = Theme.of(context).textTheme;
    final k = p.kind, pick = today.pick;
    if (pick == null) {
      return [
        const Para('Is tonight a test night? Then let the app pick. It cannot be drawn again today.', top: 0),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: onPick, icon: const Icon(Icons.casino_outlined), label: const Text('Pick for tonight')),
        const Para('Not a test night: leave it. Tonight is then not counted.', color: Night.inkMuted),
      ];
    }
    return [
      Text('The app picked: ${pick ? k.withLabel : k.withoutLabel}', style: text.titleLarge?.copyWith(height: 1.3)),
      Para(pick ? k.withMeans : k.withoutMeans, color: Night.inkMuted, top: 6),
      const Para('Tap below what you really did. The night counts as picked either way.', color: Night.inkMuted),
    ];
  }
}

class _Pair extends StatelessWidget {
  const _Pair({required this.label, required this.detail});
  final String label, detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
        Text(detail, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
      ],
    );
  }
}

/// One choice of a list: a ring or a filled circle (DESIGN.md Shapes), the line, a muted detail. 56 dp at least.
class _Choice extends StatelessWidget {
  const _Choice({required this.selected, required this.title, required this.detail, required this.onTap});
  final bool selected;
  final String title, detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected ? Night.ink : Night.inkMuted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: text.bodyLarge?.copyWith(height: 1.3)),
                      Text(detail, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the setup hands back.
typedef SleepExperimentChoice = ({ExperimentKind kind, bool picked});

/// Choosing an experiment: the short list, what the studies found, how many nights it needs, and whether the app
/// picks the nights. [needs]: kind id -> the "needs about N nights" line for its main number.
class SleepExperimentSetup extends StatefulWidget {
  const SleepExperimentSetup({super.key, required this.onStart, this.needs = const {}, this.onInfo});
  final ValueChanged<SleepExperimentChoice> onStart;
  final Map<String, String> needs;
  final VoidCallback? onInfo;

  @override
  State<SleepExperimentSetup> createState() => _SleepExperimentSetupState();
}

class _SleepExperimentSetupState extends State<SleepExperimentSetup> {
  ExperimentKind? _kind;
  bool _picked = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final k = _kind;
    return Scaffold(
      appBar: AppBar(
        title: Text('New sleep experiment', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: widget.onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          const Para('One at a time. Only things the studies say can show in one person\'s nights.', color: Night.inkMuted, top: 0),
          const SizedBox(height: 8),
          for (final kind in experimentKinds)
            _Choice(
              selected: k?.id == kind.id,
              title: kind.title,
              detail: '${kind.withLabel} against ${kind.withoutLabel.toLowerCase()}',
              onTap: () => setState(() {
                _kind = kind;
                _picked = false;
              }),
            ),
          if (k != null) ...[
            SectionHeading(k.title),
            _Pair(label: 'A night with', detail: k.withMeans),
            const SizedBox(height: 12),
            _Pair(label: 'A night without', detail: k.withoutMeans),
            Para(k.studies, color: Night.inkMuted),
            Para('The app watches your ${[for (final w in k.watched) w.measure.noun].join(' and ')}.', color: Night.inkMuted),
            if (widget.needs[k.id] case final line?) Para(line),
            const SectionHeading('Who picks the nights'),
            if (k.canPick) ...[
              SwitchListTile(
                value: _picked,
                onChanged: (v) => setState(() => _picked = v),
                title: Text('Let the app pick', style: text.bodyLarge),
                contentPadding: EdgeInsets.zero,
              ),
              const Para(
                'Off: you choose your nights and tap what happened. The result can only say "seen together".',
                color: Night.inkMuted,
                top: 0,
              ),
              const Para(
                'On: on an evening you are free to do either, you ask the app and it says with or without, by chance. '
                'That is a fair test, and the result can say "tested". You can always do otherwise.',
                color: Night.inkMuted,
              ),
            ] else
              const Para(
                'You do. The app never tells you to drink, so this result can only say "seen together".',
                color: Night.inkMuted,
                top: 0,
              ),
            const Para(
              'Nothing here is medical advice. No verdict comes before ${StatRule.minForVerdict} nights of each kind.',
              color: Night.inkMuted,
            ),
          ],
        ],
      ),
      bottomNavigationBar: PinnedAction(
        child: FilledButton(
          onPressed: k == null ? null : () => widget.onStart((kind: k, picked: _picked)),
          child: Text(k == null ? 'Choose one' : 'Start today'),
        ),
      ),
    );
  }
}

/// The section on the Trends page: today's question in one tap, where the experiment stands, and the way in.
class SleepExperimentSection extends StatelessWidget {
  const SleepExperimentSection({super.key, required this.log, required this.today, this.line, this.onAnswer, this.onOpen});

  /// The running experiment; null: none.
  final ExperimentLog? log;
  final String today;

  /// [pilesLine] of the running experiment.
  final String? line;
  final ValueChanged<Answer>? onAnswer;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final e = log;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading('Sleep experiments: one tap each evening'),
        if (e == null)
          const Para(
            'What does late caffeine, a late workout or a few drinks do to your own sleep? Tap each evening; the app '
            'compares the nights.',
            color: Night.inkMuted,
            top: 0,
          )
        else ...[
          Para('${e.plan.kind.title}: ${line ?? ''}.', top: 0),
          if (e.plan.picked && e.day(today).pick == null)
            const Para('Open it to let the app pick for tonight.', color: Night.inkMuted)
          else
            AnswerQuestion(kind: e.plan.kind, question: e.plan.kind.question, value: e.day(today).answer, onChanged: onAnswer),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: onOpen, icon: const Icon(Icons.nights_stay_outlined), label: const Text('Sleep experiments')),
      ],
    );
  }
}
