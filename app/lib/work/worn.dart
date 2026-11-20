// Is the headband on the head during a work session? (DECISIONS 680; owner, 2026-11-20, in a Zoom meeting: the phone
// said "on a break" while he talked.) Worn is skin contact, not a readable signal: talking, chewing and moving spoil
// the drowsiness reading but are worn time, never a break. The judge is the automatic recording's worn check on the
// signal (auto/probe.dart `wornFromSignal`, DECISIONS 601) over the last 20 s, every second: a channel is on skin when
// none of its samples is at the rails, and its spread (after each second's mean) is neither flat (under the
// detectors' 1.4 µV) nor wild (over their 500 µV); worn when at least half the channels are. The contact check at
// Start (ohms, `wornFromOhms`) stands in until there are 10 s of signal: BrainBit reads no contact while it streams.
import 'dart:typed_data';

import '../auto/probe.dart' show wornFromOhms, wornFromSignal;

/// The worn judgement of a running session, fed one row of µV per sample.
class SignalWornJudge {
  SignalWornJudge({this.channels = 4, this.fs = 250, int seconds = 20})
    : _cap = seconds * fs,
      _ring = List.generate(channels, (_) => Float64List(seconds * fs));

  final int channels, fs;
  final int _cap;
  final List<Float64List> _ring;
  int _next = 0, _count = 0;

  /// The contact check at Start (null: no reading): what [worn] says before the signal can.
  bool? contactWorn;

  /// Ohms per channel from the contact check (null: no contact).
  void contact(Map<String, double?> ohms) => contactWorn = wornFromOhms(ohms);

  /// One sample, µV per channel (rows of another width are ignored).
  void push(List<double> uv) {
    if (uv.length != channels) return;
    for (var c = 0; c < channels; c++) {
      _ring[c][_next] = uv[c];
    }
    _next = (_next + 1) % _cap;
    if (_count < _cap) _count++;
  }

  /// Forgets the signal (a reconnect: the old samples say nothing about now).
  void clear() {
    _next = 0;
    _count = 0;
  }

  /// On the head by the last 20 s of signal; with under 10 s, the contact check's answer; null when neither knows.
  bool? get worn {
    if (_count < 10 * fs) return contactWorn;
    final from = (_next - _count) % _cap;
    final rows = <String, List<double>>{
      for (var c = 0; c < channels; c++) '$c': [for (var i = 0; i < _count; i++) _ring[c][(from + i) % _cap]],
    };
    return wornFromSignal(rows, fs: fs.toDouble()) ?? contactWorn;
  }
}
