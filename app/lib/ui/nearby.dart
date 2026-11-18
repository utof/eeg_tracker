// Bluetooth permission ("Nearby devices" on Android 12+, location before), shared by the night and the
// meditation screens (DECISIONS row 54).
import 'package:permission_handler/permission_handler.dart';

Future<bool> nearbyAllowed(int sdk) async {
  if (sdk >= 31) {
    return await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted;
  }
  return Permission.locationWhenInUse.isGranted;
}

/// Asks for it; opens the app's settings when Android will not ask again. True when granted.
Future<bool> requestNearby(int sdk) async {
  final asked = sdk >= 31 ? [Permission.bluetoothScan, Permission.bluetoothConnect] : [Permission.locationWhenInUse];
  final result = await asked.request();
  if (result.values.every((s) => s.isGranted)) return true;
  if (result.values.any((s) => s.isPermanentlyDenied)) await openAppSettings();
  return false;
}
