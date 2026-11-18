// The self-experiments page's layout (.impeccable/surfaces/app-lib-ui-experiments-screen-dart.md; DECISIONS rows
// 200-209): the watch bill for the weeks ahead. The status, today's task, "did you keep to it?" for the days that
// are over, the weeks as rows of the watch strip's cells (days ahead sealed), and the answer's place: sealed until
// its date, then one sentence with its range. Built from an ExperimentPage only, so tests render it without a
// phone.
import 'package:flutter/material.dart';

import '../experiments/analysis.dart';
import '../experiments/experiment.dart';
import '../trends/days.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'theme.dart';

/// One experiment as the page shows it. [results]: null while the answer is sealed. [early]: they are an early
/// look the owner asked for.
class ExperimentPage {
  const ExperimentPage({required this.state, required this.now, this.results, this.early = false});
  final ExperimentState state;
  final DateTime now;
  final ExpResults? results;
  final bool early;
}

String _days(int n) => n == 1 ? '1 day' : '$n days';

/// The status word at the top.
String statusWords(ExperimentState s) => switch (s.phase) {
  ExpPhase.waiting => s.todayIndex == -1 ? 'Starts tomorrow' : 'Starts ${dayLabel(s.plan.start)}',
  ExpPhase.running => 'Day ${s.todayIndex + 1} of ${s.plan.days}',
  ExpPhase.lastNumber => 'Last number coming in',
  ExpPhase.finished => 'Finished',
  ExpPhase.stopped => 'Stopped after ${_days(s.assignedDays)}',
};

/// One line for other screens (Trends, the Morning section, a check-in's result): today's task, or where the
/// experiment stands. Null without an experiment worth a line.
String? experimentLine(ExperimentState? s) {
  if (s == null) return null;
  final open = s.unanswered().length;
  return switch (s.phase) {
    ExpPhase.waiting => 'Experiment starts ${s.todayIndex == -1 ? 'tomorrow' : dayLabel(s.plan.start)}: “${s.plan.doText}” on random days.',
    ExpPhase.running =>
      'Experiment, day ${s.todayIndex + 1} of ${s.plan.days}. Today: ${s.textFor(s.todayView!.doIt)}.'
          '${open > 0 ? ' ${_days(open)} to answer.' : ''}',
    ExpPhase.lastNumber => 'Experiment: every day is done. The answer opens ${dayLabel(s.plan.unlocks)}.',
    ExpPhase.finished => 'Experiment finished: the answer is open.',
    ExpPhase.stopped => null,
  };
}

/// Between 04:00 and 10:00 a late sleeper may still be up from the day before.
bool stillUpHours(DateTime now) => now.hour >= dayStartHour && now.hour < 10;

class ExperimentView extends StatelessWidget {
  const ExperimentView({
    super.key,
    required this.page,
    this.earlier = const [],
    this.onAnswer,
    this.onLookEarly,
    this.onStop,
    this.onInfo,
    this.onNew,
    this.onOpen,
  });

  /// The experiment shown; null: none yet.
  final ExperimentPage? page;

  /// Other experiments (finished or stopped), newest first.
  final List<ExperimentState> earlier;
  final void Function(String day, bool kept)? onAnswer;
  final VoidCallback? onLookEarly, onStop, onInfo, onNew;
  final void Function(String id)? onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = page;
    final canStart = onNew != null && (p == null || p.state.open);
    return Scaffold(
      appBar: AppBar(
        title: Text(p == null ? 'Self-experiments' : 'Experiment', style: text.titleMedium?.copyWith(color: Night.ink)),
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
            const SectionHeading('Earlier experiments'),
            for (final (i, e) in earlier.indexed)
              _Earlier(state: e, rule: i < earlier.length - 1, onTap: onOpen == null ? null : () => onOpen!(e.plan.id)),
          ],
        ],
      ),
      bottomNavigationBar: canStart
          ? PinnedAction(
              child: FilledButton(onPressed: onNew, child: const Text('New experiment')),
            )
          : null,
    );
  }

  List<Widget> _none(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      Text('None running', style: text.displaySmall),
      const Para(
        'Pick one habit and one number. The app then draws random days for a few weeks: on some you do it, on the '
        'others you don\'t. At the end it tells you what the habit did to that number, with a range.',
        color: Night.inkMuted,
      ),
      const Para(
        'Because chance picks the days, nothing else can explain the difference. That is what "tested" means here; '
        'everything else in the app is only "seen together".',
        color: Night.inkMuted,
      ),
    ];
  }

  List<Widget> _one(BuildContext context, ExperimentPage p) {
    final text = Theme.of(context).textTheme;
    final s = p.state, plan = s.plan;
    final today = s.todayView;
    final open = s.unanswered();
    final sealed = p.results == null;
    return [
      Text(statusWords(s), style: text.displaySmall?.copyWith(fontFeatures: tabular)),
      Para(
        '“${plan.doText}” against “${plan.dontText}”. Tested on your ${plan.outcome.noun} the next day.',
        color: Night.inkMuted,
        top: 10,
      ),
      if (s.phase == ExpPhase.waiting)
        Para(
          'Day 1 is ${dayLabel(plan.start)}. Open this page that day for its task: the app draws it, you don\'t choose.',
        ),
      if (today != null) ...[
        SectionHeading('Today, ${dayLabel(today.day)}'),
        Text(s.textFor(today.doIt), style: text.headlineSmall?.copyWith(height: 1.25)),
        const Para('Drawn by chance, for the sleep ahead. If today cannot be kept, say so tomorrow: it still counts.', color: Night.inkMuted),
        if (stillUpHours(p.now) && today.index > 0)
          const Para('Still up from yesterday? Then yesterday\'s task below is the one for the sleep ahead.', color: Night.inkMuted),
      ],
      for (final d in open)
        ChoiceQuestion<bool>(
          question:
              '${d.day == addDays(s.today, -1) ? 'Yesterday' : dayLabel(d.day)}: ${s.textFor(d.doIt)}. Did you keep to it?',
          choices: const [(true, 'Kept'), (false, 'Not kept')],
          value: null,
          onChanged: (v) => onAnswer?.call(d.day, v),
        ),
      if (s.phase != ExpPhase.waiting) ...[
        const SectionHeading('The days'),
        DayBill(state: s),
      ],
      SectionHeading(sealed ? 'The answer' : (p.early ? 'An early look' : 'The answer')),
      if (sealed) ...[
        Text(
          'Sealed until ${dayLabel(plan.unlocks)}',
          style: text.titleLarge?.copyWith(height: 1.3, fontFeatures: tabular),
        ),
        const Para(
          'Looking while it runs can change how you sleep, rate and keep to the days, and a half-time result is '
          'often wrong. The answer opens by itself the day after the last number.',
          color: Night.inkMuted,
        ),
        if (s.daysDone > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onLookEarly, child: const Text('Look early anyway')),
          ),
      ] else
        ..._answer(context, p),
      const SectionHeading('Kept honest'),
      LogLine(
        s.planOk ? 'Plan and order unchanged' : 'The saved order does not match its fingerprint',
        s.planOk ? 'yes' : 'no',
        color: s.planOk ? Night.live : Night.problem,
      ),
      LogLine('Plan saved', dayLabel(dayKey(plan.created)), detail: 'before day 1; fingerprint ${s.planSha.substring(0, 12)}'),
      LogLine('One number tested', plan.outcome.label, detail: 'chosen at the start', rule: !s.open),
      if (!s.open)
        LogLine('Days ahead', '${plan.days - s.daysDone - (today == null ? 0 : 1)}', detail: 'sealed until they come', rule: false),
      if (!s.open)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onStop, child: const Text('Stop this experiment')),
          ),
        ),
    ];
  }

  List<Widget> _answer(BuildContext context, ExperimentPage p) {
    final text = Theme.of(context).textTheme;
    final s = p.state, plan = s.plan, r = p.results!, t = r.tested, o = r.outcome;
    final looks = s.progress.earlyLooks;
    final a = r.adherence;
    return [
      if (p.early)
        _Mark('Day ${s.daysDone} of ${plan.days}: not the planned answer. It is marked on the final one that you looked.'),
      if (!p.early && s.phase == ExpPhase.stopped)
        _Mark('Stopped after ${_days(s.assignedDays)} of ${plan.days}: fewer days than planned, so a wider range.'),
      if (!p.early && looks.isNotEmpty)
        _Mark(
          'You looked early ${looks.length == 1 ? 'once' : '${looks.length} times'} (first after '
          '${_days(looks.first.daysDone)}): the answer is a little less sure than its range says.',
        ),
      Text(sentence(r, plan.doText, plan.dontText), style: text.titleLarge?.copyWith(height: 1.35, fontFeatures: tabular)),
      Para(verdictNote(r), color: Night.inkMuted),
      const SizedBox(height: 12),
      LogLine('Tested', t == null ? 'no' : 'random days', detail: 'counted as drawn, kept or not'),
      LogLine('Days with a number', '${r.withNumber} of ${r.days}', detail: t == null ? null : '${t.nDo} “do” · ${t.nDont} “don\'t”'),
      if (t != null)
        LogLine('Chance alone', pWords(t.p), detail: '${t.exact ? 'all' : 'sampled from'} ${t.orders} possible orders'),
      LogLine(
        'Kept to the day',
        a.answered == 0 ? 'not answered' : '${a.kept} of ${a.answered}',
        detail: a.answered == 0
            ? null
            : '“do” ${a.keptDo} of ${a.answeredDo} · “don\'t” ${a.kept - a.keptDo} of ${a.answered - a.answeredDo}'
                  '${a.days > a.answered ? ' · ${a.days - a.answered} not answered' : ''}',
        rule: false,
      ),
      const SectionHeading('Seen together, not tested'),
      const Para(
        'Plain differences between the two kinds of day. No range and no verdict: only the one number above was '
        'put to the test.',
        color: Night.inkMuted,
        top: 0,
      ),
      const SizedBox(height: 8),
      if (r.asDone != null)
        LogLine(
          '${o.label}, by what you did',
          signed(o, r.asDone!.diff),
          detail: '${r.asDone!.nDo} · ${r.asDone!.nDont} days; a day not kept counts as the other kind',
          rule: r.others.isNotEmpty,
        ),
      for (final (i, x) in r.others.indexed)
        LogLine(x.outcome.label, signed(x.outcome, x.diff), detail: '${x.nDo} · ${x.nDont} days', rule: i < r.others.length - 1),
      if (r.asDone == null && r.others.isEmpty) const Para('Nothing else has numbers on both kinds of day.', color: Night.inkMuted, top: 0),
    ];
  }
}

/// A caution line with its icon: what the owner did to the run (never colour alone: the words say it).
class _Mark extends StatelessWidget {
  const _Mark(this.words);
  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(Icons.warning_amber_rounded, size: 20, color: Night.caution),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(words, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Night.caution, height: 1.4)),
        ),
      ],
    ),
  );
}

/// A log row: label left, value right in tabular figures, a muted detail under the value.
class LogLine extends StatelessWidget {
  const LogLine(this.label, this.value, {super.key, this.detail, this.rule = true, this.color = Night.ink});
  final String label, value;
  final String? detail;
  final bool rule;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: rule
          ? const BoxDecoration(
              border: Border(bottom: BorderSide(color: Night.rule)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value, textAlign: TextAlign.end, style: text.titleMedium?.copyWith(fontFeatures: tabular, color: color)),
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

class _Earlier extends StatelessWidget {
  const _Earlier({required this.state, required this.rule, this.onTap});
  final ExperimentState state;
  final bool rule;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = state;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: rule
            ? const BoxDecoration(
                border: Border(bottom: BorderSide(color: Night.rule)),
              )
            : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.plan.doText, style: text.bodyLarge?.copyWith(height: 1.3)),
                  const SizedBox(height: 2),
                  Text(
                    '${dayLabel(s.plan.start)} · ${s.plan.outcome.label} · ${statusWords(s).toLowerCase()}',
                    style: text.bodyMedium?.copyWith(color: Night.inkMuted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Night.inkMuted),
          ],
        ),
      ),
    );
  }
}

/// The day bill: one row per week of the experiment, seven of the watch strip's cells. A "do" day is filled, a
/// "don't" day outlined, a day not kept struck through, today outlined green, the days ahead faint and empty.
class DayBill extends StatelessWidget {
  const DayBill({super.key, required this.state});
  final ExperimentState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    final s = state, plan = s.plan;
    final past = s.pastDays, today = s.todayView;
    final weeks = (plan.days / 7).ceil();
    final doDays = past.where((d) => d.doIt).length, notKept = past.where((d) => d.kept == false).length;
    final label =
        'The days so far: ${_days(past.length)} over, $doDays of them “do” days, $notKept not kept; '
        '${plan.days - past.length} still sealed or to come.';
    Widget cell(int i) {
      if (i >= plan.days) return const SizedBox(height: 32);
      final d = i < past.length ? past[i] : null;
      final isToday = today != null && today.index == i;
      final doIt = d?.doIt ?? (isToday && today.doIt);
      final known = d != null || isToday;
      final cut = i >= s.assignedDays; // after a stop
      return Container(
        height: 32,
        decoration: BoxDecoration(
          color: known && doIt ? Night.saved : (known ? Night.track : null),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isToday ? Night.live : (known ? (doIt ? Night.saved : Night.inkMuted) : Night.rule),
            width: isToday ? 2 : 1,
          ),
        ),
        child: d?.kept == false
            ? const Center(child: Icon(Icons.close_rounded, size: 18, color: Night.ink))
            : (cut ? const Center(child: Icon(Icons.remove_rounded, size: 14, color: Night.rule)) : null),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: label,
          container: true,
          child: ExcludeSemantics(
            child: Column(
              children: [
                Row(
                  children: [
                    for (var c = 0; c < 7; c++) ...[
                      if (c > 0) const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          weekdayShort(addDays(plan.start, c))[0],
                          textAlign: TextAlign.center,
                          style: text.bodySmall?.copyWith(color: Night.inkMuted),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                for (var w = 0; w < weeks; w++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        for (var c = 0; c < 7; c++) ...[
                          if (c > 0) const SizedBox(width: 6),
                          Expanded(child: cell(w * 7 + c)),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Filled: a “do” day. Outlined: a “don\'t” day. A cross: not kept. Green outline: today. '
          '${s.open ? 'Faint: never assigned or shown.' : 'Faint: days ahead, sealed until they come.'}',
          style: muted,
        ),
      ],
    );
  }
}
