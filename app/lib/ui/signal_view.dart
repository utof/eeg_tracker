// The Signal tab's page (DECISIONS 590-599), from a plain view model so it renders in tests without a phone: the state
// line, then Head / Traces / Raw as the app's segmented row. Head: the 3D head with each electrode's contact, the picked
// electrode's live trace and numbers, and every electrode as a log row. Traces: one live trace per channel in µV with a
// filter and a scale, its numbers and its band strip. Raw: all channels stacked as they came, pause and look back up to
// 5 minutes, the counters (samples, times, missing packets) and the latest values. Any number of channels.
import 'package:flutter/material.dart';

import '../logs/own_text.dart';
import '../recorder/contact.dart';
import '../signal/head3d.dart';
import '../signal/layout.dart';
import '../signal/live_signal.dart';
import '../signal/signal_feed.dart';
import 'head_view.dart';
import 'night_view.dart' show Tone;
import 'parts.dart';
import 'signal_traces.dart';
import 'theme.dart';

enum SignalPart { head, traces, raw }

enum SignalAction { allow, bluetooth, retry }

class SignalViewModel {
  const SignalViewModel({
    required this.stage,
    required this.kind,
    required this.montage,
    this.measuresContact = true,
    this.diy = false,
    this.ohms = const {},
    this.ohmsAt,
    this.ohmsFrom = ContactFrom.none,
    this.dataAge,
    this.problem,
    this.canMeasure = false,
  });

  factory SignalViewModel.of(SignalFeed f) => SignalViewModel(
    stage: f.stage,
    kind: f.kind,
    montage: f.montage,
    measuresContact: f.device.measuresContact,
    diy: f.device.diy,
    ohms: f.ohms,
    ohmsAt: f.ohmsAt,
    ohmsFrom: f.ohmsFrom,
    dataAge: f.dataAge,
    problem: f.problem,
    canMeasure: f.canMeasure,
  );

  final SignalStage stage;
  final FeedKind kind;
  final Montage montage;
  final bool measuresContact;
  final bool diy;
  final Map<String, double?> ohms;
  final DateTime? ohmsAt;
  final ContactFrom ohmsFrom;
  final int? dataAge;
  final String? problem;
  final bool canMeasure;
}

/// '820 kΩ', '1.4 MΩ', '–' (no reading).
String formatOhms(double? ohms) {
  if (ohms == null || ohms.isNaN || ohms < 0) return '–';
  if (ohms.isInfinite) return 'off';
  if (ohms < 1e3) return '${ohms.round()} Ω';
  if (ohms < 1e6) return '${(ohms / 1e3).round()} kΩ';
  return '${(ohms / 1e6).toStringAsFixed(1)} MΩ';
}

String _two(int v) => v.toString().padLeft(2, '0');
String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// 23:41:12.116
String clockMs(double ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms.round());
  return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
}

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// The state line: a title, one sentence, the tone of its mark, and the one action it offers.
({String title, String sentence, Tone tone, SignalAction? action}) describeSignal(SignalViewModel m) {
  final age = m.dataAge;
  final band = m.diy ? 'the board' : 'the headband';
  switch (m.stage) {
    case SignalStage.idle || SignalStage.starting:
      return (title: 'Starting', sentence: 'Looking at what holds $band now.', tone: Tone.calm, action: null);
    case SignalStage.noPermission:
      return (
        title: 'Not allowed',
        sentence: 'Allow Nearby devices, so the app can find the headband.',
        tone: Tone.caution,
        action: SignalAction.allow,
      );
    case SignalStage.bluetoothOff:
      return (
        title: 'Bluetooth is off',
        sentence: 'Turn Bluetooth on to see the headband\'s signal.',
        tone: Tone.caution,
        action: SignalAction.bluetooth,
      );
    case SignalStage.noWifi:
      return (
        title: 'No Wi-Fi',
        sentence: 'Connect the phone to the Wi-Fi the board sends to.',
        tone: Tone.caution,
        action: SignalAction.retry,
      );
    case SignalStage.searching:
      return (
        title: m.diy ? 'Listening' : 'Looking',
        sentence: m.diy
            ? 'Waiting for the board\'s frames on UDP port 9000.'
            : 'Looking for the headband. Is it on and near the phone?',
        tone: Tone.calm,
        action: null,
      );
    case SignalStage.checkingContact:
      return (title: 'Checking contact', sentence: 'Keep still for a few seconds.', tone: Tone.calm, action: null);
    case SignalStage.notFound:
      return (
        title: 'No headband',
        sentence: m.diy
            ? 'No frames from the board. Is it on this Wi-Fi, sending to this phone, and past its prompts?'
            : 'Headband not found. Is it switched on and charged? The head below still turns.',
        tone: Tone.caution,
        action: SignalAction.retry,
      );
    case SignalStage.failed:
      return (
        title: 'Could not connect',
        sentence: m.problem == null || m.problem!.isEmpty ? 'Try again in a moment.' : _sentence(m.problem!),
        tone: Tone.problem,
        action: SignalAction.retry,
      );
    case SignalStage.waiting:
      final from = switch (m.kind) {
        FeedKind.night => 'The night recorder is not recording yet: the signal shows here once it is.',
        FeedKind.session => 'Reading along with the session; waiting for its samples.',
        _ => 'Connected. Waiting for the first samples.',
      };
      if (age != null && age >= 5) {
        return (
          title: 'No data',
          sentence: 'No data for $age s.',
          tone: age < 40 ? Tone.caution : Tone.problem,
          action: null,
        );
      }
      return (title: 'Waiting', sentence: from, tone: Tone.calm, action: null);
    case SignalStage.live:
      final from = switch (m.kind) {
        FeedKind.night => 'From the night recording; the headband stays as the night has it.',
        FeedKind.session => 'Read along with the running session.',
        _ => m.diy ? 'From the board, as it sends.' : 'From the headband, $liveRate samples a second.',
      };
      return (title: 'Live', sentence: from, tone: Tone.live, action: null);
  }
}

String _sentence(String s) {
  final t = s.trim();
  if (t.isEmpty) return t;
  final up = t[0].toUpperCase() + t.substring(1);
  return up.endsWith('.') ? up : '$up.';
}

/// Where the shown contact comes from, in a sentence.
String contactSource(SignalViewModel m) {
  if (!m.measuresContact) return 'This board does not measure contact.';
  final at = m.ohmsAt;
  switch (m.ohmsFrom) {
    case ContactFrom.nightStart:
      return 'Measured ${at == null ? 'when the night started' : 'when the night started, ${_hm(at)}'}. The headband stays '
          'in recording mode until Stop: this is the last reading.';
    case ContactFrom.session:
      return 'Measured ${at == null ? 'when the session started' : 'at ${_hm(at)}, when the session started'}. The '
          'headband stays with the session: this is the last reading.';
    case ContactFrom.now:
      return 'Measured${at == null ? '' : ' at ${_hm(at)}'}. Measure again any time; the traces pause for about 7 s.';
    case ContactFrom.none:
      return switch (m.kind) {
        FeedKind.night => 'No contact reading from the start of this night.',
        FeedKind.session => 'The session has no contact reading.',
        _ => 'Contact is measured when the headband connects.',
      };
  }
}

/// A channel's mark from the contact reading.
SiteMark siteMark(SignalViewModel m, String name) {
  if (!m.measuresContact) return (contact: Contact.none, value: null, measured: false);
  if (m.ohms.isEmpty) return (contact: Contact.none, value: null, measured: true);
  final o = m.ohms[name];
  return (contact: classifyOhms(o), value: formatOhms(o), measured: true);
}

const List<(IconData, Color, String)> _markIcons = [
  (Icons.circle, Night.live, 'good'),
  (Icons.adjust, Night.caution, 'fair'),
  (Icons.radio_button_unchecked, Night.problem, 'poor'),
  (Icons.remove, Night.inkMuted, 'none'),
];

(IconData, Color, String) _icon(Contact c) => _markIcons[c.index];

Color _toneColor(Tone t) => switch (t) {
  Tone.calm => Night.inkMuted,
  Tone.live => Night.live,
  Tone.caution => Night.caution,
  Tone.problem => Night.problem,
};

class SignalView extends StatefulWidget {
  const SignalView({
    super.key,
    required this.model,
    required this.signal,
    required this.frames,
    required this.pose,
    this.onAction,
    this.onMeasure,
    this.onPositions,
    this.onInfo,
    this.initialPart = SignalPart.head,
  });

  final SignalViewModel model;
  final LiveSignal? signal;

  /// Ticks while samples come (the traces repaint on it).
  final Listenable frames;
  final ValueNotifier<HeadPose> pose;
  final ValueChanged<SignalAction>? onAction;
  final VoidCallback? onMeasure;

  /// The positions page for sites outside the 10-10 names.
  final VoidCallback? onPositions;
  final VoidCallback? onInfo;
  final SignalPart initialPart;

  @override
  State<SignalView> createState() => _SignalViewState();
}

class _SignalViewState extends State<SignalView> {
  late SignalPart _part = widget.initialPart;
  TraceFilter _filter = TraceFilter.band;
  double? _scale;
  String? _picked;
  int? _pausedAt;
  double _back = 0;

  SignalViewModel get m => widget.model;

  String? get _selected {
    final names = m.montage.names;
    if (_picked != null && m.montage.site(_picked!) != null) return _picked;
    return names.isEmpty ? null : names.first;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Signal', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          if (widget.onInfo != null)
            IconButton(
              onPressed: widget.onInfo,
              tooltip: 'What the numbers mean',
              icon: const Icon(Icons.info_outline),
              color: Night.inkMuted,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 14), child: _status(context)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SegmentedButton<SignalPart>(
              segments: const [
                ButtonSegment(value: SignalPart.head, label: Text('Head')),
                ButtonSegment(value: SignalPart.traces, label: Text('Traces')),
                ButtonSegment(value: SignalPart.raw, label: Text('Raw')),
              ],
              selected: {_part},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _part = s.first),
              style: _segmentStyle,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: switch (_part) {
              SignalPart.head => _head(context),
              SignalPart.traces => _traces(context),
              SignalPart.raw => _raw(context),
            },
          ),
        ],
      ),
    );
  }

  static final ButtonStyle _segmentStyle = SegmentedButton.styleFrom(
    minimumSize: const Size.fromHeight(48),
    selectedBackgroundColor: Night.surfaceHigh,
    selectedForegroundColor: Night.ink,
    foregroundColor: Night.inkMuted,
    side: const BorderSide(color: Night.rule),
  );

  Widget _status(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = describeSignal(m);
    final color = _toneColor(d.tone);
    final action = d.action;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(d.tone == Tone.calm ? Icons.radio_button_unchecked : Icons.circle, size: 14, color: color),
              const SizedBox(width: 12),
              Expanded(child: Text(d.title, style: text.titleLarge)),
              if (action != null)
                TextButton(
                  onPressed: widget.onAction == null ? null : () => widget.onAction!(action),
                  child: Text(switch (action) {
                    SignalAction.allow => 'Allow',
                    SignalAction.bluetooth => 'Bluetooth',
                    SignalAction.retry => 'Try again',
                  }),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            d.sentence,
            style: text.bodyMedium?.copyWith(
              color: d.tone == Tone.caution || d.tone == Tone.problem ? color : Night.inkMuted,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- Head

  Widget _head(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35);
    final marks = {for (final s in m.montage.channels) s.name: siteMark(m, s.name)};
    final selected = _selected;
    return LayoutBuilder(
      builder: (context, box) {
        final headHeight = (box.maxHeight * 0.52).clamp(220.0, 320.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HeadView(
              montage: m.montage,
              marks: marks,
              pose: widget.pose,
              selected: selected,
              onSelect: (name) => setState(() => _picked = name),
              height: headHeight,
            ),
            Expanded(
              child: ListView(
                key: const PageStorageKey('signal-head'),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  Text(
                    'Drag to turn, pinch to zoom, double-tap to straighten. Tap an electrode for its trace.',
                    style: muted,
                  ),
                  const SizedBox(height: 10),
                  _legend(context),
                  if (selected != null) ..._pickedBlock(context, selected),
                  const SectionHeading('Electrodes'),
                  for (final s in m.montage.channels) _siteRow(context, s, marks[s.name]!, s.name == selected),
                  for (final s in m.montage.others) _siteRow(context, s, null, false),
                  if (m.montage.unplaced.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'No place on the head for ${m.montage.unplaced.map((s) => s.name).join(', ')}: not a 10-10 name. '
                      'Give its place under Positions.',
                      style: muted?.copyWith(color: Night.caution),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(contactSource(m), style: muted),
                  if (m.montage.note != null) ...[const SizedBox(height: 8), Text(m.montage.note!, style: muted)],
                  if (m.canMeasure) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: widget.onMeasure,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Measure contact again'),
                    ),
                  ],
                  if (widget.onPositions != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: widget.onPositions,
                        icon: const Icon(Icons.edit_location_alt_outlined),
                        label: const Text('Positions'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _legend(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    if (!m.measuresContact) {
      return Text('Contact: not measured by this board (a dash on every electrode).', style: muted);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            for (final (icon, color, word) in _markIcons)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Text(word, style: muted?.copyWith(color: color)),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text('Good up to 1 MΩ, fair up to 2.5 MΩ: planning limits, not measured on your head.', style: muted),
      ],
    );
  }

  List<Widget> _pickedBlock(BuildContext context, String name) {
    final text = Theme.of(context).textTheme;
    final s = m.montage.site(name);
    final c = m.montage.names.indexOf(name);
    final mark = siteMark(m, name);
    final sig = widget.signal;
    final place = s?.at == null ? 'no place on the head' : placeWords(s!.at!);
    return [
      const SizedBox(height: 20),
      const Divider(),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(name, style: text.titleLarge),
          const SizedBox(width: 10),
          Expanded(
            child: Text(place, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
          ),
          Text(
            mark.measured ? (mark.value ?? '–') : 'not measured',
            style: text.titleLarge?.copyWith(
              fontFeatures: tabular,
              color: mark.measured ? _icon(mark.contact).$2 : Night.inkMuted,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (sig != null && c >= 0) ...[
        TraceBox(
          signal: sig,
          channel: c,
          frames: widget.frames,
          height: 96,
          label: '$name, last 5 seconds, 1 to 40 Hz',
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text('Last 5 s, 1-40 Hz', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
            ),
            ScaleLabel(
              signal: sig,
              channel: c,
              frames: widget.frames,
              filter: TraceFilter.band,
              window: (seconds: 5, end: null),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Numbers(signal: sig, channel: c, frames: widget.frames, rows: true),
      ] else
        Text('Its trace shows here once samples come.', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
    ];
  }

  /// A site's name is a 10-10 name (the same word for everyone) or the owner's own: a helmet's site given on the
  /// Positions page, a DIY board's channel name. The usage log reads the first kind and never the second.
  Widget _siteName(Site s, Text name) => !s.custom && standardPosition(s.name) != null ? name : OwnText(child: name);

  Widget _siteRow(BuildContext context, Site s, SiteMark? mark, bool picked) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final channel = s.kind == SiteKind.channel;
    final (icon, color, word) = channel && mark != null && mark.measured
        ? _icon(mark.contact)
        : (Icons.remove, Night.inkMuted, 'none');
    final kind = switch (s.kind) {
      SiteKind.reference => 'Reference',
      SiteKind.ground => 'Bias',
      SiteKind.channel => null,
    };
    final where = [
      ?kind,
      if (s.where != null) s.where! else if (s.at != null) placeWords(s.at!),
      if (s.custom) 'your position',
      if (s.approximate) 'approximate',
    ].join(', ');
    final value = !channel || mark == null || !mark.measured ? 'not measured' : (mark.value ?? '–');
    return Semantics(
      button: channel,
      selected: picked,
      label: '${s.name}, $where, contact ${channel ? word : 'not measured'}${value.contains('Ω') ? ', $value' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: channel ? () => setState(() => _picked = s.name) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: channel
                      ? Icon(icon, size: 16, color: color)
                      : const Icon(Icons.crop_square, size: 16, color: Night.inkMuted),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _siteName(
                        s,
                        Text(
                          s.name,
                          style: text.titleMedium?.copyWith(
                            color: picked ? Night.ink : null,
                            fontWeight: picked ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                      if (where.isNotEmpty) Text(where, style: muted),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  value,
                  style: text.bodyLarge?.copyWith(
                    fontFeatures: tabular,
                    color: value.contains('Ω') ? Night.ink : Night.inkMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- Traces

  Widget _traces(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final sig = widget.signal;
    final names = m.montage.names;
    return ListView.builder(
      key: const PageStorageKey('signal-traces'),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: names.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Filter', style: muted),
              const SizedBox(height: 6),
              SegmentedButton<TraceFilter>(
                segments: const [
                  ButtonSegment(value: TraceFilter.raw, label: Text('Raw')),
                  ButtonSegment(value: TraceFilter.band, label: Text('1-40 Hz')),
                  ButtonSegment(value: TraceFilter.notch, label: Text('50 Hz notch')),
                ],
                selected: {_filter},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _filter = s.first),
                style: _segmentStyle,
              ),
              const SizedBox(height: 12),
              Text('Scale, µV', style: muted),
              const SizedBox(height: 6),
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Auto')),
                  ButtonSegment(value: 50, label: Text('±50')),
                  ButtonSegment(value: 200, label: Text('±200')),
                  ButtonSegment(value: 1000, label: Text('±1000')),
                ],
                selected: {_scale ?? 0},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _scale = s.first == 0 ? null : s.first),
                style: _segmentStyle,
              ),
              const SizedBox(height: 8),
              Text(switch (_filter) {
                TraceFilter.raw => 'As it came, around its mean: the electrode\'s offset is left out of the picture.',
                TraceFilter.band => '1 to 40 Hz with the mains (50 Hz) taken out: what EEG is read from.',
                TraceFilter.notch => 'Only the mains (50 Hz) taken out; slow drifts stay.',
              }, style: muted),
              if (sig == null || sig.count == 0) ...[
                const SizedBox(height: 8),
                Text('No samples yet: the traces stay flat.', style: muted),
              ],
            ],
          );
        }
        final c = i - 1;
        return _channelBlock(context, c, names[c], sig);
      },
    );
  }

  Widget _channelBlock(BuildContext context, int c, String name, LiveSignal? sig) {
    final text = Theme.of(context).textTheme;
    final mark = siteMark(m, name);
    final (icon, color, _) = mark.measured ? _icon(mark.contact) : (Icons.remove, Night.inkMuted, 'none');
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(name, style: text.titleMedium)),
              Text(
                mark.measured ? (mark.value ?? '–') : 'contact not measured',
                style: text.bodyLarge?.copyWith(
                  fontFeatures: tabular,
                  color: mark.value == null ? Night.inkMuted : Night.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (sig != null) ...[
            TraceBox(signal: sig, channel: c, frames: widget.frames, filter: _filter, scale: _scale, height: 76),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _Numbers(signal: sig, channel: c, frames: widget.frames),
                ),
                const SizedBox(width: 8),
                ScaleLabel(
                  signal: sig,
                  channel: c,
                  frames: widget.frames,
                  filter: _filter,
                  window: (seconds: 5, end: null),
                  scale: _scale,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: widget.frames,
              builder: (context, _) => BandStrip(shares: sig.numbers(c).bands),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- Raw

  int get _windowSeconds => 10;

  Widget _raw(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final sig = widget.signal;
    if (sig == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [Text('No samples yet.', style: muted)],
      );
    }
    final paused = _pausedAt != null;
    final maxBack = paused ? ((_pausedAt! - sig.oldest) / sig.rate - _windowSeconds).clamp(0.0, 300.0) : 0.0;
    final back = _back.clamp(0.0, maxBack);
    final end = paused ? _pausedAt! - (back * sig.rate).round() : null;
    final window = (seconds: _windowSeconds, end: end);
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = scaler.scale(40).clamp(40.0, 60.0);
    return ListView(
      key: const PageStorageKey('signal-raw'),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: sig.count == 0
                    ? null
                    : () => setState(() {
                        _pausedAt = paused ? null : sig.count;
                        _back = 0;
                      }),
                icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                label: Text(paused ? 'Back to live' : 'Pause'),
              ),
            ),
          ],
        ),
        if (paused) ...[
          const SizedBox(height: 10),
          Text(
            back < 0.5
                ? 'Paused. Slide to look back up to ${(maxBack / 60).ceil()} min.'
                : 'Looking ${_mmss(back)} back.',
            style: muted,
          ),
          Slider(
            value: maxBack - back,
            min: 0,
            max: maxBack <= 0 ? 1 : maxBack,
            onChanged: maxBack <= 0 ? null : (v) => setState(() => _back = maxBack - v),
            label: _mmss(back),
          ),
        ],
        const SizedBox(height: 12),
        _RawStack(signal: sig, window: window, frames: widget.frames, rowHeight: rowHeight),
        const SizedBox(height: 6),
        ListenableBuilder(
          listenable: widget.frames,
          builder: (context, _) {
            final e = end ?? sig.count;
            final from = (e - _windowSeconds * sig.rate).clamp(sig.oldest, e);
            return Text(
              sig.count == 0
                  ? 'Each channel around its own mean, its scale at the right.'
                  : 'Showing ${clockMs(sig.timeOf(from))} to ${clockMs(sig.timeOf(e - 1))}; each channel around its own mean.',
              style: muted,
            );
          },
        ),
        const SectionHeading('Counters'),
        _RawCounters(signal: sig, frames: widget.frames, night: m.kind == FeedKind.night),
        const SectionHeading('Latest values'),
        _LatestTable(signal: sig, frames: widget.frames, end: end),
      ],
    );
  }

  static String _mmss(double s) {
    final t = s.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }
}

/// RMS, mains and the last second's flags, as rows (label left, value right) or one line.
class _Numbers extends StatelessWidget {
  const _Numbers({required this.signal, required this.channel, required this.frames, this.rows = false});

  final LiveSignal signal;
  final int channel;
  final Listenable frames;
  final bool rows;

  static String _uv(double? v) => v == null ? '–' : (v < 100 ? v.toStringAsFixed(1) : v.round().toString());

  static String flags(ChannelNumbers n) {
    final out = [if (n.flat) 'flat', if (n.railed) 'railed', if (n.swinging) 'large swings'];
    if (n.rmsUv == null) return 'not enough signal yet';
    return out.isEmpty ? 'steady' : out.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: frames,
      builder: (context, _) {
        final n = signal.numbers(channel);
        final trouble = n.flat || n.railed || n.swinging;
        final flagStyle = text.bodyMedium?.copyWith(color: trouble ? Night.caution : Night.inkMuted);
        if (!rows) {
          return Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'RMS ${_uv(n.rmsUv)} µV · 50 Hz ${_uv(n.lineUv)} µV · '),
                TextSpan(text: flags(n), style: flagStyle),
              ],
            ),
            style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
          );
        }
        Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
              ),
              Text(
                value,
                style: text.bodyLarge?.copyWith(fontFeatures: tabular, color: color),
              ),
            ],
          ),
        );
        return Column(
          children: [
            row('RMS, 1-40 Hz', '${_uv(n.rmsUv)} µV'),
            row('Mains, 50 Hz', '${_uv(n.lineUv)} µV'),
            row('Last second', flags(n), color: trouble ? Night.caution : null),
            const SizedBox(height: 4),
            BandStrip(shares: n.bands),
          ],
        );
      },
    );
  }
}

class _RawStack extends StatefulWidget {
  const _RawStack({required this.signal, required this.window, required this.frames, required this.rowHeight});
  final LiveSignal signal;
  final TraceWindow window;
  final Listenable frames;
  final double rowHeight;

  @override
  State<_RawStack> createState() => _RawStackState();
}

class _RawStackState extends State<_RawStack> {
  final Map<String, TextPainter> _labels = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clear();
  }

  void _clear() {
    for (final t in _labels.values) {
      t.dispose();
    }
    _labels.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final scaler = MediaQuery.textScalerOf(context);
    if (_labels.length > 300) _clear();
    final s = widget.signal;
    final nameWidth = scaler.scale(44).clamp(44.0, 64.0);
    return Semantics(
      label: 'All ${s.channels} channels as they came, last ${widget.window.seconds} seconds',
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(double.infinity, widget.rowHeight * s.channels),
          painter: StackedPainter(
            signal: s,
            window: widget.window,
            rowHeight: widget.rowHeight,
            nameWidth: nameWidth,
            scaleWidth: scaler.scale(66).clamp(66.0, 92.0),
            repaint: widget.frames,
            label: (t, {muted = false}) => _labels.putIfAbsent(
              '$muted$t',
              () => TextPainter(
                text: TextSpan(
                  text: t,
                  style: style.copyWith(color: muted ? Night.inkMuted : Night.ink, fontFeatures: tabular),
                ),
                textDirection: TextDirection.ltr,
                textScaler: scaler,
                maxLines: 1,
                ellipsis: '…',
              )..layout(maxWidth: muted ? 92 : nameWidth - 4),
            ),
          ),
        ),
      ),
    );
  }
}

class _RawCounters extends StatelessWidget {
  const _RawCounters({required this.signal, required this.frames, required this.night});
  final LiveSignal signal;
  final Listenable frames;
  final bool night;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: text.bodyLarge?.copyWith(fontFeatures: tabular),
            ),
          ),
        ],
      ),
    );
    return ListenableBuilder(
      listenable: frames,
      builder: (context, _) {
        final s = signal;
        final n = s.count;
        final p = s.packets;
        final rate = s.measuredRate();
        return Column(
          children: [
            row('Samples since you opened this', _thousands(n)),
            row('Channels', '${s.channels}'),
            row('Newest', n == 0 ? '–' : clockMs(s.timeOf(n - 1))),
            row(
              'Kept for looking back',
              n == 0 ? '–' : '${((n - s.oldest) / s.rate / 60).toStringAsFixed(1)} of 5 min',
            ),
            row('Rate', rate == null ? '–' : '${rate.toStringAsFixed(1)} a second'),
            row(
              'Missing packets',
              !s.numbered
                  ? 'not numbered'
                  : (p.missing == 0 ? 'none' : '${_thousands(p.missing)} in ${p.gaps} ${p.gaps == 1 ? 'gap' : 'gaps'}'),
            ),
            if (s.numbered) row('Repeated packets', _thousands(p.repeated)),
            if (night && s.run != null) row('File set', s.run!),
          ],
        );
      },
    );
  }
}

class _LatestTable extends StatelessWidget {
  const _LatestTable({required this.signal, required this.frames, this.end});
  final LiveSignal signal;
  final Listenable frames;
  final int? end;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final head = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final cell = text.bodyLarge?.copyWith(fontFeatures: tabular);
    return ListenableBuilder(
      listenable: frames,
      builder: (context, _) {
        final s = signal;
        final i = (end ?? s.count) - 1;
        final has = s.count > 0 && i >= s.oldest;
        return Column(
          children: [
            Row(
              children: [
                Expanded(child: Text('Channel', style: head)),
                Expanded(
                  flex: 2,
                  child: Text('µV', style: head, textAlign: TextAlign.end),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Divider(),
            for (var c = 0; c < s.channels; c++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(s.names[c], style: text.bodyLarge)),
                    Expanded(
                      flex: 2,
                      child: Text(
                        has ? s.window(c, TraceFilter.raw, 1, end: i + 1).first.toStringAsFixed(2) : '–',
                        style: cell,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            if (has) ...[
              const SizedBox(height: 4),
              Text(
                'Sample ${_thousands(i)}, ${s.numbered ? 'packet ${s.packOf(i)}, ' : ''}arrived ${clockMs(s.timeOf(i))}.',
                style: head?.copyWith(fontFeatures: tabular),
              ),
            ],
          ],
        );
      },
    );
  }
}
