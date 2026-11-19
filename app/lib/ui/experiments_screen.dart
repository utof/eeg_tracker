// Self-experiments (ROADMAP row 14; DECISIONS rows 200-209): reads the experiments and the trends' per-day numbers
// from the app's folders and lays them out with experiments_view.dart. Opened from the Trends page.
import 'dart:async';

import 'package:flutter/material.dart';

import '../experiments/analysis.dart';
import '../experiments/experiment.dart';
import '../experiments/store.dart';
import '../phone.dart';
import '../trends/trends.dart';
import 'evidence_sheet.dart';
import 'experiment_setup.dart';
import 'experiments_view.dart';
import '../study/arm.dart' show readOwnDayNumbers;
import 'trends_screen.dart' show readTrendInputs;

/// The running experiment (else the newest finished one) for a one-line note on other screens.
ExperimentState? currentExperiment(String recordingsDir, DateTime now) {
  final all = ExperimentStore(experimentsDirFor(recordingsDir)).all(now);
  return all.where((s) => !s.open).firstOrNull ?? all.where((s) => s.phase == ExpPhase.finished).firstOrNull;
}

class ExperimentsScreen extends StatefulWidget {
  const ExperimentsScreen({super.key, this.recordingsDir, this.id, this.now});

  /// The app's recordings folder when the caller knows it.
  final String? recordingsDir;

  /// One earlier experiment to show; null: the one under way, else the newest.
  final String? id;

  /// The clock (tests).
  final DateTime Function()? now;

  @override
  State<ExperimentsScreen> createState() => _ExperimentsScreenState();
}

class _ExperimentsScreenState extends State<ExperimentsScreen> {
  String? _dir, _error;
  bool _loaded = false, _early = false;
  ExperimentPage? _page;
  List<ExperimentState> _earlier = const [];

  DateTime get _now => (widget.now ?? DateTime.now)();
  ExperimentStore get _store => ExperimentStore(experimentsDirFor(_dir!));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      _dir ??= widget.recordingsDir ?? await Phone.recordingsDir();
      if (_dir == null) throw StateError("the app's folder is not known");
      final now = _now;
      final all = _store.all(now);
      final shown = widget.id != null
          ? all.where((s) => s.plan.id == widget.id).firstOrNull
          : (all.where((s) => !s.open).firstOrNull ?? all.firstOrNull);
      ExperimentPage? page;
      if (shown != null) {
        final early = _early && !shown.open;
        final results = shown.open || early ? resultsFor(shown, dailySeries(readTrendInputs(_dir!), extra: readOwnDayNumbers(_dir!)), early: early) : null;
        page = ExperimentPage(state: shown, now: now, results: results, early: early);
      }
      if (!mounted) return;
      setState(() {
        _page = page;
        _earlier = widget.id != null
            ? const []
            : [
                for (final s in all)
                  if (s.plan.id != shown?.plan.id) s,
              ];
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<bool> _ask(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Back')),
            TextButton(onPressed: () => Navigator.of(c).pop(true), child: Text(yes)),
          ],
        ),
      ) ??
      false;

  Future<void> _lookEarly() async {
    final s = _page!.state;
    final ok = await _ask(
      'Look before the end?',
      'Day ${s.daysDone} of ${s.plan.days}. An early result is often wrong, and knowing it can change the days '
          'that are left. The look is logged and shown beside the final answer for good.',
      'Look early',
    );
    if (!ok) return;
    _store.earlyLook(s.plan.id, _now);
    _early = true;
    await _load();
  }

  Future<void> _stop() async {
    final s = _page!.state;
    final ok = await _ask(
      'Stop this experiment?',
      'It cannot be started again. The ${s.daysDone} days that are over stay counted and the answer opens now, '
          'marked as stopped early.',
      'Stop',
    );
    if (!ok) return;
    _store.stop(s.plan.id, _now);
    await _load();
  }

  Future<void> _new() async {
    final nav = Navigator.of(context);
    await nav.push(
      MaterialPageRoute<void>(
        builder: (c) => ExperimentSetup(
          now: _now,
          onInfo: () => showEvidence(c, 'self-experiments'),
          onStart: (choice) {
            _store.create(
              preset: choice.preset,
              doText: choice.doText,
              dontText: choice.dontText,
              outcome: choice.outcome,
              weeks: choice.weeks,
              now: _now,
            );
            Navigator.of(c).pop();
          },
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Self-experiments')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error == null ? 'Reading your experiments…' : 'The experiments could not be read: $_error'),
        ),
      );
    }
    return ExperimentView(
      page: _page,
      earlier: _earlier,
      onInfo: () => showEvidence(context, 'self-experiments'),
      onAnswer: (day, kept) {
        _store.answer(_page!.state.plan.id, day, kept, _now);
        unawaited(_load());
      },
      onLookEarly: _lookEarly,
      onStop: _stop,
      onNew: widget.id == null ? _new : null,
      onOpen: (id) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ExperimentsScreen(recordingsDir: _dir, id: id, now: widget.now)),
      ),
    );
  }
}
