// The Battery page (More; DECISIONS 715-716): what costs the phone's battery, feature by feature, from the samples
// of the last 14 days (lib/logs/battery_report.dart), with a plain sentence each; every combination measured; the
// phone with the app closed; the headband's battery per recording, its contact over the day and its link's drops.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../logs/battery_report.dart';
import '../logs/files.dart';
import '../logs/log.dart' show AppLog, Logs;
import '../logs/read.dart';
import '../logs/settings.dart';
import '../logs/usage.dart';
import '../phone.dart';
import 'parts.dart' show SectionHeading;
import 'records_parts.dart';

class BatteryScreen extends StatefulWidget {
  const BatteryScreen({super.key, this.recordingsDir, this.now});

  /// The app's recordings folder when the caller knows it.
  final String? recordingsDir;

  /// Tests: the clock.
  final DateTime Function()? now;

  @override
  State<BatteryScreen> createState() => _BatteryScreenState();
}

class _BatteryScreenState extends State<BatteryScreen> {
  BatteryInputs? _in;
  String? _error, _files;
  LogSettings _settings = const LogSettings();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rec = widget.recordingsDir ?? await Phone.recordingsDir();
      if (rec == null) throw StateError("the app's folder is not known");
      final files = Directory(rec).parent.path;
      final now = widget.now?.call() ?? DateTime.now();
      final r = await batteryInBackground(files, now);
      if (!mounted) return;
      setState(() {
        _files = files;
        _in = r;
        _settings = LogSettings.load(logsDirFor(rec));
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _setMeasure(bool on) {
    final files = _files;
    if (files == null) return;
    final s = _settings.copyWith(battery: on);
    try {
      final logs = Logs.current;
      if (logs != null && logs.dir != null) {
        logs.saveSettings(s);
      } else {
        s.save(Directory('$files/logs'));
      }
      AppLog('battery').info(on ? 'battery samples: on' : 'battery samples: off');
      Usage.setting('battery', on);
      setState(() => _settings = s);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('The setting could not be saved: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _in;
    return Scaffold(
      appBar: AppBar(title: const Text('Battery')),
      body: i == null ? recordsWaiting(context, _error) : _body(context, i),
    );
  }

  Widget _body(BuildContext context, BatteryInputs i) {
    final text = Theme.of(context).textTheme;
    final r = i.report;
    final cap = r.capacity;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        Text(
          r.combos.isEmpty
              ? 'Not measured yet.'
              : 'Measured ${r.watchedHours.toStringAsFixed(1)} h of the app at work on ${r.days == 1 ? '1 day' : '${r.days} days'}.',
          style: text.titleLarge,
        ),
        const MutedLine(
          'The whole phone\'s battery while each thing ran: the screen, other apps and the phone itself are in every '
          'number, so compare rows rather than add them up.',
        ),
        RecordSwitch(
          title: 'Measure battery',
          line:
              'A look at Android\'s battery numbers every 1 to 2 minutes while the app is open or something runs, and '
              'every minute during a night. It wakes nothing and costs nothing measurable.',
          value: _settings.battery,
          onChanged: _setMeasure,
        ),
        ..._consumers(context, r),
        ..._combos(context, r),
        ..._phone(context, r, cap),
        ..._headband(context, i),
        const SectionHeading('How it is measured'),
        const MutedLine(
          'Every sample notes the battery\'s charge counter, what is on and whether the screen is on. The drop between '
          'two samples is shared out so that the things on together add up to what was measured, weighted by time. '
          'Things always on together (a night and its headband link) stay one row. Stretches with a charger are left '
          'out. "Processor busy" is the app\'s own CPU time: a high share there means the app\'s code is the cost.',
          top: 0,
        ),
        const MutedLine(
          'For a closer look the assistant can read Android\'s own battery history from the laptop (docs/app-logging.md).',
        ),
      ],
    );
  }

  List<Widget> _consumers(BuildContext context, BatteryReport r) {
    final costed = [
      for (final g in r.groups)
        if (g.adds != null && g.use.hours * 60 >= groupMin.inMinutes) g,
    ];
    if (costed.isEmpty) {
      return [
        const SectionHeading('What costs the most'),
        MutedLine(
          r.combos.isEmpty
              ? 'Nothing yet: the app needs a few samples first. Use it as usual; a night gives an hour\'s worth by itself.'
              : 'Not enough yet: each thing needs 15 minutes measured before it gets a number.',
          top: 0,
        ),
      ];
    }
    final screen = r.groups.where((g) => g.use.members.contains('screen')).firstOrNull;
    final top = costed.map((g) => g.use.rate).reduce((a, b) => a > b ? a : b);
    return [
      const SectionHeading('What costs the most'),
      for (final g in costed.take(8))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RecordRow(
                label: groupLabel(g.use),
                value: '${g.use.rate.round()} mAh/h',
                note: sentences(adviceParts(g, capacity: r.capacity, screen: screen)),
              ),
              ShareBar(top == 0 ? 0 : g.use.rate / top),
            ],
          ),
        ),
    ];
  }

  List<Widget> _combos(BuildContext context, BatteryReport r) {
    if (r.combos.isEmpty) return const [];
    return [
      const SectionHeading('Each combination measured'),
      for (final c in r.combos.take(12))
        RecordRow(
          label: groupLabel(c),
          value: '${c.rate.round()} mAh/h',
          note: [
            '${_hours(c.hours)} measured',
            if (c.cpuShare != null) 'processor busy ${(c.cpuShare! * 100).round()} %',
          ].join(' · '),
        ),
    ];
  }

  List<Widget> _phone(BuildContext context, BatteryReport r, double? cap) => [
    const SectionHeading('The phone'),
    RecordRow(
      label: 'Battery size',
      value: cap == null ? 'not known' : '${cap.round()} mAh',
      note: cap == null ? 'Android gave no charge counter' : 'From Android\'s charge counter and level',
    ),
    if (r.closed != null && r.closed!.hours >= 0.5)
      RecordRow(
        label: 'With the app closed',
        value: '${r.closed!.rate.round()} mAh/h',
        note: '${_hours(r.closed!.hours)} between the app\'s samples; other apps and the screen are in it',
      ),
  ];

  List<Widget> _headband(BuildContext context, BatteryInputs i) {
    final out = <Widget>[const SectionHeading('The headband')];
    if (i.headband.isEmpty && i.contact.isEmpty && i.link.connects == 0) {
      out.add(const MutedLine('No recording with the headband in the last 14 days.', top: 0));
      return out;
    }
    for (final run in i.headband.take(7)) {
      out.add(RecordRow(label: _when(run.start), value: run.perHour == null ? '—' : '${run.perHour!.toStringAsFixed(1)} %/h', note: headbandWords(run)));
    }
    if (i.headband.isNotEmpty) {
      out.add(const MutedLine('Its gauge sticks at 0-2 % and 100 %, and sometimes at one value for hours: those readings are left out.'));
    }
    final l = i.link;
    if (l.connects > 0 || l.drops > 0) {
      out.add(
        RecordRow(
          label: 'Link drops',
          value: '${l.drops}',
          note: [
            if (l.medianBack != null) 'back after ${l.medianBack!.inSeconds} s (median)',
            if (l.causes.isNotEmpty) [for (final e in l.causes.entries) '${e.key} ${e.value}'].join(', '),
            if (l.medianRssi != null) 'signal ${l.medianRssi} dBm when it connected (median)',
          ].join('; '),
        ),
      );
    }
    if (i.contact.isNotEmpty) {
      out.add(const SizedBox(height: 8));
      out.add(Text('Contact over the day', style: Theme.of(context).textTheme.titleSmall));
      for (final b in i.contact) {
        final words = [for (final e in b.medianKohm.entries) '${e.key} ${e.value.round()}'].join(' · ');
        out.add(
          RecordRow(
            label: '${b.fromHour.toString().padLeft(2, '0')}:00-${(b.fromHour + 3).toString().padLeft(2, '0')}:00',
            value: b.readings == 1 ? '1 check' : '${b.readings} checks',
            note: words.isEmpty ? 'off the head every time' : '$words kΩ (median)',
          ),
        );
      }
    }
    return out;
  }
}

String _hours(double h) => h >= 1 ? '${h.toStringAsFixed(1)} h' : '${(h * 60).round()} min';

String _when(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
