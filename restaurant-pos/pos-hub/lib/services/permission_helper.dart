import 'package:permission_handler/permission_handler.dart';

class PermissionHelper {
  static Future<bool> requestBluetoothPermissions() async {
    final perms = <Permission>[
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      // Location is needed for discovery on Android < 12
      Permission.locationWhenInUse,
    ];

    final results = await perms.request();

    bool granted = true;
    for (final r in results.entries) {
      // Location is "nice to have" but not fatal for SPP on 12+
      if (r.key == Permission.locationWhenInUse && r.value.isDenied) {
        continue;
      }
      if (!r.value.isGranted) {
        granted = false;
      }
    }
    return granted;
  }

  static Future<bool> hasBluetoothPermissions() async {
    final connect = await Permission.bluetoothConnect.status;
    final scan = await Permission.bluetoothScan.status;
    return connect.isGranted && scan.isGranted;
  }
}
