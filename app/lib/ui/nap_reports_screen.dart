// The nap reports (Record first step 4, DECISIONS 985). A nap is a sleep stretch of kind `nap` on a recording (the
// Nap coach's, or one you confirmed as a nap); its report is scored like a night's but kept apart, in
// `files/nights/naps/<stamp of its start>.report.json`, so it never joins a night or the trends' night rows. This page
// lists them newest first; a tap opens the same report page a night has.
import 'dart:io';

import 'package:flutter/material.dart';

import '../sleep/report.dart';
import 'evidence_sheet.dart';
import 'form_parts.dart' show Para;
import 'sleep_report_view.dart';
import 'theme.dart';

class NapReport {
  const NapReport(this.stamp, this.report);

  /// The stamp of the nap's start (`2026-11-21-130000`), its file's name.
  final String stamp;
  final SleepReport report;

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String get _day {
    final t = report.dataStart;
    return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
  }

  /// The page's title for this nap.
  String get title => 'Nap, $_day ${_hm(report.dataStart)}';

  /// One line: when, and how long asleep.
  String get line {
    final when = '$_day ${_hm(report.dataStart)}-${_hm(report.dataEnd)}';
    if (!report.scored) return '$when · not scored yet';
    final asleep = report.asleepMin;
    return asleep < noSleepFoundBelowMin ? '$when · no sleep found' : '$when · asleep ${asleep.round()} min';
  }
}

/// Every nap report under [nightsDir] (`files/nights`), newest first.
List<NapReport> napReports(Directory nightsDir) {
  final dir = Directory('${nightsDir.path}/naps');
  if (!dir.existsSync()) return const [];
  final out = <NapReport>[];
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.report.json')) continue;
    final r = SleepReport.read(f);
    if (r != null) out.add(NapReport(name.substring(0, name.length - '.report.json'.length), r));
  }
  return out..sort((a, b) => b.stamp.compareTo(a.stamp));
}

/// The Sessions tab's line about them; null when there is none.
String? napsLine(List<NapReport> naps) =>
    naps.isEmpty ? null : '${naps.length} nap report${naps.length == 1 ? '' : 's'}. Last: ${naps.first.line}';

const String napReportsEmpty =
    'No nap reports yet. One is made when a nap ends: start the Nap coach (or Nap on the Record tab) while the '
    'headband records, or answer Yes when the app asks whether you napped.';

class NapReportsView extends StatelessWidget {
  const NapReportsView({super.key, required this.naps, required this.onOpen, this.onInfo});
  final List<NapReport> naps;
  final void Function(NapReport nap) onOpen;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Nap reports', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [IconButton(onPressed: onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          Para(
            'A nap is scored like a night but kept apart: it never joins a night or the trends. Under '
            '${noSleepFoundBelowMin.round()} minutes asleep it says "no sleep found".',
            color: Night.inkMuted,
          ),
          if (naps.isEmpty) const Para(napReportsEmpty, top: 16),
          for (final n in naps)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(n.line, style: text.bodyLarge),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen(n),
            ),
        ],
      ),
    );
  }
}

class NapReportsScreen extends StatelessWidget {
  const NapReportsScreen({super.key, required this.nightsDir});
  final Directory nightsDir;

  @override
  Widget build(BuildContext context) => NapReportsView(
    naps: napReports(nightsDir),
    onInfo: () => showEvidence(context, 'record-first'),
    onOpen: (n) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (c) => SleepReportView(
          nightOf: n.report.nightOf,
          report: n.report,
          title: n.title,
          onInfo: () => showEvidence(c, 'sleep-scoring'),
          onLicences: () => showLicensePage(context: c, applicationName: 'EEG Tracker'),
        ),
      ),
    ),
  );
}
