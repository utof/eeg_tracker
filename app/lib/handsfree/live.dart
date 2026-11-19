// Hands-free controls during a session (DECISIONS 244-246): the gesture recogniser looks over the shoulder of the
// session's own detectors (no second filter bank), and each recognised gesture plays the soft confirmation tone and
// goes to the session, which decides what it means (pause or resume the sound, a moment, the dream catcher's answer).
// While the drift-off detector says probably asleep the gestures are off: a gesture found then is dropped and
// counted, never acted on. Only made while the owner's switch is on and the calibration found a usable gesture.
import '../detectors/detectors.dart';
import '../detectors/gestures.dart';
import '../sound/gesture_tone.dart';

/// What a session marks for a gesture: `hands-free: <what> (double clench)`.
String gestureWord(GestureKind k) => k == GestureKind.clench ? 'double clench' : 'look left then right';

class HandsFree {
  HandsFree(GestureSettings settings, {required this.onGesture, this.tone, bool Function()? asleep, this.keepClusters = false})
    : _asleep = asleep ?? _never,
      gestures = Gestures(settings: settings, keepClusters: keepClusters);

  /// Called for every gesture acted on (after the tone).
  final void Function(GestureKind kind) onGesture;
  final GestureTone? tone;
  final bool keepClusters;
  final bool Function() _asleep;
  final Gestures gestures;

  /// Gestures acted on, and gestures dropped because the person was probably asleep.
  int heard = 0, ignoredAsleep = 0;

  static bool _never() => false;

  /// Starts looking at [d]'s samples. Call before its first sample: a second already begun counts as spoiled.
  void attach(Detectors d) => d.tap = GestureTap(_second);

  void _second(GestureSecond s) {
    for (final g in gestures.second(s)) {
      if (_asleep()) {
        ignoredAsleep++;
        continue;
      }
      heard++;
      tone?.confirm(g.kind);
      onGesture(g.kind);
    }
    if (!keepClusters) gestures.gestures.clear();
  }

  /// For the session file.
  Map<String, Object?> summary() => {
    'settings': gestures.settings.toJson(),
    'heard': heard,
    'ignoredAsleep': ignoredAsleep,
  };
}
