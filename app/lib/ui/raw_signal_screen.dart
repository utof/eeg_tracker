// A recording's raw signal at a moment (the Archive, DECISIONS 700-709): the Signal tab's own traces (signal_traces.dart)
// fed from the files instead of the headband. Every channel of the file set, as it came (stacked, each with its own
// scale) or filtered 1-40 Hz (one trace each); 5, 10 or 30 seconds; earlier and later by the shown length; in a gap, where
// the signal is. The seconds are read in a background isolate (a packed file unpacks from its start: a moment late in a
// night takes a few seconds).
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../archive/detail.dart';
import '../signal/live_signal.dart';
import 'archive_view.dart' show hm;
import 'form_parts.dart' show Para;
import 'signal_traces.dart';
import 'theme.dart';

String hms(DateTime t) => '${hm(t)}:${t.second.toString().padLeft(2, '0')}';

Future<RawWindow> _read(List<String> paths, DateTime at, int seconds) =>
    Isolate.run(() => readWindow(paths, at, seconds), debugName: 'archive-raw');

class RawSignalScreen extends StatefulWidget {
  const RawSignalScreen({super.key, required this.paths, required this.at, this.read});

  /// The recording's `.f32` files (plain names), oldest first.
  final List<String> paths;
  final DateTime at;

  /// Tests: reads without an isolate.
  final Future<RawWindow> Function(List<String> paths, DateTime at, int seconds)? read;

  @override
  State<RawSignalScreen> createState() => _RawSignalScreenState();
}

class _RawSignalScreenState extends State<RawSignalScreen> {
  late DateTime _at = widget.at;
  int _seconds = 10;
  bool _filtered = false;
  RawWindow? _w;
  LiveSignal? _signal;
  bool _loading = true;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _loading = true);
    RawWindow w;
    try {
      w = await (widget.read ?? _read)(widget.paths, _at, _seconds);
    } catch (e) {
      w = RawWindow(names: const [], rate: 250, start: _at, values: Float32List(0), lead: 0, note: 'Could not read it: $e');
    }
    if (!mounted || ask != _asked) return;
    LiveSignal? s;
    if (w.samples > 0) {
      s = LiveSignal(names: w.names, rate: w.rate, keepSeconds: _seconds + 4, traceSeconds: _seconds + 4);
      s.add(
        LiveBatch(
          arrival: w.start.add(Duration(milliseconds: ((w.samples - w.lead) * 1000 / w.rate).round())),
          values: w.values,
          channels: w.channels,
        ),
      );
    }
    setState(() {
      _w = w;
      _signal = s;
      _loading = false;
    });
  }

  void _go(DateTime t) {
    _at = t;
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final w = _w, s = _signal;
    final shownEnd = w == null ? _at : w.start.add(Duration(seconds: _seconds));
    return Scaffold(
      appBar: AppBar(title: Text('Signal at ${hms(_at)}', style: text.titleMedium?.copyWith(color: Night.ink))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 5, label: Text('5 s')),
              ButtonSegment(value: 10, label: Text('10 s')),
              ButtonSegment(value: 30, label: Text('30 s')),
            ],
            selected: {_seconds},
            onSelectionChanged: (v) {
              _seconds = v.first;
              unawaited(_load());
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('As recorded')),
              ButtonSegment(value: true, label: Text('Filtered 1-40 Hz')),
            ],
            selected: {_filtered},
            onSelectionChanged: (v) => setState(() => _filtered = v.first),
          ),
          const SizedBox(height: 16),
          if (_loading && w == null)
            const Para('Reading the recording…', color: Night.inkMuted, top: 0)
          else if (w != null && s == null) ...[
            Para(w.note ?? 'No signal here.', color: Night.caution, top: 0),
          ] else if (w != null && s != null) ...[
            Row(
              children: [
                Text(hms(w.start), style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
                const Spacer(),
                Text(hms(shownEnd), style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
              ],
            ),
            const SizedBox(height: 6),
            if (_filtered)
              for (var c = 0; c < s.channels; c++) ...[
                Text(s.names[c], style: text.titleMedium),
                const SizedBox(height: 4),
                TraceBox(
                  signal: s,
                  channel: c,
                  frames: const AlwaysStoppedAnimation(0),
                  window: (seconds: _seconds, end: s.count),
                  height: 76,
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: ScaleLabel(
                    signal: s,
                    channel: c,
                    frames: const AlwaysStoppedAnimation(0),
                    filter: TraceFilter.band,
                    window: (seconds: _seconds, end: s.count),
                  ),
                ),
                const SizedBox(height: 8),
              ]
            else
              _FileStack(signal: s, seconds: _seconds),
            if (w.note != null) Para(w.note!, color: Night.caution),
            Para(
              '${w.rate} samples a second, ${s.channels} channels, in µV.${w.rate != liveRate ? ' The filter is set for $liveRate a second, so it is only a guide here.' : ''}',
              color: Night.inkMuted,
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _loading ? null : () => _go(_at.subtract(Duration(seconds: _seconds))),
                icon: const Icon(Icons.chevron_left),
                label: Text('$_seconds s earlier'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : () => _go(_at.add(Duration(seconds: _seconds))),
                icon: const Icon(Icons.chevron_right),
                label: Text('$_seconds s later'),
              ),
              if (w?.previous case final p? when s == null)
                TextButton(onPressed: () => _go(p), child: Text('Signal before, ${hms(p)}')),
              if (w?.next case final n? when s == null || w?.note != null)
                TextButton(onPressed: () => _go(n), child: Text('Next signal, ${hms(n)}')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Every channel stacked as recorded (the Signal tab's Raw view on a file).
class _FileStack extends StatefulWidget {
  const _FileStack({required this.signal, required this.seconds});
  final LiveSignal signal;
  final int seconds;

  @override
  State<_FileStack> createState() => _FileStackState();
}

class _FileStackState extends State<_FileStack> {
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
    final s = widget.signal;
    final nameWidth = scaler.scale(44).clamp(44.0, 64.0);
    const rowHeight = 56.0;
    return Semantics(
      label: 'All ${s.channels} channels as recorded, ${widget.seconds} seconds',
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(double.infinity, rowHeight * s.channels),
          painter: StackedPainter(
            signal: s,
            window: (seconds: widget.seconds, end: s.count),
            rowHeight: rowHeight,
            nameWidth: nameWidth,
            scaleWidth: scaler.scale(66).clamp(66.0, 92.0),
            label: (t, {muted = false}) => _labels.putIfAbsent(
              '$muted$t',
              () => TextPainter(
                text: TextSpan(text: t, style: style.copyWith(color: muted ? Night.inkMuted : Night.ink, fontFeatures: tabular)),
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
