// The replay check's results (DECISIONS row 103): opened from the training settings, only once a whole set of
// 12 randomised sessions exists. The one number (live minus replay of the primary measure, as a percentage)
// with its permutation test, the guesses against chance, how sessions felt in each kind, every session of the
// set with what it was, whether the plan and the order are unchanged, and the honest note.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../recorder/nights.dart' show nightLabel;
import '../training/check.dart';
import '../training/check_store.dart';
import '../training/control.dart';
import '../training/reveal.dart';
import 'evidence_sheet.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'theme.dart';

class ReplayResultsScreen extends StatelessWidget {
  const ReplayResultsScreen({super.key, required this.store});
  final CheckStore store;

  @override
  Widget build(BuildContext context) => ReplayResultsView(
    kind: store.kind,
    reveal: store.reveal(),
    untilReveal: store.untilReveal,
    onInfo: () => showEvidence(context, 'replay-check'),
  );
}

/// The primary difference as a percentage change of the measured ratio (10^diff - 1).
String percentWords(double diffLog) {
  final pct = (math.pow(10, diffLog) - 1) * 100;
  final r = pct.round();
  return '${r > 0
      ? '+'
      : r < 0
      ? '−'
      : ''}${r.abs()} %';
}

String pWords(double p) => p < 0.001 ? '< 0.001' : p.toStringAsFixed(p < 0.01 ? 3 : 2);

class ReplayResultsView extends StatelessWidget {
  const ReplayResultsView({
    super.key,
    required this.kind,
    required this.reveal,
    required this.untilReveal,
    required this.onInfo,
  });
  final SessionKind kind;
  final Reveal? reveal;
  final int untilReveal;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = reveal;
    final measure = kind == SessionKind.meditation ? 'alpha' : 'theta / alpha';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Replay check: ${kind == SessionKind.meditation ? 'meditation' : 'alpha-theta'}',
          style: text.titleMedium?.copyWith(color: Night.inkMuted),
        ),
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
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: r == null
            ? [
                Text('Locked', style: text.displaySmall),
                Para(
                  'Results come after every ${CheckRule.revealEvery} sessions, never one at a time, so a single good '
                  'or bad session cannot steer the rest. $untilReveal more to go.',
                  color: Night.inkMuted,
                ),
              ]
            : _shown(context, r, measure),
      ),
    );
  }

  List<Widget> _shown(BuildContext context, Reveal r, String measure) {
    final text = Theme.of(context).textTheme;
    final p = r.primary;
    final first = r.shown.first.index + 1, last = r.shown.last.index + 1;
    String mean((double?, double?) v) => '${v.$1?.toStringAsFixed(1) ?? '–'} · ${v.$2?.toStringAsFixed(1) ?? '–'}';
    return [
      Text('Sessions $first-$last', style: text.displaySmall),
      Para(
        p == null
            ? 'Not enough usable sessions of each kind for the test.'
            : p.p < 0.05
            ? 'Live and replay sessions differed.'
            : 'No clear difference between live and replay.',
        color: Night.inkMuted,
        top: 10,
      ),
      if (p != null) ...[
        const SizedBox(height: 28),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Readout(parts: [(percentWords(p.diff), true)], label: '$measure, live against replay'),
              ),
              const VerticalDivider(width: 33),
              Expanded(
                child: Readout(
                  parts: [('p ', false), (pWords(p.p), true)],
                  label: '${p.exact ? 'all' : 'sampled from'} ${p.orders} orders',
                ),
              ),
            ],
          ),
        ),
      ],
      const SectionHeading('Your guesses'),
      _Line(
        'Right',
        r.judged == 0 ? 'no guesses' : '${r.right} of ${r.judged}',
        detail: r.guessP == null ? null : 'chance alone: p = ${pWords(r.guessP!)}',
      ),
      _Line('Not sure', '${r.unsure}', rule: false),
      const SectionHeading('How it felt (live · replay, 1-5)'),
      _Line('Calm afterwards', mean(r.means['calm']!)),
      _Line('In control of the sound', mean(r.means['control']!)),
      _Line('The sound seemed random', mean(r.means['random']!), rule: false),
      const SectionHeading('Every session of the set'),
      for (final (i, s) in r.shown.indexed)
        _Line(
          '${s.index + 1} · ${nightLabel(s.start)}',
          s.arm == Arm.live ? 'live' : 'replay',
          detail: [
            'guess ${switch (s.ratings?.guess) {
              'live' => 'live',
              'replay' => 'replay',
              'unsure' => 'not sure',
              _ => 'none',
            }}',
            s.outcome == null ? 'no measure' : percentWords(s.outcome!),
            if (s.excluded) 'left out',
          ].join(' · '),
          rule: i < r.shown.length - 1,
        ),
      const SectionHeading('Kept honest'),
      _Line(
        r.planOk ? 'Plan and order unchanged' : 'The saved order does not match its fingerprint',
        r.planOk ? 'yes' : 'no',
        color: r.planOk ? Night.live : Night.problem,
      ),
      _Line('Left out (over 30 % asleep, restless or no signal)', '${r.excluded}'),
      if (r.deviations > 0) _Line('Played live instead of a replay', '${r.deviations}'),
      _Line('Still sealed', '${r.hidden}', detail: 'sessions after this set', rule: false),
      const SectionHeading('What this means'),
      for (final n in r.note) Para(n, top: 0),
    ];
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.detail, this.rule = true, this.color = Night.ink});
  final String label;
  final String value;
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
          Expanded(
            child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  textAlign: TextAlign.end,
                  style: text.titleMedium?.copyWith(fontFeatures: tabular, color: color),
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
