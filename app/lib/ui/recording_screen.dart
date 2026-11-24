// One recording of the Archive (DECISIONS 700-709): its files read in a background isolate (archive/detail.dart), the
// detectors' pass run in another when none is kept for its files as they are, your tags added, changed and removed
// (archive/tags.dart), the raw signal at a moment (raw_signal_screen.dart), and deleting it by the owner's rules (Remove
// from this phone with the laptop's checked copy; the Danger zone, twice confirmed). Pops true when anything changed.
// The pulse pass (pulse/pass.dart, DECISIONS 815) runs the same way after the detectors' pass, for the Pulse lane.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../archive/bands.dart';
import '../archive/delete.dart';
import '../archive/detail.dart';
import '../archive/items.dart';
import '../archive/raw_remover.dart' show OnLaptop;
import '../archive/seen.dart';
import '../archive/tags.dart';
import '../walking/pass.dart' show Walked, walkInBackground;
import '../pulse/pass.dart' show PulseResult, Pulsed, pulseInBackground;
import 'archive_screen.dart' show deleteInBackground, phoneArchiveBusy;
import 'archive_sheets.dart';
import 'evidence_sheet.dart' show showEvidence;
import 'raw_signal_screen.dart';
import 'recording_view.dart';

Future<RecordingDetail> _detailInBackground(String filesPath, ArchiveItem item, List<SessionFile> sessions) =>
    Isolate.run(() => loadDetail(Directory(filesPath), item, sessions), debugName: 'archive-detail');

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({
    super.key,
    required this.item,
    required this.filesPath,
    required this.all,
    this.detail,
    this.see,
    this.walk,
    this.pulse,
    this.busy,
    this.delete,
  });

  final ArchiveItem item;
  final String filesPath;

  /// The whole list: the sessions in its time, and which recording is the newest (in use while a night records).
  final List<ArchiveItem> all;

  /// Tests: without isolates.
  final Future<RecordingDetail> Function(String filesPath, ArchiveItem item, List<SessionFile> sessions)? detail;
  final Future<Seen> Function(String filesPath, String id, List<String> paths)? see;
  final Future<Walked> Function(String filesPath, String id, List<String> paths)? walk;

  /// Tests: the pulse pass without an isolate.
  final Future<Pulsed> Function(String filesPath, String id, List<String> paths)? pulse;
  final Future<ArchiveBusy> Function()? busy;
  final Future<DeleteOutcome> Function(String filesPath, ArchiveItem item, DeleteMode mode, List<ArchiveItem> all, ArchiveBusy busy)? delete;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late ArchiveItem _item = widget.item;
  RecordingDetail? _detail;
  TimelineInput? _input;
  bool _passing = false;
  String? _passWhy;
  PulseResult? _pulse;
  String? _pulseWhy;
  bool _changed = false;

  Directory get _files => Directory(widget.filesPath);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final sessions = [for (final i in widget.all) ...i.sessions];
    final d = await (widget.detail ?? _detailInBackground)(widget.filesPath, _item, sessions);
    if (!mounted) return;
    setState(() {
      _detail = d;
      _input = d.input;
      _passWhy = d.input.seenWhy;
      _pulse = d.pulse;
    });
    if (!d.passKept && d.input.seenWhy == null && d.rawPaths.isNotEmpty) await _pass(d.rawPaths);
    if (mounted && !d.walkKept && d.rawPaths.isNotEmpty) await _walk(d.rawPaths);
    if (mounted && !d.pulseKept && d.rawPaths.isNotEmpty) await _pulsePass(d.rawPaths);
  }

  /// The walking pass (walking/pass.dart) when none is kept for the files as they are; never on the night still being
  /// recorded.
  Future<void> _walk(List<String> paths) async {
    final b = await (widget.busy ?? phoneArchiveBusy)();
    if (!mounted || (b.nightRecording && _isNewest())) return;
    setState(() => _passing = true);
    Walked w;
    try {
      w = await (widget.walk ?? walkInBackground)(widget.filesPath, _item.id, paths);
    } catch (e) {
      w = (walk: null, why: 'Could not read it: $e');
    }
    if (!mounted) return;
    final i = _input!;
    setState(() {
      _passing = false;
      _input = TimelineInput(
        seen: i.seen,
        seenWhy: i.seenWhy,
        stages: i.stages,
        work: i.work,
        sessions: i.sessions,
        tags: i.tags,
        walk: w.walk ?? i.walk,
      );
    });
  }

  /// The pulse pass when none is kept for the files as they are; never on the night still being recorded.
  Future<void> _pulsePass(List<String> paths) async {
    final b = await (widget.busy ?? phoneArchiveBusy)();
    if (!mounted || (b.nightRecording && _isNewest())) return;
    setState(() => _passing = true);
    Pulsed p;
    try {
      p = await (widget.pulse ?? pulseInBackground)(widget.filesPath, _item.id, paths);
    } catch (e) {
      p = (pulse: null, why: 'Could not read it: $e');
    }
    if (!mounted) return;
    setState(() {
      _passing = false;
      _pulse = p.pulse ?? _pulse;
      _pulseWhy = p.why;
    });
  }

  Future<void> _pass(List<String> paths) async {
    final b = await (widget.busy ?? phoneArchiveBusy)();
    if (!mounted) return;
    if (b.nightRecording && _isNewest()) {
      setState(() => _passWhy = 'Waits until the night\'s Stop: it is still being recorded.');
      return;
    }
    setState(() => _passing = true);
    Seen s;
    try {
      s = await (widget.see ?? seeInBackground)(widget.filesPath, _item.id, paths);
    } catch (e) {
      s = (seen: null, why: 'Could not read it: $e');
    }
    if (!mounted) return;
    final i = _input!;
    setState(() {
      _passing = false;
      _passWhy = s.why;
      _input = TimelineInput(seen: s.seen, seenWhy: s.why, stages: i.stages, work: i.work, sessions: i.sessions, tags: i.tags, walk: i.walk);
    });
  }

  bool _isNewest() {
    final mine = widget.all.where((x) => x.folder == _item.folder).toList();
    return mine.isNotEmpty && mine.reduce((a, b) => b.end.isAfter(a.end) ? b : a).id == _item.id;
  }

  Timeline? get _timeline => _input == null ? null : timelineOf(_item, _input!);

  void _say(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void _signal(DateTime at) {
    final paths = _detail?.rawPaths ?? const <String>[];
    if (paths.isEmpty) return;
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RawSignalScreen(paths: paths, at: at))));
  }

  Future<void> _band(Band b) async {
    final a = await showBandSheet(context, b, hasSignal: _detail?.rawPaths.isNotEmpty ?? false);
    if (!mounted || a == null) return;
    switch (a) {
      case BandAction.signal:
        _signal(b.start);
      case BandAction.tag:
        await _editTag(start: b.start, end: b.end, label: _offered(b));
      case BandAction.edit:
        if (b.tag != null) await _editTag(tag: b.tag);
    }
  }

  /// The word a band's own tag starts with: what the band already says, when it is one of the usual words.
  static String? _offered(Band b) => switch (b.lane) {
    Lane.sleep => 'sleep',
    Lane.work => b.label == 'Break' ? 'rest' : 'work',
    Lane.meeting => 'meeting',
    Lane.sessions => b.label == 'Meditation' || b.label == 'Alpha-theta' ? 'meditation' : null,
    _ => null,
  };

  Future<void> _lane(Lane l) async {
    final tl = _timeline;
    if (tl == null) return;
    final b = await showLaneSheet(context, l, tl.of(l));
    if (b != null && mounted) await _band(b);
  }

  Future<void> _editTag({ManualTag? tag, DateTime? start, DateTime? end, String? label}) async {
    final i = _item;
    final e = await showTagEditor(
      context,
      within: (i.start, i.end.isAfter(i.start) ? i.end : i.start.add(const Duration(minutes: 1))),
      start: start ?? i.start,
      end: end ?? i.end,
      tag: tag,
      label: label,
    );
    if (e == null || !mounted) return;
    final store = TagStore(_files);
    final ok = e.remove
        ? store.remove(i.id, tag!)
        : (tag == null ? store.add(i.id, e.save!) : store.replace(i.id, tag, e.save!));
    if (!ok) {
      _say('The tag could not be saved: the tags file is damaged or the phone is full.');
      return;
    }
    _changed = true;
    final file = store.read(i.id);
    setState(() {
      _item = ArchiveItem(
        id: i.id,
        kind: i.kind,
        start: i.start,
        end: i.end,
        started: i.started,
        sets: i.sets,
        sessions: i.sessions,
        report: i.report,
        tags: file,
        tagsBytes: store.fileFor(i.id).existsSync() ? store.fileFor(i.id).lengthSync() : 0,
        copied: i.copied,
        laptop: i.laptop,
      );
      final x = _input;
      if (x != null) {
        _input = TimelineInput(
          seen: x.seen,
          seenWhy: x.seenWhy,
          stages: x.stages,
          work: x.work,
          sessions: x.sessions,
          tags: file?.tags ?? const [],
          walk: x.walk,
        );
      }
    });
  }

  Future<void> _delete(DeleteMode mode) async {
    final busy = await (widget.busy ?? phoneArchiveBusy)();
    if (!mounted) return;
    final why = whyInUse(_files, _item, widget.all, busy, DateTime.now());
    if (why != null) {
      _say(why);
      return;
    }
    final out = await (widget.delete ?? deleteInBackground)(widget.filesPath, _item, mode, widget.all, busy);
    if (!mounted) return;
    _say(deleteWords(out));
    if (out.freedBytes > 0 || out.complete) Navigator.of(context).pop(true);
  }

  Future<void> _remove() async {
    if (await confirmRemove(context, [_item]) && mounted) await _delete(DeleteMode.rawOnLaptop);
  }

  Future<void> _danger() async {
    final m = await confirmDanger(context, [_item], name: 'this ${_item.kind.word.toLowerCase()}');
    if (m != null && mounted) await _delete(m);
  }

  @override
  Widget build(BuildContext context) {
    final i = _item;
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: RecordingView(
        model: RecordingViewModel(
          item: i,
          timeline: _timeline,
          passRunning: _passing,
          passWhy: _passWhy,
          loading: _detail == null,
          pulse: _pulse,
          pulseWhy: _pulseWhy,
        ),
        onPulseInfo: () => showEvidence(context, 'pulse'),
        onBand: _band,
        onTime: _signal,
        onLane: _lane,
        onAddTag: () => _editTag(),
        onTag: (t) => _editTag(tag: t),
        onRemove: i.hasRaw && i.laptop == OnLaptop.yes ? _remove : null,
        onDanger: _danger,
        onSignal: () => _signal(i.start),
      ),
    );
  }
}
