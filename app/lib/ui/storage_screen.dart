// The Storage page's state (storage_view.dart; DECISIONS 690-699): the folders are read and the plans worked out in a
// background isolate; the deleting runs here, where the readers are known (recorder/remove.dart RawUse), and waits
// while a night records, a session runs or last night is being scored. Clear selected asks once; the Danger zone
// asks twice.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../export/store.dart' show sizeText;
import '../phone.dart';
import '../storage/clear.dart';
import '../storage/storage.dart';
import 'dream_screen.dart' show dreamSessionRunning;
import 'nap_screen.dart' show napSessionRunning;
import 'sleep_scoring.dart' show nightScoringBusy;
import 'states_screen.dart' show soundSessionRunning;
import 'storage_view.dart';
import 'theme.dart';
import 'work_screen.dart' show workSessionRunning;

/// Why nothing can be deleted now, in words; null when it can.
Future<String?> storageBusy() async {
  if (nightScoringBusy) return 'Last night is being scored: clearing waits until it is done.';
  if (dreamSessionRunning || soundSessionRunning || napSessionRunning || workSessionRunning) {
    return 'A session records: clearing waits until it ends.';
  }
  try {
    if (await FlutterForegroundTask.isRunningService) return 'A night records: clearing waits until Stop.';
  } catch (_) {}
  return null;
}

/// [scanStorage] in a background isolate. Top-level on purpose: a closure made inside the page's own methods carries
/// the page along, which cannot be sent to another isolate (the page then showed nothing); only [filesDir] crosses.
Future<StorageUsage> scanInBackground(String filesDir) =>
    Isolate.run(() => scanStorage(Directory(filesDir), now: DateTime.now()), debugName: 'storage-scan');

/// [planClear] in a background isolate; top-level for the same reason as [scanInBackground].
Future<ClearPlan> planInBackground(String filesDir, Set<String> items, ClearMode mode) =>
    Isolate.run(() => planClear(Directory(filesDir), items, mode: mode, now: DateTime.now()), debugName: 'storage-plan');

class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.filesDir,
    required this.paired,
    this.laptop,
    this.busy = storageBusy,
    this.space = Phone.storageSpace,
  });

  /// The app's `files/` folder.
  final String filesDir;
  final bool paired;
  final String? laptop;
  final Future<String?> Function() busy;
  final Future<({int total, int free})?> Function() space;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  late final StorageStore _store = StorageStore(Directory(widget.filesDir));
  late StorageViewModel _m = StorageViewModel(paired: widget.paired, laptop: widget.laptop, settings: _store.load());
  final Map<String, GlobalKey> _keys = {for (final c in storageCategories) c.id: GlobalKey()};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  StorageViewModel _with({
    StorageUsage? usage,
    ({int total, int free})? space,
    StorageSettings? settings,
    Set<String>? selected,
    Set<String>? danger,
    Set<String>? expanded,
    String? busy,
    bool clearBusy = false,
    bool? working,
  }) => StorageViewModel(
    usage: usage ?? _m.usage,
    space: space ?? _m.space,
    settings: settings ?? _m.settings,
    paired: _m.paired,
    laptop: _m.laptop,
    selected: selected ?? _m.selected,
    danger: danger ?? _m.danger,
    expanded: expanded ?? _m.expanded,
    busy: clearBusy ? busy : (busy ?? _m.busy),
    working: working ?? _m.working,
  );

  Future<void> _load() async {
    final dir = widget.filesDir;
    final busy = await widget.busy();
    final space = await widget.space();
    StorageUsage u;
    try {
      u = await scanInBackground(dir);
    } catch (_) {
      u = StorageUsage(bytes: const {}, files: const {}, clearable: const {}, phoneOnly: const {}, phoneOnlyCount: const {}, why: const {}, onLaptop: 0);
    }
    if (!mounted) return;
    setState(() {
      _m = _with(
        usage: u,
        space: space,
        busy: busy,
        clearBusy: true,
        // what can no longer go is no longer ticked
        selected: {for (final i in _m.selected) if ((u.clearable[i] ?? 0) > 0) i},
        danger: {for (final i in _m.danger) if ((u.phoneOnly[i] ?? 0) > 0) i},
      );
    });
  }

  void _select(String item, bool on) => setState(() => _m = _with(selected: {..._m.selected}..remove(item)..addAll({if (on) item})));

  void _danger(String item, bool on) => setState(() => _m = _with(danger: {..._m.danger}..remove(item)..addAll({if (on) item})));

  void _expand(String category) => setState(() {
    final open = {..._m.expanded};
    if (!open.remove(category)) open.add(category);
    _m = _with(expanded: open);
  });

  /// A tap on the bar: the category opens and comes into view.
  void _segment(String category) {
    setState(() => _m = _with(expanded: {..._m.expanded, category}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[category]?.currentContext;
      if (ctx != null) unawaited(Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0.1));
    });
  }

  void _keep(String category, int days) {
    final s = _m.settings.withKeep(category, days);
    try {
      _store.save(s);
      setState(() => _m = _with(settings: s));
    } catch (e) {
      _say('Not saved: $e');
    }
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _ask(String title, String body, String yes, {bool danger = false}) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: Night.surfaceHigh,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(
              style: danger ? TextButton.styleFrom(foregroundColor: Night.problem) : null,
              onPressed: () => Navigator.pop(c, true),
              child: Text(yes),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _clear() async {
    final items = {..._m.selected};
    final bytes = _m.selectedBytes;
    if (items.isEmpty) return;
    final ok = await _ask(
      'Clear ${sizeText(bytes)}?',
      'Only what your laptop has checked leaves this phone. The statistics stay.',
      'Clear',
    );
    if (ok) await _run(items, ClearMode.checked);
  }

  Future<void> _dangerDelete() async {
    final items = {..._m.danger};
    final bytes = _m.dangerBytes, n = _m.dangerCount;
    if (items.isEmpty) return;
    final first = await _ask(
      'Delete what is only on this phone?',
      '$n ${n == 1 ? 'recording' : 'recordings and files'}, ${sizeText(bytes)}. Your laptop does not have them. '
          'The statistics stay.',
      'Continue',
      danger: true,
    );
    if (!first || !mounted) return;
    final second = await _ask(
      'Delete ${sizeText(bytes)} for good?',
      'This cannot be undone.',
      'Delete for good',
      danger: true,
    );
    if (second) await _run(items, ClearMode.phoneOnly);
  }

  Future<void> _run(Set<String> items, ClearMode mode) async {
    final why = await widget.busy();
    if (why != null) {
      setState(() => _m = _with(busy: why));
      return _say(why);
    }
    setState(() => _m = _with(working: true));
    final dir = widget.filesDir;
    ClearRun? run;
    try {
      final plan = await planInBackground(dir, items, mode);
      run = await runClear(
        Directory(dir),
        plan,
        busy: () async => await widget.busy() != null,
        laptop: widget.laptop,
      );
    } catch (e) {
      _say('Not cleared: $e');
    }
    if (!mounted) return;
    setState(() => _m = _with(working: false, selected: mode == ClearMode.checked ? {} : null, danger: mode == ClearMode.phoneOnly ? {} : null));
    if (run != null) {
      final kept = run.kept.length;
      _say(
        'Freed ${sizeText(run.freedBytes)}.'
        '${kept == 0 ? '' : ' $kept kept: ${run.kept.values.first}.'}'
        '${run.stopped ? ' Stopped: something started recording.' : ''}',
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) => StorageView(
    model: _m,
    onSelect: _select,
    onExpand: _expand,
    onKeep: _keep,
    onClear: () => unawaited(_clear()),
    onDanger: _danger,
    onDangerDelete: () => unawaited(_dangerDelete()),
    onSegment: _segment,
    rowKeys: _keys,
  );
}
