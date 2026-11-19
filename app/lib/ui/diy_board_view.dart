// The DIY ADS1299 board on the phone's pages (DECISIONS rows 360-369), inside DESIGN.md: the device choice
// "Headband: BrainBit / DIY board (test)" (the app's segmented row), the board's section of the Headband connection
// page (the safety rule, where the board sends, its channel names, what is off with it), and the night screen's
// Headband block while a DIY night records (each channel's swing over the last second in the contact cells' place,
// the mode in words with "not EEG", the link). Hairline sections, label-left / value-right rows, words beside every
// colour. Built from plain models only, so tests render every state.
import 'package:flutter/material.dart';

import '../headband/diy/e9.dart' show diyUdpPort;
import '../headband/diy/settings.dart';
import '../recorder/status.dart' show BoardLive;
import 'form_parts.dart' show Para;
import 'meditation_view.dart' show MarkShape, StateMark;
import 'parts.dart';
import 'theme.dart';

/// What the Headband connection page shows about the board.
class DiyPageModel {
  const DiyPageModel({this.useDiy = false, this.names = defaultDiyNames, this.address, this.port = diyUdpPort});

  final bool useDiy;
  final List<String> names;

  /// This phone's Wi-Fi address now (the board's UDP_HOST), or null when it is not on Wi-Fi.
  final String? address;
  final int port;
}

/// Title and sentence at the top of the page while the board is chosen.
({String title, String sentence}) describeDiyPage(DiyPageModel m) => (
  title: 'DIY board (test)',
  sentence:
      'Nights record your board over Wi-Fi, into a folder of their own. The sessions, the sleep report and the '
      'check-in wait for the BrainBit.',
);

/// The app's segmented row: BrainBit or the DIY board. Locked (null) while a night records or a session runs.
class DeviceChoice extends StatelessWidget {
  const DeviceChoice({super.key, required this.diy, required this.onChanged});
  final bool diy;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('BrainBit')),
              ButtonSegment(value: true, label: Text('DIY board (test)')),
            ],
            selected: {diy},
            showSelectedIcon: false,
            onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.first),
            style: SegmentedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              selectedBackgroundColor: Night.surfaceHigh,
              selectedForegroundColor: Night.ink,
              foregroundColor: Night.inkMuted,
              side: const BorderSide(color: Night.rule),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          diy
              ? 'Nights only, as a test. Switch back here at any time.'
              : 'BrainBit for nights and every session. The DIY board is the ADS1299 board you build.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
      ],
    );
  }
}

/// Label left, value right in tabular titleLarge (DESIGN.md's log rows).
class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: SelectableText(
              value,
              textAlign: TextAlign.end,
              style: text.titleLarge?.copyWith(fontFeatures: tabular),
            ),
          ),
        ],
      ),
    );
  }
}

/// The board's part of the Headband connection page, under the status and the choice.
class DiySection extends StatelessWidget {
  const DiySection({super.key, required this.model, this.onNames});
  final DiyPageModel model;

  /// Saves new channel names (already checked); null while the page is locked.
  final ValueChanged<List<String>>? onNames;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading('Safety'),
        Text(
          'This app only listens. It never sends the board anything: its prompts (R, V, then T or N) are yours to '
          'answer in a serial terminal.',
          style: text.bodyLarge?.copyWith(height: 1.45),
        ),
        const Para(
          'Nothing in this app makes the board safe to put on a body or to power, and nothing here changes its '
          'safety gates. Follow the bring-up card in eeg_ads1299_lab, step by step.',
        ),
        const SectionHeading('Where the board sends'),
        if (m.address != null) _Row('This phone', m.address!) else _NoWifi(),
        _Row('Port', 'UDP ${m.port}'),
        const SizedBox(height: 12),
        Text(
          'In the firmware\'s board_config.h: USE_WIFI_UDP = true, your Wi-Fi\'s name and password, and UDP_HOST = '
          '${m.address ?? 'this phone\'s address'}. The phone and the board must be on the same Wi-Fi. The address can '
          'change when the phone joins again; reserving it in the router keeps it.',
          style: muted,
        ),
        const SectionHeading('Channels'),
        _ChannelNames(names: m.names, onSave: onNames),
        const SizedBox(height: 12),
        Text(
          'Names only. Until the firmware has an electrode mode, the chip records its own test signal or its shorted '
          'inputs, whatever the names say: not EEG.',
          style: muted,
        ),
        const SectionHeading('With the board'),
        Text(
          'Nights go to recordings-diy, apart from the BrainBit nights. Export data takes them; the laptop files them '
          'under _local/recordings-diy.',
          style: text.bodyLarge?.copyWith(height: 1.45),
        ),
        const Para(
          'Off until you switch back: the sleep report, the morning check-in, meditation and the other sessions, the '
          'drift-off detector and the smart alarm\'s sleep model. They read the BrainBit\'s O1 O2 T3 T4. The phone\'s '
          'alarm still rings.',
        ),
        const Para(
          'The 4-channel chip only (the laptop records the 8-channel one), and Wi-Fi only: the USB route is not built. '
          'No contact or battery reading.',
          color: Night.inkMuted,
        ),
      ],
    );
  }
}

class _NoWifi extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.wifi_off, size: 20, color: Night.caution)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'This phone is not on Wi-Fi now. Join the network the board uses.',
              style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// CH1-CH4's names: the four as they are now, a field to change them, Save.
class _ChannelNames extends StatefulWidget {
  const _ChannelNames({required this.names, this.onSave});
  final List<String> names;
  final ValueChanged<List<String>>? onSave;

  @override
  State<_ChannelNames> createState() => _ChannelNamesState();
}

class _ChannelNamesState extends State<_ChannelNames> {
  late final TextEditingController _c = TextEditingController(text: widget.names.join(', '));
  String? _problem;

  @override
  void didUpdateWidget(_ChannelNames old) {
    super.didUpdateWidget(old);
    if (old.names.join(',') != widget.names.join(',')) _c.text = widget.names.join(', ');
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _save() {
    final names = parseDiyNames(_c.text);
    final problem = diyNamesProblem(names);
    setState(() => _problem = problem);
    if (problem == null) {
      _c.text = names.join(', ');
      widget.onSave?.call(names);
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final changed = parseDiyNames(_c.text).join(',') != widget.names.join(',');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < widget.names.length; i++)
              Expanded(
                child: Semantics(
                  label: 'channel ${i + 1}: ${widget.names[i]}',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CH${i + 1}', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
                      const SizedBox(height: 4),
                      Text(widget.names[i], style: text.titleLarge, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _c,
          enabled: widget.onSave != null,
          onChanged: (_) => setState(() => _problem = null),
          onSubmitted: (_) => _save(),
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          style: text.bodyLarge,
          decoration: InputDecoration(
            labelText: 'Names, CH1 to CH4',
            helperText: 'Separated by commas, e.g. O1, O2, Fz, Fp1',
            errorText: _problem,
            errorMaxLines: 3,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: widget.onSave != null && changed ? _save : null, child: const Text('Save names')),
        ),
      ],
    );
  }
}

/// The mode in words for the night screen: what the chip records, and whether that is EEG.
String boardModeWords(BoardLive b) => switch (b.mode) {
  'test' => 'Test signal',
  'short' => 'Shorted inputs',
  'synthetic' => 'Made-up data',
  _ => 'Electrode inputs',
};

/// The night screen's Headband block while a DIY night records: the mode with "not EEG", each channel's swing over
/// the last second in the contact cells' place, the link.
class DiyNightBlock extends StatelessWidget {
  const DiyNightBlock({super.key, required this.board});
  final BoardLive board;

  @override
  Widget build(BuildContext context) {
    final b = board;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    final mode = boardModeWords(b);
    final lost = b.lost == 1 ? '1 sample lost' : '${b.lost} samples lost';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DIY board (test)', style: text.bodyLarge),
        const SizedBox(height: 12),
        Semantics(
          label: '$mode${b.notEeg ? ', not EEG' : ''}',
          excludeSemantics: true,
          child: Row(
            children: [
              StateMark(shape: MarkShape.ringedDot, color: b.notEeg ? Night.caution : Night.inkMuted, size: 16),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  b.notEeg ? '$mode, not EEG' : mode,
                  style: text.titleLarge?.copyWith(color: b.notEeg ? Night.caution : Night.ink),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Swing over the last second, µV', style: muted),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var i = 0; i < b.names.length; i++)
              Expanded(child: _Level(b.names[i], i < b.levelsUv.length ? b.levelsUv[i] : null)),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'UDP ${b.link.contains('port') ? _port(b.link) : diyUdpPort}${b.sender == null ? '' : ' from ${b.sender}'}'
          ' · $lost${b.bad > 0 ? ' · ${b.bad} damaged' : ''}',
          style: muted?.copyWith(fontFeatures: tabular),
        ),
      ],
    );
  }

  static String _port(String link) => RegExp(r'port (\d+)').firstMatch(link)?.group(1) ?? '$diyUdpPort';
}

class _Level extends StatelessWidget {
  const _Level(this.name, this.uv);
  final String name;
  final double? uv;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final v = uv;
    final shown = v == null ? '–' : (v >= 100 ? v.round().toString() : v.toStringAsFixed(1));
    return Semantics(
      label: v == null ? '$name: no reading yet' : '$name: $shown microvolts',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: text.titleMedium, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(shown, style: text.titleLarge?.copyWith(fontFeatures: tabular)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The night screen's Headband block between nights while the board is chosen.
class DiyIdleBlock extends StatelessWidget {
  const DiyIdleBlock({super.key, required this.names});
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DIY board (test). Not connected.', style: text.bodyLarge),
        const SizedBox(height: 8),
        Text(
          'Channels ${names.join(' ')}. No contact or battery reading from this board.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
      ],
    );
  }
}
