// The confirmation questions' screen side (DECISIONS 860-869): the card on the Night tab and in the Archive, which
// reads and writes through lib/confirm/questions.dart, and the settings page. The card gathers the detectors'
// estimates when it appears, when the app comes back and when [ConfirmCardHost.changed] changes (a recording stopped, a
// report was made); the file work runs in a background isolate.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:shared_labels/shared_labels.dart';

import '../archive/page.dart' show loadArchiveInBackground;
import '../confirm/phone.dart';
import '../confirm/questions.dart';

import '../walking/pass.dart' show walkInBackground;
import 'archive_screen.dart' show phoneArchiveBusy;
import 'confirm_view.dart';
import 'evidence_sheet.dart';

/// Gathers the estimates on disk and rewrites the labels file, off the screen's thread.
Future<int> gatherInBackground(String filesPath) =>
    Isolate.run(() => ConfirmQuestions(Directory(filesPath)).gather(), debugName: 'confirm-gather');

/// The walking pass for the newest recordings that have none yet (the Archive runs it too, when it is open), so a
/// walk is asked about soon after its recording stops. At most [max] recordings, only those that ended within the
/// asking age, and never while something records or the night is being scored. True when a pass ran.
Future<bool> recentWalkPasses(String filesPath, {int max = 2, DateTime? now}) async {
  final busy = await phoneArchiveBusy();
  if (busy.nightRecording || busy.sessionRunning || busy.scoring) return false;
  final page = await loadArchiveInBackground(filesPath);
  final at = now ?? DateTime.now();
  final dir = Directory(filesPath);
  var ran = false;
  for (final id in page.toWalk.take(max)) {
    final item = page.list.items.where((i) => i.id == id).firstOrNull;
    if (item == null || at.difference(item.end) > ConfirmRule.maxAge) continue;
    await walkInBackground(filesPath, id, [for (final f in item.rawFiles(dir)) f.path]);
    ran = true;
  }
  return ran;
}

class ConfirmCardHost extends StatefulWidget {
  const ConfirmCardHost({super.key, required this.filesPath, this.phone, this.changed, this.gather, this.passes, this.clock, this.takesOpen = false});

  /// The app's `files/`.
  final String filesPath;

  /// The notification side; null: none (tests).
  final ConfirmPhone? phone;

  /// What the screen saw change (a recording stopped, a report appeared): the card gathers again.
  final Object? changed;

  /// Tests: the gathering on the test's own thread; null: [gatherInBackground].
  final Future<int> Function(String filesPath)? gather;

  /// Detector passes to run for the newest recordings before asking (the phone: [recentWalkPasses]); true: one ran.
  final Future<bool> Function(String filesPath)? passes;
  final DateTime Function()? clock;

  /// This card reloads when the questions' notification is tapped (the Night tab's card, there all the time).
  final bool takesOpen;

  @override
  State<ConfirmCardHost> createState() => _ConfirmCardHostState();
}

class _ConfirmCardHostState extends State<ConfirmCardHost> with WidgetsBindingObserver {
  late final ConfirmQuestions _confirm = ConfirmQuestions(Directory(widget.filesPath), phone: widget.phone, clock: widget.clock);
  List<ConfirmQuestion> _questions = const [];
  final Map<String, Answer> _answers = {};
  final Map<String, String> _notes = {}, _saved = {};
  List<Estimate> _around = const [];

  /// When the questions on the card came on screen (the answer keeps how long you took).
  DateTime _shown = DateTime.now();
  bool _loading = false, _again = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.takesOpen) widget.phone?.onOpen = () => unawaited(_load());
    unawaited(_load(passes: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.takesOpen) widget.phone?.onOpen = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load(passes: true)); // the notification's answers are in by now
  }

  @override
  void didUpdateWidget(ConfirmCardHost old) {
    super.didUpdateWidget(old);
    if (widget.changed != old.changed) unawaited(_load(passes: true));
  }

  Future<void> _load({bool passes = false}) async {
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      await _gather();
      if (passes && widget.passes != null && await widget.passes!(widget.filesPath)) await _gather();
    } catch (_) {
      // a folder that cannot be read: no card
    } finally {
      _loading = false;
    }
    if (_again && mounted) {
      _again = false;
      unawaited(_load());
    }
  }

  Future<void> _gather() async {
    await (widget.gather ?? gatherInBackground)(widget.filesPath);
    await _confirm.plan();
    final pending = _confirm.pending();
    final around = pending.any((q) => q.exactTimes) ? _confirm.around() : const <Estimate>[];
    if (!mounted) return;
    setState(() {
      _answers.clear();
      _notes.clear();
      _saved.clear();
      _around = around;
      _questions = pending;
      _shown = (widget.clock ?? DateTime.now)();
    });
  }

  void _answer(ConfirmQuestion q, Answer a) {
    _confirm.answer(q.id, a, card: q.kind, shown: _shown);
    setState(() => _answers[q.id] = a);
  }

  /// "Yes, but the times are off", saved: a Yes with your own times.
  void _times(ConfirmQuestion q, DateTime start, DateTime end) {
    _confirm.answer(q.id, Answer.yes, card: q.kind, shown: _shown, start: start, end: end);
    String clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() {
      _answers[q.id] = Answer.yes;
      _saved[q.id] = '${q.yes}, ${clock(start)}-${clock(end)}';
    });
  }

  /// A blind card's chip.
  void _said(ConfirmQuestion q, Label label) {
    _confirm.answer(q.id, Answer.said, card: CardKind.blind, shown: _shown, said: label);
    setState(() {
      _answers[q.id] = Answer.said;
      _saved[q.id] = label.chip;
    });
  }

  /// A blind card's "Something else": your own words.
  Future<void> _words(ConfirmQuestion q) async {
    final words = await askWords(context, q.text, null);
    if (words == null || !mounted) return;
    _confirm.answer(q.id, Answer.said, card: CardKind.blind, shown: _shown, words: words);
    setState(() {
      _answers[q.id] = Answer.said;
      _saved[q.id] = cleanNote(words);
    });
  }

  void _undo(ConfirmQuestion q) {
    _confirm.undo(q.id);
    setState(() {
      _answers.remove(q.id);
      _notes.remove(q.id);
      _saved.remove(q.id);
    });
  }

  Future<void> _note(ConfirmQuestion q) async {
    final words = await askWords(context, q.text, _notes[q.id]);
    if (words == null || !mounted) return;
    _confirm.note(q.id, words);
    setState(() => _notes[q.id] = words.trim());
  }

  @override
  Widget build(BuildContext context) => ConfirmCard(
    questions: _questions,
    answers: _answers,
    notes: _notes,
    saved: _saved,
    onAnswer: _answer,
    onUndo: _undo,
    onNote: _note,
    onTimes: _times,
    onSaid: _said,
    onWords: _words,
    around: _around,
    now: (widget.clock ?? DateTime.now)(),
    onInfo: () => showEvidence(context, 'confirm-questions'),
  );
}

/// A few words of your own beside an answer; null when cancelled or empty.
Future<String?> askWords(BuildContext context, String question, String? now) async {
  final c = TextEditingController(text: now ?? '');
  final got = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(question),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: 200,
        minLines: 1,
        maxLines: 3,
        decoration: const InputDecoration(hintText: 'In your words (kept as you write them)'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Save')),
      ],
    ),
  );
  return got == null || got.trim().isEmpty ? null : got;
}

class ConfirmSettingsScreen extends StatefulWidget {
  const ConfirmSettingsScreen({super.key, required this.filesPath, this.phone});
  final String filesPath;
  final ConfirmPhone? phone;

  @override
  State<ConfirmSettingsScreen> createState() => _ConfirmSettingsScreenState();
}

class _ConfirmSettingsScreenState extends State<ConfirmSettingsScreen> with WidgetsBindingObserver {
  late final ConfirmQuestions _confirm = ConfirmQuestions(Directory(widget.filesPath), phone: widget.phone);
  late ConfirmSettings _settings = _confirm.settings;
  bool _notifications = true;

  /// The quiet hours in force now, and from how many of your nights (0: the fixed ones).
  ({int startMin, int endMin, int nights}) _quietNow() {
    final state = _confirm.store.read(), now = DateTime.now();
    final q = quietHours(state, _settings, now);
    return (startMin: q.startMin, endMin: q.endMin, nights: q.fromSleep ? (sleepHabit(state, now)?.nights ?? 0) : 0);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_status());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_status());
  }

  Future<void> _status() async {
    var on = true;
    try {
      on = await widget.phone?.notificationsOn() ?? true;
    } catch (_) {
      on = true;
    }
    if (mounted) setState(() => _notifications = on);
  }

  void _changed(ConfirmSettings s) {
    setState(() => _settings = s);
    unawaited(_confirm.saveSettings(s));
  }

  Future<int?> _pickTime(int minutes) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60));
    return t == null ? null : t.hour * 60 + t.minute;
  }

  @override
  Widget build(BuildContext context) => ConfirmSettingsView(
    settings: _settings,
    quietNow: _quietNow(),
    onChanged: _changed,
    notificationsOn: _notifications,
    onNotificationSettings: () => unawaited(widget.phone?.openChannelSettings().catchError((Object _) {})),
    onPickTime: _pickTime,
    onInfo: () => showEvidence(context, 'confirm-questions'),
  );
}
