import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import '../models/print_job.dart';
import '../services/app_events.dart';
import '../services/app_settings.dart';
import '../services/bluetooth_printer_manager.dart';
import '../services/hub_auth.dart';
import '../services/menu_sync_service.dart';
import '../services/online_order_service.dart';
import '../services/permission_helper.dart';
import '../services/pos_http_server.dart';
import '../services/print_queue_db.dart';
import '../services/queue_dispatcher.dart';

/// Hub administration: network address, HTTP server, printers and print queue.
///
/// Rendered inside the Settings page ([embedded] true) or as a standalone
/// screen.
class HubScreen extends StatefulWidget {
  const HubScreen({super.key, this.embedded = false});

  final bool embedded;

  /// Cheap thermal printers advertise many different names, so match the common
  /// tokens rather than a fixed list of models. Used to hide phones, watches,
  /// headsets and unnamed devices from the printer list.
  static const List<String> printerTokens = [
    'mpt',
    'pos',
    'printer',
    'print',
    'thermal',
    'receipt',
    'label',
    'epson',
    'star',
    'zebra',
    'bixolon',
    'citizen',
    'gainscha',
    'xprinter',
    'rpp',
    'xp-',
    'gp-',
    'sp-',
    'bt-',
    'blue',
    '58',
    '80',
  ];

  static bool looksLikePrinter(String? name) {
    final value = (name ?? '').trim().toLowerCase();
    if (value.isEmpty) return false;
    return printerTokens.any(value.contains);
  }

  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  final PrintQueueDb db = PrintQueueDb.instance;
  final BluetoothPrinterManager bt = BluetoothPrinterManager.instance;
  final QueueDispatcher dispatcher = QueueDispatcher.instance;
  final PosHttpServer server = PosHttpServer.instance;
  final SettingsStore settings = SettingsStore.instance;

  String _ip = '--';
  bool _btEnabled = false;
  List<BluetoothDevice> _devices = [];
  List<PrintJob> _jobs = [];
  Map<String, String> _stationPrinters = {};
  Map<String, String> _stationPrinterNames = {};
  int _productCount = 0;
  bool _syncing = false;
  Timer? _refreshTimer;

  /// Used until the catalogue is synced, so the UI always has stations.
  static const List<String> _fallbackStations = [
    'Griddle',
    'Kitchen',
    'Wok',
    'Beverage',
  ];

  /// Stations actually used by the synced catalogue (matches the portal).
  List<String> _stations = List.of(_fallbackStations);

  /// False until a sync has produced stations, i.e. the defaults are showing.
  bool _stationsSynced = false;
  String _testStation = 'Kitchen';

  /// Bluetooth lists include phones, watches and headsets. Only devices whose
  /// name looks like a receipt printer are listed unless this is on.
  bool _showAllDevices = false;

  List<BluetoothDevice> get _visibleDevices => _showAllDevices
      ? _devices
      : _devices
          .where((device) => HubScreen.looksLikePrinter(device.name))
          .toList();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bridge = _Bridge();
    _ip = await bridge.localIp();
    _btEnabled = await bt.isEnabled;

    dispatcher.onJobResult = (station, status) {
      if (!mounted) return;
      // Successful prints are quiet — the Queue tab already shows them.
      if (!status.startsWith('DONE')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$station: $status')),
        );
      }
      _refreshQueue();
      AppEvents.queueChanged();
    };

    server.onOrderReceived = () {
      _refreshQueue();
      dispatcher.dispatchNext();
      AppEvents.ordersChanged();
    };

    final granted = await PermissionHelper.requestBluetoothPermissions();
    if (granted) {
      _btEnabled = await bt.isEnabled;
      await _refreshDevices();
      await _refreshStationAssignments();
    } else {
      _snack('Bluetooth permissions denied. Grant them in Settings.');
    }

    await _refreshQueue();
    await _refreshStationAssignments();
    await _refreshProductCount();
    await _refreshStations();
    await db.resetStaleJobs();

    try {
      await dispatcher.loadBondedPrinters();
    } catch (_) {}

    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await _refreshQueue();
      // Safety net: if anything is still queued (a missed trigger, or a job
      // added mid-drain), print it. dispatchNext() no-ops on an empty queue.
      if (_jobs.any((job) => job.status == 'PENDING')) {
        await dispatcher.dispatchNext();
      }
    });
    if (mounted) setState(() {});
  }

  Future<void> _refreshQueue() async {
    final jobs = await db.getAllJobs();
    if (mounted) setState(() => _jobs = jobs);
  }

  Future<void> _refreshProductCount() async {
    final count = await db.countProducts();
    if (mounted) setState(() => _productCount = count);
  }

  /// The station list follows the synced catalogue, so station -> printer
  /// mapping uses exactly the station names the portal sends.
  Future<void> _refreshStations() async {
    final fromCatalog = await db.getStations();
    if (!mounted) return;
    setState(() {
      _stationsSynced = fromCatalog.isNotEmpty;
      _stations =
          fromCatalog.isEmpty ? List.of(_fallbackStations) : fromCatalog;
      if (!_stations.contains(_testStation)) {
        _testStation = _stations.first;
      }
    });
  }

  Future<void> _refreshStationsManually() async {
    await _refreshStations();
    _snack(_stationsSynced
        ? 'Stations from the menu: ${_stations.join(', ')}'
        : 'No stations in the menu cache yet — run Sync menu');
  }

  Future<void> _refreshStationAssignments() async {
    final macs = await db.getStationPrinters();
    final names = await db.getStationPrinterNames();
    // Prefer the name the system reports right now for that address: the name
    // captured at pairing time goes stale if the printer is renamed in Android.
    final live = <String, String>{
      for (final device in _devices)
        if ((device.name ?? '').trim().isNotEmpty)
          device.address.toUpperCase(): device.name!.trim(),
    };
    if (mounted) {
      setState(() {
        // Keyed case-insensitively: assignments may have been saved before the
        // portal sent its own station casing (e.g. "BEVERAGE" vs "Beverage").
        _stationPrinters = {
          for (final entry in macs.entries)
            _stationKey(entry.key): entry.value,
        };
        _stationPrinterNames = {
          for (final entry in names.entries)
            _stationKey(entry.key):
                live[entry.value.toUpperCase()] ?? entry.value,
        };
      });
    }
  }

  static String _stationKey(String station) => station.trim().toLowerCase();

  Future<void> _refreshDevices() async {
    if (!_btEnabled) return;
    final bonded = await bt.getBondedDevices();
    if (mounted) setState(() => _devices = bonded);
  }

  Future<void> _toggleServer() async {
    if (server.isRunning) {
      await server.stop();
    } else {
      try {
        await server.start();
      } catch (e) {
        _snack('Server failed to start: $e');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _syncMenu() async {
    if (settings.portalUrl.isEmpty) {
      _snack('Set the portal URL in the settings above first');
      return;
    }
    setState(() => _syncing = true);
    try {
      final result = await MenuSyncService.instance.sync();
      await _refreshProductCount();
      await _refreshStations();
      _snack(
          'Synced ${result.count} item(s) · stations: ${_stations.join(', ')}');
    } catch (error) {
      _snack('Sync failed: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _scanPrinters() async {
    if (!await PermissionHelper.hasBluetoothPermissions()) {
      final ok = await PermissionHelper.requestBluetoothPermissions();
      if (!ok) {
        _snack('Bluetooth permissions required');
        return;
      }
    }

    if (!_btEnabled) {
      final ok = await bt.enable();
      if (ok != true) {
        _snack('Bluetooth could not be enabled');
        return;
      }
      setState(() => _btEnabled = true);
    }

    _snack('Scanning for printers...');
    final discovered = <String, BluetoothDevice>{};
    for (final d in _devices) {
      discovered[d.address] = d;
    }

    final sub = bt.startDiscovery().listen((result) {
      discovered[result.device.address] = result.device;
    });

    await Future.delayed(const Duration(seconds: 12));
    await bt.cancelDiscovery();
    await sub.cancel();

    if (mounted) setState(() => _devices = discovered.values.toList());
    await _refreshStationAssignments();
    _snack('Found ${discovered.length} device(s)');
  }

  Future<void> _pairDevice(BluetoothDevice device) async {
    _snack('Pairing with ${device.name ?? device.address}...');
    final ok = await bt.bondDevice(device);
    _snack(ok ? 'Paired successfully' : 'Pairing failed');
    await _refreshDevices();
  }

  Future<void> _unpairDevice(BluetoothDevice device) async {
    final ok = await bt.unbondDevice(device);
    _snack(ok ? 'Unpaired' : 'Unpair failed');
    await _refreshDevices();
  }

  Future<void> _assignPrinter(BluetoothDevice device) async {
    final station = await _pickStation(device);
    if (station == null) return;
    await dispatcher.assignStationPrinter(station, device);
    await _refreshStationAssignments();
    _snack('Assigned ${device.name ?? device.address} to $station');
  }

  Future<String?> _pickStation(BluetoothDevice device) {
    return showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text('Assign "${device.name ?? device.address}" to'),
          children: _stations.map((s) {
            return SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Text(s),
            );
          }).toList(),
        );
      },
    );
  }

  Future<void> _testPrint() async {
    final mac = _stationPrinters[_stationKey(_testStation)];
    if (mac == null) {
      _snack('No printer assigned to $_testStation. Assign one first.');
      return;
    }

    const payload = '''
Table: 12
Server: Alex
------------------------------
Grilled Burger x 1
Fries x 1
Cola x 2
------------------------------
*** TEST PRINT ***
''';

    final id = await db.enqueue(_testStation, mac, payload);
    _snack('Test order queued #$id for $_testStation');
    await _refreshQueue();
    await dispatcher.loadBondedPrinters();
    await dispatcher.dispatchNext();
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    bt.cancelDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lastSync = settings.lastSyncAt;
    final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _card('IP Address', _ip),
            const SizedBox(height: 8),
            _card(
              'Server',
              server.isRunning
                  ? 'RUNNING on http://$_ip:${server.port}${HubAuth.enabled ? ' (auth on)' : ''}'
                  : 'STOPPED',
            ),
            const SizedBox(height: 8),
            _card(
              'Bluetooth',
              _btEnabled
                  ? 'ON (paired: ${_devices.where((d) => d.isBonded).length})'
                  : 'OFF',
            ),
            const SizedBox(height: 8),
            _card(
              'Menu cache',
              _productCount > 0
                  ? '$_productCount item(s)${lastSync.isEmpty ? '' : ' · synced ${_shortTime(lastSync)}'}'
                  : 'empty — sync from the portal',
            ),
            if (settings.portalUrl.isEmpty) ...[
              const SizedBox(height: 8),
              _card(
                'Menu source (portal)',
                'Not set — add it in Settings above',
              ),
            ] else if (settings.lastSyncError.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x1AF87171),
                  border: Border.all(color: const Color(0x4DF87171)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Portal unreachable — using the cached menu.\n'
                  '${settings.lastSyncError}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFF87171)),
                ),
              ),
            ],
            const SizedBox(height: 8),
            _card(
              'QR table orders',
              !settings.acceptQrOrders
                  ? 'Off — enable in Settings → Ordering'
                  : settings.qrLastError.isNotEmpty
                      ? 'Error: ${settings.qrLastError}'
                      : settings.qrLastPull.isEmpty
                          ? 'Waiting for the first check…'
                          : 'Checked ${_shortTime(settings.qrLastPull)}'
                              '${OnlineOrderService.instance.importedCount > 0 ? ' · ${OnlineOrderService.instance.importedCount} imported' : ''}',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _toggleServer,
                    child: Text(server.isRunning ? 'Stop Server' : 'Start Server'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _syncing ? null : _syncMenu,
                    icon: _syncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: const Text('Sync menu'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _scanPrinters,
                    child: const Text('Scan Printers'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _refreshStationsManually,
                    icon: const Icon(Icons.sync, size: 18),
                    label: const Text('Refresh stations'),
                  ),
                ),
              ],
            ),
            if (!_stationsSynced) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x1AFBBF24),
                  border: Border.all(color: const Color(0x4DFBBF24)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'No stations from the menu yet — run "Sync menu". '
                  'Showing defaults (Griddle, Kitchen, Wok, Beverage).',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFBBF24)),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    value: _testStation,
                    decoration: const InputDecoration(
                      labelText: 'Station',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _stations
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _testStation = v ?? 'KITCHEN'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: ElevatedButton.icon(
                    onPressed: _testPrint,
                    icon: const Icon(Icons.print),
                    label: const Text('Test Print'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Printers',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(
                  '${_visibleDevices.length} of ${_devices.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Show all Bluetooth devices'),
              subtitle: const Text(
                  'Phone, watches and headsets are hidden by default'),
              value: _showAllDevices,
              onChanged: (value) => setState(() => _showAllDevices = value),
            ),
            if (_devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: Text('No devices. Tap "Scan Printers".')),
              )
            else if (_visibleDevices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: Text(
                      'No printers found — turn on "Show all" to list every device.'),
                ),
              )
            else
              ..._visibleDevices.map((d) {
                return Card(
                  child: ListTile(
                    leading: Icon(
                      d.isBonded ? Icons.bluetooth_connected : Icons.bluetooth,
                      color: d.isBonded ? Colors.green : Colors.grey,
                    ),
                    title: Text(d.name ?? '(unknown)'),
                    subtitle: Text(d.address),
                    trailing: d.isBonded
                        ? IconButton(
                            icon: const Icon(Icons.link_off),
                            onPressed: () => _unpairDevice(d),
                          )
                        : IconButton(
                            icon: const Icon(Icons.link),
                            onPressed: () => _pairDevice(d),
                          ),
                    onTap: () => _assignPrinter(d),
                  ),
                );
              }),
            const SizedBox(height: 16),
            const Text('Station Assignments',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _stations.map((s) {
                final name = _stationPrinterNames[_stationKey(s)];
                final assigned = _stationPrinters.containsKey(_stationKey(s));
                return InputChip(
                  label: Text('$s: ${assigned ? name : '—'}'),
                  avatar: Icon(
                    assigned ? Icons.check_circle : Icons.circle_outlined,
                    size: 18,
                    color: assigned ? Colors.green : Colors.grey,
                  ),
                  onDeleted: assigned
                      ? () async {
                          await dispatcher.clearStationPrinter(s);
                          await _refreshStationAssignments();
                        }
                      : null,
                  deleteIconColor: Colors.red,
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            const Text(
              'The print queue now has its own tab at the bottom of the app, '
              'with retry and clear.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        );

    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('Hub')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: content,
      ),
    );
  }

  Widget _card(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  static String _shortTime(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(parsed.day)}/${two(parsed.month)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }
}

/// Reads the device's Wi-Fi IP from the platform channel.
class _Bridge {
  Future<String> localIp() async {
    try {
      const channel = MethodChannel('com.restaurant.pos/network');
      final ip = await channel.invokeMethod<String>('getLocalIp');
      if (ip != null && ip.isNotEmpty) return ip;
    } catch (_) {}
    return '127.0.0.1';
  }
}
