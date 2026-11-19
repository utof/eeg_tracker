// The study reminders page and its one-tap question (ROADMAP "Evening study, morning review", the assistant's
// proposal; DECISIONS rows 400-401; DESIGN.md "Study reminders"). Built from a StudyPageModel only, so tests render
// it without a phone: the proposal and its switch first, the two times, what is logged today, the last 14 days,
// whether the reminders arrive, your data.
import 'package:flutter/material.dart';

import '../sharp/schedule.dart' show PromptKind, clockText;
import '../study/page.dart';
import '../study/schedule.dart';
import 'form_parts.dart' show Para, PinnedAction;
import 'parts.dart';
import 'sharp_hours_view.dart' show LogRow, WarningLine;
import 'theme.dart';

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

const String studyIntro =
    'The assistant\'s idea, not one you asked for: a nudge to learn something in the evening, a '
    'couple of hours before bed, and to try recalling it in the morning, before you look. Off unless you switch it on; '
    'you can delete it all at the bottom.';

const String studyHow =
    'Never in the quiet hours, during a night recording or during a session. Say "no" to studying '
    'and the next morning\'s reminder is skipped. Neither is a reason to study: only a nudge.';

/// The muted line under a time: where it comes from.
String timeNote(StudyPageModel m, {required bool evening}) {
  final auto = evening ? m.times.eveningAuto : m.times.morningAuto;
  if (!auto) return 'Set by you.';
  if (!m.fromSleep) {
    return 'Until 3 nights are recorded: ${clockText(evening ? m.suggested.evening : m.suggested.morning)}, then it follows your sleep.';
  }
  final base = evening
      ? 'From your sleep: about 1½ hours before your usual bedtime.'
      : 'From your sleep: 45 minutes after you usually wake.';
  final moved = evening ? m.eveningMoved : m.morningMoved;
  return moved
      ? '$base Moved to keep inside your waking hours, ${clockText(m.window.$1)} to ${clockText(m.window.$2)}.'
      : base;
}

/// What an answer says.
String answerWords(StudyAnswer a) => a.isEvening
    ? (a.studied! ? 'Studied tonight: yes' : 'Studied tonight: no')
    : 'Recalled: ${a.recall!.label.toLowerCase()}';

/// The last 14 days in one or two sentences.
String historyWords(StudyPageModel m) {
  if (m.evenings == 0 && m.recallCount == 0) return 'Nothing logged yet.';
  final parts = <String>[];
  if (m.evenings > 0) {
    parts.add('Studied on ${m.studied} of ${m.evenings} ${m.evenings == 1 ? 'evening' : 'evenings'} you answered.');
  }
  if (m.recallCount > 0) {
    final r = m.recalls;
    parts.add('Recall the next morning: well ${r[Recall.well]}, some ${r[Recall.some]}, a little ${r[Recall.little]}.');
  }
  return parts.join(' ');
}

/// Whether the reminders reach you, in one sentence; null when nothing has arrived and there is nothing to say.
String? studyReachWords(StudyPageModel m) {
  final r = m.reach;
  if (!m.on || r.arrived == 0) return null;
  String were(int n) => n == 1 ? 'was' : 'were';
  final skipped = r.skipped > 0
      ? ' ${r.skipped} came during a recording or a session and ${were(r.skipped)} skipped.'
      : '';
  final late = r.late > 0 ? ' ${r.late} came over an hour late and ${were(r.late)} dropped.' : '';
  return 'Last 7 days: ${r.arrived} ${r.arrived == 1 ? 'reminder' : 'reminders'} arrived.$skipped$late';
}

class StudyView extends StatelessWidget {
  const StudyView({
    super.key,
    required this.model,
    this.onToggle,
    this.onEvening,
    this.onMorning,
    this.onAutoEvening,
    this.onAutoMorning,
    this.onLogEvening,
    this.onLogMorning,
    this.onInfo,
    this.onNotifications,
    this.onPhoneSettings,
    this.onDelete,
    this.error,
  });

  final StudyPageModel model;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onEvening,
      onMorning,
      onAutoEvening,
      onAutoMorning,
      onLogEvening,
      onLogMorning,
      onInfo,
      onNotifications,
      onDelete;

  /// Opens a phone setting by the name Phone.openSettings knows (`xiaomiAutostart`, `batteryOptimization`...).
  final ValueChanged<String>? onPhoneSettings;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final m = model;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    final note = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    final reach = studyReachWords(m);
    return Scaffold(
      appBar: AppBar(
        title: Text('Study reminders', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Text(studyIntro, style: muted),
          const SizedBox(height: 12),
          SwitchListTile(
            value: m.on,
            onChanged: onToggle,
            contentPadding: EdgeInsets.zero,
            title: Text('Evening study, morning review', style: text.titleLarge),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                studyStatus(m),
                style: text.bodyLarge?.copyWith(color: m.on ? Night.live : Night.inkMuted, height: 1.4),
              ),
            ),
          ),
          if (error != null) Para(error!, color: Night.problem),
          if (m.on && !m.notificationsOn)
            WarningLine(
              words: 'Notifications are off for this app, or for the study reminders, so they cannot appear.',
              actions: [TextButton(onPressed: onNotifications, child: const Text('Notification settings'))],
            ),
          const SizedBox(height: 8),
          LogRow(
            label: 'Evening',
            value: clockText(m.times.evening),
            action: TextButton(onPressed: onEvening, child: const Text('Change')),
          ),
          Text(timeNote(m, evening: true), style: note),
          if (!m.times.eveningAuto)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: onAutoEvening, child: const Text('Follow my sleep again')),
            ),
          const SizedBox(height: 8),
          LogRow(
            label: 'Morning',
            value: clockText(m.times.morning),
            action: TextButton(onPressed: onMorning, child: const Text('Change')),
          ),
          Text(timeNote(m, evening: false), style: note),
          if (!m.times.morningAuto)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: onAutoMorning, child: const Text('Follow my sleep again')),
            ),
          const SizedBox(height: 12),
          Text(studyHow, style: muted),
          if (reach != null) Para(reach, color: Night.inkMuted),
          const SectionHeading('Log it yourself'),
          Text('No reminder needed: one tap each.', style: muted),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onLogEvening,
                icon: const Icon(Icons.edit_note),
                label: const Text('Studied tonight?'),
              ),
              OutlinedButton.icon(
                onPressed: onLogMorning,
                icon: const Icon(Icons.psychology_alt_outlined),
                label: const Text('Recalled it?'),
              ),
            ],
          ),
          const SectionHeading('Today'),
          if (m.today.isEmpty)
            Text('Nothing logged today yet.', style: muted)
          else
            for (final (i, a) in m.today.indexed) ...[if (i > 0) const Divider(height: 17), _TodayRow(answer: a)],
          const SectionHeading('The last 14 days'),
          Text(historyWords(m), style: text.titleLarge?.copyWith(height: 1.3)),
          const SizedBox(height: 12),
          Text(
            'Seen together, not tested: the days you study in the evening may differ in other ways too. To test it on '
            'yourself, start the self-experiment "Study in the evening or the morning" (Trends, Experiments); it '
            'reads your recall as its number.',
            style: muted,
          ),
          const SectionHeading('Your data'),
          Text(
            'Kept in the app\'s private folder and copied out by Export data, with everything else. Nothing leaves the '
            'phone otherwise.',
            style: muted,
          ),
          if (m.on && m.xiaomi) ...[
            const SizedBox(height: 8),
            Text(
              'On a Xiaomi, reminders can come late or not at all unless EEG Tracker may start by itself and run without battery limits.',
              style: note,
            ),
            Wrap(
              spacing: 4,
              children: [
                TextButton(onPressed: () => onPhoneSettings?.call('xiaomiAutostart'), child: const Text('Autostart')),
                TextButton(onPressed: () => onPhoneSettings?.call('xiaomiBatterySaver'), child: const Text('Battery')),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete my study data'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One answer of today: the time and what it says.
class _TodayRow extends StatelessWidget {
  const _TodayRow({required this.answer});
  final StudyAnswer answer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(
          width: 64,
          child: Text(_clock(answer.at), style: text.titleMedium?.copyWith(fontFeatures: tabular)),
        ),
        Expanded(
          child: Text(
            '${answerWords(answer)}${answer.prompt == null ? ' (from the page)' : ''}',
            style: text.bodyLarge,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The one-tap question
// ---------------------------------------------------------------------------------------------------------------

enum StudyStage { ask, saved }

/// The muted line under the question.
String studyAskedWords(DateTime? asked) => asked == null
    ? 'Logged from the page, not a reminder. One tap saves.'
    : 'Asked at ${_clock(asked)}. One tap saves.';

class StudyLogView extends StatelessWidget {
  const StudyLogView({
    super.key,
    required this.kind,
    required this.stage,
    this.asked,
    this.saved,
    this.onStudied,
    this.onRecall,
    this.onNotYet,
    this.onDone,
    this.error,
  });

  /// [PromptKind.studyEvening] or [PromptKind.studyMorning].
  final PromptKind kind;
  final StudyStage stage;

  /// When the reminder appeared, if this was opened from one.
  final DateTime? asked;
  final StudyAnswer? saved;
  final ValueChanged<bool>? onStudied;
  final ValueChanged<Recall>? onRecall;
  final VoidCallback? onNotYet, onDone;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    final evening = kind == PromptKind.studyEvening;
    final s = saved;
    final body = switch (stage) {
      StudyStage.ask when evening => <Widget>[
        Text('Did you study something tonight?', style: text.headlineSmall?.copyWith(height: 1.25)),
        const SizedBox(height: 8),
        Text(studyAskedWords(asked), style: muted),
        const SizedBox(height: 20),
        _AnswerRow(label: 'Yes', onTap: onStudied == null ? null : () => onStudied!(true)),
        const SizedBox(height: 8),
        _AnswerRow(label: 'No', onTap: onStudied == null ? null : () => onStudied!(false)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: onNotYet, child: const Text('Not yet')),
        ),
      ],
      StudyStage.ask => <Widget>[
        Text('How much do you recall of what you studied?', style: text.headlineSmall?.copyWith(height: 1.25)),
        const SizedBox(height: 8),
        Text('Try first, before you look. ${studyAskedWords(asked)}', style: muted),
        const SizedBox(height: 20),
        for (final (i, r) in Recall.values.reversed.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          _AnswerRow(label: r.label, onTap: onRecall == null ? null : () => onRecall!(r)),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: onNotYet, child: const Text('Not yet')),
        ),
      ],
      StudyStage.saved => <Widget>[
        Text(
          s!.isEvening
              ? (s.studied! ? 'Saved: you studied tonight.' : 'Saved: not tonight.')
              : 'Saved: ${s.recall!.label.toLowerCase()}.',
          style: text.headlineSmall?.copyWith(height: 1.25),
        ),
        const SizedBox(height: 8),
        Text(
          s.isEvening
              ? (s.studied!
                    ? 'Sleep on it. Tomorrow morning, try to recall it before you look.'
                    : 'Nothing to recall tomorrow, so the morning reminder is skipped.')
              : 'At ${_clock(s.at)}. Now look at your notes and see what you missed. Thank you; that is all.',
          style: muted,
        ),
      ],
    };
    return Scaffold(
      appBar: AppBar(
        title: Text('Study reminders', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          ...body,
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(error!, style: text.bodyLarge?.copyWith(color: Night.problem)),
          ],
        ],
      ),
      bottomNavigationBar: stage == StudyStage.saved
          ? PinnedAction(
              child: FilledButton(onPressed: onDone, child: const Text('Done')),
            )
          : null,
    );
  }
}

/// One answer: a full-width 64 dp row.
class _AnswerRow extends StatelessWidget {
  const _AnswerRow({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Night.rule),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: const Size.fromHeight(64),
      ),
      child: Text(label, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w400)),
    );
  }
}
