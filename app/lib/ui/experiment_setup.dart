// Setting a self-experiment up in a minute (DECISIONS rows 200-201, 208): a question (a preset, or your own "do"
// against "don't"), ONE number, a length; then Start tomorrow. Nothing can be changed after the start, and the
// page says so before the button.
import 'package:flutter/material.dart';

import '../experiments/experiment.dart';
import '../trends/days.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'theme.dart';

/// What the setup hands back.
typedef ExperimentChoice = ({String preset, String doText, String dontText, Outcome outcome, int weeks});

class ExperimentSetup extends StatefulWidget {
  const ExperimentSetup({super.key, required this.now, required this.onStart, this.onInfo});
  final DateTime now;
  final ValueChanged<ExperimentChoice> onStart;
  final VoidCallback? onInfo;

  @override
  State<ExperimentSetup> createState() => _ExperimentSetupState();
}

class _ExperimentSetupState extends State<ExperimentSetup> {
  String? _preset; // a preset's id or 'custom'
  Outcome? _outcome;
  int _weeks = ExpRule.weeks.first;
  final _do = TextEditingController(), _dont = TextEditingController(text: 'As usual');

  @override
  void dispose() {
    _do.dispose();
    _dont.dispose();
    super.dispose();
  }

  String get _doText => _preset == 'custom' ? cleanLine(_do.text) : presets.firstWhere((p) => p.id == _preset).doText;
  String get _dontText => _preset == 'custom' ? cleanLine(_dont.text) : presets.firstWhere((p) => p.id == _preset).dontText;

  String? get _missing {
    if (_preset == null) return 'Choose a question';
    if (_preset == 'custom' && (_doText.isEmpty || _dontText.isEmpty)) return 'Write both lines';
    if (_outcome == null) return 'Choose the number';
    return null;
  }

  void _pick(String id) => setState(() {
    _preset = id;
    if (id != 'custom') _outcome = outcomeById(presets.firstWhere((p) => p.id == id).outcome);
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final start = addDays(dayKey(widget.now), 1), days = _weeks * 7;
    final missing = _missing;
    return Scaffold(
      appBar: AppBar(
        title: Text('New experiment', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: widget.onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          const Para(
            'On random days you do one thing; on the others you don\'t. The app draws the days and tells you each '
            'day\'s task that day.',
            color: Night.inkMuted,
            top: 0,
          ),
          const SectionHeading('The question'),
          for (final p in presets)
            _Option(selected: _preset == p.id, title: p.doText, detail: 'against: ${p.dontText}', onTap: () => _pick(p.id)),
          _Option(selected: _preset == 'custom', title: 'Your own', detail: 'one thing you can do or leave on any day', onTap: () => _pick('custom')),
          if (_preset == 'custom') ...[
            const SizedBox(height: 8),
            _Field(controller: _do, label: 'On a “do” day', hint: 'A cold shower in the evening', onChanged: () => setState(() {})),
            const SizedBox(height: 12),
            _Field(controller: _dont, label: 'On a “don\'t” day', hint: 'As usual', onChanged: () => setState(() {})),
          ],
          const SectionHeading('The one number'),
          const Para(
            'Chosen now, so the answer cannot be picked afterwards from whichever number looks best. It is read the '
            'next day: the night you wake from, and that morning\'s check-in.',
            color: Night.inkMuted,
            top: 0,
          ),
          const SizedBox(height: 8),
          for (final o in outcomes)
            _Option(selected: _outcome?.id == o.id, title: o.label, onTap: () => setState(() => _outcome = o)),
          ChoiceQuestion<int>(
            question: 'How long?',
            choices: [for (final w in ExpRule.weeks) (w, '$w weeks')],
            value: _weeks,
            onChanged: (w) => setState(() => _weeks = w),
          ),
          const Para('Four weeks can show a large effect. Longer runs find smaller ones.', color: Night.inkMuted),
          const SectionHeading('Before you start'),
          Para(
            'Day 1 is tomorrow, ${dayLabel(start)}; the last day is ${dayLabel(addDays(start, days - 1))}. The '
            'answer opens ${dayLabel(addDays(start, days + 1))}.',
            top: 0,
          ),
          const Para(
            'The question, the number and the length cannot be changed after the start, and the days ahead stay '
            'hidden. Record the night and do the morning check-in on as many days as you can: a day without the '
            'number is left out.',
            color: Night.inkMuted,
          ),
        ],
      ),
      bottomNavigationBar: PinnedAction(
        child: FilledButton(
          onPressed: missing != null
              ? null
              : () => widget.onStart((preset: _preset!, doText: _doText, dontText: _dontText, outcome: _outcome!, weeks: _weeks)),
          child: Text(missing ?? 'Start tomorrow'),
        ),
      ),
    );
  }
}

/// One choice of a list: a ring or a filled circle (DESIGN.md Shapes), the line, a muted detail. 56 dp at least.
class _Option extends StatelessWidget {
  const _Option({required this.selected, required this.title, required this.onTap, this.detail});
  final bool selected;
  final String title;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected ? Night.ink : Night.inkMuted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: text.bodyLarge?.copyWith(height: 1.3)),
                      if (detail != null) Text(detail!, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.label, required this.hint, required this.onChanged});
  final TextEditingController controller;
  final String label, hint;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: (_) => onChanged(),
    maxLength: 80,
    textCapitalization: TextCapitalization.sentences,
    cursorColor: Night.ink,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Night.inkMuted),
      hintStyle: const TextStyle(color: Night.inkMuted),
      counterText: '',
      enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Night.rule)),
      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Night.inkMuted)),
    ),
  );
}
