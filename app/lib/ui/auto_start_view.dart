// "When I put the headband on" (ROADMAP row 39, DECISIONS 600-609): a choice per kind (night, work, other), the
// bedtime window, what this phone allows, and how often the guess was right. State in auto_start_screen.dart.
import 'package:flutter/material.dart';

import '../auto/bedtime.dart';
import '../auto/channel.dart';
import '../auto/log.dart';
import '../auto/store.dart';
import 'form_parts.dart' show Para;
import 'parts.dart';
import 'theme.dart';

/// The line under the Settings entry: `Night: Ask me · Work: Ask me · Other: Ask me`.
String autoSummary(AutoSettings s) => s.allOff
    ? 'Do nothing (the app does not check).'
    : [for (final k in WearKind.values) '${k.label}: ${s.choice(k).label}'].join(' · ');

/// What this phone allows, in plain lines, worst news first.
List<(String, Color)> watchLines(WatchStatus s, {DateTime? now}) {
  String hm(DateTime t) => clockText(t.hour * 60 + t.minute);
  final out = <(String, Color)>[];
  if (!s.notificationsOn) {
    out.add(('Notifications are off for the app, so it cannot ask you. Switch them on in the phone\'s settings.', Night.problem));
  }
  final refused = s.refusedAt;
  if (refused != null) {
    out.add(('Android refused a check in the background at ${hm(refused)}.', Night.caution));
  }
  if (s.sdkInt > 0 && !s.companionSupported) {
    out.add(('This phone has no companion pairing.', Night.caution));
  } else if (s.paired && s.observing) {
    out.add((
      'Paired${s.pairedName == null ? '' : ' with ${s.pairedName}'}: Android watches for the headband for the app, keeps '
          'the app ready while it is near, and lets it start a recording from the background.',
      Night.live,
    ));
  } else if (s.paired) {
    out.add(('Paired, but Android does not report when the headband is near on this phone (Android ${s.sdkInt}).', Night.caution));
  } else if (s.sdkInt > 0 && !s.presenceSupported) {
    out.add(('This Android (${s.sdkInt}) cannot tell the app when the headband is near.', Night.caution));
  } else if (s.sdkInt > 0) {
    out.add(('Not paired yet. Pair the headband once: Android then tells the app when it is near.', Night.inkMuted));
  }
  if (s.batteryExempt) {
    out.add(('The app may run in the background (battery: no restrictions), so bedtime checks can start without pairing too.', Night.ink));
  } else if (!(s.paired && s.observing) && s.sdkInt > 0) {
    out.add((
      'Without the pairing or the battery exemption Android may refuse checks in the background: then the app checks '
          'only when you open it.',
      Night.caution,
    ));
  }
  final x = s.xiaomiOs;
  if (x != null) {
    out.add((
      'Xiaomi ($x): also switch on Autostart and set Battery saver to No restrictions (main screen, Phone). Whether '
          'HyperOS keeps the pairing\'s "headband near" working is not known yet.',
      Night.inkMuted,
    ));
  }
  final last = s.lastCheckAt;
  if (last != null) out.add(('Last check ${hm(last)}${s.lastTrigger == null ? '' : ' (${s.lastTrigger})'}.', Night.inkMuted));
  final next = s.nextBedtimeCheck;
  if (next != null) out.add(('Next bedtime check ${hm(next)}.', Night.inkMuted));
  return out;
}

/// One kind's results: "asked 4 times; 2 of 3 answered: right; 1 started automatically".
String statsLine(KindStats s) {
  if (s.asked == 0 && s.automatic == 0) return '${s.kind.label}: nothing yet.';
  return [
    '${s.kind.label}: asked ${s.asked} ${s.asked == 1 ? 'time' : 'times'}',
    if (s.answered > 0) s.rightText,
    if (s.unanswered > 0) '${s.unanswered} not answered',
    if (s.automatic > 0) '${s.automatic} started automatically',
  ].join('; ');
}

class AutoStartModel {
  const AutoStartModel({
    this.settings = const AutoSettings(),
    this.usual = const UsualNight(bedMin: AutoRule.defaultBedMin, wakeMin: AutoRule.defaultWakeMin),
    this.status,
    this.stats = const {},
    this.offers = const {},
    this.error,
    this.message,
  });

  final AutoSettings settings;
  final UsualNight usual;
  final WatchStatus? status;
  final Map<WearKind, KindStats> stats;

  /// Kinds whose "start it automatically?" offer waits for an answer.
  final Set<WearKind> offers;
  final String? error, message;
}

class AutoStartView extends StatelessWidget {
  const AutoStartView({
    super.key,
    required this.model,
    required this.onChoice,
    this.onChime,
    this.onBedtime,
    this.onUseNights,
    this.onPair,
    this.onForget,
    this.onCheckNow,
    this.onOffer,
    this.onInfo,
  });

  final AutoStartModel model;
  final void Function(WearKind kind, AutoChoice choice) onChoice;
  final ValueChanged<bool>? onChime;
  final VoidCallback? onBedtime, onUseNights, onPair, onForget, onCheckNow, onInfo;
  final void Function(WearKind kind, bool accept)? onOffer;

  static const Map<WearKind, String> _when = {
    WearKind.night: 'At night: inside your bedtime window, or charging with the screen off in the evening',
    WearKind.work: 'Working: when the laptop says a work session started',
    WearKind.other: 'Anything else',
  };

  static const Map<WearKind, String> _meaning = {
    WearKind.night:
        'Automatically: the night recording starts, with the drift-off detector and the sleep report after Stop; no '
        'smart alarm, cues or sounds. Ask me: a quiet "Headband on. Start the night?"; the minutes since the headband '
        'was found on are kept in memory and saved only if you say yes.',
    WearKind.work:
        'Automatically: the work page opens and the session starts, hints on the screen and the lock-screen card. Ask '
        'me: a quiet "Headband on. Start a work session?".',
    WearKind.other:
        'Ask me: "Headband on. What are you doing?" with Night, Work session and Not now; nothing is recorded until '
        'you choose. Starting by itself comes with a daytime recording, later.',
  };

  @override
  Widget build(BuildContext context) {
    final m = model, s = m.settings;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    final w = m.usual;
    final bedFrom = w.byHand
        ? 'set by hand'
        : w.fromNights > 0
        ? 'from your last ${w.fromNights} recorded nights'
        : 'until 3 nights are recorded';
    return Scaffold(
      appBar: AppBar(
        title: Text('When I put the headband on', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says', color: Night.inkMuted),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Text(
            'The app checks whether the headband is on at sensible moments and then does what you choose here. '
            'Automatically only ever means recording and silent analysis: sounds, alarms, cues, neurofeedback, the dream '
            'catcher and the microphone always need your tap.',
            style: text.bodyLarge?.copyWith(height: 1.45),
          ),
          if (m.error != null) Para(m.error!, color: Night.problem),
          if (m.message != null) Para(m.message!, color: Night.live),
          for (final k in m.offers) _Offer(kind: k, onOffer: onOffer),
          for (final k in WearKind.values) ...[
            _ChoiceRow(
              question: _when[k]!,
              choices: [
                for (final c in AutoChoice.values)
                  if (k != WearKind.other || c != AutoChoice.start) c,
              ],
              value: s.choice(k),
              onChanged: (c) => onChoice(k, c),
            ),
            const SizedBox(height: 8),
            Text(_meaning[k]!, style: muted),
            if (k == WearKind.work)
              SwitchListTile(
                value: s.workChime,
                onChanged: onChime,
                contentPadding: EdgeInsets.zero,
                title: Text('Chime in automatic work sessions', style: text.bodyLarge),
                subtitle: Text(s.workChime ? 'On: the hint\'s soft chime plays.' : 'Off: hints are silent.', style: muted),
              ),
          ],
          const SectionHeading('Your bedtime window'),
          Text(
            '${w.windowText}: 2 hours before your usual bedtime (${clockText(w.bedMin)}) to your usual wake-up '
            '(${clockText(w.wakeMin)}), $bedFrom. Inside it the app checks every 10 minutes, only while the headband is '
            'near, and a find there counts as the night.',
            style: text.bodyLarge?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(onPressed: onBedtime, icon: const Icon(Icons.schedule), label: const Text('Change')),
              if (w.byHand) TextButton(onPressed: onUseNights, child: const Text('Use my nights')),
            ],
          ),
          const SectionHeading('Watching for the headband'),
          if (m.status == null)
            Text('Reading what this phone allows.', style: muted)
          else
            for (final (line, color) in watchLines(m.status!))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line, style: text.bodyLarge?.copyWith(color: color, height: 1.45)),
              ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (m.status?.paired == true)
                TextButton(onPressed: onForget, child: const Text('Forget the pairing'))
              else
                FilledButton.icon(onPressed: onPair, icon: const Icon(Icons.link), label: const Text('Pair the headband')),
              OutlinedButton.icon(onPressed: onCheckNow, icon: const Icon(Icons.sensors), label: const Text('Check now')),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'A check connects for about 10 seconds: contact (off the head the electrodes read no contact at all) and the '
            'battery, then it lets go. The app checks when you open it, every 10 minutes in the bedtime window, and when '
            'the laptop says a work session started; never during a recording or a session.',
            style: muted,
          ),
          const SectionHeading('How often it was right'),
          for (final k in WearKind.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(statsLine(m.stats[k] ?? KindStats(k)), style: text.bodyLarge?.copyWith(height: 1.45)),
            ),
          Text('Every check, guess and answer is kept on the phone (Export data takes it).', style: muted),
          const SectionHeading('Never started by itself'),
          Text(
            'Sounds and alarms, lucid and memory cues, alpha-theta and other neurofeedback, the dream catcher, the '
            'microphone, sending data anywhere, deleting anything. After 10 yes answers in a row for the night or work, '
            'the app offers to start it by itself; only your tap switches it.',
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _Offer extends StatelessWidget {
  const _Offer({required this.kind, this.onOffer});
  final WearKind kind;
  final void Function(WearKind kind, bool accept)? onOffer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final what = kind == WearKind.night ? 'the night' : 'work sessions';
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Card(
        color: Night.surfaceHigh,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You said yes ${AutoRule.offerAfterYes} times in a row. Start $what automatically from now on?',
                style: text.bodyLarge?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton(onPressed: () => onOffer?.call(kind, true), child: const Text('Start automatically')),
                  TextButton(onPressed: () => onOffer?.call(kind, false), child: const Text('Keep asking')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A question over one row of the three choices: the night-watch segmented switch (as form_parts.dart's), with each
/// label kept on one line and scaled down rather than broken mid-word at large text sizes.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.question, required this.choices, required this.value, required this.onChanged});
  final String question;
  final List<AutoChoice> choices;
  final AutoChoice value;
  final ValueChanged<AutoChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question, style: text.bodyLarge?.copyWith(height: 1.4)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<AutoChoice>(
              segments: [
                for (final c in choices)
                  ButtonSegment(
                    value: c,
                    label: FittedBox(fit: BoxFit.scaleDown, child: Text(c.short, maxLines: 1)),
                  ),
              ],
              selected: {value},
              showSelectedIcon: false,
              onSelectionChanged: (sel) {
                if (sel.isNotEmpty) onChanged(sel.first);
              },
              style: SegmentedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                selectedBackgroundColor: Night.surfaceHigh,
                selectedForegroundColor: Night.ink,
                foregroundColor: Night.inkMuted,
                side: const BorderSide(color: Night.rule),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
