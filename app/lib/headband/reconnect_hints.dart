// The phone's side of the reconnect ladder's hints (headband/reconnect_ladder.dart, DECISIONS 943): Android tells
// this engine when the phone was unlocked, Bluetooth was switched on, the app came to the front, or "Reconnect now"
// was tapped on the headband-lost notice (ReconnectHints.kt, channel "eeg_tracker/hints"). Also whether the screen
// is on, for the fallback's shorter wait. Nothing here connects to anything: a hint only cuts a wait short.
import 'package:flutter/services.dart';

import 'reconnect_ladder.dart';

class ReconnectHints {
  ReconnectHints({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('eeg_tracker/hints');
  final MethodChannel _channel;

  /// Every hint goes to [onHint] until [stop]. A phone without the channel (a test, another platform) gives none.
  Future<void> start(void Function(ReconnectHint hint) onHint) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'hint') return;
      final h = ReconnectHint.named(call.arguments);
      if (h != null) onHint(h);
    });
    try {
      await _channel.invokeMethod<void>('watch');
    } catch (_) {}
  }

  Future<void> stop() async {
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('unwatch');
    } catch (_) {}
  }

  /// False when it cannot be asked.
  Future<bool> screenOn() async {
    try {
      return await _channel.invokeMethod<bool>('screenOn') ?? false;
    } catch (_) {
      return false;
    }
  }
}
