// Alpha-theta's safety and dose rules (ROADMAP row 22; DECISIONS rows 104-107; docs/evidence/alpha-theta.md),
// pure so each one is tested. Every number is a planning value from the research report, not a measured limit.
//   - screening before first use: any "yes" and the mode is not offered (talk to a professional first)
//   - consent in plain words and a personal stop plan (someone to call, a grounding routine)
//   - length: the first 3 sessions 15 min, then 20 or 25; after 10 sessions stop and decide
//   - a check-in before and a checklist after every session; the mode pauses on distress 7/10 or more, two
//     sessions in a row with distressing memories, anything like dissociation, a side effect lasting into the
//     next day, or anything like a seizure
//   - an alertness check before you leave: sleepiness and a 1-minute reaction test against your own usual
import 'dart:math' as math;

/// Questions before the first session (ISNR 2011 risk factors, in plain words). Any "yes" blocks the mode.
const List<String> screeningItems = [
  'PTSD, or something traumatic in the last few months',
  'Spells of feeling unreal, detached from yourself, or losing time',
  'Psychosis, or bipolar disorder',
  'Epilepsy, seizures without a known cause, or a head injury that led to seizures',
  'Coming off alcohol or drugs now, or in treatment for an addiction',
  'Severe depression, thoughts of suicide, or a suicide attempt in the past',
  'A personality disorder, or moods that swing hard and fast',
  'Abuse in the past that still causes you symptoms',
  'In trauma therapy now (unless your therapist agrees)',
];

/// The side-effect checklist (Hammond & Kirk 2008), asked before and after every session.
const List<String> sideEffectItems = [
  'Tired or drained',
  'Headache',
  'Anxious or on edge',
  'Poor sleep',
  'Mood swings or tearful',
  'Spacey, unreal or detached',
  'Unwanted memories coming back',
];

/// The consent text, one paragraph per entry.
const List<String> consentText = [
  'Alpha-theta is an eyes-closed practice that lets you drift toward the edge of sleep while sound follows two '
      'rhythms at the back of your head. It is practice, not treatment, and it is not proven to help with anything.',
  'It can bring up strong memories or feelings. It can leave you drowsy or "spacey" for a while, and cause '
      'tiredness, headache, anxiety or poor sleep. At least 1 in 5 people get no benefit at all.',
  'You can stop at any moment: the Stop button is always on the screen, the sound fades over about 10 seconds, '
      'and a minute of grounding follows.',
  'After each session the app checks how alert you are. If you are slower than usual or sleepy, do not drive or '
      'cycle until a retest says you are back to your usual.',
];

/// The grounding minute after every session.
const List<String> groundingText = [
  'Open your eyes slowly.',
  'Feel your feet on the floor and your back against the chair.',
  'Look around and name five things you can see.',
  'Breathe out slowly, a little longer than you breathe in.',
];

const String defaultGrounding = 'Open my eyes, feet on the floor, name five things I can see.';

abstract final class AtDose {
  static const int shortSessions = 3, shortMin = 15, planned = 10;
  static const List<int> laterMin = [20, 25];
}

/// Lengths on offer (minutes) after [done] completed sessions.
List<int> lengthChoices(int done) => done < AtDose.shortSessions ? const [AtDose.shortMin] : AtDose.laterMin;

/// After the planned 10 sessions the mode waits for an explicit decision to go on.
bool needsDecision(int done, DateTime? decided) => done >= AtDose.planned && decided == null;

/// Distress at or above this (0-10) pauses the mode.
const int distressPause = 7;

/// Before a session: sleepiness 1-9 (Karolinska: 1 extremely alert .. 9 fighting sleep), distress 0-10, the
/// side effects since the last session (indexes into [sideEffectItems]) and whether any lasted into the next day.
class CheckIn {
  const CheckIn({required this.sleepiness, required this.distress, this.effects = const {}, this.lasted = false});
  final int sleepiness;
  final int distress;
  final Set<int> effects;
  final bool lasted;

  Map<String, Object?> toJson() => {
    'sleepiness': sleepiness,
    'distress': distress,
    'effects': [for (final i in effects) sideEffectItems[i]],
    'lasted': lasted,
  };

  static CheckIn? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['sleepiness'], d = j['distress'], l = j['lasted'];
    if (s is! int || s < 1 || s > 9 || d is! int || d < 0 || d > 10 || l is! bool) return null;
    return CheckIn(sleepiness: s, distress: d, effects: _effects(j['effects']), lasted: l);
  }
}

/// After a session. [memories]: 'none', 'pleasant' or 'distressing'.
class AfterSession {
  const AfterSession({
    required this.distress,
    required this.memories,
    required this.unreal,
    required this.seizure,
    this.effects = const {},
    required this.control,
    this.journal = '',
  });
  final int distress;
  final String memories;
  final bool unreal;
  final bool seizure;
  final Set<int> effects;

  /// How in control of the sound you felt, 1-5.
  final int control;
  final String journal;

  static const Set<String> memoryWords = {'none', 'pleasant', 'distressing'};

  Map<String, Object?> toJson() => {
    'distress': distress,
    'memories': memories,
    'unreal': unreal,
    'seizure': seizure,
    'effects': [for (final i in effects) sideEffectItems[i]],
    'control': control,
    'journal': journal,
  };

  static AfterSession? fromJson(Object? j) {
    if (j is! Map) return null;
    final d = j['distress'], m = j['memories'], u = j['unreal'], s = j['seizure'], c = j['control'];
    if (d is! int || d < 0 || d > 10 || m is! String || !memoryWords.contains(m)) return null;
    if (u is! bool || s is! bool) return null;
    if (c is! int || c < 1 || c > 5) return null;
    return AfterSession(
      distress: d,
      memories: m,
      unreal: u,
      seizure: s,
      effects: _effects(j['effects']),
      control: c,
      journal: j['journal'] is String ? j['journal'] as String : '',
    );
  }
}

Set<int> _effects(Object? list) => {
  if (list is List)
    for (final e in list)
      if (sideEffectItems.indexOf('$e') case final i when i >= 0) i,
};

/// Why the mode pauses now, in plain words, or null. [before]: today's check-in (null before it is filled);
/// [afters]: the after-session answers of earlier sessions, oldest first.
String? pauseReason({CheckIn? before, required List<AfterSession> afters}) {
  if (afters.isNotEmpty) {
    final last = afters.last;
    if (last.seizure) {
      return 'You noted something like a seizure. Please see a doctor before any more sessions.';
    }
    if (last.unreal) return 'You felt unreal or detached after the last session.';
    if (last.distress >= distressPause) return 'Your distress after the last session was ${last.distress} of 10.';
    if (afters.length >= 2 && afters[afters.length - 2].memories == 'distressing' && last.memories == 'distressing') {
      return 'Distressing memories came up two sessions in a row.';
    }
  }
  if (before != null) {
    if (before.lasted) return 'A side effect lasted into the next day.';
    if (before.distress >= distressPause) return 'Your distress right now is ${before.distress} of 10.';
  }
  return null;
}

/// The alertness check (DECISIONS row 107): slower than this share above your usual median, or sleepiness at
/// or above [sleepyFrom], means "not yet". Without a usual yet, a median over [absoluteSlowMs] counts as slow.
abstract final class Alert {
  static const double slowerBy = 0.1;
  static const int sleepyFrom = 7, absoluteSlowMs = 500, retestMin = 10;
}

/// [usualMs]: your earlier before-session medians. Returns (ok, the words to show).
({bool ok, String words}) alertness({required int medianMs, required List<int> usualMs, required int sleepiness}) {
  final usual = usualMs.isEmpty ? null : _medianInt(usualMs);
  final slow = usual == null ? medianMs > Alert.absoluteSlowMs : medianMs > usual * (1 + Alert.slowerBy);
  final sleepy = sleepiness >= Alert.sleepyFrom;
  final vs = usual == null ? '' : ' (your usual $usual ms)';
  if (slow || sleepy) {
    final why = slow && sleepy
        ? 'slower than usual and sleepy'
        : slow
        ? 'slower than usual'
        : 'sleepy';
    return (
      ok: false,
      words: 'Reactions $medianMs ms$vs, $why. Do not drive or cycle yet. Retest in ${Alert.retestMin} minutes.',
    );
  }
  return (ok: true, words: 'Reactions $medianMs ms$vs: as alert as usual.');
}

int _medianInt(List<int> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : ((s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2).round();
}

/// A 1-minute reaction test: a dot appears after a random 2-5 s wait, you tap as fast as you can. Pure: the
/// widget asks for the next wait and reports each tap's delay (ms) or a tap with no dot (a false start).
class ReactionTest {
  ReactionTest({int? seed, this.lengthS = 60}) : _r = math.Random(seed);
  final math.Random _r;
  final int lengthS;
  final List<int> times = [];
  int falseStarts = 0;

  /// Milliseconds to wait before the next dot.
  int nextWaitMs() => 2000 + _r.nextInt(3001);

  /// A tap [ms] after the dot. Taps under 100 ms are anticipations (false starts); over 1500 ms count as 1500.
  void tap(int ms) {
    if (ms < 100) {
      falseStarts++;
    } else {
      times.add(math.min(ms, 1500));
    }
  }

  void early() => falseStarts++;

  /// Median reaction (ms), or null with fewer than 5 taps.
  int? get median => times.length < 5 ? null : _medianInt(times);

  /// Taps slower than 500 ms (lapses).
  int get lapses => times.where((t) => t > 500).length;
}
