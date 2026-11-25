// The nap reports' page (lib/ui/nap_reports_screen.dart; Record first step 4, DECISIONS 985): a nap's report lives in
// `files/nights/naps/<stamp>.report.json`, never among the nights, and this page lists and opens them.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/sleep/model.dart' show phoneModelId;
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/ui/nap_reports_screen.dart';
import 'package:eeg_tracker/ui/sleep_report_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A nap's report as the scorer writes it: 35 minutes from [start], [asleepMin] of them asleep ([scored] false: the
/// report of a nap whose scoring has not run yet).
Map<String, dynamic> _nap(DateTime start, double asleepMin, {bool scored = true}) {
  final asleep = (asleepMin * 2).round();
  final stages = [for (var i = 0; i < 70; i++) i >= 10 && i < 10 + asleep ? 'N2' : 'W'];
  final j = (jsonDecode(
            jsonEncode(
              buildReport(
                nightOf: '2026-11-21',
                built: start.add(const Duration(minutes: 40)),
                scoringSeconds: 12,
                start: start,
                lengthSeconds: 35 * 60,
                inputs: const {'2026-11-21-110200.f32': 1000},
                model: phoneModelId,
                stages: scored ? stages : null,
                confidence: scored ? List.filled(stages.length, 0.8) : null,
              ),
            ),
          )
          as Map)
      .cast<String, dynamic>();
  j['span'] = {
    'recording': ['2026-11-21-110200'],
    'spans': ['2026-11-21-110200-2'],
    'kind': 'nap',
    'from': 'pressed',
  };
  return j;
}

void main() {
  late Directory files;
  setUp(() => files = Directory.systemTemp.createTempSync('nap-reports'));
  tearDown(() => files.deleteSync(recursive: true));

  void write(String stamp, Map<String, dynamic> j) {
    final f = File('${files.path}/nights/naps/$stamp.report.json')..parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(j));
  }

  test('the naps are listed newest first, apart from the nights; each line says when and how long asleep', () {
    File('${files.path}/nights/2026-11-18.report.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(_nap(DateTime(2026, 11, 18, 23), 30))); // a night's report: not a nap
    write('2026-11-21-130000', _nap(DateTime(2026, 11, 21, 13), 22));
    write('2026-11-23-151000', _nap(DateTime(2026, 11, 23, 15, 10), 0));
    write('2026-11-24-140000', _nap(DateTime(2026, 11, 24, 14), 0, scored: false));
    final naps = napReports(Directory('${files.path}/nights'));
    expect([for (final n in naps) n.stamp], ['2026-11-24-140000', '2026-11-23-151000', '2026-11-21-130000']);
    expect(naps[2].line, 'Sat 21 Nov 13:00-13:35 · asleep 22 min');
    expect(naps[1].line, 'Mon 23 Nov 15:10-15:45 · no sleep found');
    expect(naps[0].line, 'Tue 24 Nov 14:00-14:35 · not scored yet');
    expect(napReports(Directory('${files.path}/nowhere')), isEmpty);
    expect(napsLine(naps), '3 nap reports. Last: Tue 24 Nov 14:00-14:35 · not scored yet');
    expect(napsLine(const []), isNull);
  });

  testWidgets('the page lists the naps and opens one as a report titled as a nap', (tester) async {
    write('2026-11-21-130000', _nap(DateTime(2026, 11, 21, 13), 22));
    final naps = napReports(Directory('${files.path}/nights'));
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: NapReportsView(naps: naps, onOpen: (_) {})));
    expect(find.text('Nap reports'), findsOneWidget);
    expect(find.text('Sat 21 Nov 13:00-13:35 · asleep 22 min'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(theme: nightTheme(), home: SleepReportView(nightOf: naps.single.report.nightOf, report: naps.single.report, title: naps.single.title)),
    );
    expect(find.text('Nap, Sat 21 Nov 13:00'), findsOneWidget);
    expect(find.textContaining('Night of'), findsNothing);
  });

  test('an empty page says how a nap report comes to be', () {
    expect(napReportsEmpty, contains('Nap'));
  });

  test('NightReportStore on the naps folder reads the same files', () {
    write('2026-11-21-130000', _nap(DateTime(2026, 11, 21, 13), 22));
    expect(NightReportStore(Directory('${files.path}/nights/naps')).all(), hasLength(1));
  });
}
