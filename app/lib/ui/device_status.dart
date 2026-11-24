// The one headband card every screen shows (DECISIONS 854): the connection's state, the battery estimate, each
// electrode's word from the one judge with its ohms and when they were measured, the trouble in one plain sentence
// (you or one electrode), and the foldable signal panel: a quick look folded, the raw traces with their numbers
// unfolded. Its model is headband/device_status.dart; nothing here is specific to a screen or to four electrodes.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../headband/connection.dart';
import '../headband/device_status.dart';
import '../signal/live_signal.dart';
import '../signal/quality.dart';
import 'evidence_sheet.dart';
import 'signal_traces.dart';
import 'theme.dart';

/// Where a panel's live signal comes from: the signal (null: none yet), its repaint clock, and a word to the source
/// that a panel shows it now ([watch]; while none does, nothing is worked out).
class PanelSource {
  const PanelSource({required this.signal, required this.frames, this.watch});
  final LiveSignal? Function() signal;
  final Listenable frames;
  final void Function(bool on)? watch;

  static PanelSource of(HeadbandConnection c) =>
      PanelSource(signal: () => c.panel, frames: c.frames, watch: c.watchPanel);
}

/// What a screen hands the card: the status to listen to, the panel's source, and what its buttons do.
class DeviceCard {
  const DeviceCard({required this.status, this.panel, this.onConnect, this.onMeasure});
  final ValueListenable<DeviceStatus> status;
  final PanelSource? panel;

  /// "Connect" while nothing holds the headband (null: no button; the screen's own Start connects).
  final VoidCallback? onConnect;

  /// "Measure contact again" (null: not now; never during a night or a session).
  final VoidCallback? onMeasure;

  /// The app's one connection as a card, or null where there is none (tests, another engine).
  static DeviceCard? shared({VoidCallback? onConnect, VoidCallback? onMeasure}) {
    final c = HeadbandConnection.shared;
    if (c == null) return null;
    return DeviceCard(
      status: c.status,
      panel: PanelSource.of(c),
      onConnect: onConnect ?? () => unawaited(c.connectNow()),
      onMeasure: onMeasure,
    );
  }
}

/// The card of the app's one connection for every screen under it (set once at the app's root; the Signal tab puts its
/// own over it). A view shows it with [SharedDeviceCard], so no screen builds a headband display of its own.
class DeviceCardScope extends InheritedWidget {
  const DeviceCardScope({super.key, required this.card, required super.child});
  final DeviceCard? card;

  static DeviceCard? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DeviceCardScope>()?.card;

  @override
  bool updateShouldNotify(DeviceCardScope old) => !identical(old.card, card);
}

/// The headband card where a view wants it; nothing where no connection is known (a bare test).
class SharedDeviceCard extends StatelessWidget {
  const SharedDeviceCard({super.key, this.heading = 'Headband', this.top = 0});
  final String? heading;
  final double top;

  @override
  Widget build(BuildContext context) {
    final card = DeviceCardScope.of(context);
    if (card == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: DeviceStatusCard(card: card, heading: heading),
    );
  }
}

/// Whether the panel is unfolded: one choice for every screen, kept while the app runs.
final ValueNotifier<bool> signalPanelOpen = ValueNotifier<bool>(false);

String _two(int v) => v.toString().padLeft(2, '0');
String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// A contact word's mark: shape, colour and word (DESIGN.md: never colour alone).
(IconData, Color, String) contactMark(Contact c) => switch (c) {
  Contact.good => (Icons.circle, Night.live, 'good'),
  Contact.ok => (Icons.adjust, Night.caution, 'ok'),
  Contact.poor => (Icons.radio_button_unchecked, Night.problem, 'poor'),
  Contact.none => (Icons.remove, Night.inkMuted, 'none'),
};

class DeviceStatusCard extends StatelessWidget {
  const DeviceStatusCard({super.key, required this.card, this.heading = 'Headband'});
  final DeviceCard card;

  /// The card's title; null: none (the screen has its own heading above).
  final String? heading;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DeviceStatus>(
    valueListenable: card.status,
    builder: (context, s, _) => _Body(card: card, s: s, heading: heading),
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.card, required this.s, required this.heading});
  final DeviceCard card;
  final DeviceStatus s;
  final String? heading;

  (IconData, Color) get _stateMark => switch (s.link) {
    LinkState.off => (Icons.remove, Night.inkMuted),
    LinkState.live => (Icons.circle, Night.live),
    LinkState.reconnecting => (Icons.radio_button_unchecked, Night.problem),
    _ => (Icons.adjust, Night.caution),
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final (icon, color) = _stateMark;
    final q = s.quality;
    final words = s.connected || s.link == LinkState.reconnecting ? q.words : null;
    final coaching = s.connected ? q.coaching : null;
    final at = q.ohmsAt;
    final busy = q.trouble == Trouble.busy;
    return Semantics(
      container: true,
      label: 'Headband status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (heading != null) Expanded(child: Text(heading!, style: text.titleMedium)),
              if (heading == null) const Spacer(),
              IconButton(
                onPressed: () => showEvidence(context, 'signal-quality'),
                icon: const Icon(Icons.info_outline),
                tooltip: 'How the contact and the battery are judged',
                color: Night.inkMuted,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 3), child: Icon(icon, size: 16, color: color)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.word, style: text.bodyLarge),
                    if (s.lingering) Text('Kept ready for the next start.', style: muted),
                    if (s.problem != null) Text(s.problem!, style: muted),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Battery', style: muted),
                  Text(s.battery.words, style: text.bodyLarge?.copyWith(fontFeatures: tabular)),
                ],
              ),
            ],
          ),
          if (s.battery.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(s.battery.note!, style: muted)),
          if (s.link == LinkState.off && card.onConnect != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: card.onConnect, child: const Text('Connect')),
            ),
          if (q.electrodes.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 18,
              runSpacing: 12,
              children: [for (final e in q.electrodes) ElectrodeCell(e, busy: busy && s.connected)],
            ),
          ],
          if (!s.measuresContact)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('This board does not measure contact.', style: muted))
          else if (at != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Contact measured at ${_hm(at)}. It cannot be measured while the signal runs.',
                style: muted,
              ),
            ),
          if (words != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(words, style: text.bodyMedium?.copyWith(color: busy ? Night.ink : Night.caution)),
            ),
          if (coaching != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(coaching, style: muted)),
          if (card.onMeasure != null && s.connected && s.measuresContact)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: card.onMeasure, child: const Text('Measure contact again')),
            ),
          if (card.panel != null && s.connected) SignalPanel(source: card.panel!),
        ],
      ),
    );
  }
}

/// One electrode: its name, its mark and word, and its ohms (a dash when none). While everything is busy at once the
/// word is "busy": the band is on, the electrode is not blamed.
class ElectrodeCell extends StatelessWidget {
  const ElectrodeCell(this.e, {super.key, this.busy = false});
  final ElectrodeQuality e;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color, word) = busy && e.grade != Contact.none ? (Icons.waves, Night.ink, 'busy') : contactMark(e.grade);
    return Semantics(
      label: '${e.name} $word',
      excludeSemantics: true,
      child: SizedBox(
        width: 64,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.name, style: text.titleMedium),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 5),
                Flexible(child: Text(word, style: text.bodyMedium?.copyWith(color: color))),
              ],
            ),
            Text(
              formatOhms(e.ohms),
              style: text.bodySmall?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
            ),
          ],
        ),
      ),
    );
  }
}

/// The foldable signal panel, the same on every screen: folded, every electrode's last 5 s as a thin line; unfolded,
/// each electrode's raw trace with its scale and its numbers. The source works only while a panel is on screen.
class SignalPanel extends StatefulWidget {
  const SignalPanel({super.key, required this.source});
  final PanelSource source;

  @override
  State<SignalPanel> createState() => _SignalPanelState();
}

class _SignalPanelState extends State<SignalPanel> with WidgetsBindingObserver {
  bool _watching = false;
  bool _resumed = true;
  bool _visible = true;
  Timer? _numbers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // the numbers under the traces move about twice a second (the traces repaint by themselves)
    _numbers = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _watching) setState(() {});
    });
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
  }

  void _sync() {
    final on = _resumed && _visible && mounted;
    if (on == _watching) return;
    _watching = on;
    // after the frame: the source may tell its listeners
    scheduleMicrotask(() => widget.source.watch?.call(on));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _numbers?.cancel();
    if (_watching) {
      _watching = false;
      final watch = widget.source.watch;
      scheduleMicrotask(() => watch?.call(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final signal = widget.source.signal();
    return ValueListenableBuilder<bool>(
      valueListenable: signalPanelOpen,
      builder: (context, open, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => signalPanelOpen.value = !open,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(child: Text(open ? 'Signal, raw' : 'Signal', style: text.titleSmall)),
                  Text(open ? 'Fold' : 'Unfold', style: muted),
                  Icon(open ? Icons.expand_less : Icons.expand_more, color: Night.inkMuted),
                ],
              ),
            ),
          ),
          if (signal == null || signal.count == 0)
            Text('No samples yet.', style: muted)
          else if (!open)
            for (var c = 0; c < signal.channels; c++)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    SizedBox(width: 34, child: Text(signal.names[c], style: text.bodySmall?.copyWith(color: Night.inkMuted))),
                    Expanded(child: TraceBox(signal: signal, channel: c, frames: widget.source.frames, height: 26)),
                  ],
                ),
              )
          else
            for (var c = 0; c < signal.channels; c++) _RawRow(signal: signal, channel: c, frames: widget.source.frames),
        ],
      ),
    );
  }
}

class _RawRow extends StatelessWidget {
  const _RawRow({required this.signal, required this.channel, required this.frames});
  final LiveSignal signal;
  final int channel;
  final Listenable frames;

  static const TraceWindow _window = (seconds: 5, end: null);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final small = text.bodySmall?.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    final n = signal.numbers(channel);
    String uv(double? v) => v == null ? '–' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} µV';
    final flags = [if (n.flat) 'flat', if (n.railed) 'at the limit', if (n.swinging) 'large swings'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(signal.names[channel], style: text.titleSmall)),
              ScaleLabel(signal: signal, channel: channel, frames: frames, filter: TraceFilter.raw, window: _window),
            ],
          ),
          const SizedBox(height: 4),
          TraceBox(signal: signal, channel: channel, frames: frames, filter: TraceFilter.raw, window: _window, height: 64),
          const SizedBox(height: 2),
          Text(
            '1-40 Hz ${uv(n.rmsUv)} · mains ${uv(n.lineUv)} · swing ${uv(n.swingUv)}'
            '${flags.isEmpty ? '' : ' · ${flags.join(', ')}'}',
            style: small,
          ),
        ],
      ),
    );
  }
}
