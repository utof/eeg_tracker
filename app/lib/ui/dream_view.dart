// The dream catcher's layout from a plain view model, so every state renders in tests without a phone.
// Structure (.impeccable/surfaces/app-lib-ui-dream-screen-dart.md): between sessions one scrolling column (status,
// the last session's answers, your prompts, tonight's choices, notes, earlier sessions) with Lights off pinned;
// during a session the whole screen is a near-black face with one dim word and the round marks, and after each
// answer it splits into two halves: Drifting and Awake. Prompts and answers share one clip row.
import 'package:flutter/material.dart';

import '../dream/controller.dart' show DreamStage;
import '../dream/store.dart';
import '../dream/voice.dart' show AnswerEnd;
import '../dream/rounds.dart' show DreamCause, DreamRule;
import '../recorder/nights.dart' show nightLabel;
import 'dream_text_view.dart';
import 'meditation_view.dart' show MarkShape, StateMark;
import 'parts.dart';
import 'device_status.dart';
import 'theme.dart';

/// The session face: true black (the phone's OLED pixels off) and ink at reduced strength.
const Color faceGround = Color(0xFF000000);
final Color faceInk = Night.ink.withValues(alpha: 0.72);
final Color faceMuted = Night.inkMuted.withValues(alpha: 0.72);

/// One of your prompts: its length when recorded (null: the tone plays).
class PromptInfo {
  const PromptInfo({this.seconds});
  final double? seconds;
}

class DreamViewModel {
  const DreamViewModel({
    required this.stage,
    this.message = '',
    this.rounds = 4,
    this.ending = DreamEnding.wake,
    this.roundsDone = 0,
    this.roundNow,
    this.minutes = 0,
    this.noData = false,
    this.contact = const {},
    this.notes = const [],
    this.nightRunning = false,
    this.theme = const PromptInfo(),
    this.question = const PromptInfo(),
    this.recording,
    this.recordingS = 0,
    this.playing,
    this.latest,
    this.justEnded = false,
    this.earlier = const [],
    this.words = const {},
    this.speech,
    this.keepUnlocked = false,
  });

  final DreamStage stage;
  final String message;

  /// Rounds chosen (and planned in the session running now) and how it ends.
  final int rounds;
  final DreamEnding ending;
  final int roundsDone;
  final int? roundNow;

  /// Minutes since lights off.
  final int minutes;
  final bool noData;
  final Map<String, double?> contact;

  /// Plain sentences in amber (the EEG or a session could not be saved, the microphone did not record).
  final List<String> notes;

  /// A night is being recorded: the headband is taken.
  final bool nightRunning;

  /// The sleep ending must start the night recording, which Android allows from a locked phone only to an app
  /// that may run in the background (DECISIONS rows 194 and 467): the face asks you not to lock the phone.
  final bool keepUnlocked;
  final PromptInfo theme;
  final PromptInfo question;

  /// The prompt being recorded now, and its seconds so far.
  final PromptKind? recording;
  final int recordingS;

  /// The clip playing now: `prompt:theme`, `prompt:question` or an answer's file name.
  final String? playing;

  /// The newest session (its answers come first), and whether it has just ended.
  final DreamSession? latest;
  final bool justEnded;
  final List<DreamSession> earlier;

  /// Each answer's words by its file name (DECISIONS row 254), and the speech model (null: no section).
  final Map<String, AnswerWords> words;
  final SpeechInfo? speech;

  /// The session face is up (connecting to the end).
  bool get face => stage.index >= DreamStage.connecting.index && stage.index <= DreamStage.ending.index;

  PromptInfo prompt(PromptKind k) => k == PromptKind.theme ? theme : question;
}

String _two(int v) => v.toString().padLeft(2, '0');
String clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
String _secs(double s) => s < 60 ? '${s.round()} s' : '${s ~/ 60} min ${_two((s % 60).round())} s';

/// The session's line: when, how many answers, how long, how it ended.
String sessionLine(DreamSession s) {
  final n = s.answers;
  final ended = switch (s.endWhy) {
    DreamEnd.rounds => 'all rounds',
    DreamEnd.cap => 'time up',
    DreamEnd.stopped => 'stopped',
    _ => 'did not finish',
  };
  return '${n == 1 ? '1 answer' : '$n answers'} · ${(s.endS / 60).round()} min · $ended';
}

class DreamView extends StatelessWidget {
  const DreamView({
    super.key,
    required this.model,
    required this.onRounds,
    required this.onEnding,
    required this.onLightsOff,
    required this.onStop,
    required this.onDrifting,
    required this.onRecord,
    required this.onPlayPrompt,
    required this.onPlayAnswer,
    required this.onNote,
    required this.onOpen,
    required this.onInfo,
    this.onWords,
    this.onUndoWords,
    this.onRetryWords,
    this.onSpeechDownload,
    this.onSpeechStop,
    this.onSpeechDelete,
  });

  final DreamViewModel model;
  final ValueChanged<int> onRounds;
  final ValueChanged<DreamEnding> onEnding;
  final VoidCallback onLightsOff;
  final VoidCallback onStop;
  final ValueChanged<bool> onDrifting;
  final ValueChanged<PromptKind> onRecord;
  final ValueChanged<PromptKind> onPlayPrompt;
  final void Function(DreamSession s, DreamRound r) onPlayAnswer;
  final void Function(DreamSession s, DreamRound r, String note) onNote;
  final ValueChanged<DreamSession> onOpen;
  final VoidCallback onInfo;

  /// Your words for an answer, Undo edit, Try again; the speech model's Download, Stop and Delete.
  final void Function(DreamSession s, DreamRound r, String text)? onWords;
  final void Function(DreamSession s, DreamRound r)? onUndoWords;
  final void Function(DreamSession s, DreamRound r)? onRetryWords;
  final VoidCallback? onSpeechDownload;
  final VoidCallback? onSpeechStop;
  final VoidCallback? onSpeechDelete;

  @override
  Widget build(BuildContext context) => model.face ? _face(context) : _page(context);

  // ---- between sessions ----

  Widget _page(BuildContext context) {
    final m = model, latest = m.latest;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Dream catcher', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(
            onPressed: onInfo,
            icon: const Icon(Icons.info_outline),
            tooltip: 'What the research says',
            color: Night.inkMuted,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _status(context),
          for (final n in m.notes)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(n, style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4)),
            ),
          if (latest != null) ...[
            SectionHeading(m.justEnded ? 'This session' : 'Last session'),
            DreamAnswers(
              session: latest,
              playing: m.playing,
              onPlay: onPlayAnswer,
              onNote: onNote,
              words: m.words,
              onWords: onWords,
              onUndoWords: onUndoWords,
              onRetryWords: onRetryWords,
            ),
          ],
          const SectionHeading('Your prompts'),
          for (final k in PromptKind.values) _promptRow(k, last: k == PromptKind.values.last),
          if (m.speech case final speech?) ...[
            const SectionHeading('Answers as text'),
            SpeechSection(
              info: speech,
              onDownload: onSpeechDownload ?? () {},
              onStop: onSpeechStop ?? () {},
              onDelete: onSpeechDelete ?? () {},
            ),
          ],
          const SectionHeading('Tonight'),
          _choice<int>(
            context,
            'Rounds',
            [for (final r in DreamRule.rounds) (r, '$r rounds')],
            m.rounds,
            onRounds,
          ),
          _choice<DreamEnding>(
            context,
            'At the end',
            const [(DreamEnding.wake, 'Wake me'), (DreamEnding.sleep, 'Record the night')],
            m.ending,
            onEnding,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              m.ending == DreamEnding.wake
                  ? 'A soft rising tone after the last round, or ${DreamRule.capS ~/ 60} minutes after lights off.'
                  : 'No tone. After the last round, or ${DreamRule.capS ~/ 60} minutes after lights off, the night '
                        'recording starts by itself; the answers wait for the morning.',
              style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
            ),
          ),
          const SectionHeading('Before you start'),
          const _Note(
            Icons.volume_down_outlined,
            'The prompts play quietly from the phone\'s speaker. Play one and set the phone\'s volume so you can '
            'just hear it lying down.',
          ),
          const _Note(
            Icons.dark_mode_outlined,
            'The screen goes black and dim. You can lock the phone: the session goes on. Do not swipe the app away.',
          ),
          const _Note(
            Icons.mic_none_outlined,
            'Your answers are recorded with the phone\'s microphone and stay on this phone.',
          ),
          _Note(
            Icons.info_outline,
            'A creativity exercise, not a sleep aid. The studies are small; the i button says what they show.',
            onTap: onInfo,
          ),
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
            onPressed: m.nightRunning || m.recording != null ? null : onLightsOff,
            icon: Icon(m.stage == DreamStage.failed ? Icons.refresh : Icons.bedtime_outlined),
            label: Text(m.stage == DreamStage.failed ? 'Try again' : 'Lights off'),
          ),
        ),
      ),
    );
  }

  Widget _status(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme, latest = m.latest;
    final (String word, String sentence, MarkShape mark, Color color) = switch (m.stage) {
      _ when m.nightRunning => (
        'Night recording',
        'The headband is busy recording the night. The dream catcher can start after Stop.',
        MarkShape.ringedDot,
        Night.caution,
      ),
      DreamStage.failed => ('Could not start', m.message, MarkShape.dash, Night.problem),
      _ when m.justEnded && latest != null => (
        'Session over',
        [
          latest.answers == 0
              ? 'No answer was recorded.'
              : '${latest.answers == 1 ? '1 answer' : '${latest.answers} answers'} saved. Play them and add a '
                    'note while you remember.',
          if (latest.night == 'started') 'The night is recording now.',
          if (latest.night != null && latest.night != 'started') 'The night recording ${latest.night}.',
        ].join(' '),
        MarkShape.ring,
        Night.inkMuted,
      ),
      _ => (
        'Ready',
        'Headband on, lie down, tap Lights off. As you drift off the app asks what is on your mind and records '
            'your answer, ${m.rounds} times.',
        MarkShape.ring,
        Night.inkMuted,
      ),
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
              style: text.bodyLarge?.copyWith(
                color: m.stage == DreamStage.failed ? Night.problem : Night.inkMuted,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _promptRow(PromptKind k, {required bool last}) {
    final m = model, info = m.prompt(k), rec = m.recording == k, secs = info.seconds;
    final theme = k == PromptKind.theme;
    return ClipRow(
      title: theme ? 'Theme' : 'Question',
      meta: rec
          ? 'Recording · ${m.recordingS} s'
          : secs != null
          ? 'Your voice · ${_secs(secs)}'
          : 'Not recorded: ${theme ? 'a low tone' : 'two rising notes'} instead',
      metaColor: rec ? Night.live : Night.inkMuted,
      detail: theme
          ? 'Plays as you drift off, at lights off and after each answer. For example: "Think of a tree… and drift off."'
          : 'Plays at each round. For example: "What is going through your mind?"',
      playing: m.playing == 'prompt:${k.name}',
      recordingNow: rec,
      rule: !last,
      onPlay: secs == null || m.recording != null ? null : () => onPlayPrompt(k),
      action: TextButton(
        onPressed: m.recording != null && !rec ? null : () => onRecord(k),
        style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
        child: Text(
          rec
              ? 'Stop'
              : secs == null
              ? 'Record'
              : 'Record again',
        ),
      ),
    );
  }

  Widget _choice<T extends Object>(
    BuildContext context,
    String label,
    List<(T, String)> choices,
    T value,
    ValueChanged<T> on,
  ) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              segments: [for (final (v, l) in choices) ButtonSegment(value: v, label: Text(l))],
              selected: {value},
              showSelectedIcon: false,
              onSelectionChanged: (s) => on(s.first),
              style: SegmentedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                selectedBackgroundColor: Night.surfaceHigh,
                selectedForegroundColor: Night.ink,
                foregroundColor: Night.inkMuted,
                side: const BorderSide(color: Night.rule),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _earlierRow(BuildContext context, DreamSession s, {required bool last}) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => onOpen(s),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: last ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${nightLabel(s.start)}, ${clock(s.start)}', style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(sessionLine(s), style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Night.inkMuted),
          ],
        ),
      ),
    );
  }

  // ---- the session face ----

  Widget _face(BuildContext context) {
    final m = model;
    return Scaffold(
      backgroundColor: faceGround,
      body: SafeArea(
        child: m.stage == DreamStage.checking ? _halves(context) : _faceWords(context),
      ),
    );
  }

  Widget _faceWords(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final (String word, String sentence) = switch (m.stage) {
      DreamStage.connecting => ('Connecting', m.message),
      DreamStage.contact => ('Checking contact', 'Lie still for a few seconds.'),
      DreamStage.baseline => (
        'Eyes closed',
        'The first minute sets your starting level. Think of your theme and let go.',
      ),
      DreamStage.asking => ('Listen', 'The question is playing.'),
      DreamStage.answering => (
        'Speak',
        'Say what was going through your mind. It stops after a few seconds of quiet.',
      ),
      DreamStage.ending => ('Session over', m.message),
      _ => (
        'Drift off',
        m.roundsDone == 0
            ? 'The first question comes as you drift off, at a moment you will not know.'
            : 'The next question waits until you drift off again.',
      ),
    };
    final started = m.stage.index >= DreamStage.baseline.index;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 3),
          if (started) ...[_RoundMarks(rounds: m.rounds, done: m.roundsDone, now: m.roundNow), const SizedBox(height: 24)],
          Semantics(
            liveRegion: true,
            child: Text(word, style: text.headlineMedium?.copyWith(color: faceInk)),
          ),
          const SizedBox(height: 10),
          Text(sentence, style: text.bodyLarge?.copyWith(color: faceMuted, height: 1.4)),
          if (m.keepUnlocked && started) ...[
            const SizedBox(height: 10),
            Text(
              'Do not lock the phone: the night recording must start afterwards. To lock it next time, allow the app '
              'to run in the background (main screen, under Phone).',
              style: text.bodyLarge?.copyWith(color: faceMuted, height: 1.4),
            ),
          ],
          if (m.noData && started) ...[
            const SizedBox(height: 10),
            Text(
              'No signal from the headband. The questions still come by the timer.',
              style: text.bodyLarge?.copyWith(color: Night.caution.withValues(alpha: 0.72), height: 1.4),
            ),
          ],
          if (started) ...[
            const SizedBox(height: 16),
            Text(
              m.minutes == 1 ? '1 min since lights off' : '${m.minutes} min since lights off',
              style: text.bodyMedium?.copyWith(color: faceMuted, fontFeatures: tabular),
            ),
          ],
          if (m.stage == DreamStage.baseline) const Opacity(opacity: 0.72, child: SharedDeviceCard(top: 28)),
          const Spacer(flex: 4),
          OutlinedButton.icon(
            onPressed: m.stage == DreamStage.ending ? null : onStop,
            style: OutlinedButton.styleFrom(foregroundColor: faceMuted, side: const BorderSide(color: Night.rule)),
            icon: const Icon(Icons.stop_rounded),
            label: Text(m.stage == DreamStage.ending ? 'Saving…' : 'Stop'),
          ),
        ],
      ),
    );
  }

  /// "Were you drifting?": the screen in two halves, so a tap anywhere near the top or the bottom answers.
  Widget _halves(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget half(String word, String hint, bool value) => Expanded(
      child: Semantics(
        button: true,
        label: '$word: $hint',
        excludeSemantics: true,
        child: InkWell(
          onTap: () => onDrifting(value),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: Night.rule),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(word, style: text.displaySmall?.copyWith(color: faceInk)),
                const SizedBox(height: 8),
                Text(hint, textAlign: TextAlign.center, style: text.bodyLarge?.copyWith(color: faceMuted)),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        children: [
          half('Drifting', 'half asleep, dreamlike', true),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'Were you drifting off?',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(color: faceMuted),
            ),
          ),
          half('Awake', 'clear, just thinking', false),
        ],
      ),
    );
  }
}

/// The rounds as state circles: filled = done, ringed dot = under way, ring = to come.
class _RoundMarks extends StatelessWidget {
  const _RoundMarks({required this.rounds, required this.done, required this.now});
  final int rounds;
  final int done;
  final int? now;

  @override
  Widget build(BuildContext context) => Semantics(
    label: now != null ? 'Round $now of $rounds' : '$done of $rounds rounds done',
    excludeSemantics: true,
    child: Row(
      children: [
        for (var i = 1; i <= rounds; i++) ...[
          StateMark(
            shape: i <= done
                ? MarkShape.filled
                : i == now
                ? MarkShape.ringedDot
                : MarkShape.ring,
            color: faceMuted,
            size: 16,
          ),
          const SizedBox(width: 14),
        ],
      ],
    ),
  );
}

/// A session's answers: one clip row per round, with the note under it.
class DreamAnswers extends StatelessWidget {
  const DreamAnswers({
    super.key,
    required this.session,
    required this.playing,
    required this.onPlay,
    required this.onNote,
    this.words = const {},
    this.onWords,
    this.onUndoWords,
    this.onRetryWords,
  });
  final DreamSession session;
  final String? playing;
  final void Function(DreamSession s, DreamRound r) onPlay;
  final void Function(DreamSession s, DreamRound r, String note) onNote;

  /// Each answer's words by its file name (none: no words block).
  final Map<String, AnswerWords> words;
  final void Function(DreamSession s, DreamRound r, String text)? onWords;
  final void Function(DreamSession s, DreamRound r)? onUndoWords;
  final void Function(DreamSession s, DreamRound r)? onRetryWords;

  @override
  Widget build(BuildContext context) {
    final s = session, text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${nightLabel(s.start)}, lights off ${clock(s.start)} · ${sessionLine(s)}',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted),
        ),
        if (s.rounds.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              'No round came before the session ended.',
              style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
            ),
          ),
        for (final (i, r) in s.rounds.indexed)
          ClipRow(
            key: ValueKey('${s.stem}-${r.n}'),
            title: 'Round ${r.n} · ${clock(r.at)}',
            length: r.answerFile == null ? null : _secs(r.answerS),
            meta: '${(r.atS / 60).round()} min after lights off · ${r.cause == DreamCause.drowsy ? 'alpha faded' : 'timer'}',
            detail: [
              'Drifting: ${r.drifting == null ? 'not answered' : r.drifting! ? 'yes' : 'no'}.',
              ?switch (r.end) {
                AnswerEnd.noVoice => 'No voice heard; kept in case of a whisper.',
                AnswerEnd.failed => 'Nothing recorded: the microphone did not start.',
                AnswerEnd.stopped => 'Stopped while you spoke.',
                AnswerEnd.cap => 'Cut at 30 s.',
                AnswerEnd.silence => null,
              },
            ].join('\n'),
            playing: playing == r.answerFile && r.answerFile != null,
            onPlay: r.answerFile == null ? null : () => onPlay(s, r),
            words: switch (words[r.answerFile]) {
              final w? when w.state != WordsState.none => WordsBlock(
                words: w,
                onChanged: (v) => onWords?.call(s, r, v),
                onUndo: () => onUndoWords?.call(s, r),
                onRetry: () => onRetryWords?.call(s, r),
              ),
              _ => null,
            },
            note: _NoteField(note: r.note, onChanged: (v) => onNote(s, r, v)),
            rule: i < s.rounds.length - 1,
          ),
      ],
    );
  }
}

/// One recording: a ringed play control, its title and length, a muted line, an optional action and note.
class ClipRow extends StatelessWidget {
  const ClipRow({
    super.key,
    required this.title,
    required this.meta,
    required this.onPlay,
    this.metaColor = Night.inkMuted,
    this.length,
    this.detail,
    this.playing = false,
    this.recordingNow = false,
    this.action,
    this.words,
    this.note,
    this.rule = true,
  });

  final String title;
  final String meta;
  final Color metaColor;

  /// Shown right of the title (tabular), e.g. "14 s".
  final String? length;
  final String? detail;
  final bool playing;
  final bool recordingNow;

  /// Null: nothing to play (the control is shown disabled).
  final VoidCallback? onPlay;
  final Widget? action;

  /// An answer's words (dream_text_view.dart), above its note.
  final Widget? words;
  final Widget? note;

  /// A hairline under the row; off for the last row of a section.
  final bool rule;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ring = recordingNow || playing ? Night.live : (onPlay == null ? Night.rule : Night.inkMuted);
    final control = SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        onPressed: recordingNow ? null : onPlay,
        tooltip: playing ? 'Stop playing $title' : 'Play $title',
        style: IconButton.styleFrom(
          shape: CircleBorder(side: BorderSide(color: ring, width: 1.5)),
          disabledForegroundColor: recordingNow ? Night.live : Night.rule,
          foregroundColor: playing ? Night.live : Night.ink,
        ),
        icon: Icon(
          recordingNow
              ? Icons.mic
              : playing
              ? Icons.stop_rounded
              : Icons.play_arrow_rounded,
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: rule ? const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          control,
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(child: Text(title, style: text.titleMedium)),
                    if (length != null)
                      Text(length!, style: text.titleMedium?.copyWith(fontFeatures: tabular, color: Night.ink)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(meta, style: text.bodyMedium?.copyWith(color: metaColor, fontFeatures: tabular)),
                if (detail != null) ...[
                  const SizedBox(height: 6),
                  Text(detail!, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
                ],
                ?words,
                ?note,
                if (action != null) Padding(padding: const EdgeInsets.only(top: 4), child: action),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The note under an answer, saved as you type.
class _NoteField extends StatefulWidget {
  const _NoteField({required this.note, required this.onChanged});
  final String note;
  final ValueChanged<String> onChanged;

  @override
  State<_NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<_NoteField> {
  late final TextEditingController _c = TextEditingController(text: widget.note);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: TextField(
      controller: _c,
      onChanged: widget.onChanged,
      minLines: 1,
      maxLines: 5,
      textCapitalization: TextCapitalization.sentences,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: const InputDecoration(
        hintText: 'Your note: what was it about?',
        hintStyle: TextStyle(color: Night.inkMuted),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 10),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Night.rule)),
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Night.inkMuted)),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 22, color: Night.inkMuted)),
          const SizedBox(width: 16),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: row);
  }
}

