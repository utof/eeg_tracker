// What the dream catcher needs from the phone's sound and microphone. The real ones are flutter_soloud
// (sound/dream_sound.dart) and the `record` package (dream/record_mic.dart); tests use fakes.
import 'store.dart' show PromptKind;

abstract class DreamSound {
  /// Starts the engine. Throws when the audio cannot start.
  Future<void> start();

  /// Plays your recording [file] of [kind] quietly, or the built-in tone when [file] is null; completes when it has
  /// finished (or after a deadline, should the engine never say so).
  Future<void> prompt(PromptKind kind, String? file);

  /// The gentle rising wake tone (alpha-theta's).
  void wake();

  /// Fades out and releases the audio device.
  Future<void> stop();

  Map<String, Object?> info();
}

/// Plays one recording at a time outside a session: your prompts while you set them up, your answers afterwards.
abstract class ClipPlayer {
  /// Plays [path] at [volume] (0..1); completes when it has finished or [stopClip] was called.
  Future<void> playClip(String path, {double volume = 1});
  Future<void> stopClip();
}

abstract class Mic {
  /// Whether the app may record; asks Android once when [ask].
  Future<bool> allowed({bool ask = true});

  /// Starts recording to [path] (a 16 kHz mono WAV). [levels] then gives the level in dBFS every 0.1 s.
  Future<void> start(String path);
  Stream<double> get levels;

  /// Ends the recording and closes the file.
  Future<void> stop();
  Future<void> dispose();
}

/// No sound: counts what would have played, for tests and as the fallback when the audio engine fails.
class SilentDreamSound implements DreamSound {
  final List<String> played = [];
  int wakes = 0;
  bool started = false, stopped = false;

  @override
  Future<void> start() async => started = true;
  @override
  Future<void> prompt(PromptKind kind, String? file) async => played.add('${kind.name}:${file == null ? 'tone' : 'own'}');
  @override
  void wake() => wakes++;
  @override
  Future<void> stop() async => stopped = true;
  @override
  Map<String, Object?> info() => {'engine': 'none'};
}
