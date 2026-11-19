// A fake head under the fake headband, for the probe's tests: the probe's own steps drive it, as the owner would.
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/headband/own/probe.dart';
import 'package:eeg_tracker/headband/own/protocol.dart';

import 'fake_headband.dart';

const speed = 40;

/// A fake head under the fake headband: alpha on the back electrodes when the eyes are closed, a noisy channel
/// and an open contact while its electrode is lifted. The probe's steps drive it, as the owner would.
class Head {
  Head({bool ignoreCmd5 = false, bool needsPairing = false}) {
    hb = FakeHeadband(
      interval: const Duration(microseconds: 32000 ~/ speed),
      ignoreCmd5: ignoreCmd5,
      needsPairing: needsPairing,
      rows: _row,
    );
  }

  late final FakeHeadband hb;
  final _rng = math.Random(5);
  bool eyesClosed = false;
  String? lifted;
  final steps = <ProbeStep>[];
  final t0 = DateTime.now();

  /// The probe's clock: 40 simulated seconds per real second.
  DateTime clock() => t0.add(DateTime.now().difference(t0) * speed);

  double _gauss() {
    final u = 1 - _rng.nextDouble(), v = _rng.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  Map<String, double> _row(int n) {
    final alpha = (eyesClosed ? 25e-6 : 5e-6) * math.sin(2 * math.pi * 10 * n / 250);
    double ch(String name, double sig) => sig + (lifted == name ? 60e-6 : 4e-6) * _gauss();
    return {'O1': ch('O1', alpha), 'O2': ch('O2', 0.9 * alpha), 'T3': ch('T3', 0), 'T4': ch('T4', 0)};
  }

  void onStep(ProbeStep s) {
    steps.add(s);
    eyesClosed = s.name == 'eyes_closed';
    final m = RegExp(r'lift_(\w\d)$').firstMatch(s.name);
    lifted = m?.group(1);
    hb.resistOhms = {
      for (final n in names) n: n == lifted ? 9000000 : const {'O1': 150000, 'O2': 220000, 'T3': 400000, 'T4': 180000}[n]!,
    };
  }

  BandProbe probe(Directory folder, {bool worn = true, Layout? layout, bool pair = false, String? address = fakeAddress, File? sdkRef}) =>
      BandProbe(
        transport: hb,
        folder: folder,
        address: address,
        name: 'BB Black',
        layout: layout,
        worn: worn,
        pair: pair,
        onStep: onStep,
        sdkRef: sdkRef,
        timeScale: 1 / speed,
        callTimeout: const Duration(seconds: 2),
        scanFor: const Duration(milliseconds: 300),
        clock: clock,
      );
}

