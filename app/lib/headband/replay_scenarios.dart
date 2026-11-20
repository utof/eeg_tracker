// Made-up recordings for the replay headband (replay.dart, DECISIONS 730-739): quiet work, talking, eyes closed, the
// headband off and drop-outs, written in the app's own format (`.f32 .idx .log .header.json`) for any layout. The
// committed tests and the emulator check play these; the owner's EEG never goes into the repository.
// `tool/replay_scenario.dart` writes them to a folder.
//
// The signal follows the work-session tests' synthetic headband (test/work_controller_test.dart `WorkBand`) for the
// BrainBit's O1 O2 T3 T4, and places the same parts by each channel's position for any other layout: alpha at the
// back of the head, blinks everywhere (the BrainBit's reference is on the forehead), sideways eye movements and jaw
// muscle at the temples. Talking is the work-day branch's (DECISIONS 686): 9 of every 10 s of 4 Hz jaw swings of
// 160-300 uV on every channel and 80 Hz muscle at the temples.
import 'dart:io';
import 'dart:math' as math;

import '../recorder/chunk_writer.dart';
import '../recorder/header.dart';
import '../signal/layout.dart' show Montage, Site, SiteKind, Vec3, helmetPlan8, montageFromNames, standardSites;

/// What the wearer does during one stretch.
enum Act {
  /// Working quietly: 10 uV alpha, a blink every 4 s, a sideways look every 5 s.
  quiet,

  /// Talking (a meeting): jaw swings and temple muscle 9 s of every 10.
  talking,

  /// Eyes closed: 40 uV alpha, no blinks.
  eyesClosed,

  /// The headband off: every channel at the rail.
  off,

  /// Nothing arrives (out of range); the packet numbers go on, so the gap shows in them too.
  dropout,
}

class Stretch {
  const Stretch(this.act, this.seconds);
  final Act act;
  final double seconds;
}

class Scenario {
  const Scenario(this.name, this.about, this.stretches, {required this.header, this.start});

  final String name;
  final String about;
  final List<Stretch> stretches;
  final RecordingHeader header;

  /// When it starts (local time); null: 2026-11-20 10:00, a working morning.
  final DateTime? start;

  double get seconds => stretches.fold(0, (s, x) => s + x.seconds);
}

/// The BrainBit's layout at 250 Hz.
RecordingHeader get brainBitScenarioHeader => brainBitHeader;

/// The helmet's planned 8 sites (layout.dart `helmetPlan8`) at 500 Hz: a layout that is not the BrainBit's.
RecordingHeader get helmetScenarioHeader => headerForMontage(helmetPlan8(), device: 'Made-up helmet', sampleRate: 500);

/// Three channels, one of them at a place with no 10-10 name, at 125 Hz.
RecordingHeader get customScenarioHeader => headerForMontage(
  Montage(
    name: 'Made-up custom (3)',
    channels: [
      ...montageFromNames('x', const ['Fp1', 'Oz']).channels,
      const Site(name: 'X1', at: Vec3(0.6, -0.6, 0.529150262), custom: true),
    ],
    others: [Site(name: 'Ref', kind: SiteKind.reference, at: standardSites['A1'], where: 'an earlobe')],
  ),
  device: 'Made-up board',
  sampleRate: 125,
  counter: counterSequence,
);

/// The scenarios by name (the emulator check and `tool/replay_scenario.dart` use these names).
final Map<String, Scenario> scenarios = {
  for (final s in [
    Scenario('quiet-work', '10 minutes of quiet work', const [Stretch(Act.quiet, 600)], header: brainBitHeader),
    Scenario(
      'talking-work',
      'talking from the start for 12 minutes (the owner\'s Zoom meeting of 2026-11-20, DECISIONS 680)',
      const [Stretch(Act.talking, 720)],
      header: brainBitHeader,
    ),
    Scenario(
      'quiet-then-talking',
      '5 minutes of quiet work (calibration), then 12 minutes of talking',
      const [Stretch(Act.quiet, 300), Stretch(Act.talking, 720)],
      header: brainBitHeader,
    ),
    Scenario(
      'band-off',
      '5 minutes of quiet work, the headband off for 7 minutes, then 3 minutes back on',
      const [Stretch(Act.quiet, 300), Stretch(Act.off, 420), Stretch(Act.quiet, 180)],
      header: brainBitHeader,
    ),
    Scenario(
      'dropouts',
      '3 minutes of quiet work with drop-outs of 2, 8 and 45 s',
      const [
        Stretch(Act.quiet, 60),
        Stretch(Act.dropout, 2),
        Stretch(Act.quiet, 40),
        Stretch(Act.dropout, 8),
        Stretch(Act.quiet, 40),
        Stretch(Act.dropout, 45),
        Stretch(Act.quiet, 60),
      ],
      header: brainBitHeader,
    ),
    Scenario(
      'helmet-8',
      "the helmet plan's 8 channels at 500 Hz: 1 minute quiet, 1 minute talking",
      const [Stretch(Act.quiet, 60), Stretch(Act.talking, 60)],
      header: helmetScenarioHeader,
    ),
    Scenario(
      'custom-3',
      'three channels, one at a custom place, at 125 Hz: 1 minute quiet, 20 s eyes closed',
      const [Stretch(Act.quiet, 60), Stretch(Act.eyesClosed, 20)],
      header: customScenarioHeader,
    ),
  ])
    s.name: s,
};

/// How much of each part a channel at [at] carries (null place: some of everything).
({double alpha, double eye, double muscle, double side}) _weights(List<double>? at) {
  if (at == null) return (alpha: 0.5, eye: 0, muscle: 0.5, side: 1);
  final x = at[0], y = at[1];
  final side = x > 0 ? -1.0 : 1.0; // left of the midline +, right -
  return (
    alpha: y < -0.5 ? (x > 0 ? 0.9 : 1.0) : 0.2,
    eye: x.abs() > 0.7 ? -x.sign : 0.0,
    muscle: x.abs() > 0.7 ? 1.0 : 0.15,
    side: side,
  );
}

/// One sample (volts per channel, in [h]'s order) at [t] seconds into a stretch of [act]; [noise] gives about 2 uV.
List<double> _sample(RecordingHeader h, Act act, double t, double Function() noise) {
  if (act == Act.off) return List.filled(h.count, 0.4);
  final talkingNow = act == Act.talking && t % 10 < 9;
  final alphaAmp = act == Act.eyesClosed ? 40.0 : 10.0;
  final alpha = alphaAmp * math.sin(2 * math.pi * 10 * t);
  final slow = 3 * math.sin(2 * math.pi * 3 * t);
  var blink = 0.0, eye = 0.0;
  if (act != Act.eyesClosed) {
    final bt = t % 4 - 2;
    blink = -120 * math.exp(-bt * bt / (2 * 0.04 * 0.04));
    final et = t % 5;
    final dir = (t ~/ 5).isEven ? 1 : -1;
    double ramp(double x) => x <= 0 ? 0 : x >= 1 ? 1 : 0.5 - 0.5 * math.cos(math.pi * x);
    eye = dir * 60 * (et < 2.5 ? ramp(et / 0.08) : 1 - ramp((et - 2.5) / 0.08));
  }
  final jaw = talkingNow ? (230 + 70 * math.sin(2 * math.pi * 0.13 * t)) * math.sin(2 * math.pi * 4 * t) : 0.0;
  final muscle = talkingNow ? 40 * math.sin(2 * math.pi * 80 * t) : 0.0;
  return [
    for (final c in h.channels)
      () {
        final w = _weights(c.xyz);
        return (w.alpha * alpha + blink + w.eye * eye + w.side * slow + jaw + w.muscle * muscle + noise()) * 1e-6;
      }(),
  ];
}

/// Writes [s] into [dir] as one file set and returns its `.f32`. Batches of [batchS] seconds arrive just after their
/// last sample; the `.log` says it is made up and what it holds.
File writeScenario(Directory dir, Scenario s, {double batchS = 0.1, int seed = 7}) {
  final h = s.header;
  final fs = h.sampleRate.toDouble();
  final start = s.start ?? DateTime(2026, 11, 20, 10);
  final w = ChunkWriter.open(dir, start, header: h);
  w.log('made-up recording (replay scenario ${s.name}): ${s.about}; not EEG of a person', at: start);
  var state = seed;
  double noise() {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return (state / 0x7fffffff - 0.5) * 7;
  }

  final wrap = h.counter == counterPacket ? 2048 : 1 << 32;
  final perBatch = math.max(1, (batchS * fs).round());
  var n = 0; // samples since the start, sent or not
  for (final st in s.stretches) {
    final count = (st.seconds * fs).round();
    if (st.act == Act.dropout) {
      n += count;
      continue;
    }
    for (var k = 0; k < count; k += perBatch) {
      final m = math.min(perBatch, count - k);
      final rows = <Sample>[];
      for (var i = 0; i < m; i++) {
        rows.add(Sample((n + i) % wrap, _sample(h, st.act, (k + i) / fs, noise)));
      }
      n += m;
      w.addBatch(start.add(Duration(microseconds: (n / fs * 1e6).round())), rows);
      if (n % (perBatch * 100) < perBatch) w.append();
    }
  }
  final f32 = File('${dir.path}/${w.stem}.f32');
  w.close();
  return f32;
}
