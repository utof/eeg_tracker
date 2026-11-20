// The daytime session that holds the headband, as Share on Wi-Fi's /state tells the paired laptop's tray (DECISIONS
// 671): the session's screen writes it (`WorkController.shareState`), the app's own server between nights reads it
// (ShareControl). Null while none runs. One value for the app, like `workSessionRunning`.
import 'package:flutter/foundation.dart';

final ValueNotifier<Map<String, Object?>?> sharedSession = ValueNotifier<Map<String, Object?>?>(null);
