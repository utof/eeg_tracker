// Export data (DECISIONS rows 150-156): opened from the night screen's "Your data" section between nights. Picks
// the folder once (the system picker; the app keeps the grant), then copies what is new, or everything, through
// lib/export/ and DataExport.kt. Never while a night records or a session holds the headband; the page stays in
// front while it copies (Back waits for Stop) and keeps the screen on.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../export/exporter.dart';
import '../export/store.dart';
import '../logs/activity.dart' show Activity;
import '../logs/log.dart' show AppLog;
import '../phone.dart';
import 'dream_screen.dart' show dreamSessionRunning;
import 'export_view.dart';
import 'nap_screen.dart' show napSessionRunning;
import 'states_screen.dart' show soundSessionRunning;

/// Why nothing may be exported now, or null: a night records, or a session holds the headband.
Future<String?> exportBlocked() async {
  if (await FlutterForegroundTask.isRunningService) {
    return 'A night is recording. Stop it first: nothing is exported while it records.';
  }
  if (dreamSessionRunning || soundSessionRunning || napSessionRunning) return 'A session is running. Export after it ends.';
  return null;
}

/// The page's numbers, read off the screen's thread. A top-level function on purpose: a closure made inside the
/// State shares its scope with the State's setState closures, and Isolate.run would then try to send the whole
/// screen along ("object is unsendable", found on the emulator).
Future<ExportSummary> _summarizeInBackground(String filesPath) =>
    Isolate.run(() => summarizeExport(Directory(filesPath)));

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  Directory? _files;
  ExportSummary? _sum;
  bool _usable = true;
  String? _blocked;
  ExportProgress? _progress;
  ExportOutcome? _outcome;
  bool _stop = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec == null) throw StateError("the app's folder is not known");
      final files = Directory(rec).parent;
      final sum = await _summarizeInBackground(files.path);
      final folder = sum.folder;
      final usable = folder == null || await Phone.exportFolderUsable(folder);
      final blocked = await exportBlocked();
      if (!mounted) return;
      setState(() {
        _files = files;
        _sum = sum;
        _usable = usable;
        _blocked = blocked;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pick() async {
    final files = _files;
    if (files == null) return;
    try {
      final f = await Phone.pickExportFolder();
      if (f == null) return; // the picker was closed
      ExportStore(files).chooseFolder(f.uri, f.label);
      _outcome = null;
    } on PlatformException catch (e) {
      _say('The folder could not be used: ${e.message ?? e.code}');
    }
    await _load();
  }

  Future<void> _export({required bool everything}) async {
    final files = _files, folder = _sum?.folder;
    if (files == null || folder == null || _progress != null) return;
    final blocked = await exportBlocked();
    if (blocked != null) {
      setState(() => _blocked = blocked);
      return;
    }
    setState(() {
      _stop = false;
      _outcome = null;
      _progress = const ExportProgress(0, 0, 0, 0, '');
    });
    await Phone.keepScreenOn(on: true, session: false).catchError((_) {});
    final took = Stopwatch()..start();
    Activity.begin('export'); // the battery samples (lib/logs, DECISIONS 715)
    final outcome = await runExport(
      filesDir: files,
      target: ChannelExportTarget(folder),
      everything: everything,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
      stopRequested: () => _stop,
    );
    Activity.end('export');
    AppLog('export').info(outcome.complete ? 'export done' : 'export not complete', {
      'everything': everything,
      'files': outcome.files,
      'bytes': outcome.bytes,
      'ms': took.elapsedMilliseconds,
      'error': ?outcome.error,
    });
    await Phone.keepScreenOn(on: false, session: false).catchError((_) {});
    if (!mounted) return;
    setState(() {
      _progress = null;
      _outcome = outcome;
    });
    await _load();
  }

  void _say(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = _sum;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Export data')),
        body: Padding(padding: const EdgeInsets.all(24), child: Text('The app could not read its folder: $_error')),
      );
    }
    final model = ExportViewModel(
      now: DateTime.now(),
      loading: s == null,
      folderLabel: s?.folderLabel,
      folderUsable: _usable,
      phoneFiles: s?.phoneFiles ?? 0,
      phoneBytes: s?.phoneBytes ?? 0,
      pendingFiles: s?.pendingFiles ?? 0,
      pendingBytes: s?.pendingBytes ?? 0,
      lastComplete: s?.lastComplete,
      progress: _progress,
      outcome: _outcome,
      stopping: _stop,
      blocked: _blocked,
    );
    return PopScope(
      canPop: _progress == null, // Back waits for Stop: the copy runs from this page
      child: ExportView(
        model: model,
        onPick: _pick,
        onExportNew: () => _export(everything: false),
        onExportAll: () => _export(everything: true),
        onStop: () => setState(() => _stop = true),
      ),
    );
  }
}
