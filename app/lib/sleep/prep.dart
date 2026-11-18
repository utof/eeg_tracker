// The sleep model's input for one night, made the way scripts/score_sleep.py makes it from the night's BDF:
// the four channels high-passed at 0.3 Hz (MNE), resampled 250 -> 128 Hz (SciPy), robust-scaled over the whole
// night (AnySleep's recipe), cut to whole 30 s epochs; plus the epochs with over 5 s of missing data.
// Pure Dart (no Flutter), so it runs in a background isolate and in `dart run tool/...` on the laptop.
import 'dart:io';
import 'dart:typed_data';

import 'dsp.dart';
import 'night_signal.dart';

const int modelRate = 128;
const int epochSeconds = 30;
const int epochSamples = modelRate * epochSeconds; // 3840 model samples per epoch
const double highPassHz = 0.3;

/// score_sleep.py refuses a night under 5 minutes.
const int minEpochs = 10;

class ModelInput {
  ModelInput({
    required this.startUnix,
    required this.epochs,
    required this.gap,
    required this.channels,
    required this.percentiles,
    required this.recordedSamples,
    required this.missingSamples,
  });

  /// The first epoch's start (unix seconds, a whole second).
  final int startUnix;
  final int epochs;

  /// Per epoch: over 5 s of it was filled in (not scored).
  final List<bool> gap;

  /// O1 O2 T3 T4 at 128 Hz, scaled, [epochs] * 3840 samples each.
  final List<Float32List> channels;

  /// Per channel: 25th, 50th, 75th percentile in µV after filtering and resampling.
  final List<List<double>> percentiles;

  /// Samples (250 Hz) of the joined night, gaps included; and how many of them were filled in.
  final int recordedSamples;
  final int missingSamples;

  /// Model samples [fromEpoch, toEpoch) as one (time x 4 channels) block, the model's layout.
  Float32List interleaved(int fromEpoch, int toEpoch) {
    final a = fromEpoch * epochSamples, b = toEpoch * epochSamples;
    final out = Float32List((b - a) * 4);
    for (var c = 0; c < 4; c++) {
      final ch = channels[c];
      for (var i = a; i < b; i++) {
        out[(i - a) * 4 + c] = ch[i];
      }
    }
    return out;
  }
}

/// Builds the input from the night's `.f32` files (oldest first; each with its `.idx`). [progress] gets a short
/// line per step. Null when the night has fewer than [atLeast] epochs (5 minutes, as on the laptop).
ModelInput? prepareNight(List<File> f32Files, {void Function(String step)? progress, int atLeast = minEpochs}) {
  final layout = joinLayout(f32Files);
  final epochs = layout.samples ~/ (sampleRate * epochSeconds);
  if (epochs < atLeast || epochs == 0) return null;
  final taps = mneHighPassTaps(highPassHz, sampleRate.toDouble());
  final channels = <Float32List>[];
  final pct = <List<double>>[];
  for (var c = 0; c < 4; c++) {
    progress?.call('Preparing ${channelNames[c]} (${c + 1} of 4)');
    final scaled = prepareChannel(layout.channel(c), taps);
    pct.add(scaled.percentiles);
    channels.add(Float32List.fromList(Float64List.sublistView(scaled.signal, 0, epochs * epochSamples)));
  }
  return ModelInput(
    startUnix: layout.startUnix,
    epochs: epochs,
    gap: gapEpochs(layout, epochs),
    channels: channels,
    percentiles: pct,
    recordedSamples: layout.samples,
    missingSamples: layout.missingSamples,
  );
}

/// One channel (µV at 250 Hz) through the high-pass, the resampler and the scaling.
({Float64List signal, List<double> percentiles}) prepareChannel(Float64List uv, Float64List highPassTaps) {
  final filtered = zeroPhaseFir(uv, highPassTaps);
  final resampled = resamplePoly(filtered, modelRate, sampleRate);
  final p = robustScale(resampled);
  return (signal: resampled, percentiles: p);
}
