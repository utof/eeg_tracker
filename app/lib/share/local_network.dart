// Android 17 (API 37) blocks the app's TCP connections to and from the local network (Share on Wi-Fi's server,
// pairing with the laptop) unless it holds ACCESS_LOCAL_NETWORK. Android only enforces that when the app TARGETS
// 37 or newer; below that it grants the permission by itself, and a blocked connection just times out. Dart sockets
// cannot show the prompt, so ask here before the first one. Today's target is 36 (Flutter's own), so nothing is
// asked; this starts working by itself the day Flutter's target becomes 37.
import 'package:permission_handler/permission_handler.dart';

import '../phone.dart';

/// Android 17's rule: the phone has the permission AND the app is built to be held to it.
bool localNetworkNeedsAsking({required int deviceSdk, required int targetSdk}) => deviceSdk >= 37 && targetSdk >= 37;

Future<({int device, int target})> _phoneSdks() async {
  try {
    final s = await Phone.snapshot();
    return (device: s.sdkInt, target: s.targetSdkInt);
  } on Object {
    return (device: 0, target: 0); // no Android to ask (a desktop or a test run)
  }
}

/// True when local-network traffic is allowed: without asking below Android 17 or for a target below 37, else
/// after the permission is granted (it asks once if needed; with Bluetooth already allowed Android may grant it
/// without a prompt, the two share the "Nearby devices" group). False when the owner refused: the caller says so
/// and does not start the server or the pairing; [openAppSettings] is the way back when it is permanently denied.
/// The three parameters let a test fake the phone.
Future<bool> ensureLocalNetwork({
  Future<({int device, int target})> Function() sdks = _phoneSdks,
  Future<PermissionStatus> Function() status = _status,
  Future<PermissionStatus> Function() request = _request,
}) async {
  final (:device, :target) = await sdks();
  if (!localNetworkNeedsAsking(deviceSdk: device, targetSdk: target)) return true;
  if (_allowed(await status())) return true;
  return _allowed(await request());
}

bool _allowed(PermissionStatus s) => s.isGranted || s.isLimited;

Future<PermissionStatus> _status() => Permission.accessLocalNetwork.status;

Future<PermissionStatus> _request() => Permission.accessLocalNetwork.request();
