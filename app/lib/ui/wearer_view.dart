// "Was this you?" on the sleep report and the check-in's result (.impeccable/surfaces/app-lib-ui-wearer-view-dart.md;
// DECISIONS 370-379). A question leads the page, a remark ends it: when a recording did not look like your usual
// signal, the block is the page's first entry under its lead (asked, then answered, with Undo); otherwise it sits
// after the page's own entries under a hairline heading with its "i". Words only, never colours. Built from a
// WearerLine (wearer/wearer.dart), so tests render every state without a phone.
import 'package:flutter/material.dart';

import '../wearer/check.dart' show answerMe, answerSomeoneElse;
import '../wearer/wearer.dart';
import 'theme.dart';

/// Whether the block goes at the top of its page (a question or its answer) or at the end.
bool wearerLeads(WearerLine? l) => l != null && l.asked;

/// The question (or its answer) as the page's first entry: the sentence in titleLarge ink with the "i", what
/// differed, the everyday causes, and the two equal answers; once answered, what the answer did and Undo.
class WearerQuestion extends StatelessWidget {
  const WearerQuestion({super.key, required this.line, this.onAnswer, this.onInfo});
  final WearerLine line;

  /// `me`, `someone else`, or null to take an answer back.
  final ValueChanged<String?>? onAnswer;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final l = line;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l.text,
                    style: l.question ? text.titleLarge?.copyWith(height: 1.3) : text.bodyLarge?.copyWith(height: 1.45),
                  ),
                ),
              ),
              _Info(onInfo: onInfo),
            ],
          ),
          if (l.detail != null) ...[
            const SizedBox(height: 8),
            Text(l.detail!, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45)),
          ],
          if (l.note != null) ...[
            const SizedBox(height: 6),
            Text(l.note!, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
          ],
          if (l.question) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: onAnswer == null ? null : () => onAnswer!(answerMe),
                  style: _answerStyle,
                  child: const Text('Yes, it was me'),
                ),
                OutlinedButton(
                  onPressed: onAnswer == null ? null : () => onAnswer!(answerSomeoneElse),
                  style: _answerStyle,
                  child: const Text('Someone else'),
                ),
              ],
            ),
          ],
          if (l.canUndo) _Undo(onAnswer: onAnswer),
        ],
      ),
    );
  }
}

/// The quiet actions: text buttons flush with the text above them, 48 dp tall.
final ButtonStyle _quiet = TextButton.styleFrom(
  padding: EdgeInsets.zero,
  minimumSize: const Size(48, 48),
  alignment: Alignment.centerLeft,
);

final ButtonStyle _answerStyle = OutlinedButton.styleFrom(
  minimumSize: const Size(132, 52),
  padding: const EdgeInsets.symmetric(horizontal: 20),
);

/// The remark at the end of the page: the hairline heading with its "i", one sentence and the quiet action.
class WearerRemark extends StatelessWidget {
  const WearerRemark({super.key, required this.line, this.onAnswer, this.onInfo});
  final WearerLine line;
  final ValueChanged<String?>? onAnswer;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final l = line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 32, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text('Was this you?', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                  ),
                  _Info(onInfo: onInfo),
                ],
              ),
            ],
          ),
        ),
        // an answered remark says what the answer did, in ink; the others are a muted line
        Text(l.text, style: text.bodyLarge?.copyWith(color: l.canUndo ? Night.ink : Night.inkMuted, height: 1.45)),
        if (l.canSaySomeoneElse)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onAnswer == null ? null : () => onAnswer!(answerSomeoneElse),
                style: _quiet,
                child: const Text('Someone else wore it'),
              ),
            ),
          ),
        if (l.canUndo) _Undo(onAnswer: onAnswer),
      ],
    );
  }
}

class _Undo extends StatelessWidget {
  const _Undo({this.onAnswer});
  final ValueChanged<String?>? onAnswer;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onAnswer == null ? null : () => onAnswer!(null),
        style: _quiet,
        child: const Text('Undo'),
      ),
    ),
  );
}

class _Info extends StatelessWidget {
  const _Info({this.onInfo});
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onInfo,
    tooltip: 'What the research says about "Was this you?"',
    icon: const Icon(Icons.info_outline, color: Night.inkMuted),
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------------------------------------------

/// The Settings page's section: the heading row with its "i" and the switch, the status in words, whose idea it is,
/// what it does and how often it is wrong.
class WearerSettings extends StatelessWidget {
  const WearerSettings({super.key, required this.on, required this.status, this.onSwitch, this.onInfo});
  final bool on;
  final String status;
  final ValueChanged<bool>? onSwitch;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge?.copyWith(height: 1.45);
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 32, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('Was this you?', style: text.titleLarge)),
                  _Info(onInfo: onInfo),
                  Semantics(label: 'Was this you? check', child: Switch(value: on, onChanged: onSwitch)),
                ],
              ),
            ],
          ),
        ),
        Text(status, style: text.bodyLarge?.copyWith(color: on ? Night.ink : Night.inkMuted, height: 1.45)),
        const SizedBox(height: 12),
        Text(
          "The assistant's proposal, not one of your wishes. Switch it off and nothing is checked or asked.",
          style: muted,
        ),
        const SizedBox(height: 20),
        Text('What it does', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        Text(
          'After 10 check-ins, or 10 nights, on 5 different days it knows roughly what your eyes-closed alpha looks '
          'like: its speed, its strength and the slope of the background signal. When a later one looks clearly '
          'different, the check-in\'s result or the sleep report asks whether it was you. "Someone else" keeps that '
          'recording out of your trends, the unusual card and experiments. Nothing is deleted, nothing is locked, and '
          'it never says who it was.',
          style: body,
        ),
        const SizedBox(height: 20),
        Text('How often it is wrong', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        Text(
          'Tested only on made-up people (no recordings of other people were at hand): it asked about a recording of '
          'the person themselves about once in 5 to 10 months of daily recordings, and noticed only 2 to 4 in 10 '
          'recordings of someone else. So it catches only a clearly different signal: when you know someone '
          'borrowed the headband, tap "Someone else wore it" yourself.',
          style: muted,
        ),
      ],
    );
  }
}
