// The controlled vocabulary both apps and the laptop's truth table use (scripts/truth_vocabulary.tsv, DECISIONS 821):
// the same label names everywhere, so a stretch labelled in one app means the same in the other. The lists themselves
// are generated (vocabulary.g.dart); here are the label's type and the words the questions and the matching need.
part 'vocabulary.g.dart';

/// One label of the vocabulary.
class Label {
  const Label(this.id, this.kind, this.unit, this.also, this.description);

  /// The word the tables hold (`walking`), and its kind (`activity`).
  final String id, kind;

  /// The unit of its value (`cups`, `1-5`, `bpm`); null: it takes no value.
  final String? unit;

  /// Other words that name it when typed or tagged (`walk`).
  final List<String> also;
  final String description;

  /// The label with this id; null when the vocabulary has none.
  static Label? of(Object? id) {
    for (final l in Labels.all) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// The label a free word names (a tag, a chip): its id or one of its `also` words, in any case and spacing.
  static Label? named(String word) {
    final w = normalWord(word);
    for (final l in Labels.all) {
      if (l.id == w || l.also.any((a) => normalWord(a) == w)) return l;
    }
    return null;
  }

  /// Whether [word] names this label, or one that is the same question (below).
  bool says(String word) {
    final other = named(word);
    return other != null && sameAs(other);
  }

  /// One question for both: sleep at night and a nap are told apart by the clock, not by you, so an answer (or your
  /// own tag) about a stretch as one settles the same stretch as the other.
  bool sameAs(Label other) => id == other.id || (_oneQuestion.contains(id) && _oneQuestion.contains(other.id));

  /// The question's first words ("Did you walk"); the times follow.
  String get ask => _ask[id] ?? 'Was this "${id.replaceAll('_', ' ')}"';

  /// How a card speaks of this label (asking.md): what the detector thinks ("you slept"), the two buttons that name
  /// the thing ("I slept", "I was awake"), the closing question ("Did you?") and the word on a blind card's chip
  /// ("Sleeping"). A label without words of its own gets plain ones made from its name.
  String get thinks => _say[id]?[0] ?? 'this was "$_plain"';
  String get yesWord => _say[id]?[1] ?? 'Yes, it was';
  String get noWord => _say[id]?[2] ?? 'No, it was not';
  String get asks => _say[id]?[3] ?? 'Was it?';
  String get chip => _say[id]?[4] ?? '${_plain[0].toUpperCase()}${_plain.substring(1)}';

  String get _plain => id.replaceAll('_', ' ');

  @override
  String toString() => id;
}

/// thinks, yes, no, the closing question, the chip.
const Map<String, List<String>> _say = {
  'asleep': ['you slept', 'I slept', 'I was awake', 'Did you?', 'Sleeping'],
  'night_sleep': ['you slept', 'I slept', 'I was awake', 'Did you?', 'Sleeping'],
  'nap': ['you napped', 'I napped', 'I was awake', 'Did you?', 'Napping'],
  'awake': ['you were awake', 'I was awake', 'I slept', 'Were you?', 'Awake'],
  'in_bed': ['you were in bed', 'I was in bed', 'I was up', 'Were you?', 'In bed'],
  'eyes_closed': ['your eyes were closed', 'Eyes closed', 'Eyes open', 'Were they?', 'Eyes closed'],
  'walking': ['you walked', 'I walked', 'I did not walk', 'Did you?', 'Walking'],
  'running': ['you ran', 'I ran', 'I did not run', 'Did you?', 'Running'],
  'stairs': ['you took the stairs', 'I took stairs', 'No stairs', 'Did you?', 'On stairs'],
  'cycling': ['you cycled', 'I cycled', 'I did not cycle', 'Did you?', 'Cycling'],
  'vehicle': ['you rode in a car, bus or train', 'I rode', 'I did not ride', 'Did you?', 'In a car, bus or train'],
  'eating': ['you ate', 'I ate', 'I did not eat', 'Did you?', 'Eating'],
  'talking': ['you talked', 'I talked', 'I did not talk', 'Did you?', 'Talking'],
  'meeting': ['you were in a meeting', 'In a meeting', 'No meeting', 'Were you?', 'In a meeting'],
  'focused_work': ['you were focused on work', 'I was focused', 'I was not', 'Were you?', 'Focused work'],
  'working': ['you worked', 'I worked', 'I did not work', 'Did you?', 'Working'],
  'exercise': ['you exercised', 'I exercised', 'No exercise', 'Did you?', 'Exercise'],
  'meditating': ['you meditated', 'I meditated', 'I did not', 'Did you?', 'Meditating'],
  'resting': ['you rested', 'I rested', 'I did not rest', 'Did you?', 'Resting'],
  'sitting': ['you sat', 'I sat', 'I did not sit', 'Did you?', 'Sitting'],
  'standing': ['you stood', 'I stood', 'I did not stand', 'Did you?', 'Standing'],
  'lying': ['you lay down', 'I lay down', 'I did not', 'Did you?', 'Lying down'],
  'headband_off': ['the headband was off', 'It was off', 'It was on', 'Was it?', 'Headband off'],
};

/// A word as the vocabulary compares it: lower case, any run of other characters one `_`.
String normalWord(String word) => word.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

const Set<String> _oneQuestion = {'asleep', 'nap', 'night_sleep'};

/// How each label is asked about. A label without words here is asked as `Was this "<label>" 10:00-10:20?`.
const Map<String, String> _ask = {
  'asleep': 'Did you sleep',
  'night_sleep': 'Did you sleep',
  'nap': 'Did you nap',
  'awake': 'Were you awake',
  'in_bed': 'Were you in bed',
  'eyes_closed': 'Were your eyes closed',
  'walking': 'Did you walk',
  'running': 'Did you run',
  'stairs': 'Were you on stairs',
  'cycling': 'Did you cycle',
  'vehicle': 'Were you in a car, bus or train',
  'eating': 'Did you eat',
  'talking': 'Were you talking',
  'meeting': 'Were you in a meeting',
  'focused_work': 'Were you focused on work',
  'working': 'Were you working',
  'exercise': 'Did you exercise',
  'meditating': 'Were you meditating',
  'resting': 'Were you resting',
  'sitting': 'Were you sitting',
  'standing': 'Were you standing',
  'lying': 'Were you lying down',
  'headband_off': 'Was the headband off',
};
