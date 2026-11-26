// Tonight's question of the running sleep experiment on the Record tab (DECISIONS 1084): one line and three answers
// right above the Sleep button, in the evening, until it is answered. It reads the experiment's small log itself
// (at start, when the app comes back, and whenever any page writes to a log) and shows nothing when there is
// nothing to ask.
import 'dart:async';

import 'package:flutter/material.dart';

import '../sharp/prompts.dart' show ChannelSharpPhone;
import '../sleep_experiments/kinds.dart';
import '../sleep_experiments/store.dart';
import '../sleep_experiments/tonight.dart';
import '../study/arm.dart' show rearmInBackground;
import '../trends/days.dart';
import 'sleep_experiments_view.dart';
import 'theme.dart';

/// Hands the phone its reminders again after an answer (tonight's reminder is then not needed).
Future<void> rearmOnPhone(String recordingsDir) => rearmInBackground(recordingsDir, ChannelSharpPhone(), DateTime.now());

class SleepExperimentAsk extends StatefulWidget {
  const SleepExperimentAsk({super.key, required this.recordingsDir, this.onOpen, this.now, this.rearm});

  /// The app's recordings folder; null while it is not known yet (nothing is shown).
  final String? recordingsDir;

  /// Opens the experiment's page (the pick is made there).
  final VoidCallback? onOpen;

  /// The clock, and the re-arming of the phone's reminders (tests); null: the phone's.
  final DateTime Function()? now;
  final Future<void> Function(String recordingsDir)? rearm;

  @override
  State<SleepExperimentAsk> createState() => _SleepExperimentAskState();
}

class _SleepExperimentAskState extends State<SleepExperimentAsk> with WidgetsBindingObserver {
  ExperimentLog? _log;

  DateTime get _now => (widget.now ?? DateTime.now)();
  SleepExperimentStore? get _store =>
      widget.recordingsDir == null ? null : SleepExperimentStore(sleepExperimentsDirFor(widget.recordingsDir!));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SleepExperimentStore.written.addListener(_read);
    _read();
  }

  @override
  void didUpdateWidget(SleepExperimentAsk old) {
    super.didUpdateWidget(old);
    if (old.recordingsDir != widget.recordingsDir) _read();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SleepExperimentStore.written.removeListener(_read);
    super.dispose();
  }

  void _read() {
    ExperimentLog? log;
    try {
      log = _store?.active();
    } catch (_) {
      // a line of the Record tab is never worth breaking it
    }
    if (mounted) setState(() => _log = log);
  }

  void _answer(ExperimentLog e, Answer a) {
    final now = _now;
    final messenger = ScaffoldMessenger.of(context);
    final label = switch (a) {
      Answer.withIt => e.plan.kind.withLabel,
      Answer.without => e.plan.kind.withoutLabel,
      Answer.neither => e.plan.kind.neitherLabel,
    };
    try {
      final kept = _store!.answer(e.plan.id, dayKey(now), a, now);
      messenger.showSnackBar(
        SnackBar(content: Text(kept ? 'Kept: $label. To change it: Trends, Sleep experiments.' : 'Not saved: the experiment has ended.')),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Not saved: $err')));
    }
    final dir = widget.recordingsDir;
    if (dir != null) unawaited((widget.rearm ?? rearmOnPhone)(dir).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    final e = _log;
    final what = tonightAsk(e, _now);
    if (e == null || what == Tonight.nothing) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final kind = e.plan.kind;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: what == Tonight.pick
          ? Row(
              children: [
                Expanded(
                  child: Text(
                    '${kind.title}: is tonight a test night?',
                    style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35),
                  ),
                ),
                TextButton(onPressed: widget.onOpen, child: const Text('Let the app pick')),
              ],
            )
          : AnswerQuestion(
              kind: kind,
              question: '${kind.title}. ${kind.question}',
              value: null,
              onChanged: (a) => _answer(e, a),
              dense: true,
            ),
    );
  }
}
