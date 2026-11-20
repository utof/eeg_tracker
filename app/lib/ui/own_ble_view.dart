// The "Headband connection" page's layout: which connection the app uses (BrainBit's SDK or our own), the probe
// that checks our own connection on the real headband, its result in plain sentences, and the switch. While the
// probe runs the page is one instruction in large type, the seconds left, and Stop. Built from a view model only,
// so tests render every state. Inside DESIGN.md: one column, hairline sections, state marks, one pinned action.
// Under the status, the device choice "Headband: BrainBit / DIY board (test)" (diy_board_view.dart, DECISIONS rows
// 360-369); with the board chosen the page is the board's section and has no pinned action.
import 'package:flutter/material.dart';

import '../headband/own/controller.dart' show OwnStage;
import 'diy_board_view.dart';
import 'form_parts.dart' show Para, PinnedAction;
import 'meditation_view.dart' show MarkShape, StateMark;
import 'parts.dart';
import 'lost_notice_setting.dart';
import 'theme.dart';

class OwnBleViewModel {
  const OwnBleViewModel({
    this.useOwn = false,
    this.triedAnyway = false,
    this.signalResist = false,
    this.probeAt,
    this.probePassed = false,
    this.probeWorn = false,
    this.probeLine = '',
    this.probeFolder,
    this.command5 = false,
    this.lines = const [],
    this.needsPairing = false,
    this.worn = true,
    this.pairFirst = false,
    this.stage = OwnStage.idle,
    this.stepText,
    this.stepName,
    this.secondsLeft = 0,
    this.fraction = 0,
    this.blocked,
    this.message = '',
    this.diy,
  });

  final bool useOwn, triedAnyway, signalResist;

  /// The last probe: its stamp (`2026-11-19-081500`), or null when none ran yet.
  final String? probeAt;
  final bool probePassed, probeWorn;
  final String probeLine;
  final String? probeFolder;
  final bool command5;
  final List<(bool?, String)> lines;
  final bool needsPairing;

  /// Options of the next run.
  final bool worn, pairFirst;
  final OwnStage stage;
  final String? stepText, stepName;
  final double secondsLeft, fraction;

  /// Why the probe and the switch are not offered now (a night records), or null.
  final String? blocked;
  final String message;

  /// The device choice and the DIY board's settings; null: the page without the choice.
  final DiyPageModel? diy;

  bool get busy => stage != OwnStage.idle;

  bool get diyOn => diy?.useDiy ?? false;
}

typedef OwnBleStatus = ({String title, String sentence, MarkShape mark, Color color});

/// `2026-11-19-081500` -> `19 Nov, 08:15`.
String probeWhen(String stamp) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})').firstMatch(stamp);
  if (m == null) return stamp;
  final month = int.parse(m.group(2)!);
  if (month < 1 || month > 12) return stamp;
  return '${int.parse(m.group(3)!)} ${months[month - 1]}, ${m.group(4)}:${m.group(5)}';
}

/// Title, sentence and mark for the top of the page. Pure, so it is tested without a phone.
OwnBleStatus describeOwnBle(OwnBleViewModel m) {
  if (m.blocked != null) {
    return (title: 'Not now', sentence: m.blocked!, mark: MarkShape.ring, color: Night.caution);
  }
  if (m.diyOn) {
    final d = describeDiyPage(m.diy!);
    return (title: d.title, sentence: d.sentence, mark: MarkShape.ringedDot, color: Night.caution);
  }
  if (m.useOwn) {
    final warn = !m.probePassed;
    return (
      title: 'Our own connection',
      sentence: warn
          ? 'Nights and sessions use our own connection, though the probe has not passed. If a night goes wrong, '
                "switch back to BrainBit's."
          : "Nights and sessions use our own connection (test). Switch back to BrainBit's at any time.",
      mark: warn ? MarkShape.ringedDot : MarkShape.filled,
      color: warn ? Night.caution : Night.live,
    );
  }
  if (m.probeAt == null) {
    return (
      title: "BrainBit's connection",
      sentence: "The app reaches the headband through BrainBit's own library. Our own connection is built, but it "
          'has not met your headband yet: run the probe first.',
      mark: MarkShape.ring,
      color: Night.inkMuted,
    );
  }
  if (m.probePassed) {
    return (
      title: "BrainBit's connection",
      sentence: 'The probe passed (${probeWhen(m.probeAt!)}). You can switch to our own connection below and try a night.',
      mark: MarkShape.ringedDot,
      color: Night.live,
    );
  }
  return (
    title: "BrainBit's connection",
    sentence: m.probeLine.isEmpty ? 'The last probe did not pass.' : m.probeLine,
    mark: MarkShape.ringedDot,
    color: Night.caution,
  );
}

class OwnBleView extends StatelessWidget {
  const OwnBleView({
    super.key,
    required this.model,
    this.onRun,
    this.onReady,
    this.onStop,
    this.onUseOwn,
    this.onTryAnyway,
    this.onSignalResist,
    this.onWorn,
    this.onPairFirst,
    this.onDevice,
    this.onNames,
  });

  final OwnBleViewModel model;
  final VoidCallback? onRun;
  final VoidCallback? onReady;
  final VoidCallback? onStop;
  final ValueChanged<bool>? onUseOwn;
  final VoidCallback? onTryAnyway;
  final ValueChanged<bool>? onSignalResist;
  final ValueChanged<bool>? onWorn;
  final ValueChanged<bool>? onPairFirst;

  /// The device choice: true = the DIY board (test).
  final ValueChanged<bool>? onDevice;

  /// New channel names for the board (already checked).
  final ValueChanged<List<String>>? onNames;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Headband connection', style: text.titleMedium?.copyWith(color: Night.ink))),
      body: m.busy ? _Running(m) : (m.diyOn ? _DiyIdle(m, this) : _Idle(m, this)),
      bottomNavigationBar: m.diyOn && !m.busy ? null : PinnedAction(child: _action(m)),
    );
  }

  Widget _action(OwnBleViewModel m) {
    switch (m.stage) {
      case OwnStage.waitingReady:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(onPressed: onReady, child: const Text('Ready')),
            const SizedBox(height: 8),
            TextButton(onPressed: onStop, child: const Text('Stop the probe')),
          ],
        );
      case OwnStage.connecting:
      case OwnStage.running:
        return OutlinedButton(onPressed: onStop, child: const Text('Stop the probe'));
      case OwnStage.idle:
        return FilledButton(
          onPressed: m.blocked == null ? onRun : null,
          child: Text(m.probeAt == null ? 'Run the probe' : 'Run the probe again'),
        );
    }
  }
}

class _Head extends StatelessWidget {
  const _Head(this.s);
  final OwnBleStatus s;

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
              StateMark(shape: s.mark, color: s.color),
              const SizedBox(width: 14),
              Expanded(child: Text(s.title, style: text.displaySmall)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            s.sentence,
            style: text.bodyLarge?.copyWith(color: s.color == Night.caution ? Night.caution : Night.inkMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle(this.m, this.v);
  final OwnBleViewModel m;
  final OwnBleView v;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final free = m.blocked == null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        _Head(describeOwnBle(m)),
        if (m.message.isNotEmpty) Para(m.message, color: Night.caution),
        if (m.diy != null) ...[
          const SectionHeading('Headband'),
          DeviceChoice(diy: false, onChanged: free ? v.onDevice : null),
        ],
        const SectionHeading('If the headband is lost'),
        const LostNoticeSetting(),
        const SectionHeading('Which connection'),
        _SwitchRow(
          title: 'Use our own connection (test)',
          body: m.probePassed || m.useOwn
              ? 'For nights and every session. It reconnects by itself in seconds, counts lost packets and needs '
                    "no closed library. Off: BrainBit's own library, as before."
              : 'Offered once the probe has passed on your headband.',
          value: m.useOwn,
          onChanged: free && (m.probePassed || m.useOwn) ? v.onUseOwn : null,
        ),
        if (!m.probePassed && !m.useOwn)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: free ? v.onTryAnyway : null, child: const Text('Try anyway')),
          ),
        if (m.useOwn && m.command5) ...[
          const Divider(height: 33),
          _SwitchRow(
            title: 'Measure contact all night',
            body: 'The probe saw signal and contact arrive together. On: contact goes into the night\'s log every minute.',
            value: m.signalResist,
            onChanged: free ? v.onSignalResist : null,
          ),
        ],
        const SectionHeading('The probe'),
        const Para(
          'It checks our own connection on your headband: about 5 minutes with the headband on. The page says what '
          'to do; a low tone means close your eyes, two rising tones mean open them. You will be asked to lift each '
          'electrode off the skin for 4 seconds, one at a time. Nothing is changed on the headband.',
          color: Night.inkMuted,
          top: 0,
        ),
        const SizedBox(height: 20),
        _SwitchRow(
          title: 'Headband on my head',
          body: m.worn
              ? 'The full probe: it also settles which electrode is which.'
              : 'Off: the headband lies on the desk. Connection steps only, about 1½ minutes; not a full pass.',
          value: m.worn,
          onChanged: free ? v.onWorn : null,
        ),
        if (m.needsPairing || m.pairFirst) ...[
          const Divider(height: 33),
          _SwitchRow(
            title: 'Pair first',
            body: 'Hold the headband\'s button 4 seconds until it blinks fast, then run the probe. Pairing never '
                'removes other devices.',
            value: m.pairFirst,
            onChanged: free ? v.onPairFirst : null,
          ),
        ],
        if (m.probeAt != null) ...[
          SectionHeading('Last probe, ${probeWhen(m.probeAt!)}'),
          Text(m.probeLine, style: text.bodyLarge?.copyWith(height: 1.4)),
          const SizedBox(height: 8),
          for (final (ok, line) in m.lines) _CheckRow(ok, line),
          const SizedBox(height: 12),
          Text(
            'The full result is kept in the app (${m.probeFolder ?? 'own-ble/probe'}). Export data takes it to the '
            'laptop.',
            style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
          ),
        ],
      ],
    );
  }
}

/// The page with the DIY board chosen: status, the choice, the board's section.
class _DiyIdle extends StatelessWidget {
  const _DiyIdle(this.m, this.v);
  final OwnBleViewModel m;
  final OwnBleView v;

  @override
  Widget build(BuildContext context) {
    final free = m.blocked == null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        _Head(describeOwnBle(m)),
        if (m.message.isNotEmpty) Para(m.message, color: Night.caution),
        const SectionHeading('Headband'),
        DeviceChoice(diy: true, onChanged: free ? v.onDevice : null),
        DiySection(model: m.diy!, onNames: free ? v.onNames : null),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.title, required this.body, required this.value, required this.onChanged});
  final String title, body;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium?.copyWith(color: onChanged == null ? Night.inkMuted : Night.ink)),
                const SizedBox(height: 4),
                Text(body, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow(this.ok, this.line);
  final bool? ok;
  final String line;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (shape, color, word) = switch (ok) {
      true => (MarkShape.filled, Night.live, 'yes'),
      false => (MarkShape.ring, Night.problem, 'no'),
      null => (MarkShape.dash, Night.inkMuted, 'not settled'),
    };
    return Semantics(
      label: '$word: $line',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 5), child: StateMark(shape: shape, color: color, size: 12)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(line, style: text.bodyLarge?.copyWith(color: ok == false ? Night.problem : Night.ink, height: 1.35)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The probe in progress: one instruction, the seconds left, how far along.
class _Running extends StatelessWidget {
  const _Running(this.m);
  final OwnBleViewModel m;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final String words;
    if (m.stage == OwnStage.connecting) {
      words = 'Looking for the headband. Switch it on and keep it near the phone.';
    } else {
      words = m.stepText ?? 'Checking the connection. Nothing to do: sit still.';
    }
    final left = m.secondsLeft.ceil();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const StateMark(shape: MarkShape.filled, color: Night.live),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  switch (m.stage) {
                    OwnStage.connecting => 'Connecting',
                    OwnStage.waitingReady => 'Connected',
                    _ => 'Probe running',
                  },
                  style: text.titleMedium?.copyWith(color: Night.inkMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Expanded(
            child: SingleChildScrollView(
              child: Semantics(
                liveRegion: true,
                child: Text(words, style: text.displaySmall?.copyWith(height: 1.25)),
              ),
            ),
          ),
          if (m.stage == OwnStage.running) ...[
            Readout(parts: [('$left', true), (' s', false)], label: 'left of this step'),
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: m.fraction.clamp(0, 1).toDouble(),
                minHeight: 8,
                backgroundColor: Night.track,
                color: Night.saved,
              ),
            ),
            const SizedBox(height: 8),
            Text('The whole probe', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
          ],
        ],
      ),
    );
  }
}

/// The night screen's way in, between nights: which connection is in use, and the page behind it.
class OwnBleEntryView extends StatelessWidget {
  const OwnBleEntryView({super.key, required this.useOwn, required this.onOpen, this.useDiy = false});
  final bool useOwn;
  final VoidCallback? onOpen;

  /// The DIY board is chosen: the line says so instead of the connection.
  final bool useDiy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            useDiy
                ? 'Headband: DIY board (test), over Wi-Fi.'
                : (useOwn ? 'Connection: our own (test).' : "Connection: BrainBit's library."),
            style: text.bodyMedium?.copyWith(color: Night.inkMuted),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Headband connection'),
          ),
        ],
      ),
    );
  }
}
