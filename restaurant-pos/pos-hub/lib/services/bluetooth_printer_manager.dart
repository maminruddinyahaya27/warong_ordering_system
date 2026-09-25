import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import 'print_throttle.dart';

/// Manages Classic Bluetooth SPP connections to MPT-11 / MPT-58 printers.
///
/// Strictly sequential: one RFCOMM connection at a time, with a cooldown
/// between prints to the same device. Printers are shared between stations
/// (e.g. a beverage printer also prints receipts), so two jobs can target the
/// same device back-to-back — without the cooldown the second one fails.
class BluetoothPrinterManager {
  static final BluetoothPrinterManager instance =
      BluetoothPrinterManager._internal();
  BluetoothPrinterManager._internal();

  final FlutterBluetoothSerial _bluetooth = FlutterBluetoothSerial.instance;

  /// Cooldown/retry policy, configurable from the hub settings.
  final PrintThrottle throttle = PrintThrottle();

  /// Serialises every print so a manual test print cannot overlap a queued job.
  Future<void> _printChain = Future<void>.value();

  Future<bool> get isEnabled async => (await _bluetooth.isEnabled) ?? false;

  Future<bool?> enable() async {
    return _bluetooth.requestEnable();
  }

  Future<List<BluetoothDevice>> getBondedDevices() async {
    return _bluetooth.getBondedDevices();
  }

  Stream<BluetoothDiscoveryResult> startDiscovery() {
    return _bluetooth.startDiscovery();
  }

  Future<void> cancelDiscovery() async {
    await _bluetooth.cancelDiscovery();
  }

  Future<bool> bondDevice(BluetoothDevice device, {String? pin}) async {
    try {
      final result =
          await _bluetooth.bondDeviceAtAddress(device.address, pin: pin);
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> unbondDevice(BluetoothDevice device) async {
    try {
      await _bluetooth.removeDeviceBondWithAddress(device.address);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Opens an SPP connection, writes bytes, waits for the printer, closes.
  ///
  /// Runs through a queue and waits for the device's cooldown, retrying with
  /// back-off so a shared printer keeps working.
  Future<bool> print(BluetoothDevice device, Uint8List data) {
    final completer = Completer<bool>();
    _printChain = _printChain.then((_) async {
      try {
        completer.complete(await _printNow(device, data));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<bool> _printNow(BluetoothDevice device, Uint8List data) async {
    await throttle.waitFor(device.address);

    for (var attempt = 1; attempt <= throttle.maxAttempts; attempt++) {
      final ok = await _attemptPrint(device, data);
      throttle.markUsed(device.address);
      if (ok) return true;
      if (attempt < throttle.maxAttempts) {
        await throttle.backOff(attempt);
      }
    }
    return false;
  }

  Future<bool> _attemptPrint(BluetoothDevice device, Uint8List data) async {
    BluetoothConnection? connection;
    try {
      connection = await BluetoothConnection.toAddress(device.address);
      connection.output.add(data);
      await connection.output.allSent;
      // Let the printer drain before dropping the link.
      await throttle.settle();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await connection?.finish();
      } catch (_) {}
      try {
        await connection?.close();
      } catch (_) {}
    }
  }
}
