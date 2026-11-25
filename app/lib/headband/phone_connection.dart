// The one connection as the app wires it on the phone (connection.dart, DECISIONS 855): the BrainBit's switch as the
// real finder, the connection kept for 3 minutes after its last user, the headband watcher told while it is held, the
// recorder's messages mirrored, the battery track and the lost-headband notices of daytime sessions.
import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../auto/channel.dart' show AutoChannel;
import '../phone.dart';
import '../recorder/recorder_service.dart' show statusCommand;
import '../session_keeper.dart' show PhoneSessionKeeper;
import '../share/shared_session.dart' show sharedAlert;
import '../signal/live_tap.dart' show nightTapLeaseMessage;
import 'battery_estimate.dart';
import 'connection.dart';
import 'device_status.dart';
import 'finder.dart';
import 'lost_watch.dart';

/// How long the connection is kept after the last screen let go: Signal, then Start, is one connection.
const Duration keepConnectionFor = Duration(minutes: 3);

/// Makes the screen's engine's owner and starts mirroring the recorder. Call once, at app start.
HeadbandConnection startPhoneConnection() {
  LostSettings settings() => _lostFile == null ? const LostSettings() : LostSettings.load(_lostFile!);
  late final HeadbandConnection c;
  final watch = LostWatch(
    settings: settings,
    what: 'The session',
    tell: (n) {
      sharedAlert.value = n.toMap();
      unawaited(Phone.bandNotice(n.title, n.text));
    },
  );
  var emptyLookMs = 0;
  void onStatus(DeviceStatus s) {
    // a night's notices are the recorder's own; here only a daytime session that streams the headband
    final session = PhoneSessionKeeper.heldWithHeadband && s.use != BandUse.night;
    watch.update(expecting: session, dataFresh: s.link == LinkState.live, batteryEmpty: s.battery.empty);
    final store = c.battery;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (session && store != null && now - emptyLookMs >= 60000) {
      emptyLookMs = now;
      final t = store.load();
      if (t.takeEmpty()) {
        store.save(t);
        watch.batteryEmpty(t.now.percent);
      }
    }
  }

  c = HeadbandConnection(
    makeFinder: () => BrainBitFinder(own: true),
    disposeFinder: (f, {required anyLost}) {
      if (f is BrainBitFinder) f.dispose(anyLost: anyLost);
    },
    linger: keepConnectionFor,
    hold: AutoChannel.screenHolds,
    leaseNight: (on, user) {
      FlutterForegroundTask.sendDataToTask(nightTapLeaseMessage(on: on, user: user));
      if (on) FlutterForegroundTask.sendDataToTask(statusCommand);
    },
    sendToNight: FlutterForegroundTask.sendDataToTask,
    sessionRuns: () => PhoneSessionKeeper.heldWithHeadband,
    onStatus: onStatus,
  );
  FlutterForegroundTask.addTaskDataCallback(c.recorderData);
  unawaited(() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec == null) return;
      c.battery = BandBatteryStore.forRecordings(rec);
      _lostFile = LostSettings.fileFor(rec);
    } catch (_) {}
  }());
  return c;
}

File? _lostFile;
