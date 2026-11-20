// The app log page (More > App log; DECISIONS 712): the last 7 days of every subsystem's lines, newest first, by
// level and subsystem, a line opened for its facts, error and stack; Copy what is shown, Share the log files (the
// system's share sheet), Delete. The whole folder also leaves the phone with Export data and Share on Wi-Fi.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../logs/files.dart';
import '../logs/log.dart' show AppLog;
import '../logs/read.dart';
import '../phone.dart';
import 'records_parts.dart';
import 'theme.dart';

/// Lines shown at most (the newest); Copy takes what is shown.
const int logPageLines = 1500;

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, this.recordingsDir, this.share});

  /// The app's recordings folder when the caller knows it.
  final String? recordingsDir;

  /// Tests: what Share would send.
  final Future<void> Function(List<File> files)? share;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<LogLine>? _all;
  String? _error;
  Directory? _dir;
  String _level = 'fine';
  final Set<String> _subs = {};
  final Set<LogLine> _open = {};
  Map<LogKind, ({int files, int bytes})> _sizes = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rec = widget.recordingsDir ?? await Phone.recordingsDir();
      if (rec == null) throw StateError("the app's folder is not known");
      final dir = logsDirFor(rec);
      final now = DateTime.now();
      final r = await appLogInBackground(dir, now);
      if (!mounted) return;
      setState(() {
        _dir = dir;
        _all = r.lines;
        _sizes = r.sizes;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<LogLine> get _shown {
    final f = filterLog(_all ?? const [], minLevel: _level, subs: _subs);
    return f.length <= logPageLines ? f : f.sublist(0, logPageLines);
  }

  Future<void> _copy() async {
    final lines = _shown;
    await Clipboard.setData(ClipboardData(text: [for (final l in lines) l.toText()].join('\n')));
    _say('${lines.length} lines copied');
  }

  Future<void> _share() async {
    final dir = _dir;
    if (dir == null) return;
    final cutoff = logDay(DateTime.now().subtract(const Duration(days: 2)));
    final files = [
      for (final f in logFiles(dir, kind: LogKind.app))
        if (parseLogFileName(f.uri.pathSegments.last)!.day.compareTo(cutoff) >= 0) f,
    ];
    if (files.isEmpty) return _say('Nothing logged in the last 3 days');
    try {
      if (widget.share != null) {
        await widget.share!(files);
      } else {
        await SharePlus.instance.share(
          ShareParams(files: [for (final f in files) XFile(f.path, mimeType: 'application/json')], subject: 'EEG Tracker log'),
        );
      }
    } catch (e) {
      _say('Could not share: $e');
    }
  }

  Future<void> _delete() async {
    final dir = _dir;
    if (dir == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the app log?'),
        content: const Text(
          'Every line of the app log on this phone goes. Copies on the laptop stay. How you use the app and the battery '
          'numbers are kept (their own pages delete them).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    final n = deleteLogs(dir, {LogKind.app});
    _say(n == 1 ? '1 file deleted' : '$n files deleted');
    AppLog('app').info('the app log was deleted on the log page');
    await _load();
  }

  void _say(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    return Scaffold(
      appBar: AppBar(title: const Text('App log')),
      body: all == null ? recordsWaiting(context, _error) : _body(context, all),
      bottomNavigationBar: all == null || all.isEmpty
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: OutlinedButton.icon(
                        onPressed: _copy,
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Copy'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: FilledButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.share_outlined),
                        label: const Text('Share the log'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _body(BuildContext context, List<LogLine> all) {
    final text = Theme.of(context).textTheme;
    final errors = all.where((l) => l.level == 'error').length, warns = all.where((l) => l.level == 'warn').length;
    final subs = logSubsystems(all);
    final shown = _shown;
    final kept = _sizes[LogKind.app];
    final children = <Widget>[
      Text(
        all.isEmpty
            ? 'Nothing logged yet.'
            : '${all.length} lines in 7 days: ${errors == 1 ? '1 error' : '$errors errors'}, '
                  '${warns == 1 ? '1 warning' : '$warns warnings'}.',
        style: text.titleLarge,
      ),
      MutedLine(
        all.isEmpty
            ? 'The app writes here as it works: starts, nights, the headband\'s link, sessions, scoring, errors.'
            : 'Kept 7 days and at most 20 MB, on this phone only${kept == null ? '' : ' (${sizeWords(kept.bytes)} now)'}. '
                  'Export data and Share on Wi-Fi take it to the laptop with everything else.',
      ),
      if (all.isNotEmpty) ...[
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: choiceStyle,
            segments: const [
              ButtonSegment(value: 'fine', label: Text('All')),
              ButtonSegment(value: 'warn', label: Text('Problems')),
              ButtonSegment(value: 'error', label: Text('Errors')),
            ],
            selected: {_level},
            onSelectionChanged: (s) => setState(() => _level = s.first),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (sub, n) in subs)
              RecordChip(
                label: '$sub $n',
                selected: _subs.contains(sub),
                onSelected: (on) => setState(() => on ? _subs.add(sub) : _subs.remove(sub)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty) const MutedLine('No line matches: choose another level or part of the app.'),
        ..._lines(context, shown),
        if (shown.length == logPageLines) const MutedLine('The newest $logPageLines lines; Share sends them all.'),
      ],
      const SizedBox(height: 24),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(onPressed: all.isEmpty ? null : _delete, child: const Text('Delete the app log')),
      ),
    ];
    return ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), children: children);
  }

  List<Widget> _lines(BuildContext context, List<LogLine> lines) {
    final out = <Widget>[];
    String? day;
    for (final l in lines) {
      final d = logDay(l.t);
      if (d != day) {
        day = d;
        out.add(_DayRule(_dayWords(l.t)));
      }
      out.add(
        _LogEntry(
          line: l,
          open: _open.contains(l),
          onTap: () => setState(() => _open.contains(l) ? _open.remove(l) : _open.add(l)),
        ),
      );
    }
    return out;
  }
}

String _dayWords(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final ago = today.difference(day).inDays;
  if (ago == 0) return 'Today';
  if (ago == 1) return 'Yesterday';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]}';
}

class _DayRule extends StatelessWidget {
  const _DayRule(this.words);
  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 10),
        Text(words, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Night.inkMuted)),
      ],
    ),
  );
}

/// One line: the time in tabular figures, the level as a word (amber or red with the word), the part of the app,
/// the message; tapped, its facts, error and stack as selectable muted text.
class _LogEntry extends StatelessWidget {
  const _LogEntry({required this.line, required this.open, required this.onTap});
  final LogLine line;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final l = line;
    final color = switch (l.level) {
      'error' => Night.problem,
      'warn' => Night.caution,
      _ => Night.inkMuted,
    };
    final time = logTime(l.t).substring(11, 19);
    final more = open && (l.data != null || l.error != null || l.stack != null || l.screen != null);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(time, style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
                const SizedBox(width: 10),
                Text(l.level == 'warn' ? 'warning' : l.level, style: text.bodyMedium?.copyWith(color: color)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l.engine == 'screen' || l.engine == l.sub ? l.sub : '${l.sub} · ${l.engine}',
                    style: text.bodyMedium?.copyWith(color: Night.inkMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              l.error == null || open ? l.msg : '${l.msg}: ${l.error}',
              style: text.bodyLarge?.copyWith(height: 1.35),
              maxLines: open ? null : 3,
              overflow: open ? null : TextOverflow.ellipsis,
            ),
            if (more)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(
                  [
                    if (l.screen != null) 'on ${l.screen}',
                    if (l.data != null) l.data!.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
                    if (l.error != null) 'error: ${l.error}',
                    ?l.stack,
                  ].join('\n'),
                  style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35, fontFeatures: tabular),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
