// The sharp-hours questions and the study reminders on the phone (SharpPrompts.kt through the "eeg_tracker/sharp"
// channel; DECISIONS rows 281-283, 400-401): hand the Android side the moments ahead, and take the notification
// tap that opened the app. One list and one alarm chain carry both; each moment says which it is ([PromptKind]).
import 'package:flutter/services.dart';

import 'schedule.dart';
import 'store.dart';

/// The notification tap that opened the app: its planned moment, when it appeared, what it asked, and (a sharp
/// question) whether it suggests the test.
class SharpLaunch {
  const SharpLaunch({required this.planned, this.shown, this.test = false, this.kind = PromptKind.sharp});
  final DateTime planned;
  final DateTime? shown;
  final bool test;
  final PromptKind kind;

  static SharpLaunch? fromMap(Object? m) {
    if (m is! Map) return null;
    final p = m['planned'], s = m['shown'];
    if (p is! int || p <= 0) return null;
    return SharpLaunch(
      planned: DateTime.fromMillisecondsSinceEpoch(p),
      shown: s is int && s > 0 ? DateTime.fromMillisecondsSinceEpoch(s) : null,
      test: m['test'] == true,
      kind: PromptKind.values.where((k) => k.wire == m['kind']).firstOrNull ?? PromptKind.sharp,
    );
  }
}

abstract class SharpPhone {
  /// Keeps [prompts] as the moments ahead and arms the first; an empty list cancels them all.
  Future<void> arm(List<PlannedPrompt> prompts);

  /// The question a notification tap opened, once; null otherwise.
  Future<SharpLaunch?> takeLaunch();

  /// Notifications are allowed for the app and the questions' channel.
  Future<bool> notificationsOn();

  /// The same for the study reminders' own channel.
  Future<bool> studyNotificationsOn();

  /// The phone's settings page for the questions' channel (sound, silent, off).
  Future<void> openChannelSettings();

  /// Called when a notification is tapped while the app runs.
  set onOpen(void Function()? f);
}

class ChannelSharpPhone implements SharpPhone {
  static const MethodChannel _channel = MethodChannel('eeg_tracker/sharp');

  @override
  Future<void> arm(List<PlannedPrompt> prompts) => _channel.invokeMethod<void>('arm', {
    'at': [for (final p in prompts) p.at.millisecondsSinceEpoch],
    'test': [for (final p in prompts) p.test],
    'kind': [for (final p in prompts) p.kind.wire],
  });

  @override
  Future<SharpLaunch?> takeLaunch() async => SharpLaunch.fromMap(await _channel.invokeMethod<Object?>('takeLaunch'));

  @override
  Future<bool> notificationsOn() async {
    final m = await _channel.invokeMapMethod<String, Object?>('status');
    return m?['notifications'] == true;
  }

  @override
  Future<bool> studyNotificationsOn() async {
    final m = await _channel.invokeMapMethod<String, Object?>('status');
    return m?['studyNotifications'] == true;
  }

  @override
  Future<void> openChannelSettings() => _channel.invokeMethod<void>('openChannelSettings');

  @override
  set onOpen(void Function()? f) => _channel.setMethodCallHandler(f == null
      ? null
      : (call) async {
          if (call.method == 'open') f();
        });
}

/// Hands the phone the moments ahead from the saved settings: none when off or never set up. Called at every app
/// start and return (the night screen), and after each change on the sharp-hours page.
Future<void> rearmSharp(SharpStore store, SharpPhone phone, DateTime now) async {
  final s = store.settings();
  await phone.arm(s == null ? const [] : upcomingPrompts(now, s));
}
