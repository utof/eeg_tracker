// Training settings: the replay check's toggle (off by default; ROADMAP wish 12, DECISIONS rows 100-103) with
// what it does in plain words, and per session kind where the check stands: collecting live sessions, the
// frozen plan's date and fingerprint, sessions done, and the results once a whole set of 12 exists.
import 'package:flutter/material.dart';

import '../meditation/store.dart';
import '../recorder/nights.dart' show nightLabel;
import '../training/check.dart';
import '../training/check_store.dart';
import '../training/control.dart';
import 'evidence_sheet.dart';
import 'form_parts.dart';
import 'parts.dart';
import 'replay_results_screen.dart';
import 'theme.dart';

class TrainingSettingsScreen extends StatefulWidget {
  const TrainingSettingsScreen({super.key, required this.recordingsDir, this.clock});
  final String recordingsDir;
  final DateTime Function()? clock;

  @override
  State<TrainingSettingsScreen> createState() => _TrainingSettingsScreenState();
}

/// Where one kind's check stands, for the screen.
typedef CheckLine = ({SessionKind kind, String status, String? plan, String? fingerprint, bool canReveal, int done});

CheckLine checkLine(CheckStore cs, MeditationStore sessions) {
  final p = cs.plan, n = cs.records.length;
  String two(int v) => v.toString().padLeft(2, '0');
  return (
    kind: cs.kind,
    status: p == null
        ? previewStatus(cs, donorCandidates(sessions, sessions.list()))
        : '$n of ${CheckRule.plannedSessions}-${CheckRule.maxSessions} sessions done. '
              '${cs.reveal() != null ? 'Results ready for ${n ~/ CheckRule.revealEvery * CheckRule.revealEvery}; next set after ${cs.untilReveal} more.' : 'Results after ${cs.untilReveal} more.'}',
    plan: p == null
        ? null
        : 'Plan frozen ${nightLabel(p.plan.frozen)}, ${two(p.plan.frozen.hour)}:${two(p.plan.frozen.minute)}',
    fingerprint: p?.sha,
    canReveal: cs.reveal() != null,
    done: n,
  );
}

class _TrainingSettingsScreenState extends State<TrainingSettingsScreen> {
  late final _files = filesDirFor(widget.recordingsDir);
  late final _settings = SettingsStore(_files);
  late bool _on = _settings.load().replayCheck;
  String? _error;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  void _toggle(bool on) {
    try {
      _settings.save(TrainingSettings(replayCheck: on));
      for (final k in SessionKind.values) {
        final cs = CheckStore(_files, k);
        if (cs.dir.existsSync() || on) cs.event(_now(), on ? 'switched on' : 'switched off');
      }
      setState(() {
        _on = on;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'The setting could not be saved: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = [
      for (final k in SessionKind.values)
        checkLine(CheckStore(_files, k), MeditationStore(sessionsDirFor(widget.recordingsDir, k), kind: k)),
    ];
    return TrainingSettingsView(
      on: _on,
      lines: lines,
      error: _error,
      onToggle: _toggle,
      onInfo: () => showEvidence(context, 'replay-check'),
      onResults: (k) =>
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => ReplayResultsScreen(store: CheckStore(_files, k)))),
    );
  }
}

/// The layout, from plain values (rendered in tests without a phone).
class TrainingSettingsView extends StatelessWidget {
  const TrainingSettingsView({
    super.key,
    required this.on,
    required this.lines,
    required this.onToggle,
    required this.onInfo,
    required this.onResults,
    this.error,
  });

  final bool on;
  final List<CheckLine> lines;
  final ValueChanged<bool> onToggle;
  final VoidCallback onInfo;
  final ValueChanged<SessionKind> onResults;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Training settings', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
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
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          SwitchListTile(
            value: on,
            onChanged: onToggle,
            contentPadding: EdgeInsets.zero,
            title: Text('Replay check', style: text.titleLarge),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                on ? 'On. Before every session a reminder says so.' : 'Off. Every session follows your brain live.',
                style: text.bodyLarge?.copyWith(color: on ? Night.live : Night.inkMuted),
              ),
            ),
          ),
          if (error != null) Para(error!, color: Night.problem),
          const SectionHeading('What it does'),
          const Para(
            'Does the live link to your brain matter, or would any similar sound do as well? While the check is on, '
            'some sessions replay the sound of one of your own earlier sessions instead of following you live. '
            'You are not told which.',
            top: 0,
          ),
          const Para(
            'Each kind of session first collects 4 live sessions, so there is something to replay. Then sessions '
            'come in shuffled blocks of 4: 2 live, 2 replays. The phone draws the order and saves its fingerprint '
            'with the plan before the first such session, so it cannot change afterwards.',
          ),
          const Para(
            'Jaw, blinks, a lost signal and sleep act the same in both kinds, and no live bell count is shown. '
            'After each session: how calm you feel, your guess, how in control and how random the sound felt.',
          ),
          const Para(
            'Results only after every 12 sessions, never one at a time. Plan 24 to 36; 12 is a pilot. It tests one '
            'thing: whether the live link changes your brain signal or how a session feels. Not learning over weeks, '
            'and not any health effect. Please do not test it, for example by opening your eyes to see whether the '
            'sound reacts: your guesses show whether the blinding held.',
          ),
          for (final l in lines) ...[
            SectionHeading(l.kind == SessionKind.meditation ? 'Meditation' : 'Alpha-theta'),
            Para(l.status, top: 0),
            if (l.plan != null) Para(l.plan!, color: Night.inkMuted, top: 8),
            if (l.fingerprint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Fingerprint ${_groups(l.fingerprint!.substring(0, 16))} …',
                  style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
                ),
              ),
            if (l.done > 0 || l.plan != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextButton.icon(
                    onPressed: l.canReveal ? () => onResults(l.kind) : null,
                    icon: Icon(l.canReveal ? Icons.lock_open_outlined : Icons.lock_outline),
                    label: Text(l.canReveal ? 'See the results' : 'Results locked until 12 sessions'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

String _groups(String hex) => [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)].join(' ');
