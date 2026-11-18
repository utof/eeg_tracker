// The sound for states on flutter_soloud (DECISIONS rows 73 and 134): the Dart synthesis (state_synth.dart) streamed
// into one stereo buffer stream, 8 s ahead of what plays. The engine runs at 48 kHz with 2048-frame buffers on the
// ordinary (not low-latency) path, the meditation's relax setting that gave the fewest dropouts on the phone research;
// delay does not matter here. Fades are the engine's own (per handle), so they are smooth even when the app is busy,
// and a fade to silence also schedules the voice's stop inside the engine. No reverb and no limiter: a limiter after a
// pulse would flatten it (build guide 1), and the synthesis keeps its peaks under 0.9.
// If the app stops feeding (a frozen process), the stream runs dry within the 8 s and the sound goes quiet: it can never
// outlast the session's timers by more than that.
import 'dart:async';
import 'dart:isolate';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../states/presets.dart';
import 'state_sound.dart';
import 'state_synth.dart';
import 'synth.dart' show synthRate;

class SoloudStateSound implements StateSound {
  /// Seconds made ahead of what plays, and the size of each piece handed over.
  static const double leadS = 8, chunkS = 0.25;
  static const int _buffer = 2048;

  SoLoud get _s => SoLoud.instance;
  AudioSource? _src;
  SoundHandle? _h;
  StateSynth? _synth;
  Timer? _feeder;
  int _added = 0;
  int _stalls = 0;
  int _deviceFailures = 0;
  bool _running = false;
  bool _stopping = false;
  StreamSubscription<AudioDeviceStartFailure>? _failures;
  final Stopwatch _clock = Stopwatch();

  @override
  int get stalls => _stalls;

  @override
  Future<void> start(SoundPlan plan, {double? fadeInS}) async {
    if (_running) await stop(seconds: 0.2);
    try {
      await _start(plan, fadeInS ?? plan.fadeInS);
    } catch (_) {
      await _release();
      rethrow;
    }
  }

  Future<void> _start(SoundPlan plan, double fadeInS) async {
    final g = await Isolate.run(() => StateSynth.gainsFor(plan)); // about 0.5 s of maths: off the screen's thread
    _synth = StateSynth(plan, bedGain: g.bed, beatGain: g.beat);
    if (!_s.isInitialized) await _s.init(sampleRate: synthRate, bufferSize: _buffer, lowLatency: false);
    _failures ??= _s.audioDeviceStartFailures.listen((_) {
      _deviceFailures++;
      unawaited(_s.startAudioDevice().catchError((Object _) {}));
    });
    _s.setGlobalVolume(1);
    _stalls = 0;
    _added = 0;
    _stopping = false;
    final src = _src = _s.setBufferStream(
      maxBufferSizeDuration: const Duration(seconds: 60),
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.5,
      sampleRate: synthRate,
      channels: Channels.stereo,
      format: BufferType.f32le,
      onBuffering: (isBuffering, _, _) {
        if (isBuffering && _running && !_stopping) _stalls++;
      },
    );
    _top();
    _h = _s.play(src, volume: 0);
    _s.fadeVolume(_h!, 1, _d(fadeInS));
    _clock
      ..reset()
      ..start();
    _running = true;
    _feeder = Timer.periodic(const Duration(milliseconds: 250), (_) => _guard(_top));
  }

  /// Seconds played: the engine's count (exact for a released stream), else the clock.
  double _played() {
    final src = _src;
    if (src == null) return 0;
    try {
      return _s.getStreamTimeConsumed(src).inMicroseconds / 1e6;
    } catch (_) {
      return _clock.elapsedMicroseconds / 1e6;
    }
  }

  /// Hands over pieces until the stream is [leadS] ahead of what plays.
  void _top() {
    final src = _src, synth = _synth;
    if (src == null || synth == null) return;
    final frames = (chunkS * synthRate).round();
    var ahead = _added / synthRate - _played();
    while (ahead < leadS) {
      final chunk = synth.next(frames);
      _s.addAudioDataStream(src, chunk.buffer.asUint8List(chunk.offsetInBytes, chunk.lengthInBytes));
      _added += frames;
      ahead += chunkS;
    }
  }

  Duration _d(double seconds) => Duration(milliseconds: (seconds * 1000).round());

  @override
  void fadeOut(double seconds) {
    final h = _h;
    if (!_running || h == null) return;
    _guard(() {
      _s.fadeVolume(h, 0, _d(seconds));
      _s.scheduleStop(h, _d(seconds + 0.5)); // silent for good, even if the app is not there to stop it
    });
  }

  @override
  Future<void> stop({double seconds = stopFadeS}) async {
    if (!_running) return _release();
    _running = false;
    _stopping = true;
    final h = _h;
    if (h != null) _guard(() => _s.fadeVolume(h, 0, _d(seconds)));
    await Future<void>.delayed(_d(seconds + 0.2));
    await _release();
  }

  Future<void> _release() async {
    _running = false;
    _stopping = true;
    _feeder?.cancel();
    _feeder = null;
    _synth = null;
    _src = null;
    _h = null;
    await _failures?.cancel();
    _failures = null;
    try {
      if (_s.isInitialized) await _s.deinitAsync(); // stops every voice and frees the stream
    } catch (_) {}
  }

  @override
  Map<String, Object?> info() {
    final out = <String, Object?>{
      'engine': 'flutter_soloud',
      'mode': 'sound for states',
      'sampleRate': synthRate,
      'bufferFrames': _buffer,
      'lowLatency': false,
      'leadS': leadS,
      'stalls': _stalls,
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

  /// An engine call that fails (a voice already gone) must not end the session.
  static void _guard(void Function() f) {
    try {
      f();
    } on SoLoudException catch (_) {}
  }
}
