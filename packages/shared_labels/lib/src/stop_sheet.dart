// The sheet after Stop, "What was this recording?" (Record first, DECISIONS 890-891): its chips, what one tap does,
// and the tags a filled sheet makes, in the shared label words. A tag is the Archive's
// (`archive/<id>.tags.json`) with `truth`, `source` `owner_stop_sheet`, `confidence` and `words`; the laptop's
// scripts/truth.py turns it into a truth row (golden files `tests/contract/labels/stop-sheet.*`). Either app can show
// the chips ([StopChips]); nothing here knows a recorder or a file.
import 'package:flutter/material.dart';

import 'time.dart';
import 'vocabulary.dart';

/// The source of every row the sheet makes.
const String stopSheetSource = 'owner_stop_sheet';

/// One chip: the word you tap and the vocabulary label it means.
class StopChip {
  const StopChip(this.word, this.label, {this.whole = false, this.sleep = false});
  final String word;

  /// A label id of the vocabulary (`walking`).
  final String label;

  /// "The whole recording" by its meaning (Awake the whole time): no "only part of it" times, confidence `certain`.
  final bool whole;

  /// It says you slept: switched off by "Awake the whole time", and the reverse.
  final bool sleep;
}

const List<StopChip> stopChips = [
  StopChip('Awake the whole time', 'awake', whole: true),
  StopChip('Slept', 'night_sleep', sleep: true),
  StopChip('Napped', 'nap', sleep: true),
  StopChip('Worked', 'working'),
  StopChip('Walked', 'walking'),
  StopChip('Ate', 'eating'),
  StopChip('Exercised', 'exercise'),
  StopChip('Meditated', 'meditating'),
  StopChip('Talked / meeting', 'meeting'),
  StopChip('Other', 'other'),
];

/// The label of text typed with no chip.
const String stopSheetOther = 'other';

StopChip? stopChipOf(String label) => stopChips.where((c) => c.label == label).firstOrNull;

/// The chips that are on after [label] is tapped: a tap switches it; "Awake the whole time" switches Slept and Napped
/// off, and either of them switches it off.
Set<String> tapStopChip(Set<String> on, String label) {
  final out = {...on};
  if (!out.remove(label)) {
    out.add(label);
    final c = stopChipOf(label);
    if (c != null && c.whole) out.removeWhere((l) => stopChipOf(l)?.sleep ?? false);
    if (c != null && c.sleep) out.removeWhere((l) => stopChipOf(l)?.whole ?? false);
  }
  return out;
}

/// A chip that is on, with its "only part of it" times when given.
class StopPick {
  const StopPick(this.label, {this.start, this.end});
  final String label;
  final DateTime? start, end;
  bool get timed => start != null && end != null;
}

/// The confidence of a pick: `certain` for the whole-recording chip, `likely` with times, else `within` ("it happened
/// somewhere inside the recording, not all of it").
String stopConfidence(StopPick p) => (stopChipOf(p.label)?.whole ?? false) ? 'certain' : (p.timed ? 'likely' : 'within');

/// The tags a filled sheet makes for a recording from [start] to [end], in the order of [picks]. [words]: your own
/// words, kept exactly as typed in every tag; with words and no pick, one `other` tag. Nothing picked and nothing
/// typed: no tags (Skip). Each tag's label must be in the vocabulary.
List<Map<String, Object?>> stopSheetTags({
  required DateTime start,
  required DateTime end,
  required List<StopPick> picks,
  String words = '',
  required DateTime made,
}) {
  final all = [...picks, if (picks.isEmpty && words.trim().isNotEmpty) const StopPick(stopSheetOther)];
  return [
    for (final p in all)
      if (Label.of(p.label) != null)
        {
          'start': isoLocal(p.timed ? p.start! : start),
          'end': isoLocal(p.timed ? p.end! : end),
          'label': p.label,
          'made': isoLocal(made),
          'truth': true,
          'source': stopSheetSource,
          'confidence': stopConfidence(p),
          if (words.trim().isNotEmpty) 'words': words,
        },
  ];
}

/// The chips, one tap each; several may be on. [done]: labels already covered by what was marked while recording
/// (shown ticked and not asked again).
class StopChips extends StatelessWidget {
  const StopChips({super.key, required this.on, required this.onTap, this.done = const {}});
  final Set<String> on, done;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final c in stopChips)
        FilterChip(
          key: ValueKey('stop-chip-${c.label}'),
          label: Text(c.word),
          selected: on.contains(c.label) || done.contains(c.label),
          onSelected: done.contains(c.label) ? null : (_) => onTap(c.label),
        ),
    ],
  );
}
