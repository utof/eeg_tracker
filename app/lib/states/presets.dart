// Sound for states (ROADMAP rows 17-18, DECISIONS rows 130-139): the five states, the calm beds, the optional beats,
// and the plan one session plays. Pure: no audio, no clock. The numbers come from the laptop page
// (scripts/web/beats.html, after its review fixes) and docs/evidence/sound-for-states.md:
//   - a calm bed (rain, pink or brown noise, ocean) is the default; a beat is an optional extra, and "no beat" is
//     the same bed at the same loudness, for comparison;
//   - the beat path per state (fall asleep 10 -> 3 Hz over 30 min, relax 10, focus 16, break 10 -> 8, wake up
//     10 -> 18), slid exponentially (the build guide: a constant ratio per minute sounds even);
//   - tone pitch 150, 200, 300 or 400 Hz only: a tone between 220 and 280 Hz that leaks into the headband folds
//     into the brain-wave bands at 250 samples a second (240 Hz shows as 10 Hz);
//   - a modulated layer 6 dB above the bed under it, so the bed does not fill the troughs (build guide 1).
import 'dart:math' as math;

/// What the session is for. `pause` is the Break state (`break` is a Dart keyword).
enum SoundState { asleep, relax, focus, pause, wake }

/// The calm bed under everything (made in the app, nothing downloaded).
enum Bed { rain, pink, brown, ocean, none }

/// The optional rhythm on top: none (compare), pulsed noise, isochronic tones, binaural beats (headphones).
enum Beat { none, pulsed, isochronic, binaural }

class StatePreset {
  const StatePreset({
    required this.state,
    required this.name,
    required this.why,
    required this.expect,
    required this.fromHz,
    required this.toHz,
    required this.rampMin,
    required this.minutes,
    required this.defaultMinutes,
    required this.bed,
    required this.eyesClosed,
    required this.fadeInS,
    required this.fadeOutS,
  });

  final SoundState state;

  /// "Fall asleep".
  final String name;

  /// One plain line under the choice.
  final String why;

  /// What the brain does if you get there, in the readout's words (not a promise).
  final String expect;

  /// The beat rate slides from [fromHz] to [toHz] over [rampMin] minutes (or the whole session, if shorter).
  final double fromHz;
  final double toHz;
  final int rampMin;

  /// Lengths on offer (minutes of sound) and the one picked first.
  final List<int> minutes;
  final int defaultMinutes;

  /// The bed picked first.
  final Bed bed;

  /// The quiet minute and the session are eyes closed (asleep, relax, break) or open (focus, wake up).
  final bool eyesClosed;

  /// Fade in and fade out at the end of the timer (s).
  final double fadeInS;
  final double fadeOutS;
}

const Map<SoundState, StatePreset> presets = {
  SoundState.asleep: StatePreset(
    state: SoundState.asleep,
    name: 'Fall asleep',
    why: 'Pink noise has the most (small) studies for falling asleep. A beat, if you add one, slides from 10 to 3 Hz '
        'over 30 minutes. Stops by itself once you are probably asleep (with the headband), or at the timer.',
    expect: 'Falling asleep: alpha fades and slow waves grow.',
    fromHz: 10,
    toHz: 3,
    rampMin: 30,
    minutes: [15, 30, 45],
    defaultMinutes: 30,
    bed: Bed.pink,
    eyesClosed: true,
    fadeInS: 45,
    fadeOutS: 150,
  ),
  SoundState.relax: StatePreset(
    state: SoundState.relax,
    name: 'Relax',
    why: 'Nature sounds lowered stress by a medium amount across many studies. A beat, if you add one, holds at 10 Hz.',
    expect: 'Relaxing with eyes closed: alpha goes up.',
    fromHz: 10,
    toHz: 10,
    rampMin: 10,
    minutes: [5, 10, 20],
    defaultMinutes: 10,
    bed: Bed.ocean,
    eyesClosed: true,
    fadeInS: 6,
    fadeOutS: 20,
  ),
  SoundState.focus: StatePreset(
    state: SoundState.focus,
    name: 'Focus',
    why: 'Weak evidence: noise helps people with ADHD a little and others slightly less. A beat, if you add one, is '
        '16 Hz, the rate of focus-music services (one company-run study).',
    expect: 'Focus has no clear sign in these electrodes; your answer afterwards is the measure.',
    fromHz: 16,
    toHz: 16,
    rampMin: 25,
    minutes: [15, 25, 45],
    defaultMinutes: 25,
    bed: Bed.rain,
    eyesClosed: false,
    fadeInS: 6,
    fadeOutS: 20,
  ),
  SoundState.pause: StatePreset(
    state: SoundState.pause,
    name: 'Break',
    why: 'Five minutes, eyes closed, to step out of work. No study tested sound for short breaks. A beat, if you add '
        'one, slides from 10 to 8 Hz.',
    expect: 'A rest with eyes closed: alpha goes up, and slow waves do not grow (not dozing off).',
    fromHz: 10,
    toHz: 8,
    rampMin: 5,
    minutes: [5, 10],
    defaultMinutes: 5,
    bed: Bed.rain,
    eyesClosed: true,
    fadeInS: 6,
    fadeOutS: 20,
  ),
  SoundState.wake: StatePreset(
    state: SoundState.wake,
    name: 'Wake up',
    why: 'No study tested sound for waking up. A beat, if you add one, rises from 10 to 18 Hz.',
    expect: 'Waking up has no clear sign in these electrodes; your answer afterwards is the measure.',
    fromHz: 10,
    toHz: 18,
    rampMin: 5,
    minutes: [5, 10],
    defaultMinutes: 5,
    bed: Bed.rain,
    eyesClosed: false,
    fadeInS: 6,
    fadeOutS: 20,
  ),
};

/// Plain names for the screen and the session's line.
const Map<Bed, String> bedNames = {
  Bed.rain: 'Rain',
  Bed.pink: 'Pink noise',
  Bed.brown: 'Brown noise',
  Bed.ocean: 'Ocean',
  Bed.none: 'No bed',
};

const Map<Beat, String> beatNames = {
  Beat.none: 'No beat',
  Beat.pulsed: 'Pulsed noise',
  Beat.isochronic: 'Isochronic tones',
  Beat.binaural: 'Binaural beats',
};

/// Pulse depth per kind: the gain swings between 1 - depth and 1. Pulsed noise 0.7 (troughs -10.5 dB, the page's
/// default); isochronic 0.9, the build guide's "soft isochronic" (-20 dB). Binaural has no pulse in the sound.
const Map<Beat, double> beatDepth = {Beat.none: 0, Beat.pulsed: 0.7, Beat.isochronic: 0.9, Beat.binaural: 0};

/// Share of the total loudness (power) the beat takes when a bed plays under it: 6 dB above the bed.
const double beatOverBed = 0.8;

/// Every session is scaled to this K-weighted loudness (BS.1770, as LUFS) before the phone's own volume.
const double targetLufs = -23;

/// A manual stop fades out over this long (s): no click, no startle.
const double stopFadeS = 3;

/// Tone pitch rules (binaural and isochronic).
abstract final class Tone {
  /// The pitch used: low and soft, in the 200-500 Hz range binaural studies use.
  static const double carrierHz = 200;

  /// The only pitches allowed: none between 220 and 280 Hz.
  static const List<double> carriers = [150, 200, 300, 400];

  /// The headband's sampling rate: a tone leaking into its wires shows up folded around multiples of it.
  static const double eegRate = 250;

  /// Where a tone of [hz] lands in the recording (0 .. eegRate / 2).
  static double folded(double hz) => (hz - eegRate * (hz / eegRate).roundToDouble()).abs();
}

class SoundPlan {
  SoundPlan._({
    required this.state,
    required this.bed,
    required this.beat,
    required this.minutes,
    required this.fromHz,
    required this.toHz,
    required this.rampS,
    required this.carrierHz,
    required this.depth,
    required this.fadeInS,
    required this.fadeOutS,
  });

  /// The preset of [state] with your choices. Throws when nothing would play or the pitch is not allowed.
  factory SoundPlan.of(SoundState state, {Bed? bed, Beat beat = Beat.none, int? minutes, double carrierHz = Tone.carrierHz}) {
    final p = presets[state]!;
    final b = bed ?? p.bed;
    final m = minutes ?? p.defaultMinutes;
    if (b == Bed.none && beat == Beat.none) throw ArgumentError('no bed and no beat: nothing to play');
    if (!Tone.carriers.contains(carrierHz)) throw ArgumentError.value(carrierHz, 'carrierHz', 'one of ${Tone.carriers}');
    if (m < 1 || m * 60 > 45 * 60) throw ArgumentError.value(m, 'minutes', '1 to 45');
    return SoundPlan._(
      state: state,
      bed: b,
      beat: beat,
      minutes: m,
      fromHz: p.fromHz,
      toHz: p.toHz,
      rampS: math.min(m, p.rampMin) * 60,
      carrierHz: carrierHz,
      depth: beatDepth[beat]!,
      fadeInS: p.fadeInS,
      fadeOutS: p.fadeOutS,
    );
  }

  final SoundState state;
  final Bed bed;
  final Beat beat;

  /// Minutes of sound (fall asleep: at most 45 minutes after lights off as well).
  final int minutes;
  final double fromHz;
  final double toHz;
  final double rampS;
  final double carrierHz;
  final double depth;
  final double fadeInS;
  final double fadeOutS;

  StatePreset get preset => presets[state]!;

  /// The beat rate [t] seconds after the sound started (exponential slide, then held); null without a beat.
  double? rateAt(double t) {
    if (beat == Beat.none) return null;
    if (fromHz == toHz || t <= 0) return fromHz;
    if (t >= rampS) return toHz;
    return fromHz * math.pow(toHz / fromHz, t / rampS);
  }

  /// Shares of the total loudness power.
  double get beatShare => beat == Beat.none ? 0 : (bed == Bed.none ? 1 : beatOverBed);
  double get bedShare => 1 - beatShare;

  String _hz(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// "Pink noise, pulsed noise 10 → 3 Hz".
  String get line {
    final rate = fromHz == toHz ? '${_hz(fromHz)} Hz' : '${_hz(fromHz)} → ${_hz(toHz)} Hz';
    final beatPart = beat == Beat.none ? 'no beat' : '${beatNames[beat]!.toLowerCase()} $rate';
    if (bed == Bed.none) return '${beatNames[beat]} $rate';
    return '${bedNames[bed]}, $beatPart';
  }

  Map<String, Object?> toJson() => {
    'state': state.name,
    'bed': bed.name,
    'beat': beat.name,
    'minutes': minutes,
    'fromHz': fromHz,
    'toHz': toHz,
    'rampS': rampS,
    'carrierHz': carrierHz,
    'depth': depth,
    'fadeInS': fadeInS,
    'fadeOutS': fadeOutS,
    'beatShare': beatShare,
    'targetLufs': targetLufs,
  };

  /// The plan a session file describes, rebuilt from its choices (the preset fills in the rest); null when damaged.
  static SoundPlan? fromJson(Object? j) {
    if (j is! Map) return null;
    final state = _byName(SoundState.values, j['state']), bed = _byName(Bed.values, j['bed']);
    final beat = _byName(Beat.values, j['beat']), minutes = j['minutes'], carrier = j['carrierHz'];
    if (state == null || bed == null || beat == null || minutes is! int || carrier is! num) return null;
    try {
      return SoundPlan.of(state, bed: bed, beat: beat, minutes: minutes, carrierHz: carrier.toDouble());
    } on ArgumentError {
      return null;
    }
  }
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}
