// The confirmation questions' notification on the phone (ConfirmPrompts.kt through the "eeg_tracker/confirm" channel):
// hand the Android side the batch and its moment, and tell it what was answered in the app.
import 'package:flutter/services.dart';

abstract class ConfirmPhone {
  /// Keeps the batch ([ids] and their questions' [texts]) for [at] and arms it; an empty batch cancels it.
  Future<void> arm(DateTime at, List<String> ids, List<String> texts);

  /// [id] was answered in the app: it leaves the notification.
  Future<void> answered(String id);

  /// Notifications are allowed for the app and the questions' channel.
  Future<bool> notificationsOn();

  /// The phone's settings page for the questions' channel (sound, silent, off).
  Future<void> openChannelSettings();

  /// Called when the questions' notification is tapped while the app runs.
  set onOpen(void Function()? f);
}

class ChannelConfirmPhone implements ConfirmPhone {
  static const MethodChannel _channel = MethodChannel('eeg_tracker/confirm');

  @override
  Future<void> arm(DateTime at, List<String> ids, List<String> texts) =>
      _channel.invokeMethod<void>('arm', {'at': at.millisecondsSinceEpoch, 'ids': ids, 'texts': texts});

  @override
  Future<void> answered(String id) => _channel.invokeMethod<void>('answered', {'id': id});

  @override
  Future<bool> notificationsOn() async => (await _channel.invokeMapMethod<String, Object?>('status'))?['notifications'] == true;

  @override
  Future<void> openChannelSettings() => _channel.invokeMethod<void>('openChannelSettings');

  @override
  set onOpen(void Function()? f) => _channel.setMethodCallHandler(f == null
      ? null
      : (call) async {
          if (call.method == 'open') f();
        });
}
