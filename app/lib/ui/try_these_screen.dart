// "Try these" (DECISIONS 340): opened from the night screen's "Try these" section between nights. Reads and writes
// `files/try-these/` (lib/try_these/progress.dart), ticks what the app saw done (lib/try_these/seen.dart, off the
// screen's thread) when it opens and whenever a feature's screen opened from here closes, and opens each feature's
// screen. Sleep report and the smart alarm's sheet belong to the night screen, so it hands them in; without them those
// stops go back to the main screen.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../phone.dart';
import '../try_these/cards.dart';
import '../try_these/progress.dart';
import '../try_these/seen.dart';
import 'alpha_theta_screen.dart';
import 'dream_screen.dart';
import 'experiments_screen.dart';
import 'export_screen.dart';
import 'hands_free_screen.dart' show SettingsScreen;
import 'lucid_screen.dart';
import 'meditation_screen.dart';
import 'morning_screen.dart';
import 'nap_screen.dart';
import 'own_ble_screen.dart';
import 'sharp_hours_screen.dart';
import 'states_screen.dart';
import 'training_settings_screen.dart';
import 'trends_screen.dart';
import 'try_these_view.dart';

/// Looks for what the app can see done, for the cards in [ids]; [filesDir] is the app's `files/`.
typedef SeenLookup = Future<Map<String, String>> Function(String filesDir, Set<String> ids);

/// The checks in a background isolate: they list folders and read a few files (sleep reports can be large).
Future<Map<String, String>> seenInBackground(String filesDir, Set<String> ids) =>
    Isolate.run(() => seenByApp(Directory(filesDir), ids));

/// The cards the app may still tick: those it can check that nobody has touched.
Set<String> untouchedAuto(Map<String, CardProgress> progress) => {
  for (final c in tryCards)
    if (c.auto && !progress.containsKey(c.id)) c.id,
};

/// Reads the progress and ticks what the app saw; returns the progress after it.
Future<Map<String, CardProgress>> refreshTry(TryStore store, String filesDir, SeenLookup seen, DateTime now) async {
  final progress = store.load();
  final ids = untouchedAuto(progress);
  if (ids.isEmpty) return progress;
  final found = await seen(filesDir, ids);
  if (found.isEmpty) return progress;
  store.applySeen(found, at: now);
  return store.load();
}

class TryTheseScreen extends StatefulWidget {
  const TryTheseScreen({super.key, this.recordingsDir, this.onSleepReport, this.onAlarm, this.now, this.seen});

  /// The app's recordings folder; null: asked from the phone.
  final String? recordingsDir;

  /// The night screen's Sleep report and its alarm sheet; null: those stops go back to the main screen.
  final VoidCallback? onSleepReport;
  final VoidCallback? onAlarm;
  final DateTime Function()? now;

  /// Tests pass a lookup that runs on the test's own thread.
  final SeenLookup? seen;

  @override
  State<TryTheseScreen> createState() => _TryTheseScreenState();
}

class _TryTheseScreenState extends State<TryTheseScreen> {
  TryStore? _store;
  String? _files;
  Map<String, CardProgress> _progress = const {};
  String? _expanded;
  bool _showFinished = false;
  bool _loaded = false;
  String? _error;
  final Map<String, String> _pendingNotes = {};
  Timer? _saveTimer;
  final Map<String, GlobalKey> _keys = {};

  DateTime _now() => (widget.now ?? DateTime.now)();
  TryPage get _page => buildTryPage(tryCards, _progress);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _flushNotes();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rec = widget.recordingsDir ?? await Phone.recordingsDir();
      if (rec == null) throw StateError("the app's folder is not known");
      final store = TryStore(tryDirFor(rec));
      _store = store;
      _files = Directory(rec).parent.path;
      final progress = store.load();
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _expanded = buildTryPage(tryCards, progress).next?.id;
        _loaded = true;
      });
      await _see();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _expanded ??= _page.next?.id;
          _error = 'Your ticks and notes cannot be saved here: $e';
        });
      }
    }
  }

  /// Ticks what the app saw done since; an open stop that got ticked folds away and the next one opens.
  Future<void> _see() async {
    final store = _store, files = _files;
    if (store == null || files == null) return;
    _flushNotes();
    try {
      final progress = await refreshTry(store, files, widget.seen ?? seenInBackground, _now());
      if (!mounted) return;
      setState(() {
        final wasOpen = _expanded != null && (_progress[_expanded]?.state ?? TryState.open) == TryState.open;
        _progress = progress;
        if (wasOpen && progress[_expanded]?.state == TryState.done) _expanded = _page.next?.id;
      });
    } catch (_) {
      // nothing ticked by itself this time; the owner still can
    }
  }

  void _write(void Function(TryStore s) f) {
    final s = _store;
    if (s == null) return;
    try {
      f(s);
      _progress = s.load();
      _error = null;
    } catch (e) {
      _error = 'Not saved: $e';
    }
  }

  void _flushNotes() {
    _saveTimer?.cancel();
    if (_pendingNotes.isEmpty) return;
    final notes = Map.of(_pendingNotes);
    _pendingNotes.clear();
    final at = _now();
    final s = _store;
    if (s == null) return;
    try {
      for (final e in notes.entries) {
        s.setNote(e.key, e.value, at: at);
      }
    } catch (_) {
      // the next change tries again with the whole note
    }
  }

  void _note(String id, String note) {
    _pendingNotes[id] = note;
    _progress = {..._progress, id: (_progress[id] ?? const CardProgress()).copyWith(note: note)};
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _flushNotes);
  }

  String? _noteFor(String id) => _pendingNotes[id];

  void _set(String id, TryState state) {
    final note = _noteFor(id);
    _pendingNotes.remove(id);
    _flushNotes();
    setState(() {
      _write((s) => s.mark(id, state, at: _now(), note: note));
      // Done or Skip: the stop folds away and the page re-signs to the next one; Not done yet opens it again.
      _expanded = state == TryState.open ? id : _page.next?.id;
    });
    final next = _expanded;
    if (next != null && state != TryState.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(next));
    }
  }

  Future<void> _reveal(String id) async {
    final c = _keys[id]?.currentContext;
    if (c == null || !c.mounted) return;
    await Scrollable.ensureVisible(
      c,
      duration: MediaQuery.disableAnimationsOf(c) ? Duration.zero : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: 0.05,
    );
  }

  /// The night screen's own parts are opened by the night screen; without its callback a stop goes back to it.
  TryOpen _route(TryCard c) => switch (c.opens) {
    TryOpen.sleepReport when widget.onSleepReport == null => TryOpen.nightScreen,
    TryOpen.alarm when widget.onAlarm == null => TryOpen.nightScreen,
    final o => o,
  };

  Widget? _screen(TryOpen o) {
    final rec = widget.recordingsDir ?? (_files == null ? null : '$_files/recordings');
    return switch (o) {
      TryOpen.morning => const MorningScreen(),
      TryOpen.trends => TrendsScreen(recordingsDir: rec),
      TryOpen.export => const ExportScreen(),
      TryOpen.meditation => const MeditationScreen(),
      TryOpen.alphaTheta => const AlphaThetaScreen(),
      TryOpen.training => rec == null ? null : TrainingSettingsScreen(recordingsDir: rec),
      TryOpen.dream => const DreamScreen(),
      TryOpen.lucid => const LucidScreen(),
      TryOpen.nap => const NapScreen(),
      TryOpen.sound => const StatesScreen(),
      TryOpen.settings => const SettingsScreen(),
      TryOpen.experiments => ExperimentsScreen(recordingsDir: rec),
      TryOpen.sharpHours => SharpHoursScreen(recordingsDir: rec),
      TryOpen.ownBle => const OwnBleScreen(),
      TryOpen.nightScreen || TryOpen.sleepReport || TryOpen.alarm => null,
    };
  }

  Future<void> _open(TryCard c) async {
    _flushNotes();
    final route = _route(c);
    switch (route) {
      case TryOpen.nightScreen:
        Navigator.of(context).pop();
        return;
      case TryOpen.sleepReport:
        widget.onSleepReport!();
        return;
      case TryOpen.alarm:
        widget.onAlarm!();
        return;
      default:
        final screen = _screen(route);
        if (screen == null) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
        await _see(); // the try may be done now
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Try these')),
        body: const SizedBox.shrink(),
      );
    }
    return TryTheseView(
      page: _page,
      expanded: _expanded,
      showFinished: _showFinished,
      error: _error,
      openLabel: (c) => tryOpenLabels[_route(c)]!,
      stopKey: (id) => _keys.putIfAbsent(id, GlobalKey.new),
      onToggle: (id) {
        _flushNotes();
        setState(() => _expanded = _expanded == id ? null : id);
      },
      onOpen: (c) => unawaited(_open(c)),
      onDone: (id) => _set(id, TryState.done),
      onSkip: (id) => _set(id, TryState.skipped),
      onReopen: (id) => _set(id, TryState.open),
      onNote: _note,
      onShowFinished: () => setState(() => _showFinished = true),
    );
  }
}

/// The night screen's "Try these" section: reads the progress (and what the app saw) when it appears, when the app
/// comes back, when the night screen is in front again, and at most once a minute otherwise.
class TryTheseEntry extends StatefulWidget {
  const TryTheseEntry({super.key, this.onSleepReport, this.onAlarm});
  final VoidCallback? onSleepReport;
  final VoidCallback? onAlarm;

  @override
  State<TryTheseEntry> createState() => _TryTheseEntryState();
}

class _TryTheseEntryState extends State<TryTheseEntry> with WidgetsBindingObserver {
  TryPage? _page;
  String? _rec;
  DateTime? _readAt;
  bool _reading = false;
  bool _wasFront = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_read());
  }

  @override
  void didUpdateWidget(TryTheseEntry old) {
    super.didUpdateWidget(old);
    // The night screen rebuilds every second: read again when it is back in front, or after a minute.
    final front = ModalRoute.of(context)?.isCurrent ?? true;
    final stale = _readAt == null || DateTime.now().difference(_readAt!) > const Duration(minutes: 1);
    if ((front && !_wasFront) || (front && stale)) unawaited(_read());
    _wasFront = front;
  }

  static Future<({String rec, Map<String, CardProgress> progress})?> _load() async {
    final rec = await Phone.recordingsDir();
    if (rec == null) return null;
    final progress = await refreshTry(
      TryStore(tryDirFor(rec)),
      Directory(rec).parent.path,
      seenInBackground,
      DateTime.now(),
    );
    return (rec: rec, progress: progress);
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    _readAt = DateTime.now();
    try {
      final r = await _load();
      if (r != null && mounted) {
        setState(() {
          _rec = r.rec;
          _page = buildTryPage(tryCards, r.progress);
        });
      }
    } catch (_) {
      // a line of text is never worth breaking the night screen
    } finally {
      _reading = false;
    }
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TryTheseScreen(recordingsDir: _rec, onSleepReport: widget.onSleepReport, onAlarm: widget.onAlarm),
      ),
    );
    unawaited(_read());
  }

  @override
  Widget build(BuildContext context) => TryEntryView(line: entryLine(_page), onOpen: _open);
}
