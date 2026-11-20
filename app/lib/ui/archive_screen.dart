// The Archive page (owner, 2026-11-20; DECISIONS 700-709): opened from More. The list is read in a background isolate
// (archive/page.dart, kept per file like the nights' list), and while the page is open the recordings without activity
// tags get their detectors' pass, one at a time, newest first, each in a background isolate; it waits while a night, a
// session or the sleep scoring runs; then the pulse pass the same way (pulse/pass.dart, DECISIONS 815). A day's menu
// removes what the laptop holds, or deletes the day (the Danger zone).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../archive/delete.dart';
import '../archive/items.dart';
import '../archive/page.dart';
import '../archive/raw_remover.dart';
import '../archive/seen.dart' as seen;
import '../walking/pass.dart' as walking;
import '../pulse/pass.dart' as pulses;
import '../phone.dart';
import '../session_keeper.dart' show PhoneSessionKeeper;
import 'archive_sheets.dart';
import 'archive_view.dart';
import 'dream_screen.dart' show dreamSessionRunning;
import 'nap_screen.dart' show napSessionRunning;
import 'recording_screen.dart';
import 'sleep_scoring.dart' show nightScoringBusy;
import 'states_screen.dart' show soundSessionRunning;
import 'work_screen.dart' show workSessionRunning;

/// What records or reads recordings now, on this phone.
Future<ArchiveBusy> phoneArchiveBusy() async {
  var night = false;
  try {
    night = await FlutterForegroundTask.isRunningService;
  } catch (_) {
    night = false;
  }
  return ArchiveBusy(
    nightRecording: night,
    sessionRunning: dreamSessionRunning || soundSessionRunning || napSessionRunning || workSessionRunning || PhoneSessionKeeper.held,
    scoring: nightScoringBusy,
  );
}

Future<seen.Seen> _seeInBackground(String filesPath, String id, List<String> paths) =>
    seen.seeInBackground(filesPath, id, paths);

/// [deleteItem] off the screen's thread (a top-level function: only plain data crosses).
Future<DeleteOutcome> deleteInBackground(String filesPath, ArchiveItem item, DeleteMode mode, List<ArchiveItem> all, ArchiveBusy busy) =>
    Isolate.run(() {
      final dir = Directory(filesPath);
      return deleteItem(dir, item, mode, all: all, remover: PhoneRawRemover(dir), busy: busy);
    }, debugName: 'archive-delete');

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({
    super.key,
    this.filesPath,
    this.load,
    this.see,
    this.walk,
    this.pulse,
    this.busy,
    this.delete,
    this.now,
    this.onStorage,
  });

  /// Tests: the app's `files/`; null: the phone's.
  final String? filesPath;
  final Future<ArchivePage> Function(String filesPath)? load;
  final Future<seen.Seen> Function(String filesPath, String id, List<String> paths)? see;

  /// Tests: the walking pass (walking/pass.dart) without an isolate.
  final Future<walking.Walked> Function(String filesPath, String id, List<String> paths)? walk;
  /// Tests: the pulse pass without an isolate.
  final Future<pulses.Pulsed> Function(String filesPath, String id, List<String> paths)? pulse;
  final Future<ArchiveBusy> Function()? busy;
  final Future<DeleteOutcome> Function(String filesPath, ArchiveItem item, DeleteMode mode, List<ArchiveItem> all, ArchiveBusy busy)? delete;
  final DateTime Function()? now;

  /// Opens the Storage page (what the app keeps by kind of data; DECISIONS 690-699, 709); null: no link.
  final VoidCallback? onStorage;

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  String? _files;
  ArchivePage? _page;
  bool _loading = true;
  String? _error;
  KindGroup? _filter;
  String? _seeing;
  bool _passing = true;
  bool _open = true;
  Timer? _retry;

  DateTime _now() => widget.now?.call() ?? DateTime.now();
  Future<ArchiveBusy> _busy() => (widget.busy ?? phoneArchiveBusy)();

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _open = false;
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final files = _files ??= widget.filesPath ?? Directory((await Phone.recordingsDir())!).parent.path;
      final page = await (widget.load ?? loadArchiveInBackground)(files);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
        _error = null;
      });
      unawaited(_seeNext());
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// One recording's detectors' pass, then the next, while the page is in front and nothing records; then the walking
  /// passes the same way (DECISIONS 800-809), then the pulse passes (DECISIONS 810-819).
  Future<void> _seeNext() async {
    final page = _page, files = _files;
    if (!_open || _seeing != null || page == null || files == null) return;
    if (page.toSee.isEmpty && page.toWalk.isEmpty && page.toPulse.isEmpty) return;
    final b = await _busy();
    if (!mounted) return;
    final front = ModalRoute.of(context)?.isCurrent ?? true;
    if (b.nightRecording || b.sessionRunning || b.scoring || !front) {
      setState(() => _passing = false);
      _retry?.cancel();
      _retry = Timer(const Duration(minutes: 1), () => unawaited(_seeNext()));
      return;
    }
    if (page.toSee.isEmpty) return page.toWalk.isNotEmpty ? _walkNext(page, files) : _pulseNext(page, files);
    final id = page.toSee.first;
    final item = page.list.items.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    setState(() {
      _passing = true;
      _seeing = id;
    });
    seen.Seen result;
    try {
      result = await (widget.see ?? _seeInBackground)(files, id, [for (final f in item.rawFiles(Directory(files))) f.path]);
    } catch (e) {
      result = (seen: null, why: 'Could not read it: $e');
    }
    if (!mounted) return;
    final p = _page!;
    setState(() {
      _seeing = null;
      _page = ArchivePage(
        p.list,
        found: {...p.found, if (result.seen != null) id: {...seen.seenMinutes(result.seen!), ...?p.found[id]}},
        why: {...p.why, if (result.why != null) id: result.why!},
        toSee: [for (final x in p.toSee) if (x != id) x],
        toWalk: p.toWalk,
        toPulse: p.toPulse,
      );
    });
    unawaited(_seeNext());
  }

  /// One recording's walking pass (the busy checks done), then the next.
  Future<void> _walkNext(ArchivePage page, String files) async {
    final id = page.toWalk.first;
    final item = page.list.items.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    setState(() {
      _passing = true;
      _seeing = id;
    });
    walking.Walked result;
    try {
      result = await (widget.walk ?? walking.walkInBackground)(files, id, [
        for (final f in item.rawFiles(Directory(files))) f.path,
      ]);
    } catch (e) {
      result = (walk: null, why: 'Could not read it: $e');
    }
    if (!mounted) return;
    final p = _page!;
    final minutes = result.walk?.walkingMin ?? 0;
    setState(() {
      _seeing = null;
      _page = ArchivePage(
        p.list,
        found: {...p.found, if (minutes > 0) id: {...?p.found[id], 'walking': minutes}},
        why: p.why,
        toSee: p.toSee,
        toWalk: [for (final x in p.toWalk) if (x != id) x],
        toPulse: p.toPulse,
      );
    });
    unawaited(_seeNext());
  }

  /// One recording's pulse pass (the busy checks done), then the next.
  Future<void> _pulseNext(ArchivePage page, String files) async {
    final id = page.toPulse.first;
    final item = page.list.items.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    setState(() {
      _passing = true;
      _seeing = id;
    });
    try {
      await (widget.pulse ?? pulses.pulseInBackground)(files, id, [for (final f in item.rawFiles(Directory(files))) f.path]);
    } catch (_) {
      // tried again the next time the page opens
    }
    if (!mounted) return;
    final p = _page!;
    setState(() {
      _seeing = null;
      _page = ArchivePage(
        p.list,
        found: p.found,
        why: p.why,
        toSee: p.toSee,
        toWalk: p.toWalk,
        toPulse: [for (final x in p.toPulse) if (x != id) x],
      );
    });
    unawaited(_seeNext());
  }

  Future<void> _openItem(ArchiveItem item) async {
    final files = _files, page = _page;
    if (files == null || page == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordingScreen(
          item: item,
          filesPath: files,
          all: page.list.items,
          busy: widget.busy,
          delete: widget.delete,
        ),
      ),
    );
    if (!mounted) return;
    if (changed ?? false) {
      await _reload();
    } else {
      unawaited(_seeNext());
    }
  }

  Future<void> _day(String day, List<ArchiveItem> items, bool danger) async {
    final files = _files, page = _page;
    if (files == null || page == null) return;
    final title = dayTitle(day, _now());
    final List<ArchiveItem> chosen;
    final DeleteMode mode;
    if (!danger) {
      chosen = [for (final i in items) if (i.hasRaw && i.laptop == OnLaptop.yes) i];
      if (chosen.isEmpty || !await confirmRemove(context, chosen)) return;
      mode = DeleteMode.rawOnLaptop;
    } else {
      chosen = items;
      final m = await confirmDanger(context, items, name: 'the recordings of $title');
      if (m == null) return;
      mode = m;
    }
    final b = await _busy();
    final outcomes = <DeleteOutcome>[];
    for (final i in chosen) {
      outcomes.add(await (widget.delete ?? deleteInBackground)(files, i, mode, page.list.items, b));
    }
    if (!mounted) return;
    final freed = outcomes.fold(0, (n, o) => n + o.freedBytes);
    final refused = [for (final o in outcomes) ...o.refused];
    _say(
      deleteWords(DeleteOutcome(freedBytes: freed, refused: refused)) +
          (refused.length > 1 ? ' (and ${refused.length - 1} more)' : ''),
    );
    await _reload();
  }

  void _say(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) => ArchiveView(
    model: ArchiveViewModel(
      page: _page,
      loading: _loading,
      error: _error,
      filter: _filter,
      seeing: _seeing,
      passing: _passing,
    ),
    now: _now(),
    onOpen: _openItem,
    onFilter: (g) => setState(() => _filter = g),
    onDay: _day,
    onStorage: widget.onStorage,
  );
}
