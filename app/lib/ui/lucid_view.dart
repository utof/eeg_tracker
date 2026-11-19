// The Lucid dreams page (DECISIONS 308; .impeccable/surfaces/app-lib-ui-lucid-screen-dart.md): what is due leads (the
// morning's three questions, or the evening practice and tonight's plan), then last night on its own clock, the
// test's nights and its sealed answer, how it works and who should not use it. Inside DESIGN.md's night-watch world:
// words before colour, the watch strip's cells, the sleep chart's lane. A night's kind (cues or silent) never shows
// here until the test's results open.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../lucid/plan.dart';
import '../lucid/practice.dart';
import '../lucid/rule.dart' show LucidRule;
import '../lucid/store.dart';
import 'form_parts.dart';
import 'meditation_view.dart' show MarkShape, StateMark;
import 'parts.dart';
import 'theme.dart';

enum LucidDue { turnOn, practise, answer, ready }

/// Last night as the page shows it.
class LucidLastNight {
  const LucidLastNight({required this.record, this.endMs, this.signals, this.answers, this.searching = false});
  final LucidNightRecord record;

  /// The night's last data (unix ms); null while unknown.
  final int? endMs;
  final NightSignals? signals;
  final LucidAnswers? answers;

  /// The morning's search over the night is running.
  final bool searching;
}

class LucidViewModel {
  const LucidViewModel({
    required this.on,
    required this.due,
    this.level,
    this.practisedAt,
    this.nightRunning = false,
    this.last,
    this.nights = const [],
    this.nextIndex = 0,
    this.results,
    this.draft = const LucidDraft(),
  });

  final bool on;
  final LucidDue due;

  /// The evening's loudness (share of the media volume); null until the practice set it.
  final double? level;

  /// The last practice that counts for tonight (ended in the last 3 hours).
  final DateTime? practisedAt;
  final bool nightRunning;
  final LucidLastNight? last;

  /// The test's nights so far, in order of their number: answered and lucid or not.
  final List<({bool answered, bool lucid})> nights;

  /// The number tonight gets.
  final int nextIndex;
  final LucidResults? results;
  final LucidDraft draft;
}

/// The morning's answers as they are given (nothing preselected).
class LucidDraft {
  const LucidDraft({this.lucid, this.heard, this.recall, this.signal});
  final String? lucid, heard, signal;
  final int? recall;

  bool get complete => lucid != null && heard != null && recall != null && (lucid != 'yes' || signal != null);

  LucidAnswers? get answers => complete
      ? LucidAnswers(lucid: lucid!, heard: heard!, recall: recall!, signal: lucid == 'yes' ? signal : null)
      : null;

  LucidDraft copyWith({String? lucid, String? heard, int? recall, String? signal}) => LucidDraft(
    lucid: lucid ?? this.lucid,
    heard: heard ?? this.heard,
    recall: recall ?? this.recall,
    signal: signal ?? this.signal,
  );
}

String _two(int v) => v.toString().padLeft(2, '0');
String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
String _hmMs(int ms) => _hm(DateTime.fromMillisecondsSinceEpoch(ms));
String _hours(Duration d) => d.inMinutes % 60 == 0 ? '${d.inHours} h' : '${(d.inMinutes / 60).toStringAsFixed(1)} h';

class LucidView extends StatelessWidget {
  const LucidView({
    super.key,
    required this.model,
    required this.onTurnOn,
    required this.onTurnOff,
    required this.onPractise,
    required this.onDraft,
    required this.onSave,
    required this.onInfo,
  });

  final LucidViewModel model;
  final VoidCallback onTurnOn, onTurnOff, onPractise, onSave, onInfo;
  final ValueChanged<LucidDraft> onDraft;

  @override
  Widget build(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme, last = m.last;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lucid dreams'),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says'),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _status(context),
          if (m.due == LucidDue.answer && last != null) ...[
            const SectionHeading('This morning'),
            _questions(context, last),
          ],
          if (m.due != LucidDue.answer) ...[const SectionHeading('Tonight'), _tonight(context)],
          if (last != null) ...[const SectionHeading('Last night'), LastNightLog(night: last)],
          const SectionHeading('The test'),
          _test(context),
          const SectionHeading('How it works'),
          const _Note(
            Icons.graphic_eq,
            'The cue is three soft rising tones. In the evening practice you learn to ask "am I dreaming?" each time '
            'you hear it. In the night it plays softly again while the headband reads dream sleep.',
          ),
          _Note(
            Icons.schedule,
            'Only in the second half of the night (from ${_hours(LucidRule.cuesFrom)} after Lights off), when the sleep '
            'model has read dream sleep for 2 epochs with your eyes moving and you lie still; never in deep sleep. At '
            'most ${LucidRule.perPeriod} cues in a dream and ${LucidRule.perNight} a night, 1 dB louder each time up to '
            '+${LucidRule.maxSteps} dB; a stir or a wake makes it quieter and pauses it.',
          ),
          const _Note(
            Icons.visibility_outlined,
            'Some nights are silent on purpose and you are not told which. Everything else is the same, so after 12 '
            'nights the app can test whether the sound did anything for you.',
          ),
          const _Note(
            Icons.swap_horiz,
            'If you know you are dreaming, look left-right-left-right, twice, wide. The morning search looks for that '
            'on the temple electrodes (and a double jaw clench, once hands-free is calibrated).',
          ),
          _Note(
            Icons.info_outline,
            'The evidence is weak: it worked in a sleep lab, but a home app found no clear difference against no cue. '
            'Dream sleep is read by a model not yet checked on this headband. The i button says more.',
            onTap: onInfo,
          ),
          const SectionHeading('Who should not use it'),
          const _Note(
            Icons.warning_amber_outlined,
            'Sounds in the night can disturb sleep. Turn it off if your sleep gets worse, after nightmares, or if dreams '
            'and waking start to feel mixed up. Do not use it with poor sleep, a sleep disorder, frequent nightmares, '
            'or a history of psychosis or dissociation.',
            color: Night.caution,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Lucid cues'),
            subtitle: Text(m.on ? 'On: the night recorder plays the cues.' : 'Off.', style: muted),
            value: m.on,
            onChanged: (v) => v ? onTurnOn() : onTurnOff(),
          ),
        ],
      ),
      bottomNavigationBar: PinnedAction(child: _action()),
    );
  }

  Widget _action() {
    final m = model;
    return switch (m.due) {
      LucidDue.turnOn => FilledButton.icon(
        onPressed: onTurnOn,
        icon: const Icon(Icons.nights_stay_outlined),
        label: const Text('Turn on'),
      ),
      LucidDue.answer => FilledButton(
        onPressed: m.draft.complete ? onSave : null,
        child: Text(m.draft.complete ? 'Save answers' : 'Answer each question'),
      ),
      LucidDue.practise || LucidDue.ready => FilledButton.icon(
        onPressed: onPractise,
        icon: const Icon(Icons.graphic_eq),
        label: Text(m.level == null ? 'Start practice' : (m.practisedAt == null ? 'Start practice' : 'Practise again')),
      ),
    };
  }

  Widget _status(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final (String word, String sentence, MarkShape mark, Color color) = switch (m.due) {
      LucidDue.turnOn => (
        'Off',
        'Soft sounds in dream sleep, to help you notice that you are dreaming. An experiment: the evidence is weak.',
        MarkShape.ring,
        Night.inkMuted,
      ),
      LucidDue.answer => (
        'Answer now',
        'Three questions about last night, before the dream fades.',
        MarkShape.ringedDot,
        Night.live,
      ),
      LucidDue.practise when m.level == null => (
        'Practise first',
        'The evening practice sets the loudness the cues use. Until then the night plays nothing.',
        MarkShape.ringedDot,
        Night.caution,
      ),
      LucidDue.practise => (
        'On',
        'Practise in bed before you sleep, about 15 minutes. Then Start night as usual.',
        MarkShape.ringedDot,
        Night.live,
      ),
      LucidDue.ready => (
        'On',
        m.nightRunning
            ? 'The night recorder has the cues tonight. Sleep well.'
            : 'Practised at ${_hm(m.practisedAt!)}. Start the night when you are ready.',
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
            children: [
              StateMark(shape: mark, color: color),
              const SizedBox(width: 14),
              Expanded(child: Text(word, style: text.displaySmall)),
            ],
          ),
          const SizedBox(height: 10),
          Text(sentence, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
        ],
      ),
    );
  }

  Widget _questions(BuildContext context, LucidLastNight last) {
    final d = model.draft;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The night of ${_dateWords(DateTime.fromMillisecondsSinceEpoch(last.record.startMs))}, night '
          '${last.record.index + 1} of the test.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted),
        ),
        ChoiceQuestion<String>(
          question: 'In a dream, did you know that you were dreaming?',
          choices: const [('yes', 'Yes'), ('no', 'No'), ('unsure', 'Not sure')],
          value: d.lucid,
          onChanged: (v) => onDraft(d.copyWith(lucid: v)),
        ),
        if (d.lucid == 'yes')
          ChoiceQuestion<String>(
            question: 'Did you make the eye signal, left-right-left-right?',
            choices: const [('yes', 'Yes'), ('no', 'No')],
            value: d.signal,
            onChanged: (v) => onDraft(d.copyWith(signal: v)),
          ),
        ChoiceQuestion<String>(
          question: 'Did you hear the sound in the night?',
          choices: const [('no', 'No'), ('dream', 'In a dream'), ('woke', 'Woke me'), ('unsure', 'Not sure')],
          value: d.heard,
          onChanged: (v) => onDraft(d.copyWith(heard: v)),
        ),
        ChoiceQuestion<int>(
          question: 'How much of your dreams do you remember?',
          choices: const [(0, 'Nothing'), (1, 'A bit'), (2, 'A dream'), (3, 'More')],
          value: d.recall,
          onChanged: (v) => onDraft(d.copyWith(recall: v)),
          ends: ('nothing at all', 'more than one dream'),
        ),
      ],
    );
  }

  Widget _tonight(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    if (!m.on) {
      return Text(
        'Off: tonight is an ordinary night. Turn it on to practise this evening and get cues in tonight\'s dream sleep.',
        style: muted,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const NightLane.plan(),
        const SizedBox(height: 14),
        _LogRow(label: 'Practice', value: m.practisedAt == null ? 'not yet' : 'done ${_hm(m.practisedAt!)}'),
        _LogRow(
          label: 'Loudness',
          value: m.level == null ? 'not set' : '${(m.level! * 100).toStringAsFixed(m.level! < 0.1 ? 1 : 0)} % of media',
        ),
        _LogRow(label: 'Night of the test', value: '${m.nextIndex + 1}', last: true),
        const SizedBox(height: 12),
        Text(
          'Practice: set the loudness (tap when you just hear it), then ${PracticeRule.guided} cues with the words and '
          '${PracticeRule.unguided} with your eyes closed. Earbuds or the phone on the bed, as you will sleep.',
          style: muted,
        ),
      ],
    );
  }

  Widget _test(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final r = m.results;
    final done = m.nights.length;
    final toGo = LucidTest.revealEvery - done % LucidTest.revealEvery;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NightCells(nights: m.nights, next: m.nextIndex, arms: r?.arms),
        const SizedBox(height: 10),
        Text(
          r == null
              ? 'Filled: answered. Dark: not answered. Dot: a lucid dream. Outlined: nights to come, their kind sealed.'
              : 'Filled: answered. Dark: not answered. Dot: a lucid dream. A bar under a night: it had sound; none: '
                    'silent.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted),
        ),
        const SizedBox(height: 16),
        if (r == null)
          Text(
            done == 0
                ? 'Sealed until night ${LucidTest.revealEvery}. The first night with cues on starts the test.'
                : 'Sealed until night ${LucidTest.revealEvery}: $toGo ${toGo == 1 ? 'night' : 'nights'} to go. Which '
                      'nights had sound stays hidden until then.',
            style: text.titleMedium,
          )
        else
          LucidResultsView(results: r),
        if (r == null) ...[const SizedBox(height: 10), Text(_planNote, style: muted)],
      ],
    );
  }

  static const String _planNote =
      'In each block of 4 nights, 2 have sound. The phone drew the order before the first night and locked it with a '
      'fingerprint, so nobody can change it afterwards. One person, a few nights: expect "not clear" and take it as '
      'an answer.';

  static String _dateWords(DateTime t) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final e = t.hour < 12 ? t.subtract(const Duration(days: 1)) : t;
    return '${days[e.weekday - 1]} ${e.day} ${months[e.month - 1]}';
  }
}

/// Last night: its lane, then its log in rows.
class LastNightLog extends StatelessWidget {
  const LastNightLog({super.key, required this.night});
  final LucidLastNight night;

  @override
  Widget build(BuildContext context) {
    final n = night, r = n.record, text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final periods = r.cues.map((c) => c.period).toSet().length;
    final aroused = r.cues.where((c) => c.aroused).length;
    final s = n.signals;
    final inDream = s?.inDreamSleep ?? 0;
    final end = n.endMs ?? (r.cues.isEmpty ? r.cuesFromMs : r.cues.last.atMs + 30 * 60000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NightLane(
          startMs: r.startMs,
          endMs: math.max(end, r.cuesFromMs + 60 * 60000),
          cuesFromMs: r.cuesFromMs,
          cues: [for (final c in r.cues) (c.atMs, c.aroused)],
          signals: [for (final x in s?.signals ?? const <FoundSignal>[]) (x.atMs, x.inDreamSleep)],
        ),
        const SizedBox(height: 14),
        _LogRow(
          label: 'Cue moments',
          value: r.cues.isEmpty ? 'none' : '${r.cues.length} in $periods dream${periods == 1 ? '' : 's'}',
        ),
        _LogRow(label: 'A stir after a cue', value: r.cues.isEmpty ? '-' : '$aroused of ${r.cues.length}'),
        _LogRow(
          label: 'Dream signals',
          value: n.searching
              ? 'looking...'
              : s == null
              ? 'not searched'
              : s.signals.isEmpty
              ? 'none found'
              : '$inDream in dream sleep${s.signals.length > inDream ? ', ${s.signals.length - inDream} other' : ''}',
        ),
        _LogRow(label: 'Your answers', value: _answerWords(n.answers), last: true),
        const SizedBox(height: 12),
        Text(_sentence(r, s), style: muted),
      ],
    );
  }

  static String _answerWords(LucidAnswers? a) {
    if (a == null) return 'not given';
    final lucid = switch (a.lucid) {
      'yes' => 'lucid',
      'no' => 'not lucid',
      _ => 'not sure',
    };
    final heard = switch (a.heard) {
      'dream' => 'heard it in a dream',
      'woke' => 'it woke you',
      'no' => 'did not hear it',
      _ => 'not sure you heard it',
    };
    return '$lucid, $heard';
  }

  static String _sentence(LucidNightRecord r, NightSignals? s) {
    if (r.off != null) return r.off!;
    if (r.cues.isEmpty) {
      return r.phase == 'waiting'
          ? 'The night ended before the cue hours (from ${_hmMs(r.cuesFromMs)}).'
          : 'No moment of the cue hours met every rule, so there was no cue moment.';
    }
    final first = _hmMs(r.cues.first.atMs), lastCue = _hmMs(r.cues.last.atMs);
    final staged = s != null && !s.staged ? ' The night was not scored yet, so the signals have no stage.' : '';
    return 'Cue moments from $first to $lastCue. On a silent night they are the same moments with no sound, so this '
        'log cannot tell you which kind of night it was.$staged';
  }
}

/// The test's answer, once whole sets of 12 nights are in: the verdict, then the tested numbers as a table (sound
/// nights against silent nights), then what is only seen together.
class LucidResultsView extends StatelessWidget {
  const LucidResultsView({super.key, required this.results});
  final LucidResults results;

  @override
  Widget build(BuildContext context) {
    final r = results, text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    String count(NightArm a, bool Function(LucidNight n) yes, {bool answeredOnly = true}) {
      var y = 0, n = 0;
      for (var j = 0; j < r.shown.length; j++) {
        final night = r.shown[j];
        if (r.arms[j] != a || (answeredOnly && night.answers == null)) continue;
        n++;
        if (yes(night)) y++;
      }
      return '$y of $n';
    }

    String share(double? x) => x == null ? '-' : '${(x * 100).round()} %';
    final verdict = switch (r.verdict) {
      LucidVerdict.likely => 'Likely real for you: more lucid mornings after nights with sound.',
      LucidVerdict.notClear => 'Not clear yet: nights with sound and silent nights did not differ more than chance.',
      LucidVerdict.tooFew => 'Too few answered mornings of each kind to say.',
    };
    final p = r.lucid;
    final chance = p == null
        ? ''
        : 'Lucid mornings differ by ${(p.diff * 100).round().abs()} points. Shuffled inside each block of 4, a '
              'difference this big came ${p.p < 0.001 ? 'in under 1 of 1000' : 'in ${(p.p * 100).round()} of 100'} '
              'orders (p = ${p.p < 0.001 ? '< 0.001' : p.p.toStringAsFixed(2)}).';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(verdict, style: text.titleLarge),
        const SizedBox(height: 16),
        const _TableRow('Tested', 'Sound', 'Silent', head: true),
        _TableRow(
          'Lucid mornings',
          count(NightArm.cue, (n) => n.answers!.lucidValue == 1),
          count(NightArm.silent, (n) => n.answers!.lucidValue == 1),
        ),
        _TableRow(
          'Heard the sound',
          count(NightArm.cue, (n) => n.answers!.heardValue == 1),
          count(NightArm.silent, (n) => n.answers!.heardValue == 1),
        ),
        _TableRow('A stir after a cue moment', share(r.arousalShare.$1), share(r.arousalShare.$2)),
        _TableRow(
          'Dream signals',
          count(NightArm.cue, (n) => n.signalsInDreamSleep > 0, answeredOnly: false),
          count(NightArm.silent, (n) => n.signalsInDreamSleep > 0, answeredOnly: false),
          last: true,
        ),
        if (chance.isNotEmpty) ...[const SizedBox(height: 10), Text(chance, style: muted)],
        const SizedBox(height: 20),
        Text('Seen together, not tested', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
        _LogRow(label: 'Lucid when you heard it', value: '${r.lucidWhenHeard.$1} of ${r.lucidWhenHeard.$2}'),
        _LogRow(label: 'Lucid when you did not', value: '${r.lucidWhenNotHeard.$1} of ${r.lucidWhenNotHeard.$2}'),
        _LogRow(label: 'Lucid after a practice', value: '${r.practisedLucid.$1} of ${r.practisedLucid.$2}'),
        _LogRow(label: 'Lucid without one', value: '${r.unpractisedLucid.$1} of ${r.unpractisedLucid.$2}', last: true),
        const SizedBox(height: 12),
        Text(
          '${r.shown.length} nights opened${r.hidden > 0 ? ', ${r.hidden} still sealed' : ''}'
          '${r.unanswered > 0 ? '; ${r.unanswered} without answers left out' : ''}. '
          '${r.planOk ? 'The plan and the hidden order are unchanged since night 1.' : 'Warning: the plan or the hidden order changed after night 1, so this result cannot be trusted.'} '
          'Only lucid mornings are the test; the other rows are leads, not proof.',
          style: muted?.copyWith(color: r.planOk ? Night.inkMuted : Night.caution),
        ),
      ],
    );
  }
}

/// A row of the tested table: a label, then the sound nights' and the silent nights' numbers in two right-aligned
/// columns of tabular figures.
class _TableRow extends StatelessWidget {
  const _TableRow(this.label, this.sound, this.silent, {this.head = false, this.last = false});
  final String label, sound, silent;
  final bool head, last;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final num = (head ? text.titleMedium?.copyWith(fontWeight: FontWeight.w500) : text.bodyLarge)?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final lab = head
        ? text.titleMedium?.copyWith(fontWeight: FontWeight.w500)
        : text.bodyLarge?.copyWith(color: Night.inkMuted);
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
          Expanded(flex: 9, child: Text(label, style: lab)),
          Expanded(
            flex: 5,
            child: Text(sound, textAlign: TextAlign.right, style: num),
          ),
          Expanded(
            flex: 5,
            child: Text(silent, textAlign: TextAlign.right, style: num),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.label, required this.value, this.last = false});
  final String label, value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(bottom: BorderSide(color: Night.rule)),
            ),
      child: LayoutBuilder(
        builder: (context, c) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
            ),
            const SizedBox(width: 16),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: c.maxWidth * 0.55),
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: text.bodyLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {this.onTap, this.color = Night.inkMuted});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
            ),
          ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// A night on its clock (the sleep chart's lane): the cue hours as a faint band, cue moments as ink ticks (amber when a
/// stir followed), dream signals as rings above the lane, hour rules and hours under it. [NightLane.plan] draws
/// tonight's plan: 9 hours from Lights off, the cue hours from 4.5 h.
class NightLane extends StatelessWidget {
  const NightLane({
    super.key,
    required this.startMs,
    required this.endMs,
    required this.cuesFromMs,
    this.cues = const [],
    this.signals = const [],
  }) : plan = false;

  const NightLane.plan({super.key})
    : startMs = 0,
      endMs = 9 * 3600000,
      cuesFromMs = 16200000,
      cues = const [],
      signals = const [],
      plan = true;

  final int startMs, endMs, cuesFromMs;
  final List<(int, bool)> cues;
  final List<(int, bool)> signals;
  final bool plan;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final small = text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    final words = plan
        ? 'Lights off, then ${_hours(LucidRule.cuesFrom)} without cues; the band is when they may play, in dream sleep only.'
        : 'Band: the cue hours. Ticks: cue moments${cues.any((c) => c.$2) ? ' (amber: a stir followed)' : ''}. '
              '${signals.isEmpty ? '' : 'Rings: dream signals.'}';
    return Semantics(
      label: plan ? 'Tonight\'s plan' : 'Last night on the clock',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 64,
            width: double.infinity,
            child: CustomPaint(painter: _LanePainter(this, labelStyle: small!)),
          ),
          const SizedBox(height: 8),
          Text(words, style: small),
        ],
      ),
    );
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter(this.lane, {required this.labelStyle});
  final NightLane lane;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final l = lane;
    final span = math.max(1, l.endMs - l.startMs).toDouble();
    double x(int ms) => ((ms - l.startMs) / span).clamp(0.0, 1.0) * size.width;
    const top = 14.0, laneH = 26.0;
    final laneRect = RRect.fromRectAndRadius(Rect.fromLTWH(0, top, size.width, laneH), const Radius.circular(6));
    canvas.drawRRect(laneRect, Paint()..color = Night.track);
    // the cue hours
    final band = Rect.fromLTRB(x(l.cuesFromMs), top, size.width, top + laneH);
    canvas.save();
    canvas.clipRRect(laneRect);
    canvas.drawRect(band, Paint()..color = Night.rule);
    canvas.restore();
    // hour rules and labels
    final rule = Paint()
      ..color = Night.ground.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    final hours = <int>[];
    if (l.plan) {
      for (var h = 0; h <= 9; h += 3) {
        hours.add(h * 3600000);
      }
    } else {
      final s = DateTime.fromMillisecondsSinceEpoch(l.startMs);
      var t = DateTime(s.year, s.month, s.day, s.hour + 1);
      final step = span > 8 * 3600000 ? 2 : 1;
      if (step == 2 && t.hour.isOdd) t = t.add(const Duration(hours: 1));
      while (t.millisecondsSinceEpoch < l.endMs) {
        hours.add(t.millisecondsSinceEpoch);
        t = t.add(Duration(hours: step));
      }
    }
    for (final h in hours) {
      final hx = x(h);
      if (hx > 0 && hx < size.width) canvas.drawLine(Offset(hx, top), Offset(hx, top + laneH), rule);
      final label = l.plan
          ? (h == 0 ? 'Lights off' : '+${h ~/ 3600000} h')
          : _two(DateTime.fromMillisecondsSinceEpoch(h).hour);
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (hx - (l.plan && h == 0 ? 0 : tp.width / 2)).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(lx, top + laneH + 4));
    }
    // cue moments
    for (final (ms, aroused) in l.cues) {
      final cx = x(ms);
      canvas.drawLine(
        Offset(cx, top + 4),
        Offset(cx, top + laneH - 4),
        Paint()
          ..color = aroused ? Night.caution : Night.ink
          ..strokeWidth = 1.5,
      );
    }
    // dream signals
    for (final (ms, inDream) in l.signals) {
      canvas.drawCircle(
        Offset(x(ms), 6),
        4.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = inDream ? Night.ink : Night.inkMuted,
      );
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) => old.lane != lane;
}

/// The test's nights as the watch strip's cells, 12 a row with a wider gap every 4 (a block of the draw): outlined
/// ahead (sealed), filled when answered, an ink dot for a lucid morning, the next night outlined green; after the
/// results open, a bar under each night that had sound.
class NightCells extends StatelessWidget {
  const NightCells({super.key, required this.nights, required this.next, this.arms});
  final List<({bool answered, bool lucid})> nights;
  final int next;
  final List<NightArm>? arms;

  @override
  Widget build(BuildContext context) {
    final rows = math.max(1, ((math.max(nights.length, next) + 1) / 12).ceil());
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 4.0, blockGap = 12.0;
        final cell = ((c.maxWidth - 9 * gap - 2 * blockGap) / 12).clamp(12.0, 32.0);
        return Semantics(
          label: '${nights.length} nights of the test so far',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var row = 0; row < rows; row++)
                Padding(
                  padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : 10),
                  child: Row(
                    children: [
                      for (var j = 0; j < 12; j++) ...[
                        if (j > 0) SizedBox(width: j % 4 == 0 ? blockGap : gap),
                        _cell(row * 12 + j, cell),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _cell(int i, double size) {
    final past = i < nights.length;
    final n = past ? nights[i] : null;
    final sound = arms != null && i < arms!.length && arms![i] == NightArm.cue;
    final Color? fill = n == null ? null : (n.answered ? Night.saved : Night.track);
    final Color border = i == next ? Night.live : (past ? Colors.transparent : Night.rule);
    return Column(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border, width: i == next ? 2 : 1),
          ),
          child: n != null && n.lucid
              ? Center(
                  child: Container(
                    width: size * 0.32,
                    height: size * 0.32,
                    decoration: const BoxDecoration(color: Night.ground, shape: BoxShape.circle),
                  ),
                )
              : null,
        ),
        if (arms != null) ...[
          const SizedBox(height: 3),
          Container(width: size * 0.6, height: 2.5, color: sound ? Night.ink : Colors.transparent),
        ],
      ],
    );
  }
}

/// The practice in bed: the loudness step on the night screen's ground, then the words, then a true-black face.
enum PracticeStage { loudness, guided, unguided, done }

class PracticeViewModel {
  const PracticeViewModel({required this.stage, this.step = 0, this.cue = 0, this.heardLevel, this.showWords = false});
  final PracticeStage stage;

  /// Loudness steps played; the cue's number in its part.
  final int step, cue;
  final double? heardLevel;
  final bool showWords;
}

class PracticeView extends StatelessWidget {
  const PracticeView({
    super.key,
    required this.model,
    required this.onHeard,
    required this.onStop,
    required this.onDone,
  });
  final PracticeViewModel model;
  final VoidCallback onHeard, onStop, onDone;

  @override
  Widget build(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    if (m.stage == PracticeStage.guided || m.stage == PracticeStage.unguided) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.stage == PracticeStage.guided
                      ? 'With the words: ${m.cue} of ${PracticeRule.guided}'
                      : 'Eyes closed: ${m.cue} of ${PracticeRule.unguided}',
                  style: text.bodyMedium?.copyWith(color: Night.inkMuted.withValues(alpha: 0.7)),
                ),
                const Spacer(),
                if (m.stage == PracticeStage.guided && m.showWords)
                  Text(practiceWords, style: text.titleLarge?.copyWith(color: Night.inkMuted, height: 1.45))
                else if (m.stage == PracticeStage.unguided)
                  Text(
                    'Each time you hear it: am I dreaming? Notice your body and breathing.',
                    style: text.bodyLarge?.copyWith(color: Night.inkMuted.withValues(alpha: 0.6), height: 1.45),
                  ),
                const Spacer(),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: onStop, child: const Text('Stop')),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final loud = m.stage == PracticeStage.loudness;
    return Scaffold(
      appBar: AppBar(title: const Text('Evening practice')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          Text(loud ? 'Loudness' : 'Done', style: text.displaySmall),
          const SizedBox(height: 10),
          if (loud) ...[
            Text(
              'Lie down as you will sleep: earbuds in, or the phone where it will lie. The cue plays every '
              '${PracticeRule.loudnessEveryS} seconds, very quiet at first and a little louder each time. Tap "I hear '
              'it" as soon as you hear it.',
              style: muted,
            ),
            const SizedBox(height: 20),
            Text(
              m.step == 0
                  ? 'Starting...'
                  : 'Cue ${m.step}, ${(loudnessGain(m.step - 1) * 100).toStringAsFixed(1)} % of the media volume',
              style: text.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const SizedBox(height: 10),
            Text(
              'Then come ${PracticeRule.guided} cues with words to read and ${PracticeRule.unguided} with your eyes '
              'closed, about 15 minutes in all. The screen stays on, black and dim.',
              style: muted,
            ),
          ] else ...[
            Text(
              'The cue is set at ${((m.heardLevel ?? 0) * 100).toStringAsFixed(1)} % of the media volume. Start the '
              'night as usual; keep the media volume where it is now.',
              style: muted,
            ),
          ],
        ],
      ),
      bottomNavigationBar: PinnedAction(
        child: loud
            ? Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: OutlinedButton(onPressed: onStop, child: const Text('Stop')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: FilledButton(onPressed: onHeard, child: const Text('I hear it')),
                  ),
                ],
              )
            : FilledButton(onPressed: onDone, child: const Text('Done')),
      ),
    );
  }
}
