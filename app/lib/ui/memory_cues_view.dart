// The Memory cues page (DECISIONS 500-509, the assistant's proposal; DESIGN.md "Memory cues";
// .impeccable/surfaces/app-lib-ui-memory-cues-screen-dart.md): a settings page that is also the experiment's log.
// Whose idea and how weak the evidence, the status, the switch row, Tonight / This morning / Night of the test as
// label-left / value-right rows, Last night with the board showing where memory drifted, The test (the night cells,
// sealed, later the tested number apart from what is only seen together), How it works, Who should not use it; the due
// action pinned. Built from a MemoryViewModel only, so tests render every state.
import 'package:flutter/material.dart';

import '../memory_cues/plan.dart';
import '../memory_cues/rule.dart';
import '../memory_cues/store.dart';
import '../memory_cues/task.dart';
import '../training/reveal.dart' show PermutationResult;
import 'form_parts.dart' show PinnedAction;
import 'lucid_view.dart' show IconNote, LogValueRow, NightCells;
import 'meditation_view.dart' show MarkShape, StateMark;
import 'memory_task_view.dart' show DriftBoard;
import 'parts.dart';
import 'theme.dart';

enum MemoryDue { turnOn, waiting, morning, evening, ready, night }

/// The last finished night in the test, with what its morning gave.
class MemoryLastNight {
  const MemoryLastNight({required this.record, this.session, this.morning, this.expired = false});
  final MemoryNightRecord record;
  final MemorySession? session;
  final MemoryMorning? morning;

  /// The morning test's time ran out (or a new evening began) before it was done.
  final bool expired;
}

class MemoryViewModel {
  const MemoryViewModel({
    required this.on,
    required this.due,
    this.lucidOn = false,
    this.readyAt,
    this.nightRunning = false,
    this.last,
    this.nights = const [],
    this.nextIndex = 0,
    this.results,
    this.levels,
  });
  final bool on, lucidOn, nightRunning;
  final MemoryDue due;

  /// When tonight's session was finished (ready).
  final DateTime? readyAt;
  final MemoryLastNight? last;

  /// The test's nights so far: finished with both tests (answered).
  final List<({bool answered, bool lucid})> nights;
  final int nextIndex;
  final MemoryResults? results;

  /// The newest session's loudness of each sound (share of the media volume).
  final List<double>? levels;
}

String _two(int v) => v.toString().padLeft(2, '0');
String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
String _pct(double v) => '${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0)} %';

class MemoryView extends StatelessWidget {
  const MemoryView({
    super.key,
    required this.model,
    required this.onTurnOn,
    required this.onTurnOff,
    required this.onEvening,
    required this.onMorning,
    required this.onInfo,
  });

  final MemoryViewModel model;
  final VoidCallback onTurnOn, onTurnOff, onEvening, onMorning, onInfo;

  @override
  Widget build(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme, last = m.last;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory cues'),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says'),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          Text(
            'The assistant\'s proposal. The evidence is weak: a 13-lab replication is due around 2027.',
            style: muted,
          ),
          const SizedBox(height: 18),
          _status(context),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Memory cues'),
            subtitle: Text(
              m.on ? 'On: on test nights the recorder plays one of the two sounds.' : 'Off: no task, no sounds.',
              style: muted,
            ),
            value: m.on,
            onChanged: (v) => v ? onTurnOn() : onTurnOff(),
          ),
          const Divider(height: 8),
          LogValueRow(label: 'Tonight', value: _tonightValue()),
          LogValueRow(label: 'This morning', value: _morningValue()),
          LogValueRow(label: 'Night of the test', value: '${m.nextIndex + 1} of ${MemoryTest.maxNights}'),
          LogValueRow(label: 'Bell loudness', value: m.levels == null ? 'not set' : '${_pct(m.levels![0])} of media'),
          LogValueRow(
            label: 'Knock loudness',
            value: m.levels == null ? 'not set' : '${_pct(m.levels![1])} of media',
            last: true,
          ),
          if (last != null) ...[const SectionHeading('Last night'), _lastNight(context, last)],
          const SectionHeading('The test'),
          _test(context),
          const SectionHeading('How it works'),
          const IconNote(
            Icons.grid_view_outlined,
            'In the evening you learn where ${TaskRule.objects} objects sit on a board: half come with a soft bell, '
            'half with a soft knock. Then you place each one with no help.',
          ),
          IconNote(
            Icons.bedtime_outlined,
            'In the night\'s first hours (from ${MemoryRule.cuesFrom.inMinutes} minutes to '
            '${(MemoryRule.cuesUntil.inMinutes / 60).toStringAsFixed(1)} hours after Lights off), when the sleep model '
            'reads light or deep sleep (N2 or N3) and you lie still, one of the two sounds plays, ${MemoryRule.marginDb} '
            'dB under the loudness you tapped. At most one every ${MemoryRule.spacingS} s and ${MemoryRule.perNight} a '
            'night; a stir makes it quieter and pauses it, three stirs end it.',
          ),
          const IconNote(
            Icons.visibility_off_outlined,
            'Some nights are silent on purpose, and which half\'s sound plays is hidden too. In the morning you place '
            'the objects again; after 12 nights the app tests whether the half whose sound played kept its places '
            'better.',
          ),
          IconNote(
            Icons.info_outline,
            'In the lab this effect is small and several careful recent studies found none. Sounds that wake you make '
            'the cued memories worse, which is why they are so quiet. The i button says more.',
            onTap: onInfo,
          ),
          const SectionHeading('Who should not use it'),
          const IconNote(
            Icons.warning_amber_outlined,
            'Sounds in the night can disturb sleep, yours and a partner\'s. Turn it off if your sleep gets worse or the '
            'sounds wake you. Not with poor sleep or a sleep disorder.',
            color: Night.caution,
          ),
        ],
      ),
      bottomNavigationBar: _action() == null ? null : PinnedAction(child: _action()!),
    );
  }

  String _tonightValue() {
    final m = model;
    return switch (m.due) {
      MemoryDue.turnOn => '-',
      MemoryDue.waiting => 'lucid cues instead',
      MemoryDue.ready => 'learned ${_hm(m.readyAt!)}',
      MemoryDue.night => 'recording',
      MemoryDue.morning || MemoryDue.evening => 'learn the board',
    };
  }

  String _morningValue() {
    final last = model.last;
    if (model.due == MemoryDue.morning) return 'test due';
    if (last == null) return '-';
    if (last.morning != null) return 'done ${_hm(last.morning!.made)}';
    return last.expired ? 'missed' : '-';
  }

  Widget? _action() {
    final m = model;
    return switch (m.due) {
      MemoryDue.turnOn => FilledButton.icon(
        onPressed: onTurnOn,
        icon: const Icon(Icons.nights_stay_outlined),
        label: const Text('Turn on'),
      ),
      MemoryDue.morning => FilledButton.icon(
        onPressed: onMorning,
        icon: const Icon(Icons.grid_view_outlined),
        label: const Text('Start the morning test'),
      ),
      MemoryDue.evening => FilledButton.icon(
        onPressed: onEvening,
        icon: const Icon(Icons.grid_view_outlined),
        label: const Text('Start the evening task'),
      ),
      MemoryDue.ready || MemoryDue.night || MemoryDue.waiting => null,
    };
  }

  Widget _status(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final (String word, String sentence, MarkShape mark, Color color) = switch (m.due) {
      MemoryDue.turnOn => (
        'Off',
        'Soft sounds in deep sleep, to help one half of an evening task stick. A self-test, about 12 minutes each '
            'evening and 2 each morning.',
        MarkShape.ring,
        Night.inkMuted,
      ),
      MemoryDue.waiting => (
        'Waiting',
        'Lucid cues are on, and only one kind of cue plays a night. Switch them off on the Lucid dreams page to run '
            'this test.',
        MarkShape.ringedDot,
        Night.caution,
      ),
      MemoryDue.morning => (
        'Test this morning',
        'The same board as last evening, about 2 minutes. Do it before the day fills your head.',
        MarkShape.ringedDot,
        Night.live,
      ),
      MemoryDue.evening => (
        'Learn tonight',
        'The evening task takes about 12 minutes. Do it before Start night; it counts for 3 hours.',
        MarkShape.ringedDot,
        Night.live,
      ),
      MemoryDue.ready => (
        'Ready for tonight',
        'Learned at ${_hm(m.readyAt!)}. Start the night by ${_hm(m.readyAt!.add(sessionFreshFor))}.',
        MarkShape.filled,
        Night.live,
      ),
      MemoryDue.night => (
        'Tonight',
        'The night recorder has tonight\'s sounds, if it is a night with sound. Sleep well.',
        MarkShape.filled,
        Night.live,
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: _firstLineMid(context) - 7),
                child: StateMark(shape: mark, color: color),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(word, style: text.displaySmall)),
            ],
          ),
          const SizedBox(height: 10),
          Text(sentence, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
          if (m.results != null) ...[
            const SizedBox(height: 8),
            Text('The test is open: ${_verdictShort(m.results!.verdict)}. See The test below.', style: text.bodyLarge),
          ],
        ],
      ),
    );
  }

  static String _verdictShort(MemoryVerdict v) => switch (v) {
    MemoryVerdict.likely => 'likely real for you',
    MemoryVerdict.notClear => 'not clear yet',
    MemoryVerdict.tooFew => 'too few nights to say',
  };

  static double _firstLineMid(BuildContext context) {
    final d = Theme.of(context).textTheme.displaySmall;
    final line = (d?.fontSize ?? 36) * (d?.height ?? 1.22);
    return MediaQuery.textScalerOf(context).scale(line) / 2;
  }

  Widget _lastNight(BuildContext context, MemoryLastNight last) {
    final text = Theme.of(context).textTheme, r = last.record, s = last.session, mo = last.morning;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final rows = <Widget>[
      LogValueRow(label: 'Night of the test', value: '${r.index + 1}'),
      LogValueRow(label: 'Cue moments', value: '${r.cues.length}'),
      LogValueRow(label: 'A stir after one', value: '${r.cues.where((c) => c.aroused).length}'),
    ];
    if (s != null && mo != null) {
      final ce = closeCount(s, s.evening), cm = closeCount(s, mo.taps);
      rows.addAll([
        LogValueRow(label: 'Placed close', value: '$ce, then $cm of ${TaskRule.objects}'),
        LogValueRow(
          label: 'Distance on average, % of the board\'s width',
          value:
              '${boardPercent(meanError(s, s.evening)).replaceAll(' %', '')}, then '
              '${boardPercent(meanError(s, mo.taps)).replaceAll(' %', '')}',
          last: true,
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s != null && mo != null) ...[
          DriftBoard(session: s, taps: mo.taps, maxHeight: 300),
          const SizedBox(height: 8),
          Text('Each object at its place; the line runs to where you put it this morning.', style: muted),
          const SizedBox(height: 8),
        ],
        ...rows,
        const SizedBox(height: 8),
        Text(
          r.off != null
              ? 'That night the cues stopped early: ${_offReason(r.off!)}.'
              : 'Cue moments are the same on silent nights, so they do not tell whether a sound played. "Then" is this '
                    'morning against last evening: forgetting overnight is normal.',
          style: muted,
        ),
        if (mo == null && last.expired)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('No morning test: its time ran out.', style: muted),
          ),
      ],
    );
  }

  /// The engine's sentence for why the cues went off, told of a past night.
  static String _offReason(String off) {
    const reasons = [
      ('sleep model stopped', 'the sleep model failed or was too slow'),
      ('not running', 'the sleep model was not running'),
      ('ended while the sleep model ran', 'the app had ended while the sleep model ran'),
      ('cue rule failed', 'the cue rule failed'),
      ('DIY board', 'the DIY board was recording, and the sleep model reads the BrainBit'),
      ('recorder stopped them', 'the recorder\'s guard switched them off (too slow or too much memory)'),
    ];
    for (final (key, words) in reasons) {
      if (off.contains(key)) return words;
    }
    return 'the night\'s log in Export data says why';
  }

  Widget _test(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final r = m.results;
    final done = m.nights.length;
    final toGo = MemoryTest.revealEvery - done % MemoryTest.revealEvery;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NightCells(
          nights: m.nights,
          next: m.on && m.due != MemoryDue.waiting ? m.nextIndex : -1,
          sound: r == null ? null : [for (final a in r.arms) a == MemoryArm.sound],
        ),
        const SizedBox(height: 10),
        Text(
          r == null
              ? 'Filled: both tests done. Dark: a test missed. Outlined: nights to come, their kind sealed.'
              : 'Filled: both tests done. Dark: a test missed. A bar under a night: it had sound; none: silent.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted),
        ),
        const SizedBox(height: 16),
        if (r == null) ...[
          Text(
            done == 0
                ? 'Sealed until night ${MemoryTest.revealEvery}. The first evening task and night start the test.'
                : 'Sealed until night ${MemoryTest.revealEvery}: $toGo ${toGo == 1 ? 'night' : 'nights'} to go. Which '
                      'nights had sound, and which half, stays hidden until then.',
            style: text.titleMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'In each block of 4 nights, 2 have sound. The phone drew the order and each night\'s half before the first '
            'night and locked them with a fingerprint. One person, a few weeks: expect "not clear" and take it as an '
            'answer.',
            style: muted,
          ),
        ] else
          MemoryResultsView(results: r),
      ],
    );
  }
}

/// The test's answer, once whole sets of 12 nights are in: the verdict on the one tested number, the halves per kind
/// of night as a table, the other numbers apart, and the plan check.
class MemoryResultsView extends StatelessWidget {
  const MemoryResultsView({super.key, required this.results});
  final MemoryResults results;

  @override
  Widget build(BuildContext context) {
    final r = results, text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    final s = r.shown.isEmpty ? null : r.shown.first;
    String pts(double? v) => v == null ? '-' : '${v >= 0 ? '+' : '-'}${(v.abs() * 100).toStringAsFixed(1)}';
    final p = r.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(switch (r.verdict) {
          MemoryVerdict.likely => 'Likely real for you: the half whose sound played kept its places better.',
          MemoryVerdict.notClear => 'Not clear yet: no difference the coins could not have made by chance.',
          MemoryVerdict.tooFew =>
            'Too few nights to say: the test needs ${MemoryTest.minSoundNights} nights with sound and both tests.',
        }, style: text.titleMedium),
        const SizedBox(height: 8),
        if (p != null)
          Text(
            'On ${p.live} ${p.live == 1 ? 'night' : 'nights'} with sound, the half whose sound played drifted '
            '${(p.diff.abs() * 100).toStringAsFixed(1)}\u00a0% of the board\'s width ${p.diff >= 0 ? 'less' : 'more'} '
            'than the other half (p\u00a0=\u00a0${p.p < 0.001 ? '<\u00a00.001' : p.p.toStringAsFixed(p.p < 0.01 ? 3 : 2)}, '
            '${p.exact ? 'every way' : '${p.orders} ways'} the coins could have fallen). Tested.',
            style: text.bodyLarge?.copyWith(height: 1.4),
          ),
        const SizedBox(height: 14),
        Text('Drift overnight, % of the board\'s width (more is worse)', style: muted),
        const _Row3('', 'Sound nights', 'Silent', head: true),
        _Row3('Half whose sound played (or would)', pts(r.soundNights.played), pts(r.silentNights.played)),
        _Row3('The other half', pts(r.soundNights.other), pts(r.silentNights.other)),
        _Row3('Nights with both tests', '${r.soundNights.nights}', '${r.silentNights.nights}', last: true),
        const SizedBox(height: 12),
        Text(
          'Also tested, no verdict: a sound heard in the night ${_heard(r.heard, r.heardShare)}; the other half drifted '
          '${_other(r.otherHalf)}. Seen together, not tested: stirs after a cue moment '
          '${_share(r.arousalShare.$1)} on sound nights, ${_share(r.arousalShare.$2)} on silent ones (the same moments '
          'without sound).',
          style: muted,
        ),
        const SizedBox(height: 8),
        Text(
          r.planOk
              ? 'The plan and the schedule match their fingerprints from before night 1.'
              : 'The plan or the schedule does not match its fingerprint: these results cannot be trusted.',
          style: muted?.copyWith(color: r.planOk ? Night.inkMuted : Night.problem),
        ),
        if (r.unanswered > 0 || r.hidden > 0 || s == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              [
                if (r.unanswered > 0)
                  '${r.unanswered} of ${r.shown.length} nights ${r.unanswered == 1 ? 'misses' : 'miss'} a test and '
                      '${r.unanswered == 1 ? 'is' : 'are'} left out.',
                if (r.hidden > 0)
                  '${r.hidden} newer ${r.hidden == 1 ? 'night waits' : 'nights wait'} for the next set of 12.',
              ].join(' '),
              style: muted,
            ),
          ),
      ],
    );
  }

  static String _share(double? v) => v == null ? '-' : _pc(v);

  static String _p(PermutationResult t) => 'p\u00a0=\u00a0${t.p.toStringAsFixed(2)}';

  static String _pc(double v) => '${(v * 100).round()}\u00a0%';

  /// Mornings with a sound heard: the two shares, sound nights and silent nights.
  static String _heard(PermutationResult? t, (double?, double?) shares) =>
      t == null || shares.$1 == null || shares.$2 == null
      ? '(not enough nights)'
      : 'on ${_pc(shares.$1!)} of mornings after nights with sound, ${_pc(shares.$2!)} after silent ones (${_p(t)})';

  /// The other half's drift, sound nights against silent ones.
  static String _other(PermutationResult? t) => t == null
      ? '(not enough nights)'
      : '${(t.diff.abs() * 100).toStringAsFixed(1)}\u00a0% of the width ${t.diff >= 0 ? 'more' : 'less'} on nights with sound '
            'than on silent ones (${_p(t)})';
}

class _Row3 extends StatelessWidget {
  const _Row3(this.label, this.a, this.b, {this.head = false, this.last = false});
  final String label, a, b;
  final bool head, last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final num = (head ? t.titleSmall : t.bodyLarge)?.copyWith(fontFeatures: tabular);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(bottom: BorderSide(color: Night.rule)),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 9,
            child: Text(label, style: t.bodyLarge?.copyWith(color: Night.inkMuted)),
          ),
          Expanded(
            flex: 5,
            child: Text(a, textAlign: TextAlign.right, style: num),
          ),
          Expanded(
            flex: 5,
            child: Text(b, textAlign: TextAlign.right, style: num),
          ),
        ],
      ),
    );
  }
}
