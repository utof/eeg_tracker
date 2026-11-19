// The soft confirmation tone of the hands-free gestures (DECISIONS 245): what a session needs from it. Plain Dart, so
// the night recorder's isolate and the laptop tools can use the gestures without the sound engine; the real tone is
// soloud_gesture_tone.dart.
import '../detectors/gestures.dart';

abstract interface class GestureTone {
  /// Plays the confirmation for [kind]; never throws.
  void confirm(GestureKind kind);
}

/// No sound: keeps what it was asked, for tests.
class SilentGestureTone implements GestureTone {
  final List<GestureKind> played = [];

  @override
  void confirm(GestureKind kind) => played.add(kind);
}
