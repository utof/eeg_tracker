// The night screen's layout, from a plain view model, so it can be rendered in tests without a phone.
import 'package:flutter/material.dart';

import '../recorder/contact.dart';
import '../recorder/status.dart' show BoardLive;
import 'alarm_view.dart';
import 'diy_board_view.dart';
import 'home_tabs.dart';
import 'lights_off_view.dart';
import '../share/control.dart' show ShareLine;
import 'night_strip.dart';
import 'own_ble_screen.dart' show OwnBleEntry;
import 'parts.dart';
import 'phone_checks.dart';
import 'share_sheet.dart';
import 'sleep_report_view.dart' show durationParts, nightTitle;
import 'sleep_so_far_view.dart' show SoFarSection;
import 'theme.dart';
import 'try_these_screen.dart' show TryTheseEntry;

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
    this.soFarLine,
    this.dreamLine,
    this.lightsOffLine,
    this.lightsOffTapped = false,
    this.napLine,
    this.share,
    this.alarmLine,
    this.alarmAction,
    this.ringing,
    this.lucidLine,
    this.memoryLine,
    this.board,
    this.diyNames,
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

  /// While a night records: the Sleep so far section's line (the last look, or the DIY board's refusal); null: none.
  final String? soFarLine;

  /// The dream catcher's newest session in a line ("Last session: 3 answers, Tue 18 Nov 23:10"), if any.
  final String? dreamLine;

  /// While a night records: the line above Lights off (lights_off_view.dart), and whether it was tapped tonight.
  final String? lightsOffLine;
  final bool lightsOffTapped;

  /// The nap coach's newest nap in a line ("Last nap: 30 min, woke you before deep sleep"), if any.
  final String? napLine;

  /// Share on Wi-Fi's switch and sentence (lib/share/control.dart `line`); null until the setting is read.
  final ShareLine? share;

  /// The smart alarm's line in the pinned bar (alarm_view.dart) and its text button: `Set alarm` / `Change` /
  /// `Turn off` between nights, `Alarm off` during one (null: no button).
  final String? alarmLine;
  final String? alarmAction;

  /// While the alarm rings: why it rang, for the wake face.
  final String? ringing;

  /// Lucid dream cues in a line ("On: practise before you sleep."), when they were ever used (DECISIONS 308).
  final String? lucidLine;

  /// Memory cues in a line ("On: learn the board before Start night."), once switched on (DECISIONS 508); null: no
  /// section (they live in Settings).
  final String? memoryLine;

  /// The DIY board while one records (its channels, mode and swing); null for the BrainBit.
  final BoardLive? board;

  /// The DIY board's channel names while it is chosen as the headband (DECISIONS rows 360-369); null: the BrainBit.
  final List<String>? diyNames;

  bool get diy => diyNames != null;
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
    this.onShare,
    this.onShareDetails,
    this.onMeditate,
    this.onDream,
    this.onNap,
    this.onLucid,
    this.onMemory,
    this.onSound,
    this.onWork,
    this.onSleepReport,
    this.onRetrySleep,
    this.onSleepSoFar,
    this.morning,
    this.onLightsOff,
    this.onSettings,
    this.onAlarm,
    this.onAwake,
    this.onHeadbandPage,
    this.tab,
    this.onLicences,
  });

  final NightViewModel model;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final void Function(FixAction action) onFix;
  final VoidCallback? onExport;
  final VoidCallback? onExportData;
  final ValueChanged<bool>? onShare;
  final VoidCallback? onShareDetails;
  final VoidCallback? onMeditate;
  final VoidCallback? onDream;
  final VoidCallback? onNap;
  final VoidCallback? onLucid;

  /// The Memory cues page (DECISIONS 508); its section shows only with a [NightViewModel.memoryLine].
  final VoidCallback? onMemory;
  final VoidCallback? onSound;

  /// The work session (ROADMAP row 35): holds the headband, so only between nights.
  final VoidCallback? onWork;
  final VoidCallback? onSleepReport;
  final VoidCallback? onRetrySleep;

  /// Opens "Sleep so far" while a night records (DECISIONS 640-649); null: no button (the DIY board).
  final VoidCallback? onSleepSoFar;

  /// The Morning section (check-in and trends; morning_section.dart), shown between nights after Sleep.
  final Widget? morning;

  /// Lights off while a night records (DECISIONS 180).
  final VoidCallback? onLightsOff;

  /// Settings (hands-free controls, DECISIONS 248); no gear when null.
  final VoidCallback? onSettings;

  /// The alarm line's button ([NightViewModel.alarmAction]); "I'm awake" while it rings (DECISIONS 235-236).
  final VoidCallback? onAlarm;
  final VoidCallback? onAwake;

  /// Back from the Headband connection page (the device choice may have changed).
  final VoidCallback? onHeadbandPage;

  /// The bottom bar's tab this page is (home_tabs.dart, DECISIONS 597): its sections only, and the pinned bar only on
  /// Night; null: every section on one page, as before the tabs.
  final HomeTab? tab;

  /// The licences page (More).
  final VoidCallback? onLicences;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final ringing = m.ringing;
    if (ringing != null) return WakeFace(reason: ringing, onAwake: onAwake ?? () {});
    final sleep = m.sleep;
    final text = Theme.of(context).textTheme;
    final headband = [const SectionHeading('Headband'), _Headband(m)];
    return Scaffold(
      appBar: AppBar(
        title: Text(tab?.title ?? 'EEG Tracker', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          if (onSettings != null && (tab == null || tab == HomeTab.night)) ...[
            IconButton(
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              color: Night.inkMuted,
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: ListView(
        key: PageStorageKey('home-${tab?.name}'),
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: sectionsFor(tab, [
          _Status(m),
          if (m.minutes != null) ...[const SizedBox(height: 28), _Readouts(m)],
          if (m.rows.isNotEmpty) ...[SectionHeading(m.stripTitle), NightStrip(rows: m.rows)],
          // While a night records, the night so far right under its strip: scored only when its page opens.
          if (m.running && m.soFarLine != null) ...[
            const SectionHeading('Sleep so far'),
            SoFarSection(line: m.soFarLine!, onOpen: onSleepSoFar),
          ],
          // In the morning the night's sleep comes right after its strip. The DIY board's nights get no report.
          if (!m.running && (sleep != null || m.diy)) ...[
            const SectionHeading('Sleep'),
            if (m.diy) ...[
              Text(
                'No sleep report for the DIY board\'s nights: it reads the BrainBit\'s O1 O2 T3 T4.',
                style: text.bodyLarge?.copyWith(height: 1.4),
              ),
              if (sleep != null) const SizedBox(height: 16),
            ],
            if (sleep != null) _Sleep(sleep, onOpen: onSleepReport, onRetry: onRetrySleep),
          ],
          if (!m.running && morning != null) ...[const SectionHeading('Morning'), morning!],
          // Each feature's first try and what to tell the assistant afterwards (DECISIONS 340), between nights.
          if (!m.running)
            ...[
              const SectionHeading('Try these'),
              // read again when the newest night's report changes, not every minute (DECISIONS 620-629)
              TryTheseEntry(
                onSleepReport: onSleepReport,
                onAlarm: onAlarm,
                changed: (sleep?.nightOf, sleep?.scored, sleep?.scoringStep == null),
              ),
            ],
          // Before the night the phone settings matter most; during it, the headband.
          if (m.running) ...headband,
          const SectionHeading('Phone'),
          PhoneChecksList(checks: m.checks, onFix: onFix),
          // Between nights the Headband section also leads to the connection page (the probe and the switch).
          if (!m.running) ...[...headband, OwnBleEntry(onReturn: onHeadbandPage, diy: m.diy)],
          const TabStart(HomeTab.more),
          // A night being recorded is not finished, so Export waits for Stop (DECISIONS rows 56, 150); Share on
          // Wi-Fi is there during the night too (rows 220-229).
          if (m.share != null || (!m.running && (m.nightsOnPhone > 0 || m.exportLine != null))) ...[
            const SectionHeading('Your data'),
            _YourData(
              running: m.running,
              nights: m.nightsOnPhone,
              line: m.exportLine,
              onExportData: onExportData,
              onExport: onExport,
              share: m.share,
              onShare: onShare,
              onShareDetails: onShareDetails,
            ),
          ],
          // More (the bottom bar): Settings and the licences, here as a section; on one page they are the night
          // screen's gear and the sleep report's link
          if (tab == HomeTab.more) ...[const SectionHeading('Settings'), _More(onSettings: onSettings, onLicences: onLicences)],
          const TabStart(HomeTab.sessions),
          if (tab == HomeTab.sessions && m.running) _Busy(),
          // The headband connects to one thing at a time, so meditation waits for the night to end.
          if (!m.running) ...[const SectionHeading('Meditation'), _Meditation(onMeditate: onMeditate)],
          // The dream catcher holds the headband too, so it also waits for the night to end (DECISIONS row 110).
          if (!m.running) ...[const SectionHeading('Dream catcher'), _Dream(line: m.dreamLine, onDream: onDream)],
          // The nap coach holds the headband too (DECISIONS row 173).
          if (!m.running) ...[const SectionHeading('Nap coach'), _Nap(line: m.napLine, onNap: onNap)],
          // Lucid dream cues: the evening practice and the morning questions, between nights (DECISIONS 308).
          if (!m.running && onLucid != null) ...[const SectionHeading('Lucid dreams'), _Lucid(line: m.lucidLine, onLucid: onLucid)],
          // Memory cues, the assistant's proposal: the evening task and the morning test, once switched on (DECISIONS
          // 508).
          if (!m.running && onMemory != null && m.memoryLine != null) ...[
            const SectionHeading('Memory cues'),
            _Memory(line: m.memoryLine!, onMemory: onMemory),
          ],
          // The work session holds the headband too, so it waits for the night to end (DECISIONS 447).
          if (!m.running && onWork != null) ...[const SectionHeading('Work'), _Work(onWork: onWork)],
          // Sound for states also plays during a night, by its timer alone (DECISIONS row 130).
          const SectionHeading('Sound'),
          _Sound(running: m.running, onSound: onSound),
        ]),
      ),
      bottomNavigationBar: tab != null && tab != HomeTab.night
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: _Action(m, onStart: onStart, onStop: onStop, onLightsOff: onLightsOff, onAlarm: onAlarm),
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
    final board = m.board;
    if (m.running && board != null) return DiyNightBlock(board: board);
    if (m.diyNames != null) return DiyIdleBlock(names: m.diyNames!);
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
  const _YourData({
    required this.running,
    required this.nights,
    required this.line,
    required this.onExportData,
    required this.onExport,
    this.share,
    this.onShare,
    this.onShareDetails,
  });
  final bool running;
  final ShareLine? share;
  final ValueChanged<bool>? onShare;
  final VoidCallback? onShareDetails;
  final int nights;
  final ({String text, bool warn})? line;
  final VoidCallback? onExportData;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final l = line;
    final s = share;
    final sharing = s == null ? null : ShareRow(line: s, onChanged: onShare, onDetails: onShareDetails);
    if (running) return sharing ?? const SizedBox.shrink();
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
        if (sharing != null) ...[const SizedBox(height: 20), const Divider(), const SizedBox(height: 8), sharing],
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
            '${n == 0
                ? 'No sleep period'
                : n == 1
                ? '1 sleep period'
                : '$n sleep periods'}. A first guess: the sleep '
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

/// More's Settings section: the settings page (hands-free, study reminders, "Was this you?") and the licences.
class _More extends StatelessWidget {
  const _More({required this.onSettings, required this.onLicences});
  final VoidCallback? onSettings;
  final VoidCallback? onLicences;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hands-free controls, study reminders, "Was this you?" and the other switches.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: onSettings, icon: const Icon(Icons.settings_outlined), label: const Text('Settings')),
        if (onLicences != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onLicences, child: const Text('Licences')),
          ),
        ],
      ],
    );
  }
}

/// Sessions while a night records: why most of them wait.
class _Busy extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      'The headband is busy with the night: the sessions that use it start after Stop. Sound plays by its timer.',
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
    ),
  );
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

class _Nap extends StatelessWidget {
  const _Nap({required this.line, required this.onNap});
  final String? line;
  final VoidCallback? onNap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'A nap that ends before deep sleep starts, or at the length you pick, with a soft rising sound.',
          style: muted,
        ),
        if (line != null) ...[const SizedBox(height: 8), Text(line!, style: text.bodyLarge?.copyWith(height: 1.4))],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onNap,
          icon: const Icon(Icons.airline_seat_flat_angled_outlined),
          label: const Text('Nap coach'),
        ),
      ],
    );
  }
}

class _Lucid extends StatelessWidget {
  const _Lucid({required this.line, required this.onLucid});
  final String? line;
  final VoidCallback? onLucid;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Soft sounds in dream sleep to help you notice you are dreaming: an evening practice, then the night. An '
          'experiment, with silent nights to test it.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        if (line != null) ...[const SizedBox(height: 8), Text(line!, style: text.bodyLarge?.copyWith(height: 1.4))],
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: onLucid, icon: const Icon(Icons.visibility_outlined), label: const Text('Lucid dreams')),
      ],
    );
  }
}

class _Memory extends StatelessWidget {
  const _Memory({required this.line, required this.onMemory});
  final String line;
  final VoidCallback? onMemory;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Soft sounds in deep sleep for one half of an evening task, tested the next morning. The assistant\'s '
          'proposal; the evidence is weak.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 8),
        Text(line, style: text.bodyLarge?.copyWith(height: 1.4)),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: onMemory, icon: const Icon(Icons.grid_view_outlined), label: const Text('Memory cues')),
      ],
    );
  }
}

class _Work extends StatelessWidget {
  const _Work({required this.onWork});
  final VoidCallback? onWork;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Wear the headband while you work: the phone watches for heavy eyelids and suggests a break now and then.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: onWork, icon: const Icon(Icons.laptop_outlined), label: const Text('Work session')),
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
  const _Action(this.m, {required this.onStart, required this.onStop, this.onLightsOff, this.onAlarm});
  final NightViewModel m;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback? onLightsOff;
  final VoidCallback? onAlarm;

  @override
  Widget build(BuildContext context) {
    if (m.running && onLightsOff != null) {
      return NightActions(
        line: m.lightsOffLine,
        tapped: m.lightsOffTapped,
        busy: m.busy,
        onLightsOff: onLightsOff,
        onStop: onStop,
        alarmLine: m.alarmLine,
        onAlarmOff: m.alarmAction == null ? null : onAlarm,
      );
    }
    if (m.running) {
      return OutlinedButton.icon(
        onPressed: m.busy ? null : onStop,
        icon: const Icon(Icons.stop_rounded),
        label: Text(m.busy ? 'Stopping…' : 'Stop'),
      );
    }
    final start = FilledButton.icon(
      onPressed: m.busy ? null : onStart,
      icon: const Icon(Icons.bedtime_outlined),
      label: Text(m.busy ? 'Starting…' : 'Start night'),
    );
    final line = m.alarmLine;
    if (line == null) return start;
    // the alarm is set where the night is started, like the Lights off line above Lights off (DECISIONS 233)
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 4),
        AlarmLine(line: line, action: m.alarmAction ?? 'Set alarm', onAction: m.busy ? null : onAlarm),
        const SizedBox(height: 4),
        start,
      ],
    );
  }
}
