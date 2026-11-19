// The trends page (ROADMAP row 10; DECISIONS rows 120-129): reads the phone's own sleep reports, check-ins,
// practice reports and sharp-hours answers (rows 280-289) and lays them out with trends_view.dart. Opened from the night screen's Morning section and
// from a check-in's result.
import 'dart:async';

import 'package:flutter/material.dart';

import '../meditation/store.dart';
import '../morning/store.dart';
import '../phone.dart';
import '../sleep/report.dart';
import '../training/control.dart' show SessionKind;
import '../sharp/page.dart' show sharpTrendsLine;
import '../sharp/store.dart';
import '../trends/trends.dart';
import 'evidence_sheet.dart';
import 'experiments_screen.dart';
import 'experiments_view.dart' show experimentLine;
import 'sharp_hours_screen.dart';
import 'trends_view.dart';

/// Everything the trends need, read from the app's folders (a missing folder is simply empty).
TrendInputs readTrendInputs(String recordingsDir) => (
  nights: NightReportStore(nightsDirFor(recordingsDir)).all(),
  mornings: MorningStore(morningsDirFor(recordingsDir)).list(),
  sessions: [
    ...MeditationStore(meditationsDirFor(recordingsDir)).list(),
    ...MeditationStore(sessionsDirFor(recordingsDir, SessionKind.alphaTheta), kind: SessionKind.alphaTheta).list(),
  ],
);

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key, this.recordingsDir});

  /// The app's recordings folder when the caller knows it.
  final String? recordingsDir;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  TrendsModel? _model;
  String? _error, _dir, _experiment, _sharp;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final dir = widget.recordingsDir ?? await Phone.recordingsDir();
      if (dir == null) throw StateError("the app's folder is not known");
      final now = DateTime.now();
      final m = buildTrends(readTrendInputs(dir), now, extra: readSharpDayNumbers(dir));
      final line = experimentLine(currentExperiment(dir, now));
      final sharp = SharpStore(sharpDirFor(dir));
      final sharpLine = sharpTrendsLine(sharp.settings(), sharp.ratings(), sharp.reactions(), now);
      if (!mounted) return;
      setState(() {
        _model = m;
        _dir = dir;
        _experiment = line;
        _sharp = sharpLine;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _model;
    if (m != null) {
      return TrendsView(
        model: m,
        onInfo: () => showEvidence(context, 'trends'),
        experimentLine: _experiment,
        onExperiments: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExperimentsScreen(recordingsDir: _dir)));
          await _load();
        },
        sharpLine: _sharp,
        onSharp: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SharpHoursScreen(recordingsDir: _dir)));
          await _load();
        },
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Trends')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error == null ? 'Reading your days…' : 'The trends could not be read: $_error'),
      ),
    );
  }
}
