// The alpha-theta sound on flutter_soloud (DECISIONS row 105), EEGer-style: a stream for alpha crossfading to
// ocean waves for theta, a soft high chime (alpha above its line) and a low gong (theta above its line).
//   stream bus: two pink-noise loops through band-passes that wander on short loops (0.9 s and 1.4 s), heard
//               as water over stones; a slow swell on top
//   ocean bus:  two brown-noise loops through a low-pass, their volumes rising and falling on 9 s and 13 s
//               loops, heard as waves arriving
//   each bus:   a 33 Hz amplitude modulator whose depth follows the jaw ("roughness"), as in meditation
//   main:       chime, gong, the calibration cue and the rising wake cue; reverb and a limiter over everything
// The mix (0 = stream, 1 = ocean) moves the two buses' volumes in opposite directions over about a second.
// Gated steps duck the bed a little. Stop fades everything over 10 s (the research's stop rule).
// Not heard yet: levels are guesses until the owner listens (as for the meditation engine).
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../training/control.dart';
import 'session_sound.dart';
import 'synth.dart';

/// Gong: a low strike with the slow inharmonic partials of a small gong.
const List<Partial> gongPartials = [
  (1, 1, 6),
  (1.47, 0.55, 4.5),
  (2.09, 0.4, 3.4),
  (2.56, 0.25, 2.4),
  (3.42, 0.15, 1.6),
];

/// Chime: brighter and shorter than the meditation bell.
const List<Partial> chimePartials = [(1, 1, 2.6), (2.76, 0.3, 1.2), (5.4, 0.1, 0.6)];

const double chimeHz = 1318.5, gongHz = 98, chimeLevel = 0.08, gongLevel = 0.17;

/// The wake cue's three notes, rising, 0.45 s apart.
const List<double> wakeNotes = [392, 523.25, 659.25];

/// Mix fade time (s) and the duck under a gate.
const double mixFadeS = 1.2, duckLevel = 0.75;

/// Stop fade (s): "the sound fades over about 10 s".
const double stopFadeS = 10;

typedef _Material = ({
  Uint8List stream,
  Uint8List ocean,
  Uint8List chime,
  Uint8List gong,
  Uint8List cue,
  Uint8List wake,
});

/// The wake cue: [wakeNotes] struck 0.45 s apart (also the dream catcher's end).
Float32List wakeTone() {
  final parts = [for (final hz in wakeNotes) strike(hz, cuePartials)];
  final gap = (0.45 * synthRate).round(), out = Float32List(parts.first.length + gap * (parts.length - 1));
  for (var k = 0; k < parts.length; k++) {
    for (var i = 0; i < parts[k].length; i++) {
      out[k * gap + i] += parts[k][i] / parts.length;
    }
  }
  return out;
}

_Material _make() => (
  stream: wav16([rainLoop(8.3, 11), rainLoop(8.3, 12)]),
  ocean: wav16([windLoop(11.9, 13), windLoop(11.9, 14)]),
  chime: wav16([strike(chimeHz, chimePartials)]),
  gong: wav16([strike(gongHz, gongPartials)]),
  cue: wav16([strike(220, cuePartials)]),
  wake: wav16([wakeTone()]),
);

class SoloudAlphaThetaSound implements SessionSound {
  SoLoud get _s => SoLoud.instance;
  late Bus _stream, _ocean;
  late AudioSource _chime, _gong, _cue, _wake;
  double _bed = 0, _mix = 0.5, _duck = 1;
  double? _sentMix;
  bool? _sentDuck;
  bool _running = false;
  int _deviceFailures = 0;
  StreamSubscription<AudioDeviceStartFailure>? _failures;

  @override
  Future<void> start() async {
    try {
      await _start();
    } catch (_) {
      try {
        if (_s.isInitialized) await _s.deinitAsync();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _start() async {
    final m = await Isolate.run(_make);
    await _s.init(sampleRate: synthRate, bufferSize: 2048); // a calm bed: delay matters less than dropouts
    _failures = _s.audioDeviceStartFailures.listen((_) {
      _deviceFailures++;
      unawaited(_s.startAudioDevice().catchError((Object _) {}));
    });
    _s.setMaxActiveVoiceCount(32);
    _s.setGlobalVolume(0);
    final verb = _s.filters.freeverbFilter..activate();
    verb.roomSize.value = 0.7;
    verb.damp.value = 0.5;
    verb.wet.value = 0.25;
    _s.filters.limiterFilter.activate();

    final stream = await _s.loadMem('stream.wav', m.stream);
    final ocean = await _s.loadMem('ocean.wav', m.ocean);
    _chime = await _s.loadMem('chime.wav', m.chime);
    _gong = await _s.loadMem('gong.wav', m.gong);
    _cue = await _s.loadMem('cue.wav', m.cue);
    _wake = await _s.loadMem('wake.wav', m.wake);
    stream.filters.biquadFilter.activate();
    ocean.filters.biquadFilter.activate();

    Bus bus(String name) {
      final b = _s.createMixingBus(name: name);
      b.filters.amplitudeModulatorFilter.activate();
      b.playOnEngine(volume: 0);
      final am = b.filters.amplitudeModulatorFilter;
      am.frequency().value = 33;
      am.waveform().value = 0;
      am.wet().value = 0;
      return b;
    }

    _stream = bus('stream');
    _ocean = bus('ocean');

    for (final (period, from, to, vol) in [(0.9, 1800.0, 3400.0, 0.8), (1.4, 1200.0, 2600.0, 0.6)]) {
      final h = _stream.play(stream, looping: true, volume: vol);
      final bp = stream.filters.biquadFilter;
      bp.type(soundHandle: h).value = 2; // band-pass
      bp.resonance(soundHandle: h).value = 1.2;
      bp
          .frequency(soundHandle: h)
          .oscillateFilterParameter(
            from: from,
            to: to,
            time: Duration(milliseconds: (period * 1000).round()),
          );
      _s.oscillateVolume(h, vol * 0.6, vol, const Duration(milliseconds: 2300));
    }
    for (final (period, vol) in [(9.0, 1.0), (13.0, 0.7)]) {
      final h = _ocean.play(ocean, looping: true, volume: vol);
      final lp = ocean.filters.biquadFilter;
      lp.type(soundHandle: h).value = 0; // low-pass
      lp.frequency(soundHandle: h).value = 650;
      _s.oscillateVolume(h, vol * 0.15, vol, Duration(milliseconds: (period * 1000).round()));
    }
    _s.fadeGlobalVolume(0.85, const Duration(milliseconds: 1500));
    _running = true;
  }

  double _streamLevel() => _bed * _duck * 0.6 * (1 - _mix);
  double _oceanLevel() => _bed * _duck * 0.75 * _mix;

  void _levels(double seconds) {
    final t = Duration(milliseconds: (seconds * 1000).round());
    _guard(() {
      _s.fadeVolume(_stream.soundHandle!, _streamLevel(), t);
      _s.fadeVolume(_ocean.soundHandle!, _oceanLevel(), t);
    });
  }

  @override
  void bed({required bool on}) {
    if (!_running) return;
    _bed = on ? 1 : 0;
    _levels(on ? 1.5 : 10); // falling asleep: a slow fade, as the stop
  }

  @override
  void play(Control c) {
    if (!_running) return;
    _mix = c.level;
    _duck = c.gated ? duckLevel : 1;
    final sent = _sentMix;
    if (sent == null || (c.level - sent).abs() >= 0.01 || _sentDuck != c.gated) {
      _sentMix = c.level;
      _sentDuck = c.gated;
      _levels(mixFadeS);
    }
    final t = const Duration(milliseconds: 300);
    _guard(() {
      for (final b in [_stream, _ocean]) {
        b.filters.amplitudeModulatorFilter.wet().fadeFilterParameter(to: 0.45 * c.rough, time: t);
      }
    });
    if (c.reward == 'chime') _guard(() => _s.play(_chime, volume: toneGain(chimePartials, chimeLevel)));
    if (c.reward == 'gong') _guard(() => _s.play(_gong, volume: toneGain(gongPartials, gongLevel)));
  }

  @override
  void cue() {
    if (_running) _guard(() => _s.play(_cue, volume: toneGain(cuePartials, cueLevel)));
  }

  @override
  void wake() {
    if (_running) _guard(() => _s.play(_wake, volume: toneGain(cuePartials, cueLevel)));
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _guard(() => _s.fadeGlobalVolume(0, Duration(milliseconds: (stopFadeS * 1000).round())));
    await Future<void>.delayed(Duration(milliseconds: (stopFadeS * 1000).round() + 300));
    await _failures?.cancel();
    try {
      await _s.deinitAsync();
    } catch (_) {}
  }

  @override
  Map<String, Object?> info() {
    final out = <String, Object?>{
      'engine': 'flutter_soloud',
      'mode': 'alpha-theta',
      'sampleRate': synthRate,
      'bufferFrames': 2048,
      'deviceStartFailures': _deviceFailures,
    };
    if (_s.isInitialized) {
      _guard(() {
        out['mixAheadMs'] = _s.getOutputLatency().inMicroseconds / 1000;
        out['hardwareMs'] = _s.getHardwareOutputLatency().inMicroseconds / 1000;
      });
    }
    return out;
  }

  static void _guard(void Function() f) {
    try {
      f();
    } on SoLoudException catch (_) {}
  }
}
