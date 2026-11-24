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

  @override
  String toString() => id;
}

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
