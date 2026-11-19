// The smart alarm on the screens (DECISIONS 230-238). Design: DESIGN.md (Alarm line, Wake face, Waking up) and the
// night screen's and sleep report's surface briefs in .impeccable/surfaces/ (made with /impeccable; no question
// channel, the brief stood in for the owner).
// - Night screen, before Start: one muted line in the pinned bar above Start night, like the Lights off line ("Smart
//   alarm off." / "Wakes you by 07:30, from 07:00 at a light moment."), with Set alarm / Change opening a sheet: the
//   wake-by time, the window (15 20 30 45 min), what it does in two sentences, Alarm off and Set alarm.
// - While a night records: a second muted line in the bar says what the alarm is doing, with Alarm off (it asks).
// - While it rings: the screen becomes the wake face, one "I'm awake" almost as big as the screen (the nap coach's).
// - Sleep report: "Waking up": the window, when it woke you and why, what the full-night scoring says about that
//   minute, when you tapped "I'm awake".
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../alarm/record.dart';
import '../alarm/rule.dart';
import '../recorder/status.dart' show AlarmStatus;
import '../sleep/report.dart' show SleepReport;
import 'theme.dart';

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String _clockMs(int ms) => _clock(DateTime.fromMillisecondsSinceEpoch(ms));

/// What the owner chose on the night screen; kept between nights like a bedside alarm clock.
class AlarmSetup {
  const AlarmSetup({this.on = false, this.hour = 7, this.minute = 30, this.windowMin = AlarmRule.defaultWindowMin});
  final bool on;
  final int hour, minute, windowMin;

  AlarmSetup copyWith({bool? on, int? hour, int? minute, int? windowMin}) => AlarmSetup(
    on: on ?? this.on,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    windowMin: windowMin ?? this.windowMin,
  );

  /// Tonight's plan for a night started at [now]; null when off.
  AlarmPlan? planAt(DateTime now) =>
      on ? AlarmPlan.next(now: now, hour: hour, minute: minute, windowMin: windowMin) : null;

  Map<String, Object> toJson() => {'on': on, 'hour': hour, 'minute': minute, 'windowMin': windowMin};

  static AlarmSetup fromJson(Object? j) {
    if (j is! Map) return const AlarmSetup();
    int pick(Object? v, int lo, int hi, int dflt) => v is int && v >= lo && v <= hi ? v : dflt;
    final w = j['windowMin'];
    return AlarmSetup(
      on: j['on'] == true,
      hour: pick(j['hour'], 0, 23, 7),
      minute: pick(j['minute'], 0, 59, 30),
      windowMin: w is int && AlarmRule.windowsMin.contains(w) ? w : AlarmRule.defaultWindowMin,
    );
  }
}

/// `files/alarm/setup.json`.
class AlarmSetupStore {
  AlarmSetupStore(this.file);
  final File file;

  static AlarmSetupStore forRecordings(String recordingsDir) =>
      AlarmSetupStore(File('${Directory(recordingsDir).parent.path}/alarm/setup.json'));

  AlarmSetup read() {
    try {
      return AlarmSetup.fromJson(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return const AlarmSetup();
    }
  }

  void write(AlarmSetup s) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(s.toJson()), flush: true);
    tmp.renameSync(file.path);
  }
}

/// The line above Start night.
String alarmSetupLine(AlarmSetup s, DateTime now) {
  if (!s.on) return 'Smart alarm off.';
  final p = s.planAt(now)!;
  final end = DateTime.fromMillisecondsSinceEpoch(p.endMs);
  final day = end.day == now.day ? 'today' : 'tomorrow';
  return 'Wakes you by ${_clock(end)} $day, from ${_clockMs(p.startMs)} at a light moment.';
}

const Map<String, String> _stageWords = {
  'W': 'awake',
  'N1': 'light sleep',
  'N2': 'light sleep',
  'N3': 'deep sleep',
  'R': 'dream sleep',
  'gap': 'signal lost',
};

/// The alarm's line while a night records (null without an alarm).
String? alarmNightLine(AlarmStatus? a, {required int nowMs}) {
  if (a == null) return null;
  final window = 'Alarm ${_clockMs(a.endMs - a.windowMin * 60000)}-${_clockMs(a.endMs)}.';
  final from = a.endMs - (a.windowMin + AlarmRule.scoreBeforeMin) * 60000;
  switch (a.phase) {
    case 'scoring':
      final stage = _stageWords[a.stage];
      return stage == null
          ? '$window The sleep model is starting (5 minutes).'
          : '$window Watching your sleep: $stage 2 min ago.';
    case 'woke':
      final why = switch (a.why) {
        'light' => 'in light sleep',
        'dream' => 'in dream sleep',
        'awake' => 'already awake',
        _ => 'at the window\'s end',
      };
      return 'Woke you at ${a.wakeMs == null ? '–' : _clockMs(a.wakeMs!)}, $why.';
    case 'ended':
      return '$window No light moment came, so it rang at ${_clockMs(a.endMs)}.';
    case 'off':
      if (a.note == 'Turned off.') return 'Smart alarm turned off for tonight.';
      return nowMs >= a.endMs ? window : '$window The sleep model is off; it rings at ${_clockMs(a.endMs)}.';
    default:
      if (nowMs >= a.endMs) return window;
      return '$window The sleep model starts at ${_clockMs(from)}.';
  }
}

/// The pinned bar's alarm line: muted words and one text button at the right.
class AlarmLine extends StatelessWidget {
  const AlarmLine({super.key, required this.line, required this.action, required this.onAction});
  final String line;
  final String action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Icon(Icons.wb_twilight_outlined, size: 20, color: Night.inkMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Text(line, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35, fontFeatures: tabular)),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: onAction, child: Text(action)),
      ],
    );
  }
}

/// The setup sheet: wake-by time, window, Alarm off / Set alarm. Returns the new setup, or null when closed.
Future<AlarmSetup?> showAlarmSheet(BuildContext context, AlarmSetup current, {VoidCallback? onInfo}) =>
    showModalBottomSheet<AlarmSetup>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Night.surfaceHigh,
      builder: (c) => AlarmSheet(setup: current, onInfo: onInfo),
    );

class AlarmSheet extends StatefulWidget {
  const AlarmSheet({super.key, required this.setup, this.onInfo, this.pickTime});
  final AlarmSetup setup;
  final VoidCallback? onInfo;

  /// The time picker (the system's; tests pass their own).
  final Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial)? pickTime;

  @override
  State<AlarmSheet> createState() => _AlarmSheetState();
}

class _AlarmSheetState extends State<AlarmSheet> {
  late AlarmSetup _s = widget.setup;

  Future<void> _time() async {
    final initial = TimeOfDay(hour: _s.hour, minute: _s.minute);
    final pick = widget.pickTime ??
        (c, t) => showTimePicker(
          context: c,
          initialTime: t,
          helpText: 'Wake me by',
          builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
        );
    final t = await pick(context, initial);
    if (t != null && mounted) setState(() => _s = _s.copyWith(hour: t.hour, minute: t.minute));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final start = (_s.hour * 60 + _s.minute - _s.windowMin) % (24 * 60);
    final from = '${(start ~/ 60).toString().padLeft(2, '0')}:${(start % 60).toString().padLeft(2, '0')}';
    final by = '${_s.hour.toString().padLeft(2, '0')}:${_s.minute.toString().padLeft(2, '0')}';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text('Smart alarm', style: text.titleLarge)),
                if (widget.onInfo != null)
                  IconButton(
                    onPressed: widget.onInfo,
                    tooltip: 'What the smart alarm is based on',
                    icon: const Icon(Icons.info_outline, color: Night.inkMuted),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Wake me by', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
            const SizedBox(height: 4),
            Semantics(
              button: true,
              label: 'Wake me by $by. Change the time',
              excludeSemantics: true,
              child: InkWell(
                onTap: _time,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(by, style: text.displayMedium?.copyWith(fontFeatures: tabular, height: 1)),
                      const SizedBox(width: 16),
                      Text('Change', style: text.labelLarge?.copyWith(color: Night.live)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Up to this much earlier', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                segments: [
                  for (final w in AlarmRule.windowsMin) ButtonSegment(value: w, label: Text('$w min')),
                ],
                selected: {_s.windowMin},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _s = _s.copyWith(windowMin: v.first)),
                // the app's choice rows (form_parts.dart), one step lighter than this sheet's surface
                style: SegmentedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  selectedBackgroundColor: Night.rule,
                  selectedForegroundColor: Night.ink,
                  foregroundColor: Night.inkMuted,
                  side: const BorderSide(color: Night.rule),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Between $from and $by it wakes you at the first moment of light sleep, dream sleep or being awake, '
              'never in deep sleep or the 10 minutes after it. If none comes, it rings at $by.',
              style: muted?.copyWith(fontFeatures: tabular),
            ),
            const SizedBox(height: 8),
            Text(
              'It is a real phone alarm: it rings at $by even if the app or the headband stops.',
              style: muted?.copyWith(fontFeatures: tabular),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, _s.copyWith(on: false)),
                    child: const Text('Alarm off'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, _s.copyWith(on: true)),
                    icon: const Icon(Icons.wb_twilight_outlined),
                    label: const Text('Set alarm'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks before Alarm off during a night; true to turn it off.
Future<bool> confirmAlarmOff(BuildContext context, int endMs) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Turn the alarm off?'),
      content: Text('Nothing will wake you at ${_clockMs(endMs)}. The night keeps recording.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep alarm')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Turn off')),
      ],
    ),
  );
  return ok == true;
}

/// The screen while the alarm rings: the nap coach's wake face.
class WakeFace extends StatelessWidget {
  const WakeFace({super.key, required this.reason, required this.onAwake});
  final String reason;
  final VoidCallback onAwake;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Night.ground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(liveRegion: true, child: Text('Time to wake up', style: text.displaySmall)),
              const SizedBox(height: 10),
              Text(reason, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4, fontFeatures: tabular)),
              const SizedBox(height: 6),
              Text(
                'The night is still recording. Stop it when you get up.',
                style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 28),
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onAwake,
                    style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.wb_twilight_outlined, size: 48),
                        const SizedBox(height: 16),
                        Text("I'm awake", style: text.displaySmall?.copyWith(color: Night.onLiveFill)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Waking up" section's content, worked out from the alarm's files and the night's full scoring.
class WakingUp {
  const WakingUp({required this.lead, required this.rows, required this.sentences, this.muted = const []});

  /// "Smart alarm 07:00-07:30."
  final String lead;

  /// Label-left / value-right lines.
  final List<(String, String)> rows;
  final List<String> sentences;
  final List<String> muted;
}

/// The full-night scoring's stage at [ms] (null outside the scored night).
String? _offlineAt(SleepReport r, int ms) {
  final e = (ms - r.dataStart.millisecondsSinceEpoch) ~/ 30000;
  final s = r.stages;
  return e >= 0 && e < s.length ? s[e] : null;
}

WakingUp wakingUp(AlarmNight a, SleepReport r) {
  final p = a.plan;
  final lead = 'Smart alarm ${_clockMs(p.startMs)}-${_clockMs(p.endMs)}.';
  final rows = <(String, String)>[];
  final sentences = <String>[];
  final muted = <String>[];
  final ring = a.ring, wake = a.wake, off = a.offMs;
  if (off != null && ring == null) {
    return WakingUp(lead: lead, rows: [('Turned off', _clockMs(off))], sentences: const ['It did not ring.']);
  }
  final ringMs = ring?.atMs ?? (wake?['at_ms'] as int?);
  if (ringMs == null) {
    return WakingUp(
      lead: lead,
      rows: const [],
      sentences: const ['No record of it ringing: the phone may have been off, or the alarm was changed.'],
    );
  }
  rows.add(('Woke you', _clockMs(ringMs)));
  final why = a.why;
  rows.add((
    'Why',
    switch (why) {
      AlarmWhy.light => 'light sleep',
      AlarmWhy.dream => 'dream sleep',
      AlarmWhy.awake => 'already awake',
      AlarmWhy.windowEnd || null => 'the window\'s end',
    },
  ));
  final offline = _offlineAt(r, ringMs);
  if (offline != null) rows.add(('Full-night scoring', _stageWords[offline] ?? offline));
  final awake = a.awakeMs;
  if (awake != null) {
    final s = ((awake - ringMs) / 1000).round();
    rows.add(('I\'m awake', s < 120 ? 'after $s s' : 'after ${(s / 60).round()} min'));
  }
  // why it rang when it did
  if (why == null || why == AlarmWhy.windowEnd) {
    final modelOff = a.modelOff;
    if (ring?.by == 'window end' && a.record == null) {
      sentences.add('The sleep model did not run (the app was not recording then), so the phone\'s alarm rang at '
          '${_clockMs(p.endMs)}.');
    } else if (modelOff != null) {
      sentences.add(modelOff);
    } else {
      sentences.add('No light moment came inside the window, so it rang at its end.');
    }
  } else {
    final early = ((p.endMs - ringMs) / 60000).round();
    sentences.add('That was $early min before ${_clockMs(p.endMs)}, read by the live sleep model 2 minutes behind.');
    if (offline == 'N3') {
      sentences.add('The full-night scoring calls that minute deep sleep: the live reading was wrong this time.');
    } else if (offline != null && offline != 'gap') {
      sentences.add('The full-night scoring agrees: not deep sleep.');
    }
  }
  if (offline == 'N3' && (why == null || why == AlarmWhy.windowEnd)) {
    sentences.add('You were in deep sleep then, by the full-night scoring: you may feel groggy for a while.');
  }
  if (a.gaveUpMs != null) sentences.add('No "I\'m awake" came, so the alarm stopped after 13 minutes.');
  if (ring?.by == 'backup') muted.add('The app was stopped while it rang; the phone\'s alarm rang again.');
  muted.add('Both readings are guesses by the same sleep model; neither is checked against a sleep lab.');
  return WakingUp(lead: lead, rows: rows, sentences: sentences, muted: muted);
}

/// The sleep report's "Waking up" section, after "Falling asleep".
class WakingUpSection extends StatelessWidget {
  const WakingUpSection({super.key, required this.content, this.onInfo});
  final WakingUp content;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge?.copyWith(height: 1.4);
    final muted = body?.copyWith(color: Night.inkMuted);
    final c = content;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 32, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: Text('Waking up', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500))),
                    if (onInfo != null)
                      IconButton(
                        onPressed: onInfo,
                        tooltip: 'What the smart alarm is based on',
                        icon: const Icon(Icons.info_outline, color: Night.inkMuted),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Text(c.lead, style: muted?.copyWith(fontFeatures: tabular)),
          const SizedBox(height: 6),
          for (final (label, value) in c.rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(label, style: text.bodyLarge),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      style: (RegExp(r'^\d\d:\d\d$').hasMatch(value) ? text.titleLarge : text.bodyLarge)
                          ?.copyWith(fontFeatures: tabular),
                    ),
                  ),
                ],
              ),
            ),
          for (final s in c.sentences) ...[const SizedBox(height: 8), Text(s, style: body?.copyWith(fontFeatures: tabular))],
          for (final s in c.muted) ...[const SizedBox(height: 8), Text(s, style: muted)],
        ],
      ),
    );
  }
}
