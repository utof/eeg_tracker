// Android's word that a Wi-Fi network came, went or changed its addresses (NetworkWatch.kt), so Share on Wi-Fi tells
// the paired laptop where this phone is at once, not at the next 5 minutes (DECISIONS 676). Without the platform
// side (tests, the laptop tools) the stream is simply silent.
import 'dart:async';

import 'package:flutter/services.dart';

class NetworkWatch {
  NetworkWatch._();

  static const MethodChannel _channel = MethodChannel('eeg_tracker/network');
  static StreamController<void>? _changes;

  /// One event per change (Android's callbacks, a second apart at most); asks Android to watch only while listened to.
  static Stream<void> changes() {
    final c = _changes ??= StreamController<void>.broadcast(onListen: () => unawaited(_watch(true)), onCancel: () => unawaited(_watch(false)));
    return c.stream;
  }

  static Future<void> _watch(bool on) async {
    _channel.setMethodCallHandler(
      on
          ? (call) async {
              if (call.method == 'changed') _changes?.add(null);
            }
          : null,
    );
    try {
      await _channel.invokeMethod<void>(on ? 'watch' : 'unwatch');
    } on PlatformException {
      // the phone would not watch: the 5-minute announcements and the minute's address look still run
    } on MissingPluginException {
      // no platform side here
    }
  }
}
