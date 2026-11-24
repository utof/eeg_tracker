// The push's own engine (DECISIONS 840-849): Android's job service (PushJob.kt) runs [runPushTask] in a Flutter
// engine of its own, with no service in the foreground and no notification, about every 15 minutes while the phone
// is on Wi-Fi and soon after a recording ends. It sends once (run.dart) and tells the job it is done.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../logs/activity.dart' show Activity;
import '../../logs/engine.dart' show EngineRecords;
import '../../logs/log.dart' show AppLog;
import '../../phone.dart';
import '../../recorder/recorder_service.dart' show loadShareConfig;
import '../protocol.dart';
import 'run.dart';

const MethodChannel _task = MethodChannel('eeg_tracker/push_task');
final AppLog _log = AppLog('push');

/// The engine's body; its entry point is `pushMain` in main.dart.
Future<void> runPushTask() async {
  WidgetsFlutterBinding.ensureInitialized();
  final records = EngineRecords.start(engine: 'push', recordingsDir: Phone.recordingsDir, power: Phone.powerMap);
  var ok = false;
  try {
    final soon = await _task.invokeMethod<bool>('soon') ?? false;
    final rec = await Phone.recordingsDir();
    if (rec == null) return;
    final filesDir = rec.substring(0, rec.lastIndexOf('/'));
    final ShareConfig config = await loadShareConfig();
    final wifi = await Phone.wifiNets().timeout(const Duration(seconds: 3), onTimeout: () => noWifiAnswer);
    final r = await Activity.during(
      'push',
      () => runPush(filesDir: filesDir, config: config, wifi: wifi, soon: soon, sharePort: config.port, log: _log.info),
    );
    ok = r.sent;
    // one line a run that tried: what was sent, or why not (never an address: DECISIONS 757)
    if (!r.sent && r.why != 'too soon after the last try' && r.why != 'sharing is off or no laptop is paired') {
      _log.info('nothing sent to the laptop: ${r.why}');
    }
  } catch (e) {
    _log.info('the push failed: ${'$e'.length > 160 ? '$e'.substring(0, 160) : e}');
  } finally {
    try {
      await records.stop();
    } catch (_) {}
    try {
      await _task.invokeMethod<void>('done', {'ok': ok});
    } catch (_) {}
  }
}
