// The phone's microphone through the `record` package (BSD-3-Clause; DECISIONS row 112): 16 kHz mono WAV, no
// automatic gain (it would lift the room's hiss after you stop speaking and look like a voice), no Bluetooth
// headset link (the headband is Bluetooth too, and the phone's own microphone hears you in bed).
import 'package:record/record.dart';

import 'audio.dart';

class RecordMic implements Mic {
  final AudioRecorder _rec = AudioRecorder();

  static const RecordConfig config = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
    androidConfig: AndroidRecordConfig(manageBluetooth: false),
  );

  @override
  Future<bool> allowed({bool ask = true}) => _rec.hasPermission(request: ask);

  @override
  Future<void> start(String path) => _rec.start(config, path: path);

  @override
  Stream<double> get levels => _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).map((a) => a.current);

  @override
  Future<void> stop() async {
    await _rec.stop();
  }

  @override
  Future<void> dispose() => _rec.dispose();
}
