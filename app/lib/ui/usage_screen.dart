// "How I use the app" (More; DECISIONS 713-714): the switch, then for today, 7 or 30 days: time in the app, the
// screens, the features, the most-tapped controls, what was not opened, scrolling, hints and questions, smoothness,
// start-up and storage. Everything is read from `files/logs/` on this phone; nothing is sent anywhere.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../logs/files.dart';
import '../logs/log.dart' show AppLog, Logs;
import '../logs/read.dart';
import '../logs/settings.dart';
import '../logs/usage.dart';
import '../logs/usage_report.dart';
import '../phone.dart';
import 'parts.dart' show SectionHeading;
import 'records_parts.dart';
import 'theme.dart';

class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, this.recordingsDir, this.now});

  /// The app's recordings folder when the caller knows it.
  final String? recordingsDir;

  /// Tests: the clock.
  final DateTime Function()? now;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

/// The words for a hint's kind.
const Map<String, String> _hintWords = {
  'work-break': 'Break hints (work)',
  'auto-start': 'Auto-start questions',
  'sharp': 'Sharp-hours questions',
  'study': 'Study reminders',
};

class _UsageScreenState extends State<UsageScreen> {
  UsageSummary? _sum;
  String? _error;
  String? _files;
  int _days = 7;
  LogSettings _settings = const LogSettings();

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rec = widget.recordingsDir ?? await Phone.recordingsDir();
      if (rec == null) throw StateError("the app's folder is not known");
      final files = Directory(rec).parent.path;
      final now = _now(), days = _days;
      final sum = await usageInBackground(files, now, days);
      if (!mounted) return;
      setState(() {
        _files = files;
        _sum = sum;
        _settings = LogSettings.load(logsDirFor(rec));
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _setUsage(bool on) {
    final files = _files;
    if (files == null) return;
    final s = _settings.copyWith(usage: on);
    try {
      final logs = Logs.current;
      if (logs != null && logs.dir != null) {
        logs.saveSettings(s);
      } else {
        s.save(Directory('$files/logs'));
      }
      AppLog('usage').info(on ? 'recording how the app is used: on' : 'recording how the app is used: off');
      Usage.setting('usage', on);
      setState(() => _settings = s);
    } catch (e) {
      _say('The setting could not be saved: $e');
    }
  }

  Future<void> _delete() async {
    final files = _files;
    if (files == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete how you used the app?'),
        content: const Text('Every screen, tap, scroll and hint recorded so far on this phone goes. Copies on the laptop stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    final n = deleteLogs(Directory('$files/logs'), {LogKind.usage});
    _say(n == 1 ? '1 file deleted' : '$n files deleted');
    await _load();
  }

  void _say(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = _sum;
    return Scaffold(
      appBar: AppBar(title: const Text('How I use the app')),
      body: s == null ? recordsWaiting(context, _error) : _body(context, s),
    );
  }

  Widget _body(BuildContext context, UsageSummary s) {
    final text = Theme.of(context).textTheme;
    final period = _days == 1 ? 'today' : 'in the last $_days days';
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        RecordSwitch(
          title: 'Record how I use the app',
          line:
              'Which screens you open, which buttons you tap, how you scroll and swipe, which features run and how you '
              'answer hints. Only inside this app, never what you type into a field, never sent anywhere: so you and '
              'the assistant can see what to keep, improve or drop.',
          value: _settings.usage,
          onChanged: _setUsage,
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: PeriodChoice(
            days: _days,
            onChanged: (d) {
              setState(() => _days = d);
              unawaited(_load());
            },
          ),
        ),
        if (s.empty) ...[
          const SizedBox(height: 20),
          Text('Nothing recorded $period.', style: text.titleLarge),
          MutedLine(
            _settings.usage
                ? 'Use the app as usual; this page fills as you go.'
                : 'Recording is off. Switch it on above to see what you use.',
          ),
        ] else
          ..._summary(context, s, period),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: _delete, child: const Text('Delete what was recorded')),
        ),
      ],
    );
  }

  List<Widget> _summary(BuildContext context, UsageSummary s, String period) {
    final out = <Widget>[
      const SectionHeading('Time in the app'),
      RecordRow(label: 'With the app open', value: spanWords(s.inApp), note: '${s.opens == 1 ? 'Opened once' : 'Opened ${s.opens} times'} $period.'),
      if (s.perDay.length > 1)
        for (final (day, t) in s.perDay.reversed) RecordRow(label: day, value: spanWords(t)),
    ];
    if (s.screens.isNotEmpty) {
      final top = s.screens.first.time.inSeconds;
      out.add(const SectionHeading('Screens'));
      for (final sc in s.screens.take(12)) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RecordRow(label: screenLabel(sc.screen), value: spanWords(sc.time), note: sc.visits == 1 ? '1 visit' : '${sc.visits} visits'),
                ShareBar(top == 0 ? 0 : sc.time.inSeconds / top),
              ],
            ),
          ),
        );
      }
    }
    if (s.features.isNotEmpty) {
      out.add(const SectionHeading('Features that ran'));
      for (final f in s.features.take(12)) {
        out.add(
          RecordRow(
            label: featureWords(f.feature),
            value: f.total == Duration.zero ? '—' : spanWords(f.total),
            note: f.times == 1 ? 'Once' : '${f.times} times',
          ),
        );
      }
    }
    if (s.taps.isNotEmpty) {
      out.add(const SectionHeading('Most tapped'));
      for (final t in s.taps) {
        out.add(RecordRow(label: t.control, value: '${t.taps}', note: 'on ${screenLabel(t.screen)}'));
      }
    }
    if (s.notOpened.isNotEmpty) {
      out.add(const SectionHeading('Not opened'));
      out.add(MutedLine('${[for (final k in s.notOpened) screenLabel(k)].join(', ')}.', top: 0));
      out.add(const MutedLine('A feature you never open may not be worth its place; tell the assistant.'));
    }
    if (s.scrolls.isNotEmpty || s.drags > 0) {
      out.add(const SectionHeading('Scrolling and swiping'));
      for (final sc in s.scrolls.take(8)) {
        out.add(
          RecordRow(
            label: screenLabel(sc.screen),
            value: sc.scrolls == 1 ? '1 scroll' : '${sc.scrolls} scrolls',
            note: sc.reach > 0 ? 'Down to ${(sc.reach * 100).round()} % of the page at most' : null,
          ),
        );
      }
      if (s.drags > 0) out.add(MutedLine('${s.drags} swipes that scrolled nothing (the 3D head, sliders).'));
      out.add(const MutedLine('A page scrolled a lot to reach its end may hold too much.'));
    }
    if (s.hints.isNotEmpty || s.autoGuesses > 0) {
      out.add(const SectionHeading('Hints and questions'));
      for (final h in s.hints) {
        final answered = h.answers.values.fold<int>(0, (a, b) => a + b);
        final how = [for (final e in h.answers.entries) '${e.key} ${e.value}'].join(', ');
        out.add(
          RecordRow(
            label: _hintWords[h.kind] ?? h.kind,
            value: '${h.shown} shown',
            note: [
              '$answered answered${how.isEmpty ? '' : ' ($how)'}, ${h.ignored} left unanswered',
              if (h.medianAfter != null) 'answered after ${spanWords(h.medianAfter!)} (median)',
            ].join('; '),
          ),
        );
      }
      if (s.breakHints > 0) {
        out.add(MutedLine('A break came within 15 minutes after ${s.breaksAfter} of ${s.breakHints} break hints.'));
      }
      if (s.autoGuesses > 0) {
        out.add(MutedLine('Auto-start guessed night or work right ${s.autoRight} of ${s.autoGuesses} times you answered.'));
      }
    }
    if (s.smooth.isNotEmpty) {
      out.add(const SectionHeading('Smoothness'));
      for (final f in s.smooth.take(8)) {
        final share = f.frames == 0 ? 0.0 : f.janky / f.frames;
        final stutters = share >= 0.05;
        out.add(
          RecordRow(
            label: screenLabel(f.screen),
            value: stutters ? 'stutters' : 'smooth',
            valueColor: stutters ? Night.caution : Night.ink,
            note: '${(share * 100).toStringAsFixed(1)} % of ${f.frames} frames over 33 ms; the slowest ${f.worstMs} ms',
          ),
        );
      }
    }
    if (s.startups.isNotEmpty) {
      final sorted = [...s.startups]..sort();
      final median = sorted[sorted.length ~/ 2];
      out.add(const SectionHeading('Start-up'));
      out.add(
        RecordRow(
          label: 'From a tap on the icon to the first screen',
          value: '${(median / 1000).toStringAsFixed(1)} s',
          note: 'Median of ${sorted.length} starts; the slowest ${(sorted.last / 1000).toStringAsFixed(1)} s.',
        ),
      );
    }
    if (s.storage.isNotEmpty) {
      out.add(const SectionHeading('Storage'));
      for (final st in s.storage.take(10)) {
        final grow = st.perDay;
        out.add(
          RecordRow(
            label: st.category,
            value: sizeWords(st.bytes),
            note: grow == null ? null : (grow.abs() < 5e5 ? 'about the same each day' : '${grow > 0 ? '+' : '−'}${sizeWords(grow.abs())} a day'),
          ),
        );
      }
    }
    return out;
  }
}
