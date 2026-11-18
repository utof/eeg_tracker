// The night screen's layout, from a plain view model, so it can be rendered in tests without a phone.
import 'package:flutter/material.dart';

import '../recorder/contact.dart';
import 'night_strip.dart';
import 'phone_checks.dart';
import 'theme.dart';

enum Tone { calm, live, caution, problem }

class NightViewModel {
  const NightViewModel({
    required this.title,
    required this.sentence,
    required this.tone,
    required this.running,
    this.busy = false,
    this.minutes,
    this.dataAgeSeconds,
    this.coverage,
    this.stripTitle = 'Tonight',
    this.rows = const [],
    this.battery,
    this.rssi,
    this.contactOhms = const {},
    this.checks = const [],
    this.filesPath,
  });

  final String title;
  final String sentence;
  final Tone tone;

  /// A night is being recorded (the service runs).
  final bool running;

  /// Start or Stop is in progress.
  final bool busy;
  final double? minutes;
  final int? dataAgeSeconds;

  /// Share of the night saved (0..1), shown in the morning.
  final double? coverage;
  final String stripTitle;
  final List<StripRow> rows;
  final int? battery;
  final int? rssi;

  /// Empty: no contact check yet.
  final Map<String, double?> contactOhms;
  final List<PhoneCheck> checks;
  final String? filesPath;
}

class NightView extends StatelessWidget {
  const NightView({super.key, required this.model, required this.onStart, required this.onStop, required this.onFix});

  final NightViewModel model;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final void Function(FixAction action) onFix;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final headband = [const _Heading('Headband'), _Headband(m)];
    return Scaffold(
      appBar: AppBar(
        title: Text('EEG Tracker', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _Status(m),
          if (m.minutes != null) ...[const SizedBox(height: 28), _Readouts(m)],
          if (m.rows.isNotEmpty) ...[_Heading(m.stripTitle), NightStrip(rows: m.rows)],
          // Before the night the phone settings matter most; during it, the headband.
          if (m.running) ...headband,
          const _Heading('Phone'),
          PhoneChecksList(checks: m.checks, onFix: onFix),
          if (!m.running) ...headband,
          if (m.filesPath != null) ...[
            const SizedBox(height: 32),
            Text('Files: ${m.filesPath}', style: text.bodySmall?.copyWith(color: Night.inkMuted)),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: _Action(m, onStart: onStart, onStop: onStop),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32, bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 20),
        Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
      ],
    ),
  );
}

Color _toneColor(Tone t) => switch (t) {
  Tone.calm => Night.inkMuted,
  Tone.live => Night.live,
  Tone.caution => Night.caution,
  Tone.problem => Night.problem,
};

class _Status extends StatelessWidget {
  const _Status(this.m);
  final NightViewModel m;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Mark(tone: m.tone),
              const SizedBox(width: 14),
              Expanded(child: Text(m.title, style: text.displaySmall)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            m.sentence,
            style: text.bodyLarge?.copyWith(
              color: m.tone == Tone.caution || m.tone == Tone.problem ? _toneColor(m.tone) : Night.inkMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// The state mark beside the title. While live it breathes slowly: the one motion on the screen.
class _Mark extends StatefulWidget {
  const _Mark({required this.tone});
  final Tone tone;

  @override
  State<_Mark> createState() => _MarkState();
}

class _MarkState extends State<_Mark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Mark old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final breathe = widget.tone == Tone.live && !MediaQuery.disableAnimationsOf(context);
    if (breathe && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!breathe && _c.isAnimating) {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _toneColor(widget.tone);
    final hollow = widget.tone == Tone.calm;
    return FadeTransition(
      opacity: _c.drive(Tween(begin: 1.0, end: 0.4).chain(CurveTween(curve: Curves.easeInOutSine))),
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hollow ? null : color,
          border: hollow ? Border.all(color: color, width: 2) : null,
        ),
      ),
    );
  }
}

class _Readouts extends StatelessWidget {
  const _Readouts(this.m);
  final NightViewModel m;

  @override
  Widget build(BuildContext context) {
    final age = m.dataAgeSeconds;
    final ageColor = !m.running || age == null || age < 5 ? Night.ink : (age < 40 ? Night.caution : Night.problem);
    final second = m.running
        ? _Readout(parts: _age(age), label: 'since the last data', color: ageColor)
        : _Readout(
            parts: [(m.coverage == null ? '–' : '${(m.coverage! * 100).floor()}', true), (' %', false)],
            label: 'of the night saved',
          );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Readout(parts: _minutes(m.minutes!), label: m.running ? 'recorded' : 'recorded last night'),
          ),
          const VerticalDivider(width: 33),
          Expanded(child: second),
        ],
      ),
    );
  }

  static List<(String, bool)> _minutes(double minutes) {
    final total = minutes.floor();
    if (total < 60) return [('$total', true), (' min', false)];
    return [('${total ~/ 60}', true), (' h ', false), ((total % 60).toString().padLeft(2, '0'), true), (' min', false)];
  }

  static List<(String, bool)> _age(int? s) {
    if (s == null) return [('–', true)];
    if (s < 120) return [('$s', true), (' s', false)];
    if (s < 7200) return [('${s ~/ 60}', true), (' min', false)];
    return [('${s ~/ 3600}', true), (' h', false)];
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.parts, required this.label, this.color = Night.ink});

  /// (text, isNumber): numbers large, units small.
  final List<(String, bool)> parts;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final big = text.displayMedium?.copyWith(color: color);
    final unit = text.titleLarge?.copyWith(color: color == Night.ink ? Night.inkMuted : color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [for (final (s, isNumber) in parts) TextSpan(text: s, style: isNumber ? big : unit)],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
      ],
    );
  }
}

class _Headband extends StatelessWidget {
  const _Headband(this.m);
  final NightViewModel m;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final value = text.titleLarge?.copyWith(fontFeatures: tabular);
    final rssi = m.rssi;
    final connected = m.battery != null || rssi != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!connected) Text(m.running ? 'Not connected yet.' : 'Not connected.', style: text.bodyLarge),
        if (connected)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Battery', style: muted),
                    const SizedBox(height: 4),
                    Text(m.battery == null ? '–' : '${m.battery} %', style: value),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Signal at connect', style: muted),
                    const SizedBox(height: 4),
                    Text(
                      rssi == null ? '–' : '${_signalWord(rssi)}, ${rssi < 0 ? '−${-rssi}' : '$rssi'} dBm',
                      style: value,
                    ),
                  ],
                ),
              ),
            ],
          ),
        const SizedBox(height: 24),
        Text(m.running ? 'Contact' : 'Contact at the start of the last night', style: muted),
        const SizedBox(height: 10),
        if (m.contactOhms.isEmpty)
          Text('Checked once, when the night starts.', style: text.bodyLarge)
        else
          Row(
            children: [for (final n in channelNames) Expanded(child: _ContactCell(n, classifyOhms(m.contactOhms[n])))],
          ),
      ],
    );
  }

  /// Planning thresholds for Bluetooth LE signal strength, not measured on this headband.
  static String _signalWord(int dbm) => dbm >= -70 ? 'strong' : (dbm >= -85 ? 'fair' : 'weak');
}

class _ContactCell extends StatelessWidget {
  const _ContactCell(this.channel, this.contact);
  final String channel;
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color, word) = switch (contact) {
      Contact.good => (Icons.circle, Night.live, 'good'),
      Contact.fair => (Icons.adjust, Night.caution, 'fair'),
      Contact.poor => (Icons.radio_button_unchecked, Night.problem, 'poor'),
      Contact.none => (Icons.remove, Night.inkMuted, 'none'),
    };
    return Semantics(
      label: '$channel contact $word',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(channel, style: text.titleMedium),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(word, style: text.bodyLarge?.copyWith(color: color)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.m, {required this.onStart, required this.onStop});
  final NightViewModel m;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    if (m.running) {
      return OutlinedButton.icon(
        onPressed: m.busy ? null : onStop,
        icon: const Icon(Icons.stop_rounded),
        label: Text(m.busy ? 'Stopping…' : 'Stop'),
      );
    }
    return FilledButton.icon(
      onPressed: m.busy ? null : onStart,
      icon: const Icon(Icons.bedtime_outlined),
      label: Text(m.busy ? 'Starting…' : 'Start night'),
    );
  }
}
