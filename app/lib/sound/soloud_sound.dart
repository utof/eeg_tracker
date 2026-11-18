// The meditation sound on flutter_soloud (DECISIONS rows 11 and 72): rain and wind, a soft drone, bells.
// Same layers and reactions as the laptop page (scripts/web/sound-engine.js), built from SoLoud parts:
//   weather bus: rain (pink noise, low-pass = rain tone) + wind (brown noise, band moving on a 19 s loop,
//                gusts on an 11 s loop); bus volume = rain level
//   drone bus:   4 partials (A1 to A3) with slow swells of unequal length; low-pass = drone tone
//   warm bus:    the low octave and the third, faded in by "warmth"
//   each bus:    a 33 Hz amplitude modulator whose depth follows the jaw ("roughness"), and a slight detune
//   main:        bells and cues; a soft reverb and a limiter over everything
// Every movement is a fade or an oscillation run by the engine's own clock: Dart only hands over a new target
// when it changes (glide.dart), so a busy phone cannot make the sound step or stutter.
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../feedback/mapping.dart';
import 'feedback_sound.dart';
import 'glide.dart';
import 'synth.dart';

/// Drone partials: frequency (Hz), level, swell period (s), part of "warmth" (sound-engine.js PARTIALS).
const List<(double, double, double, bool)> _partials = [
  (55, 0.55, 23, true), // low octave
  (110, 0.7, 17, false),
  (165, 0.35, 29, false), // fifth
  (220, 0.3, 37, false),
  (277.2, 0.18, 31, true), // major third, an octave up
];

/// The WAVs, made off the screen's thread (a few hundred ms of maths on a phone).
typedef _Material = ({Uint8List rain, Uint8List wind, List<Uint8List> bells, Uint8List cue});

_Material _make() => (
  rain: wav16([rainLoop(9.7, 1), rainLoop(9.7, 2)]),
  wind: wav16([windLoop(13.3, 3), windLoop(13.3, 4)]),
  bells: [for (final f in bellNotes) wav16([strike(f, bellPartials)])],
  cue: wav16([strike(220, cuePartials)]),
);

class SoloudSound implements FeedbackSound {
  SoloudSound({this.mode = 'training'}) : _glider = Glider(mode);

  /// 'training': 512-frame buffers on the low-latency path (the sound answers in about 0.3 s);
  /// 'relax': 2048 frames on the ordinary path (research: fewer dropouts, delay does not matter).
  final String mode;
  final Glider _glider;
  SoLoud get _s => SoLoud.instance;
  late Bus _weather, _drone, _warm;
  late AudioSource _rain;
  late SoundHandle _rainH;
  final List<(SoundHandle, double)> _partialHandles = [];
  final List<AudioSource> _bells = [];
  late AudioSource _cue;
  double _bed = 0;
  final Map<String, double> _want = Targets.layers(neutralCalm, 0).settings;
  int _bellN = 0;
  bool _running = false;
  int _deviceFailures = 0;
  StreamSubscription<AudioDeviceStartFailure>? _failures;

  int get _buffer => mode == 'training' ? 512 : 2048;

  @override
  Future<void> start() async {
    try {
      await _start();
    } catch (_) {
      // leave no half-built engine behind: the meditation goes on silently
      try {
        if (_s.isInitialized) await _s.deinitAsync();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _start() async {
    final m = await Isolate.run(_make);
    await _s.init(sampleRate: synthRate, bufferSize: _buffer, lowLatency: mode == 'training');
    _failures = _s.audioDeviceStartFailures.listen((_) {
      _deviceFailures++;
      unawaited(_s.startAudioDevice().catchError((Object _) {}));
    });
    _s.setMaxActiveVoiceCount(32);
    _s.setGlobalVolume(0);
    final verb = _s.filters.freeverbFilter..activate();
    verb.roomSize.value = 0.6;
    verb.damp.value = 0.6;
    verb.wet.value = 0.2;
    _s.filters.limiterFilter.activate(); // last: catches what the layers add up to

    _rain = await _s.loadMem('rain.wav', m.rain);
    final wind = await _s.loadMem('wind.wav', m.wind);
    for (var i = 0; i < m.bells.length; i++) {
      _bells.add(await _s.loadMem('bell$i.wav', m.bells[i]));
    }
    _cue = await _s.loadMem('cue.wav', m.cue);
    _rain.filters.biquadFilter.activate(); // per-sound filters go on before play()
    wind.filters.biquadFilter.activate();

    Bus bus(String name, {bool lowPass = false}) {
      final b = _s.createMixingBus(name: name);
      b.filters.amplitudeModulatorFilter.activate();
      if (lowPass) b.filters.biquadFilter.activate();
      b.playOnEngine(volume: 0);
      final am = b.filters.amplitudeModulatorFilter;
      am.frequency().value = 33; // heard as rough, not as a beat
      am.waveform().value = 0;
      am.wet().value = 0;
      if (lowPass) {
        final lp = b.filters.biquadFilter;
        lp.type().value = 0;
        lp.resonance().value = 0.6;
        lp.frequency().value = _want['droneTone']!;
      }
      return b;
    }

    _weather = bus('weather');
    _drone = bus('drone', lowPass: true);
    _warm = bus('warm', lowPass: true);

    _rainH = _weather.play(_rain, looping: true);
    final rainLp = _rain.filters.biquadFilter;
    rainLp.type(soundHandle: _rainH).value = 0;
    rainLp.frequency(soundHandle: _rainH).value = _want['rainTone']!;
    final windH = _weather.play(wind, looping: true, volume: 0.55);
    final band = wind.filters.biquadFilter;
    band.type(soundHandle: windH).value = 2; // band-pass
    band.resonance(soundHandle: windH).value = 0.8;
    band.frequency(soundHandle: windH).oscillateFilterParameter(from: 240, to: 600, time: const Duration(seconds: 19));
    _s.oscillateVolume(windH, 0.3, 0.8, const Duration(seconds: 11)); // gusts

    for (var i = 0; i < _partials.length; i++) {
      final (hz, level, period, warm) = _partials[i];
      final src = await _s.loadWaveform(i == 1 ? WaveForm.triangle : WaveForm.sin, false, 1, 0);
      _s.setWaveformFreq(src, hz);
      final h = (warm ? _warm : _drone).play(src, looping: true, volume: level * 0.7);
      _s.oscillateVolume(h, level * 0.4, level, Duration(milliseconds: (period * 1000).round()));
      _partialHandles.add((h, i.isOdd ? 1.0 : -1.0));
    }
    _s.fadeGlobalVolume(0.85, const Duration(milliseconds: 1500));
    _running = true;
  }

  double _weatherLevel() => _bed * 0.55 * _want['rain']!;
  double _droneLevel() => _bed * 0.5 * _want['drone']!;
  double _warmLevel() => _droneLevel() * _want['warmth']!;

  Duration _d(double seconds) => Duration(milliseconds: (seconds * 1000).round());

  @override
  void bed({required bool on}) {
    if (!_running) return;
    _bed = on ? 1 : 0;
    const t = Duration(milliseconds: 1000);
    _guard(() {
      _s.fadeVolume(_weather.soundHandle!, _weatherLevel(), t);
      _s.fadeVolume(_drone.soundHandle!, _droneLevel(), t);
      _s.fadeVolume(_warm.soundHandle!, _warmLevel(), t);
    });
  }

  @override
  void glide(Targets target) {
    if (!_running) return;
    for (final f in _glider.next(target)) {
      _want[f.key] = f.to;
      final t = _d(f.seconds);
      _guard(() {
        switch (f.key) {
          case 'rain':
            _s.fadeVolume(_weather.soundHandle!, _weatherLevel(), t);
          case 'rainTone':
            _rain.filters.biquadFilter.frequency(soundHandle: _rainH).fadeFilterParameter(to: f.to, time: t);
          case 'drone':
            _s.fadeVolume(_drone.soundHandle!, _droneLevel(), t);
            _s.fadeVolume(_warm.soundHandle!, _warmLevel(), t);
          case 'warmth':
            _s.fadeVolume(_warm.soundHandle!, _warmLevel(), t);
          case 'droneTone':
            for (final b in [_drone, _warm]) {
              b.filters.biquadFilter.frequency().fadeFilterParameter(to: f.to, time: t);
            }
          case 'rough':
            for (final b in [_weather, _drone, _warm]) {
              b.filters.amplitudeModulatorFilter.wet().fadeFilterParameter(to: 0.45 * f.to, time: t);
            }
            for (final (h, sign) in _partialHandles) {
              _s.fadeRelativePlaySpeed(h, 1 + sign * 0.012 * f.to, t);
            }
        }
      });
    }
  }

  @override
  void bell() {
    if (!_running) return;
    final note = bellOrder[_bellN++ % bellOrder.length];
    _guard(() => _s.play(_bells[note], volume: toneGain(bellPartials, bellLevel)));
  }

  @override
  void cue() {
    if (!_running) return;
    _guard(() => _s.play(_cue, volume: toneGain(cuePartials, cueLevel)));
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _guard(() => _s.fadeGlobalVolume(0, const Duration(milliseconds: 1200)));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await _failures?.cancel();
    try {
      await _s.deinitAsync(); // stops every voice and frees every sound and bus
    } catch (_) {}
  }

  @override
  Map<String, Object?> info() {
    final out = <String, Object?>{
      'engine': 'flutter_soloud',
      'mode': mode,
      'sampleRate': synthRate,
      'bufferFrames': _buffer,
      'lowLatency': mode == 'training',
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

  /// An engine call that fails (a voice already gone, a value out of range) must not end the meditation.
  static void _guard(void Function() f) {
    try {
      f();
    } on SoLoudException catch (_) {}
  }
}
