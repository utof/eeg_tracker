// The replay check's questions after a session (DECISIONS row 102): how calm you feel first, then the guess
// (live, replay, not sure, and how sure), how in control and how random the sound felt. Asked before any
// report, the same way after every check session; nothing here tells which kind the session was.
import 'package:flutter/material.dart';

import '../training/check.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'theme.dart';

/// The answers so far; [ratings] is non-null once every question has one.
class RatingAnswers {
  const RatingAnswers({this.calm, this.guess, this.confidence, this.control, this.random});
  final int? calm;
  final String? guess;
  final int? confidence;
  final int? control;
  final int? random;

  RatingAnswers copyWith({int? calm, String? guess, int? confidence, int? control, int? random}) => RatingAnswers(
    calm: calm ?? this.calm,
    guess: guess ?? this.guess,
    confidence: confidence ?? this.confidence,
    control: control ?? this.control,
    random: random ?? this.random,
  );

  /// "Not sure" needs no confidence (it is stored as 0).
  CheckRatings? get ratings {
    final c = calm, g = guess, ctl = control, r = random;
    final conf = g == 'unsure' ? 0 : confidence;
    if (c == null || g == null || conf == null || ctl == null || r == null) return null;
    return CheckRatings(calm: c, guess: g, confidence: conf, control: ctl, random: r);
  }
}

/// The questions as a column of sections. [withCalm]: false where the page asks calm itself.
class CheckQuestions extends StatelessWidget {
  const CheckQuestions({
    super.key,
    required this.answers,
    required this.onChanged,
    this.withCalm = true,
    this.withControl = true,
  });
  final RatingAnswers answers;
  final ValueChanged<RatingAnswers> onChanged;
  final bool withCalm;

  /// False where the page asks "in control" itself (alpha-theta asks it in every session).
  final bool withControl;

  @override
  Widget build(BuildContext context) {
    final a = answers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (withCalm)
          scaleQuestion('How calm do you feel now?', a.calm, (v) => onChanged(a.copyWith(calm: v)), (
            'not at all',
            'very calm',
          )),
        const SectionHeading('Live or replay?'),
        ChoiceQuestion<String>(
          question: 'Did this session\'s sound follow your brain live, or replay an earlier session?',
          choices: const [('live', 'Live'), ('replay', 'Replay'), ('unsure', 'Not sure')],
          value: a.guess,
          onChanged: (v) => onChanged(a.copyWith(guess: v)),
        ),
        if (a.guess != null && a.guess != 'unsure')
          SliderQuestion(
            question: 'How sure are you?',
            value: a.confidence,
            min: 0,
            max: 100,
            step: 10,
            unit: ' %',
            onChanged: (v) => onChanged(a.copyWith(confidence: v)),
            ends: ('a pure guess', 'certain'),
          ),
        if (withControl)
          scaleQuestion(
            'How much did you feel in control of the sound?',
            a.control,
            (v) => onChanged(a.copyWith(control: v)),
            ('not at all', 'completely'),
          ),
        scaleQuestion('How random did the sound seem?', a.random, (v) => onChanged(a.copyWith(random: v)), (
          'not at all',
          'completely random',
        )),
      ],
    );
  }
}

/// Meditation's rating stage: its own page with the questions and one pinned action.
class CheckRatingsView extends StatefulWidget {
  const CheckRatingsView({super.key, required this.onDone, this.initial = const RatingAnswers()});
  final ValueChanged<CheckRatings> onDone;
  final RatingAnswers initial;

  @override
  State<CheckRatingsView> createState() => _CheckRatingsViewState();
}

class _CheckRatingsViewState extends State<CheckRatingsView> {
  late RatingAnswers _a = widget.initial;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = _a.ratings;
    return Scaffold(
      appBar: AppBar(
        title: Text('Meditation', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          Text('Your answers first', style: text.displaySmall),
          const Para(
            'The replay check asks the same questions after every session, before the report. Its results come '
            'only after every 12 sessions.',
            color: Night.inkMuted,
            top: 10,
          ),
          CheckQuestions(answers: _a, onChanged: (v) => setState(() => _a = v)),
        ],
      ),
      bottomNavigationBar: PinnedAction(
        child: FilledButton.icon(
          onPressed: r == null ? null : () => widget.onDone(r),
          icon: const Icon(Icons.check),
          label: Text(r == null ? 'Answer each question' : 'Save and see the report'),
        ),
      ),
    );
  }
}
