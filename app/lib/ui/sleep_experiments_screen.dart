// Sleep experiments (DECISIONS rows 838, 1050-1069): reads the experiment's log and the nights' sleep reports from
// the app's folders and lays them out with sleep_experiments_view.dart. Opened from the Trends page.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../phone.dart';
import '../pulse/night.dart' show pulseDayNumbers;
import '../sharp/prompts.dart';
import '../sharp/schedule.dart' show clockText;
import '../study/arm.dart' show experimentReminderMinute, rearmPrompts;
import '../sleep_experiments/kinds.dart';
import '../sleep_experiments/result.dart';
import '../sleep_experiments/store.dart';
import '../trends/days.dart';
import '../wearer/wearer.dart' show ownNightReports;
import 'evidence_sheet.dart';
import 'sleep_experiments_view.dart';

/// The "i" note's name (docs/evidence).
const String sleepExperimentsNote = 'sleep-experiments';

/// Every night that counts, by the day you woke: from the sleep reports the owner wore the headband for (a removed
/// or "Not sleep" night has no report here) and the pulse read beside them.
Map<String, NightNumbers> readNightNumbers(String recordingsDir) {
  final nights = ownNightReports(recordingsDir);
  return nightNumbersFrom(nights, pulse: pulseDayNumbers(Directory(recordingsDir).parent, nights));
}

Future<Map<String, NightNumbers>> _inBackground(String recordingsDir) =>
    Isolate.run(() => readNightNumbers(recordingsDir), debugName: 'sleep experiments');

/// Kind id -> the "needs about N nights" line for its main number, from the owner's own nights where there are
/// enough of them.
Map<String, String> neededBeforeStart(Map<String, NightNumbers> nights) => {
  for (final k in experimentKinds)
    k.id: () {
      final n = neededFor(k.watched.first, ordinaryValues(k.main.id, nights, const {}));
      return neededWords(k.main, n.needed, n.own);
    }(),
};

class SleepExperimentsScreen extends StatefulWidget {
  const SleepExperimentsScreen({super.key, this.recordingsDir, this.id, this.now, this.readNights, this.phone, this.notificationsOn});

  /// The phone's one list of reminders (re-armed after every tap here), and whether the reminder's notifications are
  /// allowed (tests); null: the phone's.
  final SharpPhone? phone;
  final Future<bool> Function()? notificationsOn;

  /// The app's recordings folder when the caller knows it.
  final String? recordingsDir;

  /// One earlier experiment to show; null: the one that runs, else the newest.
  final String? id;

  /// The clock, and the reader of the nights (tests).
  final DateTime Function()? now;
  final Future<Map<String, NightNumbers>> Function(String recordingsDir)? readNights;

  @override
  State<SleepExperimentsScreen> createState() => _SleepExperimentsScreenState();
}

class _SleepExperimentsScreenState extends State<SleepExperimentsScreen> {
  String? _dir, _error;
  bool _loaded = false;
  SleepExperimentPage? _page;
  List<ExperimentLog> _earlier = const [];
  Map<String, NightNumbers> _nights = const {};
  int? _remindMin;
  bool _notificationsOff = false;

  DateTime get _now => (widget.now ?? DateTime.now)();
  SleepExperimentStore get _store => SleepExperimentStore(sleepExperimentsDirFor(_dir!));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// [nights]: read the sleep reports again (false after a tap: only the log changed).
  Future<void> _load({bool nights = true}) async {
    try {
      _dir ??= widget.recordingsDir ?? await Phone.recordingsDir();
      if (_dir == null) throw StateError("the app's folder is not known");
      if (nights) _nights = await (widget.readNights ?? _inBackground)(_dir!);
      if (nights) {
        try {
          _remindMin = experimentReminderMinute(_dir!, _now);
        } catch (_) {
          // the page stands without the reminder's time
        }
      }
      final all = _store.all();
      final shown = widget.id != null
          ? all.where((e) => e.plan.id == widget.id).firstOrNull
          : (all.where((e) => e.running).firstOrNull ?? all.firstOrNull);
      final allowed = shown != null && shown.remind ? await (widget.notificationsOn ?? experimentNotificationsOn)() : true;
      if (!mounted) return;
      setState(() {
        _notificationsOff = !allowed;
        _page = shown == null ? null : SleepExperimentPage(result: resultFor(shown, _nights), today: dayKey(_now));
        _earlier = widget.id != null
            ? const []
            : [
                for (final e in all)
                  if (e.plan.id != shown?.plan.id) e,
              ];
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// A tap written to the log, then the page again; a failed write is said in a snackbar.
  void _write(void Function(SleepExperimentStore store, String id, DateTime now) tap) {
    try {
      tap(_store, _page!.log.plan.id, _now);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not saved: $e')));
    }
    // tonight's reminder is not needed once answered, and the switch itself changes the list
    final dir = _dir;
    if (dir != null) unawaited(rearmPrompts(dir, widget.phone ?? ChannelSharpPhone(), _now).catchError((Object _) {}));
    unawaited(_load(nights: false));
  }

  Future<void> _end() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('End this experiment?'),
        content: const Text('It cannot be started again. Everything you logged stays, and the result stays readable.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Back')),
          TextButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('End')),
        ],
      ),
    );
    if (ok == true) _write((s, id, now) => s.end(id, now));
  }

  Future<void> _new() async {
    final needs = neededBeforeStart(_nights);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (c) => SleepExperimentSetup(
          needs: needs,
          onInfo: () => showEvidence(c, sleepExperimentsNote),
          onStart: (choice) {
            _store.create(kind: choice.kind, picked: choice.picked, now: _now);
            Navigator.of(c).pop();
          },
        ),
      ),
    );
    await _load(nights: false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Sleep experiments')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error == null ? 'Reading your nights…' : 'The experiments could not be read: $_error'),
        ),
      );
    }
    final own = widget.id == null;
    return SleepExperimentView(
      page: _page,
      earlier: _earlier,
      onInfo: () => showEvidence(context, sleepExperimentsNote),
      onAnswer: own ? (day, a) => _write((s, id, now) => s.answer(id, day, a, now)) : null,
      onOdd: own ? (day, flag, on) => _write((s, id, now) => s.odd(id, day, flag, on, now)) : null,
      onPick: own ? () => _write((s, id, now) => s.pick(id, now)) : null,
      onEnd: own ? _end : null,
      onNew: own ? _new : null,
      onRemind: own ? (on) => _write((s, id, now) => s.setReminder(id, on, now)) : null,
      remindAt: _remindMin == null ? null : clockText(_remindMin!),
      notificationsOff: _notificationsOff,
      onOpen: (id) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SleepExperimentsScreen(recordingsDir: _dir, id: id, now: widget.now, readNights: widget.readNights),
        ),
      ),
    );
  }
}
