// The sleep report's night extras (DECISIONS 140-145): jaw muscle bursts and movements per hour asleep with the
// earlier nights beside them (a trend, not a teeth-grinding test), and the night hour by hour (signal, jaw,
// movements) as ruled log rows on the chart's clock. Design: DESIGN.md (Sleep chart, Night extras) and
// .impeccable/surfaces/app-lib-ui-sleep-report-screen-dart.md.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../detectors/detectors.dart' show EpochQuality;
import '../sleep/extras.dart';
import '../sleep/report.dart';
import 'sleep_chart.dart' show paintSignalLane;
import 'theme.dart';

/// `23 an hour`, `4.5 an hour`: whole numbers from 10 up, one decimal below.
String rateText(double? perHour) {
  if (perHour == null) return '–';
  final v = perHour >= 10 ? perHour.round().toString() : perHour.toStringAsFixed(1);
  return '$v an hour';
}

/// `16 %`, `under 1 %` for a share that rounds to nothing but is not nothing.
String shareText(double share) =>
    share > 0 && share < 0.005 ? 'under 1 %' : '${(share * 100).round()} %';

/// One sentence for the honest note: how much of the sleep (or, without sleep, of the recording) the model read
/// through noise or with no usable electrode.
String noiseSentence(NightExtras x) {
  final asleep = x.asleep.min > 0;
  final ExtrasTally t = asleep ? x.asleep : x.night;
  final what = asleep ? 'your sleep' : 'the recording';
  if (t.min == 0) return '';
  final noisy = t.degradedMin / t.min, unusable = t.missingMin / t.min;
  if (noisy == 0 && unusable == 0) return 'The signal was clean for all of $what.';
  final parts = [
    if (noisy > 0) '${shareText(noisy)} of $what through noise (movement, muscle or a loose electrode)',
    if (unusable > 0) '${shareText(unusable)}${noisy > 0 ? '' : ' of $what'} with no usable electrode',
  ];
  return 'It read ${parts.join(' and ')}.';
}

class ExtrasSection extends StatelessWidget {
  const ExtrasSection({super.key, required this.extras, this.earlier = const [], this.onInfo});
  final NightExtras extras;

  /// Earlier nights' jaw bursts an hour asleep, newest first.
  final List<double> earlier;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final a = extras.asleep;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(label, style: text.bodyLarge)),
          Text(value, style: text.titleLarge?.copyWith(fontFeatures: tabular)),
        ],
      ),
    );
    final asleep = a.min > 0;
    final count = asleep
        ? 'While asleep (${_hm(a.min)}): ${_n(a.jawBursts, 'jaw muscle burst')} on both sides at once and '
              '${_n(a.moves, 'movement')}.'
        : 'No sleep period, so no rates. Over the whole recording: ${_n(extras.night.jawBursts, 'jaw muscle burst')} '
              'and ${_n(extras.night.moves, 'movement')}.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading('Jaw and movement', onInfo: onInfo),
        if (asleep) ...[
          line('Jaw muscle bursts', rateText(a.jawPerHour)),
          line('Movements', rateText(a.movesPerHour)),
          const SizedBox(height: 12),
        ],
        Text(count, style: text.bodyLarge?.copyWith(height: 1.4)),
        if (asleep && earlier.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Jaw on earlier nights: ${_list([for (final e in earlier) rateText(e).replaceAll(' an hour', '')])} '
            'an hour.',
            style: text.bodyLarge?.copyWith(height: 1.4, fontFeatures: tabular),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'A trend to compare your nights, not a test for teeth grinding: the muscle can also be swallowing, '
          'turning or the pillow. The limits are planning values until your setup test.',
          style: muted,
        ),
        const SizedBox(height: 24),
        Text('Hour by hour', style: text.titleSmall),
        const SizedBox(height: 10),
        HourTable(hours: extras.hours),
        const SizedBox(height: 12),
        const Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [SignalSwatch(EpochQuality.degraded), SignalSwatch(EpochQuality.missing)],
        ),
        const SizedBox(height: 8),
        Text(
          'A full bar is one hour recorded. The counts are for the whole hour, awake or asleep.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
      ],
    );
  }

  static String _n(int n, String word) => '$n ${n == 1 ? word : '${word}s'}';

  static String _hm(double minutes) {
    final m = minutes.round();
    return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
  }

  static String _list(List<String> items) =>
      items.length == 1 ? items.single : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}

/// A section heading with an "i" button at its end (the report's own heading style).
class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.onInfo});
  final String title;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
            ),
            if (onInfo != null)
              IconButton(
                onPressed: onInfo,
                tooltip: 'What the jaw and movement counts mean',
                icon: const Icon(Icons.info_outline, color: Night.inkMuted),
              ),
          ],
        ),
      ],
    ),
  );
}

/// The night by clock hour: the hour, a bar of its recorded minutes (clean on the track, amber dots where noisy,
/// solid amber where no electrode was usable; a full row is 60 minutes), jaw bursts and movements in that hour.
class HourTable extends StatelessWidget {
  const HourTable({super.key, required this.hours});
  final List<ExtrasHour> hours;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final head = text.bodyMedium!.copyWith(color: Night.inkMuted);
    final cell = text.bodyLarge!.copyWith(fontFeatures: tabular);
    double width(String s, TextStyle style) =>
        (TextPainter(text: TextSpan(text: s, style: style), textScaler: scaler, textDirection: TextDirection.ltr)
              ..layout())
            .width;
    final hourW = math.max(width('00:00', cell), width('Hour', head)) + 14;
    final numW = math.max(width('000', cell), width('Moves', head)) + 10;
    Widget row(Widget hour, Widget bar, Widget jaw, Widget moves) => Row(
      children: [
        SizedBox(width: hourW, child: hour),
        Expanded(child: bar),
        SizedBox(width: numW, child: Align(alignment: Alignment.centerRight, child: jaw)),
        SizedBox(width: numW, child: Align(alignment: Alignment.centerRight, child: moves)),
      ],
    );
    String two(int v) => v.toString().padLeft(2, '0');
    return Column(
      children: [
        ExcludeSemantics(
          child: row(Text('Hour', style: head), Text('Signal', style: head), Text('Jaw', style: head),
              Text('Moves', style: head)),
        ),
        const SizedBox(height: 6),
        for (final h in hours)
          Semantics(
            container: true,
            label: '${two(h.start.hour)}:${two(h.start.minute)}, ${h.minutes.round()} minutes recorded: '
                '${h.tally.goodMin.round()} clean, ${h.tally.degradedMin.round()} noisy, '
                '${h.tally.missingMin.round()} with no usable electrode; '
                '${h.tally.jawBursts} jaw muscle bursts, ${h.tally.moves} movements.',
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: row(
                Text('${two(h.start.hour)}:${two(h.start.minute)}', style: cell),
                SizedBox(height: 14, child: CustomPaint(painter: _HourBar(h))),
                Text('${h.tally.jawBursts}', style: cell),
                Text('${h.tally.moves}', style: cell),
              ),
            ),
          ),
      ],
    );
  }
}

class _HourBar extends CustomPainter {
  _HourBar(this.hour);
  final ExtrasHour hour;

  @override
  void paint(Canvas canvas, Size size) {
    final t = hour.tally;
    final minutes = math.max(t.min, 0.5);
    final r = Rect.fromLTWH(0, 0, size.width * math.min(1, minutes / 60), size.height);
    // the clean minutes first, then noisy, then unusable: as epochs of one quality each, in that order
    final epochs = (minutes * 2).round();
    final noisy = (t.degradedMin * 2).round(), unusable = (t.missingMin * 2).round();
    final q = <EpochQuality?>[
      for (var i = 0; i < epochs - noisy - unusable; i++) EpochQuality.good,
      for (var i = 0; i < noisy; i++) EpochQuality.degraded,
      for (var i = 0; i < unusable; i++) EpochQuality.missing,
    ];
    paintSignalLane(canvas, r, q, math.max(1, q.length));
  }

  @override
  bool shouldRepaint(_HourBar old) => old.hour != hour;
}

/// Earlier nights' jaw bursts an hour asleep for [nightOf]: the nights before it with extras, newest first.
List<double> earlierJaw(String nightOf, List<SleepReport> others, {int count = 6}) => [
  for (final o in [...others]..sort((a, b) => b.nightOf.compareTo(a.nightOf)))
    if (o.nightOf.compareTo(nightOf) < 0) ?o.extras?.asleep.jawPerHour,
].take(count).toList();

/// A legend entry for the Signal lane and the hour bars: noisy signal (dots) or no usable electrode (solid).
class SignalSwatch extends StatelessWidget {
  const SignalSwatch(this.quality, {super.key});
  final EpochQuality quality;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(size: const Size(18, 14), painter: _Swatch(quality)),
      const SizedBox(width: 8),
      Text(
        quality == EpochQuality.missing ? 'no usable electrode' : 'noisy signal',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Night.inkMuted),
      ),
    ],
  );
}

class _Swatch extends CustomPainter {
  _Swatch(this.quality);
  final EpochQuality quality;

  @override
  void paint(Canvas canvas, Size size) => paintSignalLane(canvas, Offset.zero & size, [quality], 1);

  @override
  bool shouldRepaint(_Swatch old) => old.quality != quality;
}
