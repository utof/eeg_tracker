// Sound for states, laid out from a plain view model, so every state renders in tests without a phone.
// Structure (.impeccable/surfaces/app-lib-ui-states-screen-dart.md): between sessions one scrolling column (status,
// the score of the session you are choosing, the state, the sound, the length, the headband, notes, earlier sessions)
// with Start pinned; the last session's result and its one question come first after a session. During a session the
// whole screen is a near-black face with words only: the stage, time left, the beat's rate, the brain line, Stop.
import 'package:flutter/material.dart';

import '../detectors/drift_off.dart' show DriftState;
import '../recorder/nights.dart' show nightLabel;
import '../sound/audio_route.dart';
import '../states/controller.dart' show SoundStage;
import '../states/presets.dart';
import '../states/readout.dart' show ReadSummary;
import '../states/store.dart';
import '../states/timers.dart' show StopWhy;
import '../states/trial.dart';
import '../states/weeks.dart' show StateComparison;
import 'dream_view.dart' show ClipRow, clock, faceGround, faceInk, faceMuted;
import 'form_parts.dart' show ChoiceQuestion;
import 'meditation_view.dart' show MarkShape, StateMark;
import 'parts.dart';
import 'sound_score.dart';
import 'states_weeks_view.dart';
import 'device_status.dart';
import 'theme.dart';

class StatesViewModel {
  const StatesViewModel({
    required this.stage,
    required this.plan,
    this.message = '',
    this.useHeadband = true,
    this.thenNight = true,
    this.nightRunning = false,
    this.listening = false,
    this.seconds = 0,
    this.soundSeconds,
    this.secondsLeft,
    this.quietS = 0,
    this.quietTarget = 60,
    this.rateNow,
    this.live,
    this.hasBaseline = false,
    this.driftState,
    this.stopWhy,
    this.headbandUse = HeadbandUse.soundOnly,
    this.contact = const {},
    this.noData = false,
    this.notes = const [],
    this.screenStaysOn = false,
    this.screenNote = '',
    this.last,
    this.justEnded = false,
    this.earlier = const [],
    this.comparison,
    this.test,
    this.testResults,
    this.soundLocked = false,
    this.route = AudioRoute.unknown,
  });

  final SoundStage stage;

  /// The plan being chosen, or the session's own while one runs.
  final SoundPlan plan;
  final String message;
  final bool useHeadband;
  final bool thenNight;

  /// The night recording holds the headband: sound only.
  final bool nightRunning;
  final bool listening;

  /// Seconds after lights off, of sound, and until the sound is silent.
  final double seconds;
  final double? soundSeconds;
  final double? secondsLeft;

  /// Clean seconds of the quiet minute so far, and how many end it.
  final int quietS;
  final int quietTarget;
  final double? rateNow;
  final ReadSummary? live;
  final bool hasBaseline;
  final DriftState? driftState;
  final StopWhy? stopWhy;
  final String headbandUse;
  final Map<String, double?> contact;
  final bool noData;

  /// "Screen: Stays on" was chosen (default: the phone can be locked during a session).
  final bool screenStaysOn;

  /// One line on the session face about locking the phone ('' for none).
  final String screenNote;

  /// Plain sentences in amber (a file could not be saved).
  final List<String> notes;

  /// The newest session (its result comes first after one), and the ones before it.
  final SoundSession? last;
  final bool justEnded;
  final List<SoundSession> earlier;

  /// The chosen state's sounds over the weeks (null: not loaded).
  final StateComparison? comparison;

  /// The chosen state's fair test under way, or its latest once the answer is open; and that answer.
  final TrialState? test;
  final TrialResults? testResults;

  /// Today is a day of the chosen state's fair test: its sound and length are drawn, not chosen.
  final bool soundLocked;

  /// Where the sound goes now (sound/audio_route.dart).
  final AudioRoute route;

  bool get face => stage.index >= SoundStage.connecting.index && stage.index <= SoundStage.ending.index;
  bool get measuring => headbandUse == HeadbandUse.used;
  StatePreset get preset => plan.preset;
}

String _two(int v) => v.toString().padLeft(2, '0');
String _mmss(double s) => '${s ~/ 60}:${_two((s % 60).floor())}';
String _hz(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)} Hz';

/// "alpha 18 % higher", "slow waves about the same" (within 5 %).
String change(String what, double ratio) {
  if (!ratio.isFinite) return '$what not measured';
  final d = ((ratio - 1) * 100).round();
  if (d.abs() < 5) return '$what about the same';
  return d > 0 ? '$what $d % higher' : '$what ${-d} % lower';
}

/// The echo at the beat's rate, in plain words: expected, not a state, and possibly a leak from earbuds.
String echoLine(double? echo) {
  if (echo == null || !echo.isFinite) return 'The echo at the beat\'s rate could not be measured.';
  if (echo < 1.5) return 'No clear echo at the beat\'s rate.';
  return 'Echo at the beat\'s rate: ${echo.toStringAsFixed(1)} times the quiet minute. Expected: the hearing part of '
      'the brain follows a pulse. It is not a sign that your brain "tuned in", and earbuds near the headband can leak '
      'into it.';
}

/// The question after a session.
String ratingQuestion(SoundState s) => switch (s) {
  SoundState.asleep => 'Did it help you fall asleep?',
  SoundState.relax => 'Did it help you relax?',
  SoundState.focus => 'Did it help you focus?',
  SoundState.pause => 'Was it a good break?',
  SoundState.wake => 'Did it help you wake up?',
};

const Map<Beat, String> beatWhy = {
  Beat.none: 'The bed alone, as loud as with a beat. Use it on some days to compare.',
  Beat.pulsed: 'The noise swells and fades at the beat\'s rate. Works on a speaker.',
  Beat.isochronic: 'A soft tone pulsing at the beat\'s rate. Works on a speaker.',
  Beat.binaural: 'A slightly different tone in each ear: the beat exists only inside your head. Needs headphones in both '
      'ears. The weakest effect on brain waves in studies.',
};

/// What a finished session showed, in plain sentences (honest: what was measured, and what it does not mean).
List<String> resultLines(SoundSession s) {
  final p = s.plan, sum = s.summary, out = <String>[];
  switch (s.headband) {
    case HeadbandUse.soundOnly:
      out.add('Sound only: nothing was measured.');
    case HeadbandUse.nightRecording:
      out.add('Sound only, while the night recorded: nothing was measured.');
    case HeadbandUse.notFound:
      out.add('The headband was not found, so nothing was measured.');
    case HeadbandUse.lost:
      out.add('No signal came from the headband, so nothing was measured.');
    default:
      if (sum == null) {
        out.add(
          s.baselineS < 20
              ? 'The quiet minute was too short to compare with, so there is no readout.'
              : 'Too little clean signal during the sound to compare with.',
        );
      } else {
        final mins = (sum.cleanS / 60).round();
        out.add(
          'Against your quiet minute: ${change('alpha', sum.alpha)}, ${change('slow waves', sum.slow)} (back of the '
          'head, ${mins < 1 ? 'under a minute' : '$mins min'} of clean signal).',
        );
        out.add(p.preset.expect);
        if (p.beat != Beat.none) {
          out.add('${echoLine(sum.echo)} The beat\'s rate and twice it were left out of alpha and slow waves.');
        }
      }
  }
  if (p.state == SoundState.asleep && s.headband == HeadbandUse.used) {
    final at = s.drift['asleepAtS'];
    out.add(
      at is int
          ? 'Probably asleep ${(at / 60).round()} min after lights off; the sound faded out from then.'
          : 'The detector did not see you fall asleep.',
    );
  }
  final played = s.soundStartS == null ? null : (s.endS - s.soundStartS!) / 60;
  if (s.end == SoundEnd.stopped) {
    out.add(played == null ? 'Stopped before the sound began.' : 'You stopped it after ${played.round()} min of sound.');
  } else if (s.end == SoundEnd.cap) {
    out.add('Silent 45 minutes after lights off.');
  }
  if (s.night == 'started') {
    out.add('The night recording started.');
  } else if (s.night != null) {
    out.add('The night recording ${s.night}.');
  }
  if (s.stalls > 0) out.add('The sound ran dry ${s.stalls == 1 ? 'once' : '${s.stalls} times'} while the phone was busy.');
  return out;
}

class StatesView extends StatelessWidget {
  const StatesView({
    super.key,
    required this.model,
    required this.onState,
    required this.onBed,
    required this.onBeat,
    required this.onMinutes,
    required this.onHeadband,
    required this.onThenNight,
    this.onScreen,
    required this.onListen,
    required this.onStart,
    required this.onStop,
    required this.onSkip,
    required this.onRate,
    required this.onInfo,
    this.onPlanTest,
    this.onStopTest,
  });

  final StatesViewModel model;
  final ValueChanged<SoundState> onState;
  final ValueChanged<Bed> onBed;
  final ValueChanged<Beat> onBeat;
  final ValueChanged<int> onMinutes;
  final ValueChanged<bool> onHeadband;
  final ValueChanged<bool> onThenNight;

  /// "Screen": true = stays on.
  final ValueChanged<bool>? onScreen;
  final VoidCallback onListen;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onSkip;
  final ValueChanged<int> onRate;
  final VoidCallback onInfo;

  /// The fair test: open its setup; stop the one under way.
  final VoidCallback? onPlanTest;
  final VoidCallback? onStopTest;

  @override
  Widget build(BuildContext context) => model.face ? _face(context) : _page(context);

  // ---- between sessions ----

  Widget _page(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme, last = m.last;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final quiet = m.useHeadband && !m.nightRunning ? 60.0 : 0.0;
    return Scaffold(
      appBar: AppBar(
        title: Text('Sound', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'What the research says', color: Night.inkMuted),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _status(context),
          for (final n in m.notes)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(n, style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4)),
            ),
          if (last != null && m.justEnded) ...[
            ..._result(context, last, heading: 'This session'),
            const SectionHeading('Next session'),
          ] else
            const SizedBox(height: 28),
          SoundScore(ScoreModel(plan: m.plan, quietS: quiet)),
          const SectionHeading('State'),
          _chips<SoundState>(context, [for (final p in presets.values) (p.state, p.name)], m.plan.state, onState),
          const SizedBox(height: 12),
          Text(m.preset.why, style: muted),
          const SectionHeading('Sound'),
          if (m.soundLocked && m.test != null) ...[
            Text(
              'Drawn for day ${m.test!.todayIndex + 1} of your fair test. The sound and the length stay as they are today.',
              style: text.bodyLarge?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 14),
          ],
          soundChips<Bed>(context, [for (final b in Bed.values) (b, bedNames[b]!)], m.plan.bed, onBed,
              disabled: {if (m.plan.beat == Beat.none) Bed.none}, locked: m.soundLocked),
          const SizedBox(height: 18),
          Text('Beat', style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
          const SizedBox(height: 8),
          soundChips<Beat>(context, [for (final b in Beat.values) (b, beatNames[b]!)], m.plan.beat, onBeat,
              disabled: {if (m.plan.bed == Bed.none) Beat.none}, locked: m.soundLocked),
          const SizedBox(height: 12),
          Text(beatWhy[m.plan.beat]!, style: muted),
          _routeNote(m),
          const SizedBox(height: 8),
          ClipRow(
            title: 'Listen',
            meta: m.listening ? 'Playing: set the phone\'s volume low' : 'A few seconds of this sound, to set the volume',
            metaColor: m.listening ? Night.live : Night.inkMuted,
            playing: m.listening,
            rule: false,
            onPlay: onListen,
          ),
          const SectionHeading('Length'),
          soundSegments<int>(context, [for (final v in m.preset.minutes) (v, '$v min')], m.plan.minutes, onMinutes, locked: m.soundLocked),
          const SectionHeading('Headband'),
          if (m.nightRunning)
            Text('The headband is recording the night, so the sound plays by its timer alone.', style: muted)
          else ...[
            _segments<bool>(context, const [(true, 'Measure'), (false, 'Sound only')], m.useHeadband, onHeadband),
            const SizedBox(height: 12),
            Text(
              m.useHeadband
                  ? 'A silent quiet minute first, then the sound and what your brain does against that minute.'
                  : 'No headband: the sound plays by its timer, nothing is measured.',
              style: muted,
            ),
            if (m.useHeadband && m.plan.state == SoundState.asleep) ...[
              const SizedBox(height: 18),
              Text('When the sound has stopped', style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
              const SizedBox(height: 8),
              _segments<bool>(context, const [(true, 'Record the night'), (false, 'Let the headband go')], m.thenNight, onThenNight),
            ],
          ],
          const SectionHeading('Screen'),
          _segments<bool>(context, const [(false, 'Can lock'), (true, 'Stays on')], m.screenStaysOn, onScreen ?? (_) {}),
          const SizedBox(height: 12),
          Text(
            m.screenStaysOn
                ? 'The screen stays on and black during the session (dim with eyes closed).'
                : 'Lock the phone or let the screen turn off: the sound goes on. Stop is also on the lock screen.',
            style: muted,
          ),
          const SectionHeading('Before you start'),
          const _Note(Icons.volume_down_outlined, 'Keep the volume low: set it with Listen. Never while driving.'),
          const _Note(
            Icons.bedtime_outlined,
            'For a whole night, earbuds are the harder choice: the phone\'s speaker beside you is kinder (binaural '
            'beats do not work there).',
          ),
          const _Note(
            Icons.dark_mode_outlined,
            'During the session the screen goes black (dim with eyes closed). Do not swipe the app away: that ends '
            'the session.',
          ),
          _Note(
            Icons.info_outline,
            'The hearing part of the brain follows a pulse; that it moves your whole state is not proven, and plain '
            'calm sound often does as well. The i button says what the studies show.',
            onTap: onInfo,
          ),
          if (last != null && !m.justEnded) ..._result(context, last, heading: 'Last session'),
          if (m.comparison != null) ...[
            SoundLedger(comparison: m.comparison!),
            FairTest(state: m.plan.state, test: m.test, results: m.testResults, onPlan: onPlanTest, onStop: onStopTest),
          ],
          if (m.earlier.isNotEmpty) ...[
            const SectionHeading('Earlier sessions'),
            for (final (i, s) in m.earlier.indexed) _earlierRow(context, s, last: i == m.earlier.length - 1),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: FilledButton.icon(
            onPressed: onStart,
            icon: Icon(m.stage == SoundStage.failed ? Icons.refresh : Icons.play_arrow_rounded),
            label: Text(m.stage == SoundStage.failed ? 'Try again' : 'Start'),
          ),
        ),
      ),
    );
  }

  /// Where the sound goes now; amber only for a binaural beat on the phone's speaker (DECISIONS 470).
  Widget _routeNote(StatesViewModel m) {
    final r = stateRouteNote(m.route, binaural: m.plan.beat == Beat.binaural);
    return _Note(r.warn ? Icons.headphones_outlined : Icons.volume_up_outlined, r.text, color: r.warn ? Night.caution : null);
  }

  Widget _status(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final (String word, String sentence, MarkShape mark, Color color) = switch (m.stage) {
      SoundStage.failed => ('Could not start', m.message, MarkShape.dash, Night.problem),
      _ when m.justEnded => ('Session over', '${m.last?.plan.preset.name ?? ''}: ${m.last?.plan.line ?? ''}.', MarkShape.ring, Night.inkMuted),
      _ when m.nightRunning => (
        'Night recording',
        'The headband is busy with the night. The sound can still play by its timer.',
        MarkShape.ringedDot,
        Night.caution,
      ),
      _ => ('Ready', 'Pick a state and a sound. A beat is an optional extra.', MarkShape.ring, Night.inkMuted),
    };
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StateMark(shape: mark, color: color),
              const SizedBox(width: 14),
              Expanded(child: Text(word, style: text.displaySmall)),
            ],
          ),
          if (sentence.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              sentence,
              style: text.bodyLarge?.copyWith(color: m.stage == SoundStage.failed ? Night.problem : Night.inkMuted, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _result(BuildContext context, SoundSession s, {required String heading}) {
    final text = Theme.of(context).textTheme;
    final quiet = s.soundStartS?.toDouble() ?? 0;
    return [
      SectionHeading(heading),
      SoundScore(ScoreModel(plan: s.plan, quietS: quiet, soundStartS: s.soundStartS?.toDouble(), endS: s.endS)),
      const SizedBox(height: 8),
      for (final line in resultLines(s))
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(line, style: text.bodyLarge?.copyWith(height: 1.4)),
        ),
      if (s.end != SoundEnd.running)
        ChoiceQuestion<int>(
          question: ratingQuestion(s.plan.state),
          choices: [for (var i = 1; i <= 5; i++) (i, '$i')],
          value: s.rating,
          onChanged: onRate,
          ends: ('Not at all', 'Clearly'),
        ),
    ];
  }

  Widget _chips<T extends Object>(BuildContext context, List<(T, String)> items, T value, ValueChanged<T> on, {Set<T> disabled = const {}}) =>
      soundChips<T>(context, items, value, on, disabled: disabled);

  Widget _segments<T extends Object>(BuildContext context, List<(T, String)> choices, T value, ValueChanged<T> on) =>
      soundSegments<T>(context, choices, value, on);

  Widget _earlierRow(BuildContext context, SoundSession s, {required bool last}) {
    final text = Theme.of(context).textTheme;
    final rated = s.rating == null ? 'not rated' : 'rated ${s.rating} of 5';
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: last ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${nightLabel(s.start)}, ${clock(s.start)} · ${s.plan.preset.name}', style: text.titleMedium),
          const SizedBox(height: 2),
          Text('${s.plan.line} · ${s.plan.minutes} min · $rated', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
        ],
      ),
    );
  }

  // ---- the session face ----

  Widget _face(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final eyes = m.preset.eyesClosed;
    final (String word, String sentence) = switch (m.stage) {
      SoundStage.connecting => ('Connecting', m.message),
      SoundStage.contact => ('Checking contact', 'Keep still for a few seconds.'),
      SoundStage.quiet => (
        'Quiet minute',
        eyes
            ? 'Close your eyes and settle as you will during the sound. It starts by itself.'
            : 'Sit as you will during the sound, eyes open. It starts by itself.',
      ),
      SoundStage.starting => ('Starting the sound', m.message),
      SoundStage.fading => (
        'Fading out',
        switch (m.stopWhy) {
          StopWhy.asleep => 'Probably asleep. The sound fades over 2.5 minutes.',
          StopWhy.cap => '45 minutes since lights off.',
          _ => 'Time is up.',
        },
      ),
      SoundStage.ending => ('Session over', m.message),
      _ => (m.plan.state == SoundState.asleep ? 'Drift off' : 'Sound on', m.message),
    };
    final small = text.bodyLarge?.copyWith(color: faceMuted, height: 1.4);
    final sounding = m.stage == SoundStage.playing || m.stage == SoundStage.fading;
    final rate = m.rateNow;
    return Scaffold(
      backgroundColor: faceGround,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${m.preset.name} · ${m.plan.line}', style: text.bodyMedium?.copyWith(color: faceMuted)),
              const Spacer(flex: 3),
              Semantics(liveRegion: true, child: Text(word, style: text.headlineMedium?.copyWith(color: faceInk))),
              if (sentence.isNotEmpty) ...[const SizedBox(height: 10), Text(sentence, style: small)],
              if (m.stage == SoundStage.quiet) ...[
                const SizedBox(height: 16),
                Text(
                  '${m.quietS} of ${m.quietTarget} clean seconds',
                  style: text.bodyMedium?.copyWith(color: faceMuted, fontFeatures: tabular),
                ),
                const Opacity(opacity: 0.72, child: SharedDeviceCard(top: 24)),
              ],
              if (sounding) ...[
                const SizedBox(height: 16),
                Text(
                  [
                    if (m.secondsLeft != null) '${_mmss(m.secondsLeft!)} left',
                    rate == null ? 'no beat' : 'beat ${_hz(rate)}',
                  ].join(' · '),
                  style: text.titleMedium?.copyWith(color: faceInk, fontFeatures: tabular),
                ),
                if (m.measuring) ...[const SizedBox(height: 10), Text(_brainLine(), style: small)],
              ],
              if (m.noData && m.measuring) ...[
                const SizedBox(height: 10),
                Text(
                  'No signal from the headband. The sound goes on by its timer.',
                  style: text.bodyLarge?.copyWith(color: Night.caution.withValues(alpha: 0.72), height: 1.4),
                ),
              ],
              const Spacer(flex: 4),
              if (m.screenNote.isNotEmpty) ...[Text(m.screenNote, style: small), const SizedBox(height: 16)],
              if (m.stage == SoundStage.quiet) ...[
                Center(
                  child: TextButton(
                    onPressed: onSkip,
                    style: TextButton.styleFrom(foregroundColor: faceMuted),
                    child: const Text('Start the sound now'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                onPressed: m.stage == SoundStage.ending ? null : onStop,
                style: OutlinedButton.styleFrom(foregroundColor: faceMuted, side: const BorderSide(color: Night.rule)),
                icon: const Icon(Icons.stop_rounded),
                label: Text(m.stage == SoundStage.ending ? 'Saving…' : 'Stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The brain during the sound: the drift-off detector for fall asleep, else the last 30 s against the quiet minute.
  String _brainLine() {
    final m = model;
    final parts = <String>[];
    if (m.plan.state == SoundState.asleep) {
      parts.add(switch (m.driftState) {
        DriftState.asleep => 'Detector: probably asleep.',
        DriftState.drowsy => 'Detector: drowsy.',
        DriftState.awake => 'Detector: awake.',
        _ => 'Detector: still learning your eyes-closed level.',
      });
    }
    final live = m.live;
    if (!m.hasBaseline) {
      parts.add('No quiet minute to compare with.');
    } else if (live == null) {
      parts.add('Waiting for clean signal.');
    } else {
      parts.add('Last 30 s against your quiet minute: ${change('alpha', live.alpha)}, ${change('slow waves', live.slow)}.');
      if (m.plan.beat != Beat.none && live.echo != null && live.echo!.isFinite) {
        parts.add('Echo at the beat: ${live.echo!.toStringAsFixed(1)} times (expected, left out of both).');
      }
    }
    return parts.join(' ');
  }
}

/// The page's chips (state, bed, beat). [locked]: drawn for a fair test's day, so none can be picked; the chosen
/// one keeps its look.
Widget soundChips<T extends Object>(
  BuildContext context,
  List<(T, String)> items,
  T value,
  ValueChanged<T> on, {
  Set<T> disabled = const {},
  bool locked = false,
}) {
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (v, label) in items)
        ChoiceChip(
          label: Text(label),
          selected: v == value,
          showCheckmark: false,
          onSelected: locked || disabled.contains(v) ? null : (_) => on(v),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          selectedColor: Night.surfaceHigh,
          disabledColor: locked && v == value ? Night.surfaceHigh : null,
          backgroundColor: Night.ground,
          side: BorderSide(color: v == value ? Night.inkMuted : Night.rule),
          labelStyle: locked && v == value
              ? WidgetStateTextStyle.resolveWith((_) => Theme.of(context).textTheme.bodyLarge!.copyWith(color: Night.ink))
              : Theme.of(context).textTheme.bodyLarge?.copyWith(color: v == value ? Night.ink : Night.inkMuted),
        ),
    ],
  );
}

/// The page's segmented rows (length, headband, screen). [locked]: as for [soundChips].
Widget soundSegments<T extends Object>(BuildContext context, List<(T, String)> choices, T value, ValueChanged<T> on, {bool locked = false}) =>
    SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        segments: [for (final (v, l) in choices) ButtonSegment(value: v, label: Text(l))],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: locked ? null : (s) => on(s.first),
        style: _segmentStyle(locked),
      ),
    );

ButtonStyle _segmentStyle(bool locked) {
  final base = SegmentedButton.styleFrom(
    minimumSize: const Size.fromHeight(52),
    selectedBackgroundColor: Night.surfaceHigh,
    selectedForegroundColor: Night.ink,
    foregroundColor: Night.inkMuted,
    side: const BorderSide(color: Night.rule),
  );
  if (!locked) return base;
  // drawn, not chosen: the drawn segment keeps its look, the others fade like any disabled control
  bool on(Set<WidgetState> s) => s.contains(WidgetState.selected);
  return base.copyWith(
    backgroundColor: WidgetStateProperty.resolveWith((s) => on(s) ? Night.surfaceHigh : Colors.transparent),
    foregroundColor: WidgetStateProperty.resolveWith((s) => on(s) ? Night.ink : Night.inkMuted.withValues(alpha: 0.45)),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {this.onTap, this.color});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  /// Amber for a warning (null: the muted ink).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(color: color ?? Night.inkMuted, height: 1.4);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: color ?? Night.inkMuted),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

