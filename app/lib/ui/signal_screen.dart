// The Signal tab (DECISIONS 590-599): binds the feed (signal/signal_feed.dart) to the page (signal_view.dart). It reads
// only while it is on screen: a tab switch, another page on top or the app in the background lets go of the headband
// (its own connection) or of the night's tap; the kept signal and the head's pose stay for the next look.
import 'dart:async';

import 'package:flutter/material.dart';

import '../logs/activity.dart' show Activity;
import '../phone.dart';
import '../signal/layout.dart';
import '../signal/signal_feed.dart';
import 'evidence_sheet.dart' show showEvidence;
import 'signal_phone.dart';
import 'signal_view.dart';
import 'theme.dart';

class SignalScreen extends StatefulWidget {
  const SignalScreen({super.key, required this.feed, this.recordingsDir});

  /// Owned by the main screen, so the signal and the pose outlive a tab switch.
  final SignalFeed feed;
  final String? recordingsDir;

  @override
  State<SignalScreen> createState() => _SignalScreenState();
}

class _SignalScreenState extends State<SignalScreen> with WidgetsBindingObserver {
  bool _resumed = true;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.feed.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
    if (_resumed && widget.feed.stage == SignalStage.bluetoothOff) unawaited(widget.feed.retry());
  }

  /// After the frame: switching the feed tells its listeners, and this may run while the tree builds.
  void _sync() {
    final on = _resumed && _visible;
    scheduleMicrotask(() {
      Activity.set('signal', on: on && mounted); // the battery samples (lib/logs, DECISIONS 715)
      unawaited(widget.feed.setActive(on && mounted));
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.feed.removeListener(_changed);
    Activity.set('signal', on: false);
    unawaited(widget.feed.setActive(false));
    super.dispose();
  }

  Future<void> _action(SignalAction a) async {
    switch (a) {
      case SignalAction.allow:
        await askNearby();
        await widget.feed.retry();
      case SignalAction.bluetooth:
        try {
          await Phone.openSettings('bluetooth');
        } catch (_) {}
      case SignalAction.retry:
        await widget.feed.retry();
    }
  }

  Future<void> _positions() async {
    final dir = widget.recordingsDir ?? await Phone.recordingsDir().catchError((Object _) => null);
    if (dir == null || !mounted) return;
    final store = PositionsStore(signalDirFor(dir));
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PositionsScreen(store: store, names: widget.feed.montage.names),
      ),
    );
    if (saved == true) await widget.feed.retry();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.feed;
    return SignalView(
      model: SignalViewModel.of(f),
      signal: f.signal,
      frames: f.frames,
      pose: f.pose,
      onAction: (a) => unawaited(_action(a)),
      onMeasure: () => unawaited(f.measureAgain()),
      onPositions: () => unawaited(_positions()),
      onInfo: () => showEvidence(context, 'sleep-recording'),
    );
  }
}

/// Places for sites outside the 10-10 names (a helmet's own): one line a site, checked before it is saved.
class PositionsScreen extends StatefulWidget {
  const PositionsScreen({super.key, required this.store, required this.names});
  final PositionsStore store;

  /// The device's channel names, for the example.
  final List<String> names;

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  late final TextEditingController _text = TextEditingController(text: widget.store.read());
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    try {
      widget.store.write(_text.text);
      Navigator.of(context).pop(true);
    } on PositionsError catch (e) {
      setState(() => _error = '$e');
    } catch (e) {
      setState(() => _error = 'Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    final unplaced = [
      for (final n in widget.names)
        if (standardPosition(n) == null) n,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('Positions', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          Text(
            'Channels named by the 10-10 system (O1, Fz, C3, T7, M1 ...) find their place by themselves. For a helmet\'s '
            'other sites, give one line each: the name, then polar and azimuth in degrees, or x y z.',
            style: text.bodyLarge?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Polar: down from the top of the head (Cz 0, the ring through Fpz, T7, Oz and T8 90). Azimuth: around from '
            'the nose toward the right ear (T8 90, Oz 180, T7 -90). x y z: right, front, up. "ref Fpz" or "ground A2" '
            'place the reference and the ground.',
            style: muted,
          ),
          const SizedBox(height: 8),
          Text(
            'Example:\n${unplaced.isEmpty ? 'X1' : unplaced.first} 60 30\nX2 0.3 0.5 0.8\nref Fpz',
            style: muted?.copyWith(fontFeatures: tabular),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            minLines: 6,
            maxLines: 16,
            keyboardType: TextInputType.multiline,
            style: text.bodyLarge?.copyWith(fontFeatures: tabular),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'One site a line',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 8),
          Text('Kept in the app and copied out with Export data.', style: muted),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: FilledButton(onPressed: _save, child: const Text('Save')),
        ),
      ),
    );
  }
}
