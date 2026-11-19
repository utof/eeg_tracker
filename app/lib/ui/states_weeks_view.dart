// Sound for states over weeks (ROADMAP row 18, DECISIONS rows 430-439), two sections near the end of the states
// page (states_view.dart) for the state being chosen, and the fair test's setup page.
// - What works for you: the comparison ledger (.impeccable/surfaces/app-lib-ui-states-screen-dart.md, structure 7,
//   declined before for want of an engine): one row per sound played, its name and its median at the right; under
//   it the watch strip's own cells counting sessions with a number toward 14, then, once there, a lane on one scale
//   for every row (the middle half a `saved` band, the median an ink tick, the sharp-hours chart's marks); a muted
//   line saying it is seen together, not tested.
// - A fair test: the test's place, like the self-experiments' answer: the offer (outlined Plan a fair test), the day
//   and today's drawn sound while it runs, "sealed until", then the tested sentence with its log rows.
// - The setup page: two sounds (bed and beat chips each), the length, the weeks, what counts and what cannot be
//   changed; Start tomorrow pinned.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../experiments/analysis.dart' show pWords;
import '../experiments/experiment.dart' show ExpPhase;
import '../states/presets.dart';
import '../states/trial.dart';
import '../states/weeks.dart';
import '../trends/days.dart' show addDays, dayKey, dayLabel;
import 'experiments_view.dart' show LogLine;
import 'form_parts.dart' show ChoiceQuestion, Para, PinnedAction;
import 'parts.dart';
import 'states_view.dart' show soundChips, soundSegments;
import 'theme.dart';

/// Where [v] sits on a lane, 0 (left) to 1 (right): 0 to 45 min, ratios from half to double on a log scale (the
/// quiet minute in the middle), answers 1 to 5. Outside values sit at the ends.
double lanePosition(StateMeasure m, double v) {
  final x = m.logScale
      ? (math.log(v) - math.log(0.5)) / (math.log(2) - math.log(0.5))
      : (m.rating ? (v - 1) / 4 : v / WeeksRule.capMin);
  return x.isFinite ? x.clamp(0.0, 1.0) : 0;
}

/// The lanes' ends in words, for the legend.
String laneEnds(StateMeasure m) => m.logScale
    ? 'from −50 % to +100 % against the quiet minute (the hairline in the middle)'
    : (m.rating ? 'from 1 to 5' : 'from 0 to ${WeeksRule.capMin.round()} min');

/// "What works for you": the sounds of one state over the weeks, seen together, not tested.
class SoundLedger extends StatelessWidget {
  const SoundLedger({super.key, required this.comparison});
  final StateComparison comparison;

  @override
  Widget build(BuildContext context) {
    final c = comparison, m = c.measure, name = presets[c.state]!.name;
    final lanes = c.rows.any((r) => r.enough), cells = c.rows.any((r) => !r.enough);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading('What works for you'),
        Para('For $name: ${m.how[0].toLowerCase()}${m.how.substring(1)}', color: Night.inkMuted, top: 0),
        const SizedBox(height: 8),
        if (c.rows.isEmpty)
          Para('No $name sessions yet. Each one lands here under its sound.', color: Night.inkMuted, top: 4)
        else
          for (final (i, r) in c.rows.indexed) _LedgerRow(row: r, measure: m, rule: i < c.rows.length - 1),
        if (c.rows.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            [
              if (cells) 'Cells: sessions with a number, toward ${WeeksRule.minSessions}.',
              if (lanes) 'Lanes run ${laneEnds(m)}: the band is the middle half of the sessions, the line the median.',
            ].join(' '),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
          ),
          const Para(
            'Seen together, not tested: you chose the sound, and the days you chose each one may differ in other ways '
            '(how tired you were, the hour). A fair test lets chance choose.',
            color: Night.inkMuted,
          ),
        ],
      ],
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.row, required this.measure, required this.rule});
  final SoundRow row;
  final StateMeasure measure;
  final bool rule;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme, r = row;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: rule ? const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(r.line, style: text.bodyLarge?.copyWith(height: 1.3))),
              const SizedBox(width: 16),
              Text(
                rowValue(measure, r),
                style: text.titleMedium?.copyWith(fontFeatures: tabular, color: r.enough ? Night.ink : Night.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          r.enough ? _Lane(row: r, measure: measure) : _Cells(r.values.length),
          const SizedBox(height: 8),
          Text(rowDetail(measure, r), style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
        ],
      ),
    );
  }
}

/// The watch strip's cells counting sessions with a number toward [WeeksRule.minSessions]; a wider gap after 7.
class _Cells extends StatelessWidget {
  const _Cells(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    const k = WeeksRule.minSessions;
    return Semantics(
      container: true,
      label: '$n of $k sessions with a number',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var i = 0; i < k; i++) ...[
              if (i > 0) SizedBox(width: i == k ~/ 2 ? 12 : 4),
              Expanded(
                child: Container(
                  height: 12,
                  decoration: BoxDecoration(color: i < n ? Night.saved : Night.track, borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One sound on the shared scale: the track, the middle half in `saved`, the median as an ink tick; the quiet
/// minute as a hairline for ratios.
class _Lane extends StatelessWidget {
  const _Lane({required this.row, required this.measure});
  final SoundRow row;
  final StateMeasure measure;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'median ${measure.show(row.median!)}, middle half ${measure.between(row.low!, row.high!)}',
    child: ExcludeSemantics(
      child: CustomPaint(
        size: const Size.fromHeight(16),
        painter: _LanePainter(
          lanePosition(measure, row.low!),
          lanePosition(measure, row.high!),
          lanePosition(measure, row.median!),
          measure.logScale ? 0.5 : null,
        ),
      ),
    ),
  );
}

class _LanePainter extends CustomPainter {
  _LanePainter(this.low, this.high, this.median, this.middle);
  final double low, high, median;
  final double? middle;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 2.0;
    final h = size.height, w = size.width;
    final track = RRect.fromLTRBR(0, pad, w, h - pad, const Radius.circular(3));
    canvas.drawRRect(track, Paint()..color = Night.track);
    final m = middle;
    if (m != null) canvas.drawRect(Rect.fromLTWH(w * m - 0.5, pad, 1, h - 2 * pad), Paint()..color = Night.inkMuted);
    final a = w * low, b = math.max(w * high, a + 3);
    canvas.drawRRect(RRect.fromLTRBR(a, pad, b, h - pad, const Radius.circular(3)), Paint()..color = Night.saved);
    final x = (w * median).clamp(1.0, w - 1);
    canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, h), Paint()..color = Night.ink);
  }

  @override
  bool shouldRepaint(_LanePainter old) => old.low != low || old.high != high || old.median != median || old.middle != middle;
}

String _weeks(int days) => days % 7 == 0 ? '${days ~/ 7} weeks' : '$days days';

/// The fair test's place for one state: the offer, the running test with today's sound, or the tested answer.
class FairTest extends StatelessWidget {
  const FairTest({super.key, required this.state, this.test, this.results, this.onPlan, this.onStop});
  final SoundState state;

  /// The state's test under way, or its latest one once the answer is open; null: none yet.
  final TrialState? test;

  /// The answer, once open.
  final TrialResults? results;
  final VoidCallback? onPlan;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final t = test, text = Theme.of(context).textTheme;
    final big = text.titleLarge?.copyWith(height: 1.3, fontFeatures: tabular);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading('A fair test'),
        if (t == null) ..._offer(context) else if (t.open && results != null) ..._answer(context, results!) else ..._running(context, t, big),
      ],
    );
  }

  List<Widget> _offer(BuildContext context) => [
    Para(
      'Let the app choose between two sounds for ${presets[state]!.name}: one on random days, the other on the rest, '
      'for 4 to 8 weeks. Then it tests the difference. Chance picked the days, so nothing else can explain it.',
      color: Night.inkMuted,
      top: 0,
    ),
    const SizedBox(height: 16),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(onPressed: onPlan, icon: const Icon(Icons.shuffle_rounded), label: const Text('Plan a fair test')),
    ),
  ];

  List<Widget> _running(BuildContext context, TrialState t, TextStyle? big) {
    final p = t.plan, st = p.state, today = t.todaySound, m = p.measure;
    final pair = '“${p.a.line(st)}” against “${p.b.line(st)}”, ${p.minutes} min, ${_weeks(p.days)}.';
    final counts = m.rating
        ? 'Answer the question after each session: a day without an answer is left out.'
        : 'Wear the headband for each session: a day without a number is left out.';
    return [
      Text(switch (t.phase) {
        ExpPhase.waiting => t.todayIndex == -1 ? 'Starts tomorrow' : 'Starts ${dayLabel(p.start)}',
        ExpPhase.running => 'Day ${t.todayIndex + 1} of ${p.days}',
        _ => 'Every day is done',
      }, style: big),
      if (today != null) Para('Today\'s sound, drawn for you: ${today.line(st)}.', top: 10),
      Para(
        t.phase == ExpPhase.running || t.phase == ExpPhase.waiting
            ? '$pair Each day\'s sound is set when that day comes, and the sound and the length stay fixed until the '
                  'end. $counts'
            : '$pair The last day\'s number can still come in.',
        color: Night.inkMuted,
      ),
      const SizedBox(height: 12),
      LogLine('The answer opens', dayLabel(p.unlocks), detail: 'sealed until then', rule: false),
      if (t.phase != ExpPhase.lastNumber)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: onStop, child: const Text('Stop this test')),
        ),
    ];
  }

  List<Widget> _answer(BuildContext context, TrialResults r) {
    final text = Theme.of(context).textTheme, s = r.state, t = r.tested;
    return [
      if (s.phase == ExpPhase.stopped)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.warning_amber_rounded, size: 22, color: Night.caution)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Stopped after ${r.days} of ${s.plan.days} days: fewer days than planned, so a wider range.',
                  style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      Text(trialSentence(r), style: text.titleLarge?.copyWith(height: 1.35, fontFeatures: tabular)),
      Para(trialNote(r), color: Night.inkMuted),
      const SizedBox(height: 12),
      const LogLine('Tested', 'random days', detail: 'each day\'s sound drawn by chance'),
      LogLine(
        'Days with a number',
        '${r.withNumber} of ${r.days}',
        detail: t == null ? null : '${t.nDo} with the first sound · ${t.nDont} with the second',
      ),
      if (t != null) LogLine('Chance alone', pWords(t.p), detail: '${t.exact ? 'all' : 'sampled from'} ${t.orders} possible orders'),
      LogLine(
        s.planOk ? 'Plan and order unchanged' : 'The saved order does not match its fingerprint',
        s.planOk ? 'yes' : 'no',
        color: s.planOk ? Night.live : Night.problem,
        rule: false,
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(onPressed: onPlan, icon: const Icon(Icons.shuffle_rounded), label: const Text('Plan another test')),
      ),
    ];
  }
}

/// What the setup hands back.
typedef FairTestChoice = ({SoundPick a, SoundPick b, int minutes, int weeks});

/// The second sound offered first: the same bed with a pulse added, or without its beat.
SoundPick otherSound(SoundState state, SoundPick a) {
  final bed = a.bed == Bed.none ? presets[state]!.bed : a.bed;
  return a.beat == Beat.none ? SoundPick(bed, Beat.pulsed) : SoundPick(bed, Beat.none);
}

/// The fair test's setup page: two sounds, the length, the weeks; Start tomorrow pinned.
class FairTestSetup extends StatefulWidget {
  const FairTestSetup({super.key, required this.state, required this.first, required this.minutes, required this.now, required this.onStart, this.onInfo});
  final SoundState state;

  /// The sound chosen on the page (the first sound offered) and its length.
  final SoundPick first;
  final int minutes;
  final DateTime now;
  final ValueChanged<FairTestChoice> onStart;
  final VoidCallback? onInfo;

  @override
  State<FairTestSetup> createState() => _FairTestSetupState();
}

class _FairTestSetupState extends State<FairTestSetup> {
  late SoundPick _a = widget.first.valid ? widget.first : SoundPick(presets[widget.state]!.bed, Beat.none);
  late SoundPick _b = otherSound(widget.state, _a);
  late int _minutes = presets[widget.state]!.minutes.contains(widget.minutes) ? widget.minutes : presets[widget.state]!.defaultMinutes;
  int _weeks = TrialRule.weeks.first;

  List<Widget> _sound(BuildContext context, String title, SoundPick v, ValueChanged<SoundPick> on) {
    final text = Theme.of(context).textTheme;
    return [
      SectionHeading(title),
      soundChips<Bed>(context, [for (final b in Bed.values) (b, bedNames[b]!)], v.bed, (b) => on(SoundPick(b, v.beat)),
          disabled: {if (v.beat == Beat.none) Bed.none}),
      const SizedBox(height: 18),
      Text('Beat', style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
      const SizedBox(height: 8),
      soundChips<Beat>(context, [for (final b in Beat.values) (b, beatNames[b]!)], v.beat, (b) => on(SoundPick(v.bed, b)),
          disabled: {if (v.bed == Bed.none) Beat.none}),
      const SizedBox(height: 12),
      Text(v.line(widget.state), style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme, st = widget.state, p = presets[st]!, m = stateMeasures[st]!;
    final start = addDays(dayKey(widget.now), 1), days = _weeks * 7;
    final missing = _a == _b ? 'Choose two different sounds' : null;
    return Scaffold(
      appBar: AppBar(
        title: Text('Fair test: ${p.name}', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: widget.onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline), color: Night.inkMuted),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Para(
            'Two sounds for ${p.name}. Each day the app draws which one plays, and at the end it tests the difference in '
            '${m.label.toLowerCase()}.',
            color: Night.inkMuted,
            top: 0,
          ),
          ..._sound(context, 'First sound', _a, (v) => setState(() => _a = v)),
          ..._sound(context, 'Second sound', _b, (v) => setState(() => _b = v)),
          const SectionHeading('Length'),
          soundSegments<int>(context, [for (final v in p.minutes) (v, '$v min')], _minutes, (v) => setState(() => _minutes = v)),
          ChoiceQuestion<int>(
            question: 'How many weeks?',
            choices: [for (final w in TrialRule.weeks) (w, '$w weeks')],
            value: _weeks,
            onChanged: (w) => setState(() => _weeks = w),
          ),
          const Para(
            'A clear difference takes 3 to 6 weeks of daily sessions; a 2-minute difference in falling asleep is barely '
            'seen in a month. Longer tests find smaller differences.',
            color: Night.inkMuted,
          ),
          const SectionHeading('What counts'),
          Para(m.how, top: 0),
          const Para(
            'One session a day counts: the first one of the day with a number. A day without one is left out.',
            color: Night.inkMuted,
          ),
          const SectionHeading('Before you start'),
          Para(
            'Day 1 is tomorrow, ${dayLabel(start)}; the last day is ${dayLabel(addDays(start, days - 1))}. The answer '
            'opens ${dayLabel(addDays(start, days + 1))}.',
            top: 0,
          ),
          Para(
            'The two sounds, the length and the weeks cannot be changed after the start, and the days ahead stay '
            'hidden. You will hear which sound plays, so what you expect can be part of the difference'
            '${m.weak ? ', and all of it for your own answer' : ''}.',
            color: Night.inkMuted,
          ),
        ],
      ),
      bottomNavigationBar: PinnedAction(
        child: FilledButton(
          onPressed: missing != null ? null : () => widget.onStart((a: _a, b: _b, minutes: _minutes, weeks: _weeks)),
          child: Text(missing ?? 'Start tomorrow'),
        ),
      ),
    );
  }
}
