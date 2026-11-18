// The night screen's layout, from a plain view model, so it can be rendered in tests without a phone.
import 'package:flutter/material.dart';

import '../recorder/contact.dart';
import 'night_strip.dart';
import 'parts.dart';
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
    this.nightsOnPhone = 0,
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

  /// Finished nights kept in the app's private folder (Export copies one out).
  final int nightsOnPhone;
}

class NightView extends StatelessWidget {
  const NightView({
    super.key,
    required this.model,
    required this.onStart,
    required this.onStop,
    required this.onFix,
    this.onExport,
    this.onMeditate,
  });

  final NightViewModel model;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final void Function(FixAction action) onFix;
  final VoidCallback? onExport;
  final VoidCallback? onMeditate;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final headband = [const SectionHeading('Headband'), _Headband(m)];
    return Scaffold(
      appBar: AppBar(
        title: Text('EEG Tracker', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _Status(m),
          if (m.minutes != null) ...[const SizedBox(height: 28), _Readouts(m)],
          if (m.rows.isNotEmpty) ...[SectionHeading(m.stripTitle), NightStrip(rows: m.rows)],
          // Before the night the phone settings matter most; during it, the headband.
          if (m.running) ...headband,
          const SectionHeading('Phone'),
          PhoneChecksList(checks: m.checks, onFix: onFix),
          if (!m.running) ...headband,
          // A night being recorded is not finished, so Export waits for Stop.
          if (!m.running && m.nightsOnPhone > 0) ...[
            const SectionHeading('Recordings'),
            _Recordings(nights: m.nightsOnPhone, onExport: onExport),
          ],
          // The headband connects to one thing at a time, so meditation waits for the night to end.
          if (!m.running) ...[const SectionHeading('Meditation'), _Meditation(onMeditate: onMeditate)],
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
        ? Readout(parts: _age(age), label: 'since the last data', color: ageColor)
        : Readout(
            parts: [(m.coverage == null ? '–' : '${(m.coverage! * 100).floor()}', true), (' %', false)],
            label: 'of the night saved',
          );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Readout(parts: _minutes(m.minutes!), label: m.running ? 'recorded' : 'recorded last night'),
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
            children: [for (final n in channelNames) Expanded(child: ContactCell(n, classifyOhms(m.contactOhms[n])))],
          ),
      ],
    );
  }

  /// Planning thresholds for Bluetooth LE signal strength, not measured on this headband.
  static String _signalWord(int dbm) => dbm >= -70 ? 'strong' : (dbm >= -85 ? 'fair' : 'weak');
}

class _Recordings extends StatelessWidget {
  const _Recordings({required this.nights, required this.onExport});
  final int nights;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${nights == 1 ? '1 night' : '$nights nights'} on this phone, kept inside the app where other apps '
          'cannot read them.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onExport,
          icon: const Icon(Icons.drive_folder_upload_outlined),
          label: const Text('Export a night'),
        ),
      ],
    );
  }
}

class _Meditation extends StatelessWidget {
  const _Meditation({required this.onMeditate});
  final VoidCallback? onMeditate;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '5 to 20 minutes eyes closed, with rain and a drone that follow your alpha rhythm, and a short report '
          'after.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onMeditate,
          icon: const Icon(Icons.self_improvement),
          label: const Text('Meditate'),
        ),
      ],
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
