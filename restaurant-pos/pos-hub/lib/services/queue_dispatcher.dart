import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import '../models/print_job.dart';
import 'escpos_renderer.dart';
import 'print_queue_db.dart';
import 'bluetooth_printer_manager.dart';

/// Dispatches PENDING jobs one at a time to the correct printer over SPP.
class QueueDispatcher {
  static final QueueDispatcher instance = QueueDispatcher._internal();
  QueueDispatcher._internal();

  final PrintQueueDb db = PrintQueueDb.instance;
  final BluetoothPrinterManager bt = BluetoothPrinterManager.instance;

  final Map<String, BluetoothDevice> _printerMap = {};
  final Map<String, String> _stationMacMap = {};

  bool _dispatching = false;
  bool _drainQueued = false;

  void Function(String station, String status)? onJobResult;

  /// Station names come from the portal (e.g. "Griddle") but may have been
  /// typed in a different case when assigning a printer, so all station keys are
  /// compared case-insensitively.
  static String normalizeStation(String station) => station.trim().toLowerCase();

  Future<void> loadBondedPrinters() async {
    _printerMap.clear();
    final bonded = await bt.getBondedDevices();
    for (final d in bonded) {
      if (d.name != null) _printerMap[d.name!] = d;
      _printerMap[d.address] = d;
    }
    await loadStationMappings();
  }

  /// Loads persistent station -> printer MAC assignments from SQLite.
  Future<void> loadStationMappings() async {
    _stationMacMap.clear();
    final stored = await db.getStationPrinters();
    stored.forEach((station, mac) {
      _stationMacMap[normalizeStation(station)] = mac;
    });
  }

  void registerPrinter(String station, BluetoothDevice device) {
    _printerMap[station] = device;
    _printerMap[device.address] = device;
  }

  /// Persists a station -> printer assignment.
  Future<void> assignStationPrinter(
      String station, BluetoothDevice device) async {
    _stationMacMap[normalizeStation(station)] = device.address;
    _printerMap[device.address] = device;
    await db.assignPrinter(station, device.address, device.name ?? '');
  }

  Future<void> clearStationPrinter(String station) async {
    _stationMacMap.remove(normalizeStation(station));
    await db.clearStationPrinter(station);
  }

  /// Reset a failed/stuck job to PENDING and re-dispatch.
  Future<void> retryJob(int id) async {
    await db.retry(id);
    // Reload mappings in case a station->printer was assigned after startup.
    await loadBondedPrinters();
    await dispatchNext();
  }

  /// Single entry point. Safe to call concurrently: concurrent triggers
  /// coalesce into one serial drain of the queue.
  Future<void> dispatchNext() async {
    if (_dispatching) {
      _drainQueued = true;
      return;
    }
    _dispatching = true;

    try {
      do {
        _drainQueued = false;
        await _processOne();
      } while (_drainQueued);
    } finally {
      _dispatching = false;
    }
  }

  Future<void> _processOne() async {
    final pending = await db.getPendingJobs();
    if (pending.isEmpty) {
      _drainQueued = false;
      return;
    }

    final job = pending.first;
    final device = _resolvePrinter(job);

    if (device == null) {
      final assigned = _stationMacMap.keys.join(', ');
      final detail = assigned.isEmpty ? 'no stations assigned yet' : 'assigned: $assigned';
      final message = 'No printer for station "${job.station}" ($detail)';
      await db.fail(job.id!, message);
      onJobResult?.call(job.station, 'FAILED — $message');
    } else {
      await db.updateStatus(job.id!, 'PRINTING');

      try {
        final data = job.kind == 'receipt'
            ? await EscPosRenderer.renderReceipt(job.payload)
            : await EscPosRenderer.renderOrder(job.station, job.payload);
        final ok = await bt.print(device, data);

        if (ok) {
          // Printed: it leaves the queue, so the list only shows outstanding
          // or failed jobs.
          await db.deleteJob(job.id!);
        } else {
          await db.updateStatus(job.id!, 'FAILED', error: 'Print failed');
        }
        onJobResult?.call(job.station, ok ? 'DONE' : 'FAILED');
      } catch (e) {
        await db.fail(job.id!, 'Error: $e');
        onJobResult?.call(job.station, 'FAILED (error: $e)');
      }
    }

    // One order can span several stations, each with its own ticket, so keep
    // draining while jobs remain. A concurrent dispatchNext() during this job
    // may also have set the flag; preserve it.
    final remaining = await db.getPendingJobs();
    _drainQueued = _drainQueued || remaining.isNotEmpty;
  }

  BluetoothDevice? _resolvePrinter(PrintJob job) {
    // 1. Explicit MAC in the job payload (e.g. from HTTP client)
    if (job.printerMac.isNotEmpty) {
      final d = _printerMap[job.printerMac];
      if (d != null) return d;
      try {
        return BluetoothDevice(address: job.printerMac);
      } catch (_) {}
    }

    // 2. Persistent station -> MAC mapping (case-insensitive)
    final mappedMac = _stationMacMap[normalizeStation(job.station)];
    if (mappedMac != null) {
      final d = _printerMap[mappedMac];
      if (d != null) return d;
      try {
        return BluetoothDevice(address: mappedMac);
      } catch (_) {}
    }

    // 3. Fallback: a device registered in-memory for this station name
    return _printerMap[job.station] ??
        _printerMap[normalizeStation(job.station)];
  }
}
