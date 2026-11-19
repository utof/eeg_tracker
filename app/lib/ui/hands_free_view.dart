// Hands-free controls: the Settings page and the calibration page (.impeccable/surfaces/app-lib-ui-hands-free-screen-dart.md,
// DECISIONS 240-249). Calibration shows what the headband sees while you do it: your jaw and your eyes as two live
// lanes, the clench line across the jaw lane, and the six tries as the watch strip's cells. Built from plain view
// models only, so tests render them without a phone.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../detectors/gestures.dart';
import '../handsfree/calibration_controller.dart' show CalStage, LaneStep, calTries, laneSeconds;
import '../handsfree/store.dart';
import '../recorder/nights.dart' show nightLabel;
import 'form_parts.dart' show Para, PinnedAction;
import 'parts.dart';
import 'theme.dart';
import 'wearer_view.dart' show WearerSettings;

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The two gestures as the pages name them.
String gestureName(GestureKind k) => k == GestureKind.clench ? 'Double clench' : 'Look left, then right';

/// Why a try was not caught, in plain words (gestures.dart's rule codes).
String whyWords(GestureKind k, String why) {
  final clench = k == GestureKind.clench;
  return switch (why) {
    'ok' => 'caught',
    'none' => 'nothing seen',
    'noisy' => 'movement or a lost signal nearby',
    'one' => clench ? 'only one clench seen' : 'only one eye movement seen',
    'many' => clench ? 'other jaw movement close by' : 'other eye movements close by',
    'long' => 'a clench lasted over a second',
    'short' => 'a clench was too short to see',
    'close' => 'the two clenches ran together',
    'apart' => 'the clenches were over 1.5 s apart',
    'weak' => 'weaker than your other clenches',
    'slow' => 'the look back came after 1.5 s',
    'same' => 'both movements went the same way',
    'way' => 'the first look went right',
    'small' => 'smaller than your other looks',
    _ => why,
  };
}

/// What a gesture does, by session (DECISIONS 244-247).
const List<(String, String, String)> gestureUses = [
  ('Sound, Meditation', 'pauses the sound, or brings it back', 'marks a moment'),
  ('Dream catcher', 'answers Drifting, else a moment', 'answers Awake, else a moment'),
  ('Alpha-theta, Nap coach', 'marks a moment', 'marks a moment'),
  ('Night recording', 'marks a moment, no tone', 'not used at night'),
];

// ---------------------------------------------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------------------------------------------

class SettingsViewModel {
  const SettingsViewModel({
    this.on = false,
    this.calibration,
    this.nightRunning = false,
    this.error,
    this.wearerOn,
    this.wearerStatus = '',
  });
  final bool on;
  final CalibrationRecord? calibration;
  final bool nightRunning;
  final String? error;

  /// "Was this you?" (DECISIONS 370-379): the switch and its status in words; null when not known (no folder).
  final bool? wearerOn;
  final String wearerStatus;
}

/// The switch's line: what is on now, in words.
String handsFreeStatus(SettingsViewModel m) {
  final c = m.calibration;
  if (!m.on) {
    if (c == null) return 'Off. Calibrate first, then switch it on.';
    return c.usable ? 'Off.' : 'Off. No gesture was caught clearly; calibrate again.';
  }
  if (c == null) return 'On, but not calibrated yet. Calibrate first.';
  if (!c.usable) return 'On, but no gesture was caught clearly enough. Calibrate again.';
  final s = c.settings;
  if (s.clenchOn && s.glanceOn) return 'On: both gestures.';
  return s.clenchOn ? 'On: the double clench only.' : 'On: the look left, then right only.';
}

class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.model,
    required this.onToggle,
    required this.onCalibrate,
    required this.onInfo,
    this.onWearerSwitch,
    this.onWearerInfo,
    this.studyOn,
    this.onStudy,
  });

  final SettingsViewModel model;
  final ValueChanged<bool> onToggle;
  final VoidCallback onCalibrate;
  final VoidCallback onInfo;
  final ValueChanged<bool>? onWearerSwitch;
  final VoidCallback? onWearerInfo;

  /// The study reminders' switch (null while it is not known) and the page that holds them.
  final bool? studyOn;
  final VoidCallback? onStudy;

  @override
  Widget build(BuildContext context) {
    final m = model, c = m.calibration;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    final working = m.on && c != null && c.usable;
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says', color: Night.inkMuted),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          if (onStudy != null) ...[
            ListTile(
              onTap: onStudy,
              contentPadding: EdgeInsets.zero,
              title: Text('Study reminders', style: text.titleLarge),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${studyOn == true ? 'On' : 'Off'}. The assistant\'s idea: a nudge to study in the evening and to recall it in the morning.',
                  style: text.bodyLarge?.copyWith(color: studyOn == true ? Night.live : Night.inkMuted, height: 1.4),
                ),
              ),
              trailing: const Icon(Icons.chevron_right, color: Night.inkMuted),
            ),
            const Divider(height: 24),
          ],
          SwitchListTile(
            value: m.on,
            onChanged: onToggle,
            contentPadding: EdgeInsets.zero,
            title: Text('Hands-free controls', style: text.titleLarge),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(handsFreeStatus(m), style: text.bodyLarge?.copyWith(color: working ? Night.live : Night.inkMuted)),
            ),
          ),
          if (m.error != null) Para(m.error!, color: Night.problem),
          const SizedBox(height: 12),
          if (c == null)
            Text('Not calibrated yet. About 90 seconds with the headband on.', style: text.bodyLarge?.copyWith(height: 1.45))
          else ...[
            Text('Calibrated ${nightLabel(c.made)}, ${_clock(c.made)}.', style: text.bodyLarge?.copyWith(height: 1.45)),
            const SizedBox(height: 12),
            for (final k in GestureKind.values) _GestureLine(kind: k, calibration: c),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: c == null
                ? FilledButton.icon(onPressed: m.nightRunning ? null : onCalibrate, icon: const Icon(Icons.tune), label: const Text('Calibrate'))
                : OutlinedButton.icon(onPressed: m.nightRunning ? null : onCalibrate, icon: const Icon(Icons.tune), label: const Text('Calibrate again')),
          ),
          if (m.nightRunning) ...[
            const SizedBox(height: 8),
            Text('The headband is busy with the night. Calibrate after Stop.', style: muted),
          ],
          const SectionHeading('What it is'),
          Text(
            'A firm double clench of your teeth, or a look far left and then far right, works as a switch during '
            'sessions. A soft tone says it was caught. The temple electrodes see jaw muscle and sideways eye '
            'movements best.',
            style: text.bodyLarge?.copyWith(height: 1.45),
          ),
          const SectionHeading('What each one does'),
          _Uses(clenchOn: c?.settings.clenchOn ?? true, glanceOn: c?.settings.glanceOn ?? true),
          const SizedBox(height: 14),
          Text(
            'Never in the morning check-in (it would change the measurement), and never while the app thinks you '
            'are asleep.',
            style: muted,
          ),
          const SectionHeading('How often it is wrong'),
          Text(
            'Tested on one recorded night when nobody made a gesture: no double clench came up in 4.6 hours awake; '
            'a look left, then right came up about twice an hour (about once an hour when left and right are told '
            'apart). Asleep, either came up about once in 2 hours, so the app ignores them then. The limits are '
            'first guesses until your calibration sets them.',
            style: muted,
          ),
          if (m.wearerOn != null)
            WearerSettings(on: m.wearerOn!, status: m.wearerStatus, onSwitch: onWearerSwitch, onInfo: onWearerInfo),
        ],
      ),
    );
  }
}

class _Uses extends StatelessWidget {
  const _Uses({required this.clenchOn, required this.glanceOn});
  final bool clenchOn, glanceOn;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = text.bodyMedium?.copyWith(color: Night.inkMuted);
    Widget cell(String s, bool on) => Text(
      on ? s : 'off: not caught clearly',
      style: text.bodyLarge?.copyWith(height: 1.35, color: on ? Night.ink : Night.inkMuted),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (where, clench, look)) in gestureUses.indexed) ...[
          if (i > 0) const Divider(height: 25),
          Text(where, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text('Double clench', style: label), const SizedBox(height: 2), cell(clench, clenchOn)],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Look left, then right', style: label),
                    const SizedBox(height: 2),
                    cell(look, glanceOn || look.startsWith('not used')),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// One gesture's calibration in a line: label left, verdict right, the detail under it.
class _GestureLine extends StatelessWidget {
  const _GestureLine({required this.kind, required this.calibration});
  final GestureKind kind;
  final CalibrationRecord calibration;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = calibration, clench = kind == GestureKind.clench;
    final on = clench ? c.settings.clenchOn : c.settings.glanceOn;
    final seen = clench ? c.clenchSeen : c.glanceSeen;
    final detail = clench
        ? 'Caught $seen of 3. It counts at ${c.settings.clenchX.round()} times your jaw at rest.'
        : 'Caught $seen of 3, ${c.leftKnown ? 'left and right told apart' : 'either way: left and right were not told apart'}.';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(gestureName(kind), style: text.titleMedium)),
              Text(on ? 'Works' : 'Not used', style: text.titleMedium?.copyWith(color: on ? Night.live : Night.caution)),
            ],
          ),
          const SizedBox(height: 4),
          Text(detail, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4, fontFeatures: tabular)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Calibration
// ---------------------------------------------------------------------------------------------------------------

class CalViewModel {
  const CalViewModel({
    required this.stage,
    this.message = '',
    this.tryNow,
    this.inWindow = false,
    this.stillLeft = 32,
    this.jaw = const [],
    this.eyes = const [],
    this.clenchLine = GestureRule.clenchX,
    this.glanceSize = GestureRule.glanceUv,
    this.result,
    this.saveNote,
    this.nightRunning = false,
    this.shaped = const [],
    this.linesAreYours = false,
  });

  final CalStage stage;

  /// Each try's live mark (calibration_controller.dart `shaped`): true seen, false not seen, null not judged yet.
  final List<bool?> shaped;

  /// The lanes' lines come from an earlier calibration; else they are first guesses.
  final bool linesAreYours;
  final String message;

  /// The try cued now (0..5), and whether its 5 s are still open.
  final int? tryNow;
  final bool inWindow;
  final int stillLeft;

  /// The lanes (calibration_controller.dart): the jaw's weaker side against its rest, the last 100 ticks; eye moves.
  final List<double> jaw;
  final List<LaneStep> eyes;
  final double clenchLine;
  final double glanceSize;
  final GestureCalibration? result;
  final String? saveNote;
  final bool nightRunning;

  bool get running => stage == CalStage.still || stage == CalStage.trying;
}

/// The instruction and the line under it.
(String, String) calInstruction(CalViewModel m) {
  final t = m.tryNow;
  if (m.stage == CalStage.still) {
    return ('Sit still', 'Let your jaw rest and look ahead. Learning your resting level: ${m.stillLeft} s.');
  }
  if (t == null || !m.inWindow) return ('Relax', 'The next try comes with a tone.');
  return calTries[t] == GestureKind.clench
      ? ('Clench twice now', 'Two short, firm clenches, about a second apart.')
      : ('Look left, then right', 'Eyes only, head still: far left, far right, then back.');
}

class CalibrationView extends StatelessWidget {
  const CalibrationView({
    super.key,
    required this.model,
    required this.onStart,
    required this.onStop,
    required this.onDone,
    required this.onInfo,
  });

  final CalViewModel model;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onDone;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final Widget action = switch (m.stage) {
      CalStage.setup || CalStage.failed => FilledButton.icon(
        onPressed: m.nightRunning ? null : onStart,
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(m.stage == CalStage.failed ? 'Try again' : 'Start'),
      ),
      CalStage.result when !_usable(m.result) => FilledButton.icon(
        onPressed: onStart,
        icon: const Icon(Icons.replay_rounded),
        label: const Text('Try again'),
      ),
      CalStage.result => FilledButton.icon(onPressed: onDone, icon: const Icon(Icons.check), label: const Text('Done')),
      _ => OutlinedButton.icon(onPressed: onStop, icon: const Icon(Icons.stop_rounded), label: const Text('Stop')),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text('Hands-free calibration', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says', color: Night.inkMuted),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: switch (m.stage) {
          CalStage.setup => _setup(context),
          CalStage.connecting || CalStage.contact => [
            TryCells(model: m),
            const SizedBox(height: 28),
            Text(m.stage == CalStage.contact ? 'Checking contact' : 'Connecting', style: text.displaySmall),
            const SizedBox(height: 10),
            Text(m.message, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
            const SizedBox(height: 28),
            GestureLanes(jaw: const [], eyes: const [], clenchLine: m.clenchLine, glanceSize: m.glanceSize, yours: m.linesAreYours),
          ],
          CalStage.still || CalStage.trying => _running(context),
          CalStage.result => _result(context),
          CalStage.failed => [
            Text('Stopped', style: text.displaySmall),
            Para(m.message, color: Night.caution),
          ],
        },
      ),
      bottomNavigationBar: PinnedAction(child: action),
    );
  }

  List<Widget> _setup(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge?.copyWith(height: 1.45);
    Widget step(int n, String s) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _NumberCell(n),
          const SizedBox(width: 14),
          Expanded(child: Text(s, style: body)),
        ],
      ),
    );
    return [
      Text('About 90 seconds', style: text.displaySmall),
      const Para('Headband on, sitting up, the phone in front of you. The app learns how your own clench and your own '
          'look show on the headband.'),
      const SizedBox(height: 24),
      step(1, 'Sit still for 30 seconds, jaw relaxed.'),
      step(2, 'On each low tone, clench your teeth twice: short and firm, about a second apart. Three times.'),
      step(3, 'On each rising tone, look far left, then far right, then back. Eyes only, head still. Three times.'),
      if (model.nightRunning)
        Para('The headband is busy with the night. Calibrate after Stop.', color: Night.caution)
      else
        Para('Nothing changes in your sessions until you switch hands-free on in Settings.', color: Night.inkMuted),
    ];
  }

  List<Widget> _running(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final (title, line) = calInstruction(m);
    final active = m.stage == CalStage.still || m.inWindow;
    return [
      TryCells(model: m),
      const SizedBox(height: 28),
      Semantics(
        liveRegion: true,
        child: Text(title, style: text.displaySmall?.copyWith(color: active ? Night.ink : Night.inkMuted)),
      ),
      const SizedBox(height: 10),
      Text(line, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4, fontFeatures: tabular)),
      const SizedBox(height: 28),
      GestureLanes(jaw: m.jaw, eyes: m.eyes, clenchLine: m.clenchLine, glanceSize: m.glanceSize, yours: m.linesAreYours),
      const SizedBox(height: 10),
      Text(
        'The last $laneSeconds seconds. Jaw: how strong both temple electrodes are, compared with sitting still; a '
        'clench counts above the dashed line. Eyes: where your eyes went, up for one side and down for the other; a '
        'look counts past the faint lines.',
        style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
      ),
    ];
  }

  List<Widget> _result(BuildContext context) {
    final m = model, r = m.result!;
    final text = Theme.of(context).textTheme;
    final usable = _usable(r);
    final headline = !usable
        ? 'Not clear enough'
        : r.settings.clenchOn && r.settings.glanceOn
        ? 'Both work'
        : '${gestureName(r.settings.clenchOn ? GestureKind.clench : GestureKind.glance)} works';
    return [
      TryCells(model: m),
      const SizedBox(height: 28),
      Text(headline, style: text.displaySmall),
      Para(
        usable
            ? 'Saved. Switch hands-free on in Settings to use ${r.settings.clenchOn && r.settings.glanceOn ? 'both gestures' : 'it'}.'
            : 'No gesture was caught at least 2 times of 3. Try again, a little firmer and with a pause between.',
        color: Night.inkMuted,
      ),
      if (m.saveNote != null) Para(m.saveNote!, color: Night.caution),
      const SizedBox(height: 8),
      for (final k in GestureKind.values) _Verdict(kind: k, result: r),
      const SectionHeading('Each try'),
      Text(
        'Clench: how strong, in times your jaw at rest. Look: how far your eyes moved, in microvolts (µV) at the '
        'temples.',
        style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
      ),
      const SizedBox(height: 6),
      for (final (i, t) in r.tries.indexed) _TryRow(n: i + 1, result: t, last: i == r.tries.length - 1),
      if (r.others > 0) ...[
        const SizedBox(height: 12),
        Text(
          '${r.others == 1 ? 'One gesture' : '${r.others} gestures'} came up between the tries. If you did not '
          'make ${r.others == 1 ? 'it' : 'them'}, calibrate again sitting stiller.',
          style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4),
        ),
      ],
    ];
  }
}

bool _usable(GestureCalibration? r) => r != null && (r.settings.clenchOn || r.settings.glanceOn);

class _Verdict extends StatelessWidget {
  const _Verdict({required this.kind, required this.result});
  final GestureKind kind;
  final GestureCalibration result;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = result, clench = kind == GestureKind.clench;
    final on = clench ? r.settings.clenchOn : r.settings.glanceOn;
    final seen = clench ? r.clenchSeen : r.glanceSeen;
    final what = !on
        ? 'Caught $seen of 3; it needs 2.'
        : clench
        ? 'Caught $seen of 3. Pauses the sound, answers Drifting, marks a moment.'
        : 'Caught $seen of 3${r.leftKnown ? '' : ', either way'}. Marks a moment, answers Awake.';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(gestureName(kind), style: text.titleMedium)),
              Text(on ? 'Works' : 'Not used', style: text.titleMedium?.copyWith(color: on ? Night.live : Night.caution)),
            ],
          ),
          const SizedBox(height: 4),
          Text(what, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
        ],
      ),
    );
  }
}

class _NumberCell extends StatelessWidget {
  const _NumberCell(this.n);
  final int n;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: Night.track, borderRadius: BorderRadius.circular(6)),
    child: Text('$n', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
  );
}

/// One try in the result: its number, what was asked, caught or why not, and how strong.
class _TryRow extends StatelessWidget {
  const _TryRow({required this.n, required this.result, required this.last});
  final int n;
  final TryResult result;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = result, ok = r.why == 'ok', level = r.level;
    final size = level == null
        ? null
        : r.kind == GestureKind.clench
        ? '${level.round()} x'
        : '${level.round()} µV';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: Night.rule))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _NumberCell(n),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.kind == GestureKind.clench ? 'Clench twice' : 'Look left, then right', style: text.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  ok ? 'Caught' : 'Missed: ${whyWords(r.kind, r.why)}',
                  style: text.bodyMedium?.copyWith(color: ok ? Night.inkMuted : Night.caution, height: 1.35),
                ),
              ],
            ),
          ),
          if (size != null) ...[
            const SizedBox(width: 12),
            Text(size, style: text.titleMedium?.copyWith(fontFeatures: tabular, color: ok ? Night.ink : Night.inkMuted)),
          ],
        ],
      ),
    );
  }
}

/// The six tries as the watch strip's cells under two words: to come a faint outline, the try in progress a green
/// outline, done and waiting a `track` cell, after the result caught `saved` and missed a cell with a dash.
class TryCells extends StatelessWidget {
  const TryCells({super.key, required this.model});
  final CalViewModel model;

  @override
  Widget build(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final r = m.result;
    String live(int i) {
      final now = m.tryNow;
      if (now == null || i > now) return 'to come';
      if (i == now) return 'now';
      final seen = i < m.shaped.length ? m.shaped[i] : null;
      return seen == null ? 'done' : (seen ? 'seen' : 'not seen');
    }

    final words = [
      for (var i = 0; i < calTries.length; i++) r != null ? (r.tries[i].why == 'ok' ? 'caught' : 'missed') : live(i),
    ];
    final step = m.stage == CalStage.still
        ? 'Sitting still'
        : m.tryNow != null
        ? 'Try ${m.tryNow! + 1} of ${calTries.length}'
        : r != null
        ? '${r.clenchSeen + r.glanceSeen} of ${calTries.length} caught'
        : '${calTries.length} tries';
    Widget cell(int i) {
      final w = words[i];
      final (fill, border) = switch (w) {
        'caught' || 'seen' => (Night.saved, null),
        'missed' || 'not seen' => (Night.track, null),
        'done' => (Night.track, Night.inkMuted),
        'now' => (Night.track, Night.live),
        _ => (Colors.transparent, Night.rule),
      };
      return Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(6),
          border: border == null ? null : Border.all(color: border, width: w == 'now' ? 2 : 1),
        ),
        child: w == 'missed' || w == 'not seen' ? const Center(child: SizedBox(width: 12, height: 2, child: ColoredBox(color: Night.caution))) : null,
      );
    }

    Widget group(String label, List<int> idx) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [for (final i in idx) Padding(padding: const EdgeInsets.only(right: 6), child: cell(i))]),
        const SizedBox(height: 6),
        Text(label, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
      ],
    );
    return Semantics(
      label: '$step. ${[for (var i = 0; i < words.length; i++) 'Try ${i + 1} ${words[i]}'].join(', ')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step, style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [group('Clench twice', [0, 1, 2]), group('Look left, then right', [3, 4, 5])],
          ),
        ],
      ),
    );
  }
}

/// The two live lanes: Jaw (bars per 0.1 s on a log scale from 1 to 100 times the resting level, the clench line
/// dashed) and Eyes (each sideways movement as a step up or down from the middle, the glance size as faint rules).
class GestureLanes extends StatelessWidget {
  const GestureLanes({
    super.key,
    required this.jaw,
    required this.eyes,
    required this.clenchLine,
    required this.glanceSize,
    this.yours = false,
  });
  final List<double> jaw;
  final List<LaneStep> eyes;
  final double clenchLine;
  final double glanceSize;

  /// The lines come from an earlier calibration; else they are first guesses and say so.
  final bool yours;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final learning = jaw.isEmpty || jaw.every((v) => v.isNaN);
    Widget lane(String name, String note, CustomPainter p, double h) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(name, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
            const Spacer(),
            Text(note, style: label?.copyWith(fontFeatures: tabular)),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(height: h, width: double.infinity, child: CustomPaint(painter: p)),
      ],
    );
    return Semantics(
      label: learning ? 'Jaw lane: learning your resting level' : 'Jaw and eye lanes of the last $laneSeconds seconds',
      excludeSemantics: true,
      child: Column(
        children: [
          lane(
            'Jaw',
            learning ? 'learning your jaw at rest' : '${yours ? 'yours' : 'first guess'}: ${clenchLine.round()} x',
            _JawPainter(jaw, clenchLine),
            72,
          ),
          const SizedBox(height: 16),
          lane('Eyes', yours ? 'your look size' : 'first-guess look size', _EyePainter(eyes, glanceSize), 72),
        ],
      ),
    );
  }
}

const double _jawTop = 100; // the lane's top: 100 times the resting level

double _logY(double x, double h) {
  final v = math.log(x.clamp(1, _jawTop)) / math.log(_jawTop);
  return h - v * h;
}

class _JawPainter extends CustomPainter {
  _JawPainter(this.jaw, this.line);
  final List<double> jaw;
  final double line;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(r, Paint()..color = Night.track);
    const n = laneSeconds * ticksPerSecond;
    final w = size.width / n;
    final bar = Paint()..color = Night.ink;
    final under = Paint()..color = Night.saved;
    final start = n - jaw.length;
    for (var i = 0; i < jaw.length; i++) {
      final v = jaw[i];
      if (v.isNaN || v <= 1) continue;
      final y = _logY(v, size.height);
      canvas.drawRect(Rect.fromLTRB((start + i) * w + 0.5, y, (start + i + 1) * w - 0.5, size.height), v >= line ? bar : under);
    }
    final ly = _logY(line, size.height);
    final dash = Paint()
      ..color = Night.ink
      ..strokeWidth = 1.5;
    for (var x = 0.0; x < size.width; x += 10) {
      canvas.drawLine(Offset(x, ly), Offset(math.min(x + 6, size.width), ly), dash);
    }
  }

  @override
  bool shouldRepaint(_JawPainter old) => true;
}

class _EyePainter extends CustomPainter {
  _EyePainter(this.eyes, this.size);
  final List<LaneStep> eyes;
  final double size;
  static const double top = 250; // µV at the lane's edge

  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(6)), Paint()..color = Night.track);
    final mid = s.height / 2;
    final rule = Paint()
      ..color = Night.rule
      ..strokeWidth = 1;
    final g = (size / top).clamp(0.0, 1.0) * mid;
    canvas.drawLine(Offset(0, mid - g), Offset(s.width, mid - g), rule);
    canvas.drawLine(Offset(0, mid + g), Offset(s.width, mid + g), rule);
    canvas.drawLine(Offset(0, mid), Offset(s.width, mid), rule..color = Night.saved);
    // where the eyes went: a step line from the middle, up for one side, down for the other, holding between moves
    final ink = Paint()
      ..color = Night.ink
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(0, mid);
    var y = mid;
    for (final e in [...eyes]..sort((a, b) => b.ago.compareTo(a.ago))) {
      final x = s.width * (1 - e.ago / laneSeconds);
      path.lineTo(x, y);
      y = (y - e.step / top * mid).clamp(3.0, s.height - 3);
      path.lineTo(x, y);
    }
    path.lineTo(s.width, y);
    canvas.drawPath(path, ink);
  }

  @override
  bool shouldRepaint(_EyePainter old) => true;
}
