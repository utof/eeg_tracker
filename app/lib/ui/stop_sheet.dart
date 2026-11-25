// "What was this recording?": the sheet after Stop (Record first, DECISIONS 890-891, 908-910). Chips are one tap
// each (the shared package's StopChips), "only part of it" times belong to the chip tapped last, your own words are
// kept exactly as typed, and the confirm questions for this recording sit under them. Skip writes nothing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_labels/shared_labels.dart';

import '../confirm/questions.dart';
import '../spans/stop_sheet.dart';
import 'theme.dart';

/// Shows the sheet for [plan]; true when something was saved. Either way the sheet counts as answered.
Future<bool> showStopSheet(BuildContext context, StopSheetPlan plan, {required Directory filesDir, ConfirmQuestions? confirm}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Night.surfaceHigh,
    builder: (_) => StopSheet(plan: plan, filesDir: filesDir, confirm: confirm),
  );
  StopSheetSeen(filesDir).mark(plan.recording, saved: saved ?? false);
  return saved ?? false;
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _length(Duration d) => d.inHours > 0 ? '${d.inHours} h ${d.inMinutes % 60} min' : '${d.inMinutes} min';

class StopSheet extends StatefulWidget {
  const StopSheet({super.key, required this.plan, required this.filesDir, this.confirm, this.pickTime});
  final StopSheetPlan plan;
  final Directory filesDir;

  /// The confirm questions (null: no slot).
  final ConfirmQuestions? confirm;

  /// The clock-time picker (tests give their own); null: the system's.
  final Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial)? pickTime;

  @override
  State<StopSheet> createState() => _StopSheetState();
}

class _StopSheetState extends State<StopSheet> {
  Set<String> _on = {};
  String? _last;
  final Map<String, (DateTime, DateTime)> _times = {};
  final TextEditingController _words = TextEditingController();
  late final List<ConfirmQuestion> _questions = _load();
  final Map<String, Answer> _answers = {};

  StopSheetPlan get _p => widget.plan;

  List<ConfirmQuestion> _load() {
    try {
      return widget.confirm?.pendingFor(_p.recording, _p.start, _p.end) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  void _tap(String label) => setState(() {
    _on = tapStopChip(_on, label);
    _times.removeWhere((l, _) => !_on.contains(l));
    _last = _on.contains(label) && !(stopChipOf(label)?.whole ?? false) ? label : null;
  });

  /// A clock time inside the recording: the first moment with that hour and minute from its start.
  DateTime _at(TimeOfDay t) {
    var d = DateTime(_p.start.year, _p.start.month, _p.start.day, t.hour, t.minute);
    if (d.isBefore(_p.start)) d = d.add(const Duration(days: 1));
    return d.isAfter(_p.end) ? _p.end : d;
  }

  Future<void> _pick(String label, {required bool start}) async {
    final now = _times[label] ?? (_p.start, _p.end);
    final initial = TimeOfDay.fromDateTime(start ? now.$1 : now.$2);
    final t = await (widget.pickTime ?? (c, i) => showTimePicker(context: c, initialTime: i))(context, initial);
    if (t == null || !mounted) return;
    final at = _at(t);
    setState(() {
      final next = start ? (at, now.$2) : (now.$1, at);
      _times[label] = next.$2.isAfter(next.$1) ? next : (next.$1, _p.end);
    });
  }

  Future<void> _save() async {
    final picks = [
      for (final c in stopChips)
        if (_on.contains(c.label)) StopPick(c.label, start: _times[c.label]?.$1, end: _times[c.label]?.$2),
    ];
    // "Slept 23:50-07:10" can become a sleep report; asked, never assumed
    final reports = <String>{};
    for (final p in picks) {
      if (!p.timed || !(stopChipOf(p.label)?.sleep ?? false)) continue;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Make a sleep report for ${_hm(p.start!)}-${_hm(p.end!)}?'),
          content: const Text('The app scores that stretch as sleep and lists it with your nights.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes')),
          ],
        ),
      );
      if (yes ?? false) reports.add(p.label);
    }
    if (!mounted) return;
    final ok = saveStopSheet(widget.filesDir, _p, picks: picks, words: _words.text, confirm: widget.confirm, sleepReports: reports);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That could not be saved: the phone is full.')));
      return;
    }
    Navigator.pop(context, picks.isNotEmpty || _words.text.trim().isNotEmpty || _answers.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35);
    final marked = _p.marked;
    final last = _last;
    final times = last == null ? null : _times[last];
    // above the keyboard and above the phone's own bar at the bottom edge
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 16 + MediaQuery.viewInsetsOf(context).bottom + MediaQuery.viewPaddingOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What was this recording?', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('${_hm(_p.start)} - ${_hm(_p.end)} · ${_length(_p.length)}', style: muted),
            if (marked != null) ...[const SizedBox(height: 8), Text('Already marked: $marked', style: muted)],
            const SizedBox(height: 12),
            StopChips(on: _on, done: _p.done, onTap: _tap),
            if (last != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('${stopChipOf(last)!.word}: only part of it?', style: muted)),
                  TextButton(
                    key: const ValueKey('stop-from'),
                    onPressed: () => _pick(last, start: true),
                    child: Text(times == null ? 'From' : _hm(times.$1)),
                  ),
                  const Text('-'),
                  TextButton(
                    key: const ValueKey('stop-to'),
                    onPressed: () => _pick(last, start: false),
                    child: Text(times == null ? 'To' : _hm(times.$2)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('stop-words'),
              controller: _words,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'In your words (optional)'),
            ),
            if (_questions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('A few quick questions', style: text.titleSmall),
              ConfirmBatch(
                questions: _questions,
                answers: _answers,
                onAnswer: (q, a) {
                  widget.confirm?.answer(q.id, a, via: AnswerVia.stopSheet);
                  setState(() => _answers[q.id] = a);
                },
                onUndo: (q) {
                  widget.confirm?.undo(q.id);
                  setState(() => _answers.remove(q.id));
                },
              ),
            ],
            const SizedBox(height: 16),
            // each button takes half the row: the app's filled buttons are as wide as they are allowed to be
            Row(
              children: [
                Expanded(
                  child: TextButton(onPressed: () => Navigator.pop(context, _answers.isNotEmpty), child: const Text('Skip')),
                ),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(onPressed: _save, child: const Text('Save'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
