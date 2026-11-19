// Lights off on the night screen and "Falling asleep" in the sleep report (DECISIONS 180-184). Design: DESIGN.md
// (Lights off, Falling asleep) and the night screen's and sleep report's surface briefs in .impeccable/surfaces/.
// - Night screen, while a night records: the pinned bar holds Lights off beside Stop, with one muted line above them
//   for what the drift-off detector is doing. The first tap is instant (the moment you close your eyes); a later tap
//   asks first, because it moves the night's comparison to that moment.
// - Sleep report: lights off, the minutes from it to sleep by the detector and by the sleep model as log lines, whether
//   they agree, and the running check toward "4 of 5 nights within 5 minutes".
import 'package:flutter/material.dart';

import '../detectors/drift_off.dart' show DriftState;
import '../sleep/drift.dart';
import 'alarm_view.dart' show AlarmLine;
import 'theme.dart';

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The line above Lights off while a night records, from the recorder's status. [recording]: data is coming in (until
/// then the detector has nothing to say).
String lightsOffLine({required int? lightsOffMs, required DriftState? drift, required int? onsetMs, bool recording = true}) {
  final onset = onsetMs == null ? null : _clock(DateTime.fromMillisecondsSinceEpoch(onsetMs));
  if (lightsOffMs == null) {
    if (drift == DriftState.asleep && onset != null) return 'Asleep since $onset by the detector, counted from the start.';
    return 'Tap Lights off as you close your eyes to sleep.';
  }
  final at = 'Lights off ${_clock(DateTime.fromMillisecondsSinceEpoch(lightsOffMs))}';
  if (drift == null && !recording) return '$at.';
  return switch (drift) {
    null => '$at. The morning report works out when you fell asleep.',
    DriftState.baseline => '$at. Learning your eyes-closed alpha (a minute).',
    DriftState.awake => '$at. Awake, by the detector.',
    DriftState.drowsy => '$at. Drowsy, by the detector.',
    DriftState.asleep => onset == null ? '$at. Asleep, by the detector.' : '$at. Asleep since $onset, by the detector.',
  };
}

/// The pinned bar while a night records: [line], then Lights off and Stop side by side.
class NightActions extends StatelessWidget {
  const NightActions({
    super.key,
    required this.line,
    required this.tapped,
    required this.busy,
    required this.onLightsOff,
    required this.onStop,
    this.alarmLine,
    this.onAlarmOff,
  });

  final String? line;

  /// The smart alarm's line (alarm_view.dart), with Alarm off while it can still ring.
  final String? alarmLine;
  final VoidCallback? onAlarmOff;

  /// Lights off was tapped tonight: the button turns quiet ("Lights off again").
  final bool tapped;
  final bool busy;
  final VoidCallback? onLightsOff;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final lightsOff = tapped
        ? OutlinedButton(onPressed: busy ? null : onLightsOff, child: const Text('Lights off again', textAlign: TextAlign.center))
        : FilledButton.icon(
            onPressed: busy ? null : onLightsOff,
            icon: const Icon(Icons.bedtime_outlined),
            label: const Text('Lights off'),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // a hairline sets the bar apart from the page scrolling under it (the line is about the night, not a section)
        const Divider(),
        const SizedBox(height: 12),
        if (line != null) ...[
          Text(line!, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35, fontFeatures: tabular)),
          const SizedBox(height: 10),
        ],
        if (alarmLine != null) ...[
          onAlarmOff == null
              ? Text(alarmLine!, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35, fontFeatures: tabular))
              : AlarmLine(line: alarmLine!, action: 'Alarm off', onAction: busy ? null : onAlarmOff),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(flex: 3, child: lightsOff),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: busy ? null : onStop,
                icon: const Icon(Icons.stop_rounded),
                label: Text(busy ? 'Stopping…' : 'Stop'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Asks before a second Lights off; true to go ahead.
Future<bool> confirmLightsOffAgain(BuildContext context, DateTime first) async {
  final at = _clock(first);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Lights off again?'),
      content: Text('The detector starts over from now, and tonight\'s comparison counts from now instead of $at.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Keep $at')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lights off now')),
      ],
    ),
  );
  return ok == true;
}

/// `17 min`, `17½ min`, `1 h 14 min`: minutes after lights off (the epochs are half minutes).
String afterText(double minutes) {
  if (minutes >= 60) {
    final m = minutes.round();
    return '${m ~/ 60}\u00a0h ${(m % 60).toString().padLeft(2, '0')}\u00a0min';
  }
  final whole = minutes.floor(), half = minutes - whole >= 0.5;
  return '${whole == 0 && half ? '' : '$whole'}${half ? '½' : ''}\u00a0min';
}

/// Whether the detector and the sleep model agree, in words.
String agreeSentence(DriftResult d) {
  final on = d.onsetMin, model = d.modelOnsetMin, diff = d.diffMin;
  if (on == null && model == null) return 'Neither found you falling asleep after lights off.';
  if (on == null) return 'The detector did not see you fall asleep; the sleep model did.';
  if (model == null) return 'The sleep model found no sleep after lights off; the detector did.';
  final apart = diff!.abs();
  if (apart == 0) return 'They agree to the half minute.';
  final gap = apart == 0.5 ? 'half a minute' : afterText(apart);
  return d.agree == true
      ? 'They agree: $gap apart, within 5 minutes.'
      : 'They are $gap apart, more than 5 minutes, so they disagree.';
}

/// Where lights off came from, when it was not your tap.
String? sourceSentence(DriftResult d) => switch (d.from) {
  LightsOffFrom.button => null,
  LightsOffFrom.dreamCatcher => 'Lights off came from the dream catcher.',
  LightsOffFrom.sound => 'Lights off came from the sound session\'s quiet minute.',
  LightsOffFrom.nightStart =>
    'Lights off was not tapped, so both count from the start of the recording, and this night does not count '
        'toward the check.',
};

/// The running check toward 4 of 5 nights.
String checkSentence(DriftCheck c) {
  final nights = c.nights == 1 ? '1 night' : '${c.nights} nights';
  final agree = c.agree == 1 && c.nights == 1 ? 'agrees' : 'agree';
  if (c.nights == 0) {
    return 'The check: no night with Lights off yet. The detector is trusted once 4 of 5 nights agree within 5 '
        'minutes.';
  }
  if (!c.decided) {
    return 'The check so far: ${c.agree} of $nights $agree within 5 minutes. The detector is trusted once 4 of 5 '
        'nights do.';
  }
  return c.trusted
      ? 'The check: ${c.agree} of the last 5 nights agree within 5 minutes, so the detector can be trusted.'
      : 'The check: ${c.agree} of the last 5 nights agree within 5 minutes; it needs 4 to be trusted.';
}

/// The sleep report's "Falling asleep" section.
class FallingAsleepSection extends StatelessWidget {
  const FallingAsleepSection({super.key, required this.drift, required this.check, this.onInfo});
  final DriftResult drift;
  final DriftCheck check;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = drift;
    final body = text.bodyLarge?.copyWith(height: 1.4);
    final muted = body?.copyWith(color: Night.inkMuted);
    Widget line(String label, double? minutes) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(label, style: text.bodyLarge)),
          Text(
            minutes == null ? 'not seen' : afterText(minutes),
            style: (minutes == null ? text.bodyLarge?.copyWith(color: Night.inkMuted) : text.titleLarge)
                ?.copyWith(fontFeatures: tabular),
          ),
        ],
      ),
    );
    final source = sourceSentence(d);
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 32, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text('Falling asleep', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                    ),
                    if (onInfo != null)
                      IconButton(
                        onPressed: onInfo,
                        tooltip: 'How the drift-off detector works',
                        icon: const Icon(Icons.info_outline, color: Night.inkMuted),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Text(
            d.from == LightsOffFrom.nightStart
                ? 'Counted from ${_clock(d.lightsOff)}, the start of the recording. From then until asleep:'
                : 'Lights off at ${_clock(d.lightsOff)}. From then until asleep:',
            style: muted?.copyWith(fontFeatures: tabular),
          ),
          const SizedBox(height: 6),
          line('The detector', d.onsetMin),
          line('The sleep model', d.modelOnsetMin),
          const SizedBox(height: 12),
          Text(agreeSentence(d), style: body),
          if (source != null) ...[const SizedBox(height: 8), Text(source, style: muted)],
          const SizedBox(height: 8),
          Text(checkSentence(check), style: body?.copyWith(fontFeatures: tabular)),
          const SizedBox(height: 8),
          Text('Both are guesses: this checks that they agree, not that either is right.', style: muted),
        ],
      ),
    );
  }
}
