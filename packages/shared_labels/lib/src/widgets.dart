// The questions as widgets (DECISIONS 867, 964-967): [ConfirmBatch] is "19:08-21:14. The headband thinks you walked.
// Did you?" with "I walked", "I did not walk" and "Not sure", one tap each, for any screen that has questions to ask (a card, a sheet after Stop, another app's check-in); it
// draws nothing without questions. [ConfirmCard] wraps it with a heading and the "i" button. Colours come from the
// app's theme; no files here.
import 'package:flutter/material.dart';

import 'estimate.dart';
import 'store.dart';
import 'times_editor.dart';
import 'vocabulary.dart';

/// A batch of questions. An answered one stays, with its answer, Undo and "Add a few words", until the batch is
/// loaded again.
///
/// A card that shows the guess has the two buttons that name the thing and "Not sure", always in that order, and,
/// with [onTimes] and on the day of the stretch, a small "Yes, but the times are off" that opens the timeline
/// (times_editor.dart). A blind card ([ConfirmQuestion.kind], drawn only with [onSaid]) offers chips and words of
/// your own instead and never shows the guess; a choice card (two words the detector cannot tell apart) is drawn the
/// same way with its two words.
class ConfirmBatch extends StatelessWidget {
  const ConfirmBatch({
    super.key,
    required this.questions,
    required this.onAnswer,
    this.answers = const {},
    this.notes = const {},
    this.saved = const {},
    this.onUndo,
    this.onNote,
    this.onTimes,
    this.onSaid,
    this.onWords,
    this.around = const [],
    this.now,
  });

  final List<ConfirmQuestion> questions;

  /// What you answered since the batch was loaded, by estimate id, and the words you added.
  final Map<String, Answer> answers;
  final Map<String, String> notes;

  /// What to show after "Saved:" for an answer that is not one of the plain three ("Walking", "19:20-21:00").
  final Map<String, String> saved;
  final void Function(ConfirmQuestion question, Answer answer) onAnswer;
  final void Function(ConfirmQuestion question)? onUndo;
  final void Function(ConfirmQuestion question)? onNote;

  /// "Yes, but the times are off" was saved with these times; null: the link is not offered.
  final void Function(ConfirmQuestion question, DateTime start, DateTime end)? onTimes;

  /// A blind card's chip was tapped; null: blind cards are drawn with the guess shown.
  final void Function(ConfirmQuestion question, Label label)? onSaid;

  /// A blind card's "Something else" was tapped: ask for the words and save them.
  final void Function(ConfirmQuestion question)? onWords;

  /// What else was found near the questions' stretches, for the timeline. [now]: the latest an end can be set to.
  final List<Estimate> around;
  final DateTime? now;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final q in questions)
        _Question(
          key: ValueKey('confirm-${q.id}'),
          question: q,
          answer: answers[q.id],
          note: notes[q.id],
          saved: saved[q.id],
          onAnswer: (a) => onAnswer(q, a),
          onUndo: onUndo == null ? null : () => onUndo!(q),
          onNote: onNote == null ? null : () => onNote!(q),
          onTimes: onTimes == null || !q.exactTimes
              ? null
              : () async {
                  final t = await showTimesEditor(context, q.estimate, around: around, now: now);
                  if (t != null) onTimes!(q, t.start, t.end);
                },
          onSaid: onSaid == null ? null : (l) => onSaid!(q, l),
          onWords: onWords == null ? null : () => onWords!(q),
        ),
    ],
  );
}

/// A text link that starts at the text's left edge.
final ButtonStyle _link = TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(48, 44));

class _Question extends StatelessWidget {
  const _Question({
    super.key,
    required this.question,
    required this.answer,
    required this.note,
    required this.saved,
    required this.onAnswer,
    this.onUndo,
    this.onNote,
    this.onTimes,
    this.onSaid,
    this.onWords,
  });
  final ConfirmQuestion question;
  final Answer? answer;
  final String? note, saved;
  final ValueChanged<Answer> onAnswer;
  final VoidCallback? onUndo, onNote, onTimes, onWords;
  final ValueChanged<Label>? onSaid;

  /// Drawn with chips: a blind card, or a choice card ("Meditating or resting?").
  bool get _blind => question.kind != CardKind.normal && onSaid != null;

  String _word(Answer a) => switch (a) {
    Answer.yes => question.yes,
    Answer.no => question.no,
    Answer.skip => 'Not sure',
    Answer.said => 'Said',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final a = answer;
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      foregroundColor: c.onSurface,
      side: BorderSide(color: c.outlineVariant),
    );
    Widget button(String word, VoidCallback onPressed) => OutlinedButton(
      onPressed: onPressed,
      style: style,
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(word, maxLines: 1, softWrap: false)),
    );
    final kept = saved ?? (a == null ? '' : _word(a));
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_blind ? question.text : question.guessText, style: text.bodyLarge?.copyWith(height: 1.4, color: a == null ? c.onSurface : c.onSurfaceVariant)),
          if (a == null && _blind) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final l in question.chips) button(l.chip, () => onSaid!(l)),
                if (onWords != null) button('Something else', onWords!),
                button('Not sure', () => onAnswer(Answer.skip)),
              ],
            ),
          ] else if (a == null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (i, choice) in Answer.buttons.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: button(_word(choice), () => onAnswer(choice))),
                ],
              ],
            ),
            if (onTimes != null) TextButton(onPressed: onTimes, style: _link, child: const Text('Yes, but the times are off')),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              note == null ? 'Saved: $kept' : 'Saved: $kept. "$note"',
              style: text.bodyMedium?.copyWith(color: c.onSurfaceVariant, height: 1.4),
            ),
            Wrap(
              spacing: 4,
              children: [
                if (onUndo != null) TextButton(onPressed: onUndo, style: _link, child: const Text('Undo')),
                if (onNote != null && a != Answer.skip)
                  TextButton(onPressed: onNote, style: _link, child: Text(note == null ? 'Add a few words' : 'Change words')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The card: a heading with the "i" note, one line of what this is, and the batch. Nothing when there is no question.
class ConfirmCard extends StatelessWidget {
  const ConfirmCard({
    super.key,
    required this.questions,
    required this.onAnswer,
    this.answers = const {},
    this.notes = const {},
    this.saved = const {},
    this.onUndo,
    this.onNote,
    this.onTimes,
    this.onSaid,
    this.onWords,
    this.around = const [],
    this.now,
    this.onInfo,
  });

  final List<ConfirmQuestion> questions;
  final Map<String, Answer> answers;
  final Map<String, String> notes, saved;
  final void Function(ConfirmQuestion question, Answer answer) onAnswer;
  final void Function(ConfirmQuestion question)? onUndo;
  final void Function(ConfirmQuestion question)? onNote;
  final void Function(ConfirmQuestion question, DateTime start, DateTime end)? onTimes;
  final void Function(ConfirmQuestion question, Label label)? onSaid;
  final void Function(ConfirmQuestion question)? onWords;
  final List<Estimate> around;
  final DateTime? now;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    if (questions.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 16),
      decoration: BoxDecoration(color: c.surfaceContainer, border: Border.all(color: c.outlineVariant), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Quick check', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500))),
              IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'Why the app asks', color: c.onSurfaceVariant),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What the headband found. One tap each; your answer is what counts.',
                  style: text.bodyMedium?.copyWith(color: c.onSurfaceVariant, height: 1.4),
                ),
                ConfirmBatch(
                  questions: questions,
                  answers: answers,
                  notes: notes,
                  saved: saved,
                  onAnswer: onAnswer,
                  onUndo: onUndo,
                  onNote: onNote,
                  onTimes: onTimes,
                  onSaid: onSaid,
                  onWords: onWords,
                  around: around,
                  now: now,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
