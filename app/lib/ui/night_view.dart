// The night screen's layout, from a plain view model, so it can be rendered in tests without a phone.
import 'package:flutter/material.dart';

import '../recorder/contact.dart';
import 'lights_off_view.dart';
import 'night_strip.dart';
import 'parts.dart';
import 'phone_checks.dart';
import 'sleep_report_view.dart' show durationParts, nightTitle;
import 'theme.dart';

enum Tone { calm, live, caution, problem }

/// The Sleep section: the newest night's report, or what the scorer is doing.
class SleepSummary {
  const SleepSummary({
    required this.nightOf,
    this.scored = false,
    this.asleepMin,
    this.periods = 0,
    this.scoringStep,
    this.blocked,
  });

  /// `2026-11-17`.
  final String nightOf;
  final bool scored;
  final double? asleepMin;
  final int periods;

  /// Set while this night is being scored.
  final String? scoringStep;

  /// Why its scoring stopped ('' when the app stopped while scoring), or null.
  final String? blocked;
}

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
    this.exportLine,
    this.sleep,
    this.dreamLine,
    this.lightsOffLine,
    this.lightsOffTapped = false,
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

  /// Finished nights kept in the app's private folder (Export a night copies one out).
  final int nightsOnPhone;

  /// When the last export was and what is only on this phone since (lib/export/store.dart `exportLine`); null
  /// when there is nothing to export. [warn] from 3 days with something new, or never exported.
  final ({String text, bool warn})? exportLine;

  /// The Sleep section, shown between nights.
  final SleepSummary? sleep;

  /// The dream catcher's newest session in a line ("Last session: 3 answers, Tue 18 Nov 23:10"), if any.
  final String? dreamLine;

  /// While a night records: the line above Lights off (lights_off_view.dart), and whether it was tapped tonight.
  final String? lightsOffLine;
  final bool lightsOffTapped;
}

class NightView extends StatelessWidget {
  const NightView({
    super.key,
    required this.model,
    required this.onStart,
    required this.onStop,
    required this.onFix,
    this.onExport,
    this.onExportData,
    this.onMeditate,
    this.onDream,
    this.onSound,
    this.onSleepReport,
    this.onRetrySleep,
    this.morning,
    this.onLightsOff,
  });

  final NightViewModel model;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final void Function(FixAction action) onFix;
  final VoidCallback? onExport;
  final VoidCallback? onExportData;
  final VoidCallback? onMeditate;
  final VoidCallback? onDream;
  final VoidCallback? onSound;
  final VoidCallback? onSleepReport;
  final VoidCallback? onRetrySleep;

  /// The Morning section (check-in and trends; morning_section.dart), shown between nights after Sleep.
  final Widget? morning;

  /// Lights off while a night records (DECISIONS 180).
  final VoidCallback? onLightsOff;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final sleep = m.sleep;
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
          // In the morning the night's sleep comes right after its strip.
          if (!m.running && sleep != null) ...[
            const SectionHeading('Sleep'),
            _Sleep(sleep, onOpen: onSleepReport, onRetry: onRetrySleep),
          ],
          if (!m.running && morning != null) ...[const SectionHeading('Morning'), morning!],
          // Before the night the phone settings matter most; during it, the headband.
          if (m.running) ...headband,
          const SectionHeading('Phone'),
          PhoneChecksList(checks: m.checks, onFix: onFix),
          if (!m.running) ...headband,
          // A night being recorded is not finished, so Export waits for Stop (DECISIONS rows 56, 150).
          if (!m.running && (m.nightsOnPhone > 0 || m.exportLine != null)) ...[
            const SectionHeading('Your data'),
            _YourData(nights: m.nightsOnPhone, line: m.exportLine, onExportData: onExportData, onExport: onExport),
          ],
          // The headband connects to one thing at a time, so meditation waits for the night to end.
          if (!m.running) ...[const SectionHeading('Meditation'), _Meditation(onMeditate: onMeditate)],
          // The dream catcher holds the headband too, so it also waits for the night to end (DECISIONS row 110).
          if (!m.running) ...[const SectionHeading('Dream catcher'), _Dream(line: m.dreamLine, onDream: onDream)],
          // Sound for states also plays during a night, by its timer alone (DECISIONS row 130).
          const SectionHeading('Sound'),
          _Sound(running: m.running, onSound: onSound),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: _Action(m, onStart: onStart, onStop: onStop, onLightsOff: onLightsOff),
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

/// What the app keeps, when it last left the phone (amber, with a mark and words, once it gets old), Export data
/// (everything new, its own page) and Export a night (one night into a folder of its own).
class _YourData extends StatelessWidget {
  const _YourData({required this.nights, required this.line, required this.onExportData, required this.onExport});
  final int nights;
  final ({String text, bool warn})? line;
  final VoidCallback? onExportData;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final l = line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          nights == 0
              ? 'Kept inside the app, where other apps cannot read it.'
              : '${nights == 1 ? '1 night' : '$nights nights'} and everything else on this phone, kept inside the app '
                    'where other apps cannot read them.',
          style: muted,
        ),
        if (l != null) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  l.warn ? Icons.warning_amber_rounded : Icons.history,
                  size: 22,
                  color: l.warn ? Night.caution : Night.inkMuted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(l.text, style: l.warn ? muted?.copyWith(color: Night.caution) : muted),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onExportData,
          icon: const Icon(Icons.drive_folder_upload_outlined),
          label: const Text('Export data'),
        ),
        if (nights > 0) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onExport,
            icon: const Icon(Icons.nightlight_outlined),
            label: const Text('Export a night'),
          ),
        ],
      ],
    );
  }
}

class _Sleep extends StatelessWidget {
  const _Sleep(this.s, {required this.onOpen, required this.onRetry});
  final SleepSummary s;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final night = nightTitle(s.nightOf);
    final body = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final open = OutlinedButton.icon(
      onPressed: onOpen,
      icon: const Icon(Icons.bar_chart_rounded),
      label: const Text('Sleep report'),
    );
    if (s.scoringStep != null) {
      return Text('Scoring the night of $night on the phone: ${s.scoringStep}.', style: body);
    }
    if (s.blocked != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.blocked!.isEmpty
                ? 'Scoring the night of $night stopped before it finished.'
                : 'Scoring the night of $night failed: ${s.blocked}',
            style: body?.copyWith(color: Night.caution),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
        ],
      );
    }
    final n = s.periods;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (s.scored)
          Readout(parts: durationParts(s.asleepMin ?? 0), label: 'asleep, night of $night')
        else
          Text('The night of $night was too short to score.', style: body),
        if (s.scored) ...[
          const SizedBox(height: 12),
          Text(
            '${n == 0 ? 'No sleep period' : n == 1 ? '1 sleep period' : '$n sleep periods'}. A first guess: the sleep '
            'model is not yet validated on this headband.',
            style: body,
          ),
        ],
        const SizedBox(height: 16),
        open,
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

class _Dream extends StatelessWidget {
  const _Dream({required this.line, required this.onDream});
  final String? line;
  final VoidCallback? onDream;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'At bedtime or a nap: as you drift off, the app asks what is on your mind and records your answer, 3 or 4 '
          'times. For ideas.',
          style: muted,
        ),
        if (line != null) ...[const SizedBox(height: 8), Text(line!, style: text.bodyLarge?.copyWith(height: 1.4))],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onDream,
          icon: const Icon(Icons.nights_stay_outlined),
          label: const Text('Dream catcher'),
        ),
      ],
    );
  }
}

class _Sound extends StatelessWidget {
  const _Sound({required this.running, required this.onSound});
  final bool running;
  final VoidCallback? onSound;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          running
              ? 'Calm sound to fall asleep to, stopping by its timer (the headband is busy with the night).'
              : 'Calm sound for falling asleep, relaxing, focus, a break or waking up; a beat if you like. With the '
                    'headband, see what your brain does.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: onSound, icon: const Icon(Icons.graphic_eq), label: const Text('Sound')),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.m, {required this.onStart, required this.onStop, this.onLightsOff});
  final NightViewModel m;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback? onLightsOff;

  @override
  Widget build(BuildContext context) {
    if (m.running && onLightsOff != null) {
      return NightActions(
        line: m.lightsOffLine,
        tapped: m.lightsOffTapped,
        busy: m.busy,
        onLightsOff: onLightsOff,
        onStop: onStop,
      );
    }
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
