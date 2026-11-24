// The questions as widgets (DECISIONS 867): [ConfirmBatch] is "Did you walk 19:08-21:14?" with Yes, No and Not sure,
// one tap each, for any screen that has questions to ask (a card, a sheet after Stop, another app's check-in); it
// draws nothing without questions. [ConfirmCard] wraps it with a heading and the "i" button. Colours come from the
// app's theme; no files here.
import 'package:flutter/material.dart';

import 'estimate.dart';
import 'store.dart';

/// A batch of questions. An answered one stays, with its answer, Undo and "Add a few words", until the batch is
/// loaded again.
class ConfirmBatch extends StatelessWidget {
  const ConfirmBatch({
    super.key,
    required this.questions,
    required this.onAnswer,
    this.answers = const {},
    this.notes = const {},
    this.onUndo,
    this.onNote,
  });

  final List<ConfirmQuestion> questions;

  /// What you answered since the batch was loaded, by estimate id, and the words you added.
  final Map<String, Answer> answers;
  final Map<String, String> notes;
  final void Function(ConfirmQuestion question, Answer answer) onAnswer;
  final void Function(ConfirmQuestion question)? onUndo;
  final void Function(ConfirmQuestion question)? onNote;

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
          onAnswer: (a) => onAnswer(q, a),
          onUndo: onUndo == null ? null : () => onUndo!(q),
          onNote: onNote == null ? null : () => onNote!(q),
        ),
    ],
  );
}

/// A text link that starts at the text's left edge.
final ButtonStyle _link = TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(48, 44));

class _Question extends StatelessWidget {
  const _Question({super.key, required this.question, required this.answer, required this.note, required this.onAnswer, this.onUndo, this.onNote});
  final ConfirmQuestion question;
  final Answer? answer;
  final String? note;
  final ValueChanged<Answer> onAnswer;
  final VoidCallback? onUndo, onNote;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final a = answer;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question.text, style: text.bodyLarge?.copyWith(height: 1.4, color: a == null ? c.onSurface : c.onSurfaceVariant)),
          if (a == null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (i, choice) in Answer.buttons.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => onAnswer(choice),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        foregroundColor: c.onSurface,
                        side: BorderSide(color: c.outlineVariant),
                      ),
                      child: Text(choice.word, maxLines: 1, softWrap: false),
                    ),
                  ),
                ],
              ],
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              note == null ? 'Saved: ${a.word}' : 'Saved: ${a.word}. "$note"',
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
    this.onUndo,
    this.onNote,
    this.onInfo,
  });

  final List<ConfirmQuestion> questions;
  final Map<String, Answer> answers;
  final Map<String, String> notes;
  final void Function(ConfirmQuestion question, Answer answer) onAnswer;
  final void Function(ConfirmQuestion question)? onUndo;
  final void Function(ConfirmQuestion question)? onNote;
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
                  'The app thinks these happened. One tap each; your answer is what counts.',
                  style: text.bodyMedium?.copyWith(color: c.onSurfaceVariant, height: 1.4),
                ),
                ConfirmBatch(questions: questions, answers: answers, notes: notes, onAnswer: onAnswer, onUndo: onUndo, onNote: onNote),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
