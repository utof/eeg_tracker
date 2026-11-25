// The Signal view's phone side (signal/signal_feed.dart `SignalPhone`): the night recorder's service and messages, the
// device choice and the positions file, Nearby devices, Bluetooth and Wi-Fi, and the headband finders.
import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../auto/channel.dart' show AutoChannel;
import '../headband/connection.dart';
import '../headband/diy/board.dart' show DiyFinder;
import '../headband/finder.dart';
import '../phone.dart';
import '../recorder/recorder_service.dart' show statusCommand;
import '../signal/layout.dart';
import '../signal/live_tap.dart';
import '../signal/signal_feed.dart';
import 'nearby.dart';
import 'own_ble_screen.dart' show phoneWifiAddress;

SignalPhone phoneSignal() {
  // The DIY board's connection of the Signal tab has an owner like the BrainBit's (headband/connection.dart), so the
  // one headband card shows it: state and each channel's word from the one judge, for any number of channels
  // (DECISIONS 947). Nothing is kept after the tab lets go, and no night is ever lent from it.
  var names = const <String>[];
  final diy = HeadbandConnection(
    makeFinder: () => BrainBitFinder(pick: () async => DiyFinder(names: names)),
    disposeFinder: (f, {required anyLost}) {
      if (f is BrainBitFinder) f.dispose(anyLost: anyLost);
    },
  );
  return SignalPhone(
    nightRunning: () => FlutterForegroundTask.isRunningService,
    leaseNight: (on) {
      FlutterForegroundTask.sendDataToTask(nightTapLeaseMessage(on: on, user: tapSignal));
      if (on) FlutterForegroundTask.sendDataToTask(statusCommand);
    },
    fromRecorder: _recorderMessages,
    device: signalDevice,
    readiness: _readiness,
    finderFor: (d) {
      if (!d.diy) return BrainBitFinder();
      names = d.montage.names;
      return diy.finder;
    },
    disposeFinder: (f, {required anyLost}) {
      // the board's finder is its owner's to end
      if (f is BrainBitFinder) f.dispose(anyLost: anyLost);
    },
    holdHeadband: AutoChannel.screenHolds,
    diyConnection: diy,
  );
}

/// The recorder's messages while someone listens (the night screen keeps its own callback).
Stream<Object> _recorderMessages() {
  late final StreamController<Object> c;
  void on(Object data) {
    if (!c.isClosed) c.add(data);
  }

  c = StreamController<Object>(
    onListen: () => FlutterForegroundTask.addTaskDataCallback(on),
    onCancel: () => FlutterForegroundTask.removeTaskDataCallback(on),
  );
  return c.stream;
}

/// The chosen device (BrainBit, or the DIY board with its channel names) with the positions file's places.
Future<SignalDevice> signalDevice() async {
  final diy = await loadDiyBoard();
  final useDiy = diy.settings.useDiy;
  final base = useDiy ? diyBoardMontage(diy.settings.names) : brainBitMontage();
  CustomPositions custom = const CustomPositions();
  try {
    final rec = await Phone.recordingsDir();
    if (rec != null) custom = PositionsStore(signalDirFor(rec)).load();
  } catch (_) {}
  return SignalDevice(montage: withPositions(base, custom), measuresContact: !useDiy, diy: useDiy);
}

Future<Readiness?> _readiness(SignalDevice d) async {
  if (d.diy) return await phoneWifiAddress() == null ? Readiness.wifi : null;
  final phone = await Phone.snapshot();
  if (!await nearbyAllowed(phone.sdkInt)) return Readiness.nearby;
  if (!phone.bluetoothOn) return Readiness.bluetooth;
  return null;
}

/// Asks for Nearby devices; true when allowed.
Future<bool> askNearby() async {
  try {
    final phone = await Phone.snapshot();
    return await requestNearby(phone.sdkInt);
  } catch (_) {
    return false;
  }
}
