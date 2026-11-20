// The trends page (ROADMAP row 10; DECISIONS rows 120-129): reads the phone's own sleep reports, check-ins,
// practice reports and sharp-hours answers (rows 280-289) and lays them out with trends_view.dart. Opened from the night screen's Morning section and
// from a check-in's result. The files are read and the page worked out in a background isolate (DECISIONS 620-629).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../meditation/store.dart';
import '../morning/store.dart';
import '../phone.dart';
import '../training/control.dart' show SessionKind;
import '../sharp/page.dart' show sharpTrendsLine;
import '../sharp/store.dart';
import '../trends/trends.dart';
import '../unusual/card.dart';
import '../unusual/store.dart';
import '../sleep/report.dart' show NightReportStore, nightsDirFor;
import '../archive/page.dart' show loadArchiveInBackground;
import '../walking/days.dart';
import '../walking/pass.dart' show walkInBackground;
import '../walking/detector.dart' show CheckStatus;
import '../wearer/check.dart' show answerSomeoneElse;
import '../wearer/wearer.dart' show ownNightReports;
import 'archive_screen.dart' show phoneArchiveBusy;
import 'evidence_sheet.dart';
import '../study/arm.dart' show readOwnDayNumbers;
import 'experiments_screen.dart';
import 'experiments_view.dart' show experimentLine;
import 'sharp_hours_screen.dart';
import 'trends_view.dart';
import 'unusual_view.dart';

/// Everything the trends need, read from the app's folders (a missing folder is simply empty). Nights and check-ins
/// the owner said someone else wore the headband for are left out ("Was this you?", DECISIONS 377): the trends,
/// the unusual card, the experiments and the check-in's own result all read them through here (Sharp hours reads
/// the same nights through [ownNightReports]).
TrendInputs readTrendInputs(String recordingsDir) => (
  nights: ownNightReports(recordingsDir),
  mornings: [
    for (final m in MorningStore(morningsDirFor(recordingsDir)).list())
      if (m.wearerAnswer != answerSomeoneElse) m,
  ],
  sessions: [
    ...MeditationStore(meditationsDirFor(recordingsDir)).list(),
    ...MeditationStore(sessionsDirFor(recordingsDir, SessionKind.alphaTheta), kind: SessionKind.alphaTheta).list(),
  ],
);

/// The time of every night the owner said someone else wore the headband for: its walking is left out too.
List<(DateTime, DateTime)> someoneElseSpans(String recordingsDir) => [
  for (final r in NightReportStore(nightsDirFor(recordingsDir)).all())
    if (r.wearerAnswer == answerSomeoneElse) (r.dataStart, r.dataEnd),
];

/// The steps row's note: where the newest day's steps came from and how the headband's estimate stands against the
/// phone's step counter (DECISIONS 800-809).
String walkStepsLine(WalkDays w) {
  final c = w.check;
  final days = w.steps.keys.toList()..sort();
  final from = days.isEmpty ? '' : 'From ${w.sourceOf(days.last)}. ';
  return switch (c.status) {
    CheckStatus.unchecked =>
      '${from}Your phone\'s own count where it counted, else estimated from the headband\'s step rhythm. Not yet '
          'checked against your phone: that needs 10 minutes walked with both (so far ${c.paired}).',
    CheckStatus.passed =>
      '${from}Your phone\'s own count where it counted, else estimated from the headband\'s step rhythm, whose pace '
          'matched your phone in ${c.right} of ${c.paired} minutes walked with both.',
    CheckStatus.failed =>
      '${from}Your phone\'s own count only: the headband\'s estimate matched your phone\'s pace in ${c.right} of '
          '${c.paired} minutes walked with both, too few to trust it, so it is left out. Walking minutes still show.',
  };
}

/// Today's "Unusual for you" card from the app's folders; while it is on, the back-test log gets the finished days
/// it does not have yet (DECISIONS 290-299). Also run off the night screen's thread for its one line. Switched off,
/// nothing else is read (DECISIONS row 586: every start and return read every night's report for nothing).
UnusualCard unusualToday(String recordingsDir, DateTime now) {
  final store = UnusualStore(unusualDirFor(recordingsDir));
  if (!store.on) return offCard;
  return refreshUnusual(
    store,
    dailySeries(readTrendInputs(recordingsDir), extra: readOwnDayNumbers(recordingsDir)),
    now,
  );
}

/// What the Trends page shows, read and worked out together.
typedef TrendsPage = ({
  TrendsModel model,
  String? experiment,
  UnusualCard? unusual,
  String? unusualError,
  String? sharp,
});

/// Reads the app's folders beside [recordingsDir] and works the page out (the unusual card also gets the back-test
/// lines it lacks). Run in a background isolate ([trendsInBackground]): it reads every report, check-in, practice and
/// work session, and the screen's thread froze while it did (DECISIONS 586, 620-629).
TrendsPage loadTrendsPage(String recordingsDir, DateTime now) {
  final inputs = readTrendInputs(recordingsDir);
  final dayNumbers = readOwnDayNumbers(recordingsDir);
  final walk = readWalkDays(recordingsDir, notMine: someoneElseSpans(recordingsDir));
  final m = buildTrends(
    inputs,
    now,
    extra: {...dayNumbers, 'walk_min': walk.minutes, 'walk_steps': walk.steps},
    notes: {'walk_steps': walkStepsLine(walk)},
  );
  final line = experimentLine(currentExperiment(recordingsDir, now));
  UnusualCard? unusual;
  String? unusualError;
  try {
    unusual = refreshUnusual(UnusualStore(unusualDirFor(recordingsDir)), dailySeries(inputs, extra: dayNumbers), now);
  } catch (e) {
    unusualError = '$e'; // the card is never worth breaking the trends
  }
  final sharp = SharpStore(sharpDirFor(recordingsDir));
  final sharpLine = sharpTrendsLine(sharp.settings(), sharp.ratings(), sharp.reactions(), now);
  return (model: m, experiment: line, unusual: unusual, unusualError: unusualError, sharp: sharpLine);
}

/// [loadTrendsPage] in a background isolate.
Future<TrendsPage> trendsInBackground(String recordingsDir, DateTime now) =>
    Isolate.run(() => loadTrendsPage(recordingsDir, now), debugName: 'trends');

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key, this.recordingsDir, this.walkPending = false});

  /// The app's recordings folder when the caller knows it.
  final String? recordingsDir;

  /// Runs the walking passes the recordings still need (the app's own pages; off in tests).
  final bool walkPending;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  TrendsModel? _model;
  String? _error, _dir, _experiment, _unusualError, _sharp;
  UnusualCard? _unusual;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool walk = true}) async {
    try {
      final dir = widget.recordingsDir ?? await Phone.recordingsDir();
      if (dir == null) throw StateError("the app's folder is not known");
      final p = await trendsInBackground(dir, DateTime.now());
      if (!mounted) return;
      setState(() {
        _model = p.model;
        _dir = dir;
        _experiment = p.experiment;
        _unusual = p.unusual;
        _unusualError = p.unusualError;
        _sharp = p.sharp;
      });
      if (walk && widget.walkPending) unawaited(_walkPending(dir));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Recordings without a current walking pass get one here too, as in the Archive (DECISIONS 800-809): one at a time
  /// in a background isolate, never while a night records, a session runs or the sleep scoring runs; the page is read
  /// again once they are done.
  Future<void> _walkPending(String dir) async {
    final files = Directory(dir).parent.path;
    try {
      final b = await phoneArchiveBusy();
      if (!mounted || b.nightRecording || b.sessionRunning || b.scoring) return;
      final page = await loadArchiveInBackground(files);
      if (page.toWalk.isEmpty) return;
      for (final id in page.toWalk) {
        if (!mounted) return;
        final item = page.list.items.where((i) => i.id == id).firstOrNull;
        if (item == null) continue;
        await walkInBackground(files, id, [for (final f in item.rawFiles(Directory(files))) f.path]);
      }
      if (mounted) await _load(walk: false);
    } catch (_) {
      // the trends stand without the walking; the Archive tries again
    }
  }

  UnusualStore _unusualStore(String dir) => UnusualStore(unusualDirFor(dir));

  /// A change to the card's files, then the page again; a failed write is said in a snackbar.
  Future<void> _change(void Function(UnusualStore store, DateTime now) write) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      write(_unusualStore(dir), DateTime.now());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not saved: $e')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _model;
    if (m != null) {
      final card = _unusual;
      return TrendsView(
        model: m,
        unusual: UnusualSection(
          card: card,
          error: _unusualError,
          onInfo: () => showEvidence(context, 'unusual-for-you'),
          onSwitch: (on) => unawaited(_change((s, now) => s.setOn(on, now))),
          onCauses: card?.episode == null
              ? null
              : (causes) => unawaited(_change((s, now) => s.setCauses(card!.episode!, causes, now))),
          onResume: () => unawaited(_change((s, now) => s.resume(now))),
        ),
        onInfo: () => showEvidence(context, 'trends'),
        experimentLine: _experiment,
        onExperiments: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => ExperimentsScreen(recordingsDir: _dir)));
          await _load();
        },
        sharpLine: _sharp,
        onSharp: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => SharpHoursScreen(recordingsDir: _dir)));
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
