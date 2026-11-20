// The alpha-theta pages around a session (DECISIONS rows 104-107), each one screen of the night-watch system with
// one action pinned at the bottom: first use (screening, consent, stop plan), setup (session number, the length
// rule, pause and the decision after 10), check-in, grounding, the after-session questions and the alertness
// check. The session itself and the report use the meditation's view (meditation_view.dart).
import 'dart:async';

import 'package:flutter/material.dart';

import '../alphatheta/rules.dart';
import '../logs/own_text.dart';
import '../training/check.dart';
import 'check_views.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'reaction_test.dart';
import 'theme.dart';

Widget _scaffold(
  BuildContext context, {
  required List<Widget> children,
  required Widget action,
  VoidCallback? onInfo,
  VoidCallback? onSettings,
}) {
  final text = Theme.of(context).textTheme;
  return Scaffold(
    appBar: AppBar(
      title: Text('Alpha-theta', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
      actions: [
        if (onSettings != null)
          IconButton(
            onPressed: onSettings,
            icon: const Icon(Icons.tune),
            tooltip: 'Training settings',
            color: Night.inkMuted,
          ),
        if (onInfo != null)
          IconButton(
            onPressed: onInfo,
            icon: const Icon(Icons.info_outline),
            tooltip: 'What the research says',
            color: Night.inkMuted,
          ),
        const SizedBox(width: 8),
      ],
    ),
    body: ListView(padding: const EdgeInsets.fromLTRB(24, 4, 24, 32), children: children),
    bottomNavigationBar: PinnedAction(child: action),
  );
}

Widget _title(BuildContext context, String t) => Text(t, style: Theme.of(context).textTheme.displaySmall);

// ---- first use -------------------------------------------------------------------------------------------

class AtFirstUseView extends StatefulWidget {
  const AtFirstUseView({super.key, required this.onAgree, required this.onInfo});
  final void Function(String contact, String grounding) onAgree;
  final VoidCallback onInfo;

  @override
  State<AtFirstUseView> createState() => _AtFirstUseViewState();
}

class _AtFirstUseViewState extends State<AtFirstUseView> {
  Set<int> _ticked = {};
  bool _consent = false;
  final _contact = TextEditingController();
  final _grounding = TextEditingController(text: defaultGrounding);

  @override
  void dispose() {
    _contact.dispose();
    _grounding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _ticked.isNotEmpty;
    final ok = !blocked && _consent && _contact.text.trim().isNotEmpty;
    return _scaffold(
      context,
      onInfo: widget.onInfo,
      children: [
        _title(context, 'Before the first session'),
        const Para(
          'Alpha-theta can bring up strong memories and feelings, so a few questions first. Nothing you tick here '
          'is saved.',
          color: Night.inkMuted,
          top: 10,
        ),
        const SectionHeading('Does any of this apply to you?'),
        Checklist(items: screeningItems, ticked: _ticked, onChanged: (v) => setState(() => _ticked = v)),
        if (blocked)
          const Para(
            'Then alpha-theta is not offered here. Please talk to a doctor or therapist first. Meditation stays '
            'available.',
            color: Night.caution,
          ),
        const SectionHeading('What it is, and what it can do'),
        for (final (i, t) in consentText.indexed) Para(t, top: i == 0 ? 0 : 12),
        CheckboxListTile(
          value: _consent,
          onChanged: blocked ? null : (v) => setState(() => _consent = v == true),
          title: const Text('I understand: practice, not treatment, and I can stop at any time.'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.only(top: 12),
          activeColor: Night.inkMuted,
          checkColor: Night.ground,
        ),
        const SectionHeading('Your stop plan'),
        const Para('If something comes up during or after a session:', top: 0, color: Night.inkMuted),
        const SizedBox(height: 12),
        TextField(
          controller: _contact,
          onChanged: (_) => setState(() {}),
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Someone you can call (name, number)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _grounding,
          maxLines: 2,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What grounds you', border: OutlineInputBorder()),
        ),
      ],
      action: FilledButton.icon(
        onPressed: ok ? () => widget.onAgree(_contact.text.trim(), _grounding.text.trim()) : null,
        icon: const Icon(Icons.check),
        label: Text(
          blocked
              ? 'Not offered'
              : ok
              ? 'Agree and continue'
              : 'Answer above to continue',
        ),
      ),
    );
  }
}

// ---- setup -----------------------------------------------------------------------------------------------

class AtSetupModel {
  const AtSetupModel({
    required this.done,
    required this.minutes,
    required this.lengths,
    this.pausedWhy,
    this.needsDecision = false,
    this.checkOn = false,
    this.checkStatus,
    this.contact = '',
    this.grounding = '',
    this.nightRunning = false,
    this.message = '',
  });

  /// Completed sessions.
  final int done;
  final int minutes;
  final List<int> lengths;
  final String? pausedWhy;
  final bool needsDecision;
  final bool checkOn;
  final String? checkStatus;
  final String contact;
  final String grounding;
  final bool nightRunning;
  final String message;
}

class AtSetupView extends StatelessWidget {
  const AtSetupView({
    super.key,
    required this.model,
    required this.onMinutes,
    required this.onCheckIn,
    required this.onResume,
    required this.onDecide,
    required this.onInfo,
    required this.onSettings,
  });

  final AtSetupModel model;
  final ValueChanged<int> onMinutes;
  final VoidCallback onCheckIn;
  final VoidCallback onResume;
  final VoidCallback onDecide;
  final VoidCallback onInfo;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final paused = m.pausedWhy != null;
    final (title, sentence, color) = paused
        ? (
            'Paused',
            '${m.pausedWhy} Please talk to a professional before going on. Meditation stays available.',
            Night.caution,
          )
        : m.needsDecision
        ? (
            '${m.done} sessions done',
            'The plan was ${AtDose.planned} sessions, then decide. Look back at how they went and how you felt '
                'between them; go on only if it still feels right.',
            Night.inkMuted,
          )
        : m.nightRunning
        ? (
            'Night recording',
            'A night is being recorded, and the headband connects to one thing at a time.',
            Night.caution,
          )
        : (
            'Session ${m.done + 1}',
            m.message.isNotEmpty
                ? m.message
                : 'Of ${AtDose.planned} planned. Recline with the back of your head free, eyes closed, wired '
                      'headphones in.',
            Night.inkMuted,
          );
    return _scaffold(
      context,
      onInfo: onInfo,
      onSettings: onSettings,
      children: [
        _title(context, title),
        Para(sentence, color: color, top: 10),
        if (!paused && !m.needsDecision) ...[
          const SectionHeading('Length'),
          if (m.lengths.length == 1)
            Para('${m.lengths.single} min: the first ${AtDose.shortSessions} sessions are short.', top: 0)
          else
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                segments: [for (final v in m.lengths) ButtonSegment(value: v, label: Text('$v min'))],
                selected: {m.minutes},
                onSelectionChanged: (s) => onMinutes(s.first),
                style: SegmentedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  selectedBackgroundColor: Night.surfaceHigh,
                  selectedForegroundColor: Night.ink,
                  foregroundColor: Night.inkMuted,
                  side: const BorderSide(color: Night.rule),
                ),
              ),
            ),
          Para(
            'First 1½ minutes in silence: 30 s eyes open, then 60 s eyes closed. Then the stream and the waves. '
            'A high chime: alpha above its line. A low gong: theta above its line.',
            color: Night.inkMuted,
          ),
          if (m.checkOn) ...[
            const SectionHeading('Replay check'),
            const Para(checkReminder, top: 0),
            if (m.checkStatus != null) Para(m.checkStatus!, color: Night.inkMuted, top: 8),
          ],
        ],
        const SectionHeading('Your stop plan'),
        OwnText(child: Text('Call: ${m.contact.isEmpty ? '–' : m.contact}', style: text.bodyLarge?.copyWith(height: 1.4))),
        const SizedBox(height: 6),
        OwnText(child: Text('Grounding: ${m.grounding}', style: text.bodyLarge?.copyWith(height: 1.4))),
        const Para(
          'Stop is always on the screen; the sound fades over about 10 seconds. Practice, not treatment.',
          color: Night.inkMuted,
        ),
      ],
      action: paused
          ? OutlinedButton.icon(
              onPressed: onResume,
              icon: const Icon(Icons.forum_outlined),
              label: const Text('I have talked to someone'),
            )
          : m.needsDecision
          ? OutlinedButton.icon(
              onPressed: onDecide,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Go on past 10'),
            )
          : FilledButton.icon(
              onPressed: m.nightRunning ? null : onCheckIn,
              icon: const Icon(Icons.checklist),
              label: const Text('Check in'),
            ),
    );
  }
}

// ---- check-in --------------------------------------------------------------------------------------------

class AtCheckInView extends StatefulWidget {
  const AtCheckInView({
    super.key,
    required this.firstSession,
    required this.needReaction,
    required this.onStart,
    required this.onBack,
  });
  final bool firstSession;

  /// Until 3 before-session tests exist, the reaction test is part of the check-in (it sets your usual).
  final bool needReaction;
  final void Function(CheckIn checkIn, int? reactionMs) onStart;
  final VoidCallback onBack;

  @override
  State<AtCheckInView> createState() => _AtCheckInViewState();
}

class _AtCheckInViewState extends State<AtCheckInView> {
  int? _sleepy, _distress;
  Set<int> _effects = {};
  bool? _lasted;
  int? _ms;
  bool _tested = false;

  @override
  Widget build(BuildContext context) {
    final lastedOk = _effects.isEmpty || _lasted != null;
    final reactionOk = !widget.needReaction || _tested;
    final ok = _sleepy != null && _distress != null && lastedOk && reactionOk;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) widget.onBack();
      },
      child: _scaffold(
        context,
        children: [
          _title(context, 'Check in'),
          const Para(
            'A minute of questions before the session; the same ones each time.',
            color: Night.inkMuted,
            top: 10,
          ),
          SliderQuestion(
            question: 'How sleepy are you right now?',
            value: _sleepy,
            min: 1,
            max: 9,
            onChanged: (v) => setState(() => _sleepy = v),
            ends: ('1 very alert', '9 fighting sleep'),
          ),
          SliderQuestion(
            question: 'How distressed or upset are you right now?',
            value: _distress,
            min: 0,
            max: 10,
            onChanged: (v) => setState(() => _distress = v),
            ends: ('0 not at all', '10 extremely'),
          ),
          SectionHeading(widget.firstSession ? 'In the last few days' : 'Since your last session'),
          Checklist(items: sideEffectItems, ticked: _effects, onChanged: (v) => setState(() => _effects = v)),
          if (_effects.isNotEmpty)
            ChoiceQuestion<bool>(
              question: 'Did any of these last into the next day?',
              choices: const [(true, 'Yes'), (false, 'No')],
              value: _lasted,
              onChanged: (v) => setState(() => _lasted = v),
            ),
          if (widget.needReaction) ...[
            const SectionHeading('Reaction test'),
            const Para(
              'For your first sessions: this sets your usual speed, so the check after a session can compare.',
              top: 0,
              color: Night.inkMuted,
            ),
            const SizedBox(height: 12),
            ReactionPanel(
              onDone: (ms) => setState(() {
                _ms = ms;
                _tested = ms != null;
              }),
            ),
          ],
        ],
        action: FilledButton.icon(
          onPressed: ok
              ? () => widget.onStart(
                  CheckIn(sleepiness: _sleepy!, distress: _distress!, effects: _effects, lasted: _lasted ?? false),
                  _ms,
                )
              : null,
          icon: const Icon(Icons.self_improvement),
          label: Text(ok ? 'Start the session' : 'Answer each question'),
        ),
      ),
    );
  }
}

// ---- grounding -------------------------------------------------------------------------------------------

class AtGroundingView extends StatefulWidget {
  const AtGroundingView({super.key, required this.ownRoutine, required this.onDone, this.seconds = 60});
  final String ownRoutine;
  final VoidCallback onDone;
  final int seconds;

  @override
  State<AtGroundingView> createState() => _AtGroundingViewState();
}

class _AtGroundingViewState extends State<AtGroundingView> {
  late int _left = widget.seconds;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left = (_left - 1).clamp(0, widget.seconds));
      if (_left == 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _scaffold(
    context,
    children: [
      _title(context, 'Eyes open'),
      const Para('A minute to come back before the questions.', color: Night.inkMuted, top: 10),
      const SizedBox(height: 28),
      Readout(parts: [('$_left', true), (' s', false)], label: _left > 0 ? 'of grounding left' : 'take your time'),
      const SectionHeading('Grounding'),
      for (final (i, line) in groundingText.indexed) Para(line, top: i == 0 ? 0 : 10),
      if (widget.ownRoutine.isNotEmpty && widget.ownRoutine != defaultGrounding)
        OwnText(child: Para('Yours: ${widget.ownRoutine}')),
    ],
    action: FilledButton.icon(
      onPressed: widget.onDone,
      icon: const Icon(Icons.arrow_forward),
      label: const Text('Continue'),
    ),
  );
}

// ---- after the session -----------------------------------------------------------------------------------

class AtAfterView extends StatefulWidget {
  const AtAfterView({super.key, required this.asksGuess, required this.onSave});

  /// The replay check's guess questions belong to this session.
  final bool asksGuess;
  final void Function(AfterSession after, CheckRatings? ratings) onSave;

  @override
  State<AtAfterView> createState() => _AtAfterViewState();
}

class _AtAfterViewState extends State<AtAfterView> {
  int? _distress, _control;
  String? _memories;
  bool? _unreal, _seizure;
  Set<int> _effects = {};
  RatingAnswers _check = const RatingAnswers();
  final _journal = TextEditingController();

  @override
  void dispose() {
    _journal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final check = _check.copyWith(control: _control).ratings;
    final ok =
        _distress != null &&
        _control != null &&
        _memories != null &&
        _unreal != null &&
        _seizure != null &&
        (!widget.asksGuess || check != null);
    return _scaffold(
      context,
      children: [
        _title(context, 'How was it?'),
        const Para(
          'The same questions after every session. Answers stay on this phone.',
          color: Night.inkMuted,
          top: 10,
        ),
        SliderQuestion(
          question: 'How distressed or upset are you now?',
          value: _distress,
          min: 0,
          max: 10,
          onChanged: (v) => setState(() => _distress = v),
          ends: ('0 not at all', '10 extremely'),
        ),
        ChoiceQuestion<String>(
          question: 'Did strong memories or images come up?',
          choices: const [('none', 'No'), ('pleasant', 'Pleasant'), ('distressing', 'Distressing')],
          value: _memories,
          onChanged: (v) => setState(() => _memories = v),
        ),
        ChoiceQuestion<bool>(
          question: 'Did you feel unreal, detached, or outside yourself?',
          choices: const [(true, 'Yes'), (false, 'No')],
          value: _unreal,
          onChanged: (v) => setState(() => _unreal = v),
        ),
        ChoiceQuestion<bool>(
          question: 'Anything like a seizure: jerking, a blank spell, lost time?',
          choices: const [(true, 'Yes'), (false, 'No')],
          value: _seizure,
          onChanged: (v) => setState(() => _seizure = v),
        ),
        scaleQuestion('How much did you feel in control of the sound?', _control, (v) => setState(() => _control = v), (
          'not at all',
          'completely',
        )),
        const SectionHeading('Right now'),
        Checklist(items: sideEffectItems, ticked: _effects, onChanged: (v) => setState(() => _effects = v)),
        if (widget.asksGuess) ...[
          const SectionHeading('Replay check'),
          CheckQuestions(
            heading: false,
            answers: _check, onChanged: (v) => setState(() => _check = v), withControl: false),
        ],
        const SectionHeading('Notes (optional)'),
        TextField(
          controller: _journal,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Anything you want to remember', border: OutlineInputBorder()),
        ),
      ],
      action: FilledButton.icon(
        onPressed: ok
            ? () => widget.onSave(
                AfterSession(
                  distress: _distress!,
                  memories: _memories!,
                  unreal: _unreal!,
                  seizure: _seizure!,
                  effects: _effects,
                  control: _control!,
                  journal: _journal.text.trim(),
                ),
                widget.asksGuess ? check : null,
              )
            : null,
        icon: const Icon(Icons.check),
        label: Text(ok ? 'Save' : 'Answer each question'),
      ),
    );
  }
}

// ---- alertness -------------------------------------------------------------------------------------------

class AtAlertnessView extends StatefulWidget {
  const AtAlertnessView({super.key, required this.usualMs, required this.onDone, this.clock});
  final List<int> usualMs;

  /// The last test's median (null: not done) and whether it said alert as usual.
  final void Function(int? ms, bool? ok) onDone;
  final DateTime Function()? clock;

  @override
  State<AtAlertnessView> createState() => _AtAlertnessViewState();
}

class _AtAlertnessViewState extends State<AtAlertnessView> {
  int? _sleepy, _ms;
  ({bool ok, String words})? _verdict;
  DateTime? _retestAt;
  int _round = 0;
  Timer? _wait;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    // the retest opens by itself once its 10 minutes are up
    _wait = Timer.periodic(const Duration(seconds: 15), (_) {
      final at = _retestAt;
      if (mounted && at != null && !_now().isBefore(at)) {
        setState(() {
          _retestAt = null;
          _round++;
        });
      }
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  void _result(int? ms) {
    setState(() {
      _ms = ms;
      _verdict = ms == null || _sleepy == null
          ? null
          : alertness(medianMs: ms, usualMs: widget.usualMs, sleepiness: _sleepy!);
      _retestAt = _verdict?.ok == false ? _now().add(const Duration(minutes: Alert.retestMin)) : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = _verdict, retest = _retestAt;
    String two(int x) => x.toString().padLeft(2, '0');
    return _scaffold(
      context,
      children: [
        _title(context, 'Before you leave'),
        const Para(
          'Alpha-theta can leave you drowsier than you feel. A sleepiness rating and a 1-minute reaction test '
          'against your usual, before you drive or cycle.',
          color: Night.inkMuted,
          top: 10,
        ),
        SliderQuestion(
          question: 'How sleepy are you right now?',
          value: _sleepy,
          min: 1,
          max: 9,
          onChanged: (x) => setState(() {
            _sleepy = x;
            if (_ms != null) _verdict = alertness(medianMs: _ms!, usualMs: widget.usualMs, sleepiness: x);
          }),
          ends: ('1 very alert', '9 fighting sleep'),
        ),
        const SectionHeading('Reaction test'),
        if (v != null) Para(v.words, color: v.ok ? Night.live : Night.caution, top: 0),
        if (retest != null)
          Para(
            'The retest opens at ${two(retest.hour)}:${two(retest.minute)}; this page can stay open.',
            color: Night.inkMuted,
          )
        else ...[
          if (v != null) const SizedBox(height: 16),
          ReactionPanel(key: ValueKey(_round), onDone: _result),
        ],
      ],
      action: FilledButton.icon(
        onPressed: _sleepy == null ? null : () => widget.onDone(_ms, v?.ok),
        icon: const Icon(Icons.arrow_forward),
        label: Text(_sleepy == null ? 'Rate your sleepiness' : 'See the report'),
      ),
    );
  }
}
