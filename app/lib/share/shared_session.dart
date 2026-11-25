// The daytime session that holds the headband, as Share on Wi-Fi's /state tells the paired laptop's tray (DECISIONS
// 671): the session's screen writes it (`WorkController.shareState`), the app's own server between nights reads it
// (ShareControl). Null while none runs. One value for the app, like `workSessionRunning`.
import 'package:flutter/foundation.dart';

final ValueNotifier<Map<String, Object?>?> sharedSession = ValueNotifier<Map<String, Object?>?>(null);

/// The newest headband notice of a daytime session (lost, back, battery nearly empty; lib/headband/lost_watch.dart,
/// DECISIONS 857), for /state's `alert`: it travels beside the session's summary. Null: none in this app run.
final ValueNotifier<Map<String, Object?>?> sharedAlert = ValueNotifier<Map<String, Object?>?>(null);

/// The message that carries the session's summary to the recorder's service (its server answers during a recording).
const String shareSessionKind = 'shareSession';

/// What the server gets as the session: [session] with [alert] beside it (null when there is neither).
Map<String, Object?>? sessionWithAlert(Map<String, Object?>? session, Map<String, Object?>? alert) =>
    alert == null ? session : {...?session, 'alert': alert};
