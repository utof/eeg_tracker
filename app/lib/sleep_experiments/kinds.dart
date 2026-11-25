// Sleep experiments (DECISIONS rows 838, 1050-1069; research 2026-11-24 "personal experiments"): which experiments
// the app offers, the three answers of the one-tap log, and the numbers each one watches. Pure.
//
// Only what the research says can show in a few weeks on one person is offered: a lot of caffeine late, a hard
// workout late, three or more drinks. One cup of coffee, one drink, an ordinary evening gym visit, a late dinner and
// evening screens are not offered: the studies found nothing or an effect too small for one person's nights.
//
// Every number comes from the night's sleep report (and the pulse the app reads beside it), so it works for any
// number of channels at any positions.

/// The answer of an evening's tap.
enum Answer {
  /// It happened, as much and as late as the research says it must to show.
  withIt('with'),

  /// The comparison night.
  without('without'),

  /// Something in between: the night goes in neither pile.
  neither('neither');

  const Answer(this.id);
  final String id;
  static Answer? byId(Object? id) => values.where((a) => a.id == id).firstOrNull;
}

/// How a number is written.
enum Unit { minutes, points, beats, clock }

/// A number of the night that an experiment watches.
class NightMeasure {
  const NightMeasure(this.id, this.label, this.noun, this.unit, this.typicalSpread, this.more, this.less, {this.note});
  final String id;

  /// "Sleep efficiency" (a row's name) and "sleep efficiency" (after "your").
  final String label, noun;
  final Unit unit;

  /// How much this number moves from one ordinary night to the next in a typical person (research section 3):
  /// used until the owner has 14 ordinary nights of their own.
  final double typicalSpread;

  /// The words for a higher and a lower value.
  final String more, less;

  /// A limit said with every result of this number.
  final String? note;
}

const NightMeasure efficiency = NightMeasure('efficiency', 'Sleep efficiency', 'sleep efficiency', Unit.points, 6.5, 'higher', 'lower');
const NightMeasure deepSleep = NightMeasure('deep', 'Deep sleep', 'deep sleep', Unit.minutes, 25, 'more', 'less');
const NightMeasure awakeInNight = NightMeasure('awake', 'Awake in the night', 'time awake in the night', Unit.minutes, 17.5, 'more', 'less');
const NightMeasure pulseAsleep = NightMeasure(
  'pulse',
  'Pulse while asleep',
  'pulse while asleep',
  Unit.beats,
  3.3,
  'higher',
  'lower',
  note: 'The pulse is read from the headband\'s signal and is not yet checked against a watch.',
);
const NightMeasure sleepStart = NightMeasure('sleep_start', 'Fell asleep at', 'sleep', Unit.clock, 35, 'later', 'earlier');
const NightMeasure dreamSleep = NightMeasure(
  'dream',
  'Dream sleep',
  'dream sleep',
  Unit.minutes,
  20,
  'more',
  'less',
  note:
      'Studies find less dream sleep after alcohol. This headband under-counts dream sleep, so not seeing it here '
      'does not mean it is not happening.',
);

const List<NightMeasure> nightMeasures = [efficiency, deepSleep, awakeInNight, pulseAsleep, sleepStart, dreamSleep];

/// A number an experiment watches, with the change the studies found (always positive; the size only).
typedef Watched = ({NightMeasure measure, double expected});

class ExperimentKind {
  const ExperimentKind({
    required this.id,
    required this.title,
    required this.thing,
    required this.question,
    required this.withLabel,
    required this.withoutLabel,
    required this.neitherLabel,
    required this.withMeans,
    required this.withoutMeans,
    required this.watched,
    required this.studies,
    required this.canPick,
    this.nightAfterOut = false,
    this.rule,
  });
  final String id;

  /// "Late caffeine" (the list) and "late caffeine" (inside a sentence: "nights with late caffeine").
  final String title, thing;

  /// The evening's question and its three one-tap answers.
  final String question, withLabel, withoutLabel, neitherLabel;

  /// What counts as a night with, and as a night without, in full.
  final String withMeans, withoutMeans;

  /// The numbers watched; the first is the main one.
  final List<Watched> watched;

  /// What the studies found, in one or two sentences.
  final String studies;

  /// The app may pick the nights (a fair test). Never for alcohol: the app does not tell anyone to drink.
  final bool canPick;

  /// The night after a night with goes in neither pile (alcohol: the pulse stays raised).
  final bool nightAfterOut;

  /// A rule to keep while it runs.
  final String? rule;

  NightMeasure get main => watched.first.measure;
}

const List<ExperimentKind> experimentKinds = [
  ExperimentKind(
    id: 'caffeine_late',
    title: 'Late caffeine',
    thing: 'late caffeine',
    question: 'Caffeine today?',
    withLabel: 'A lot, late',
    withoutLabel: 'None after noon',
    neitherLabel: 'In between',
    withMeans: 'About 400 mg of caffeine (some 4 cups of coffee) in the last 4 to 6 hours before bed.',
    withoutMeans: 'No caffeine after noon. Morning coffee as on every day.',
    watched: [(measure: efficiency, expected: 9.5), (measure: deepSleep, expected: 34), (measure: awakeInNight, expected: 26)],
    studies:
        'In a trial, 400 mg four hours before bed cost 51 minutes of sleep and 34 minutes of deep sleep. One cup '
        '(100 mg) four hours or more before bed changed nothing, so that is not offered.',
    canPick: true,
    rule: 'Leave two days between nights with. Keep your morning coffee the same every day.',
  ),
  ExperimentKind(
    id: 'workout_late',
    title: 'Late hard workout',
    thing: 'a late hard workout',
    question: 'Hard workout today?',
    withLabel: 'Late',
    withoutLabel: 'Early',
    neitherLabel: 'None or light',
    withMeans: 'A long, hard workout that ends in the last 2 hours before bed.',
    withoutMeans: 'The same hard workout, finished before 17:00.',
    watched: [(measure: pulseAsleep, expected: 3.9), (measure: sleepStart, expected: 36)],
    studies:
        'In 4 million nights of wristband wearers, a very hard workout ending 2 hours before bed went with sleep '
        'starting 36 minutes later and a pulse about 4 beats a minute higher. An ordinary evening gym visit showed '
        'nothing, so that is not offered.',
    canPick: true,
    rule: 'Compare with the same workout done early, not with a rest day. One easy day between hard days.',
  ),
  ExperimentKind(
    id: 'alcohol',
    title: 'Alcohol',
    thing: '3 or more drinks',
    question: 'Drinks today?',
    withLabel: '3 or more',
    withoutLabel: 'None',
    neitherLabel: '1 or 2',
    withMeans: 'Three or more drinks in the evening (a drink: a small beer, a glass of wine, a shot).',
    withoutMeans: 'No alcohol that day.',
    watched: [(measure: pulseAsleep, expected: 2.5), (measure: dreamSleep, expected: 10)],
    studies:
        'Studies find a pulse while asleep about 1 beat a minute higher per drink, and less dream sleep from about '
        '3 drinks. One or two drinks would need a hundred nights or more, so those nights are left out.',
    canPick: false,
    nightAfterOut: true,
  ),
];

ExperimentKind? kindById(Object? id) => experimentKinds.where((k) => k.id == id).firstOrNull;

/// A reason a logged night is in neither pile.
enum LeftOut {
  inBetween('in between'),
  noNight('no night that counts'),
  odd('ill or not your own bed'),
  nightAfter('the night after drinks'),
  afterShortNight('after a night under 5 hours');

  const LeftOut(this.words);
  final String words;
}

/// Things that make a night odd whatever the experiment: one tap each, the night is then left out.
const List<(String id, String label)> oddFlags = [('ill', 'Ill'), ('away', 'Not my own bed')];

/// A night under this many minutes asleep makes the next night a rebound night, left out (research section 5).
const double shortNightMin = 300;
