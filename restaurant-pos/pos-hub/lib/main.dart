import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/counter_screen.dart';
import 'screens/history_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/report_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_events.dart';
import 'services/app_settings.dart';
import 'services/bluetooth_printer_manager.dart';
import 'services/cashier_service.dart';
import 'services/hub_auth.dart';
import 'services/menu_sync_service.dart';
import 'services/online_order_service.dart';
import 'services/pos_http_server.dart';
import 'services/print_queue_db.dart';
import 'services/screen_awake.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RestaurantPosApp());
}

class RestaurantPosApp extends StatelessWidget {
  const RestaurantPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Restaurant POS Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B5E20),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF202020),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF202020),
          elevation: 0,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF262626),
        ),
      ),
      home: const HomeShell(),
    );
  }
}

/// Bottom tabs: Order (menu), Counter (open bills) and Queue. History,
/// Reports, the trading day and Settings live in the side menu.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _ready = false;
  String _status = 'Starting…';
  int _openCount = 0;
  int _pendingCount = 0;
  Map<String, dynamic>? _activeDay;
  Map<String, double>? _dayTotals;
  bool _dayBusy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
    AppEvents.ordersRevision.addListener(_refreshCounts);
    AppEvents.queueRevision.addListener(_refreshCounts);
    _tick = Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshCounts();
      _refreshDay();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ScreenAwake.instance.stop();
    _tick?.cancel();
    AppEvents.ordersRevision.removeListener(_refreshCounts);
    AppEvents.queueRevision.removeListener(_refreshCounts);
    super.dispose();
  }

  /// Keep the till's screen awake while it is in use; release it otherwise.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ScreenAwake.instance.start();
    } else {
      ScreenAwake.instance.stop();
    }
  }

  Future<void> _refreshCounts() async {
    final db = PrintQueueDb.instance;
    final open = await db.countOrders(status: 'OPEN');
    final pending = await db.countJobs(status: 'PENDING');
    if (mounted) {
      setState(() {
        _openCount = open;
        _pendingCount = pending;
      });
    }
  }

  Future<void> _refreshDay() async {
    final active = await CashierService.instance.activeDay();
    Map<String, double>? totals;
    if (active != null) {
      totals = await PrintQueueDb.instance.salesBetween(
        (active['started_at'] as int?) ?? 0,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    if (mounted) {
      setState(() {
        _activeDay = active;
        _dayTotals = totals;
      });
    }
  }

  Future<void> _bootstrap() async {
    final settings = SettingsStore.instance;
    try {
      await settings.load();
      HubAuth.configure(user: settings.hubUser, pass: settings.hubPass);
      BluetoothPrinterManager.instance.throttle.cooldownMs =
          settings.printerCooldownMs;

      _setStatus('Starting server…');
      try {
        await PosHttpServer.instance.start();
      } catch (error) {
        _setStatus('Server failed to start: $error');
      }

      await _refreshCounts();
      await _refreshDay();
    } finally {
      if (mounted) setState(() => _ready = true);
      ScreenAwake.instance.start();
    }

    // The portal menu is pulled in the background: a slow or unreachable portal
    // must never block the till from starting or Settings from opening. The
    // counter keeps running on the last cached menu.
    if (settings.portalUrl.isNotEmpty) {
      unawaited(MenuSyncService.instance.syncQuietly());
    }

    // Poll for QR table orders. The service no-ops unless the setting is on.
    OnlineOrderService.instance.start();
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String get _currency => SettingsStore.instance.currency;

  String _stamp(int? millis) {
    if (millis == null || millis <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<void> _startDay() async {
    if (_dayBusy) return;
    setState(() => _dayBusy = true);
    try {
      await CashierService.instance.openDay(by: 'hub');
      await _refreshDay();
      _snack('Day started');
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _dayBusy = false);
    }
  }

  Future<void> _endDay() async {
    if (_dayBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End the trading day?'),
        content: const Text(
            'The day is closed and its takings are summarised. New orders start a fresh day.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End day'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _dayBusy = true);
    try {
      final summary = await CashierService.instance.closeDay(by: 'hub');
      await _refreshDay();
      await _refreshCounts();
      if (mounted) await _showTotals('Day closed', summary);
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _dayBusy = false);
    }
  }

  Future<void> _showDay() {
    final totals = _dayTotals ??
        const <String, double>{'orders': 0, 'sales': 0, 'cash': 0};
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            'Day · opened ${_stamp((_activeDay?['started_at'] as int?) ?? 0)}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _totalRow('Orders', (totals['orders'] ?? 0).toInt().toString()),
            _totalRow('Sales', '$_currency${(totals['sales'] ?? 0).toStringAsFixed(2)}'),
            _totalRow('Cash', '$_currency${(totals['cash'] ?? 0).toStringAsFixed(2)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _endDay();
            },
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('End day'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTotals(String title, Map<String, double> summary) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _totalRow('Orders', summary['orders']!.toInt().toString()),
            _totalRow('Sales', '$_currency${summary['sales']!.toStringAsFixed(2)}'),
            _totalRow('Cash', '$_currency${summary['cash']!.toStringAsFixed(2)}'),
            _totalRow('Card', '$_currency${summary['card']!.toStringAsFixed(2)}'),
            _totalRow(
                'E-wallet', '$_currency${summary['ewallet']!.toStringAsFixed(2)}'),
            _totalRow('Take away', summary['takeaway']!.toInt().toString()),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted) setState(() {});
  }

  void _openScreen(String title, Widget body) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: body,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_status),
            ],
          ),
        ),
      );
    }

    final dayOpen = _activeDay != null;
    final daySales = _dayTotals?['sales'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        // No automatic leading hamburger: the menu button is on the right.
        automaticallyImplyLeading: false,
        title: Text(SettingsStore.instance.restaurantName),
        actions: [
          // The side menu holds the day controls, History, Reports and
          // Settings, so the hamburger is the only header action.
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(context).openDrawer(),
              icon: const Icon(Icons.menu),
            ),
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: const BoxDecoration(color: Color(0xFF262626)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    SettingsStore.instance.restaurantName,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    dayOpen
                        ? 'Day open · $_currency${daySales.toStringAsFixed(2)}'
                        : 'Day not started',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('History'),
              onTap: () {
                Navigator.pop(context);
                _openScreen('History', const HistoryScreen());
              },
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart),
              title: const Text('Reports'),
              onTap: () {
                Navigator.pop(context);
                _openScreen('Reports', const ReportScreen());
              },
            ),
            const Divider(),
            if (dayOpen)
              ListTile(
                leading: const Icon(Icons.stop),
                title: const Text('Day summary & end day'),
                subtitle: Text('$_currency${daySales.toStringAsFixed(2)} so far'),
                onTap: () {
                  Navigator.pop(context);
                  _showDay();
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Start day'),
                onTap: () {
                  Navigator.pop(context);
                  _startDay();
                },
              ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                _openSettings();
              },
            ),
          ],
        ),
      ),
      body: Listener(
        // Any touch while the till is in use keeps the screen awake.
        onPointerDown: (_) => ScreenAwake.instance.noteInteraction(),
        child: IndexedStack(
          index: _index,
          children: const [
            // Main page: the open order list (bills to settle).
            OrdersScreen(),
            // Menu page: build an order from the catalogue.
            CounterScreen(),
            QueueScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          NavigationDestination(
            icon: _openCount > 0
                ? Badge(
                    label: Text('$_openCount'),
                    child: const Icon(Icons.point_of_sale),
                  )
                : const Icon(Icons.point_of_sale),
            label: 'Orders',
          ),
          const NavigationDestination(
            icon: Icon(Icons.list_alt),
            label: 'Menu',
          ),
          NavigationDestination(
            icon: _pendingCount > 0
                ? Badge(
                    label: Text('$_pendingCount'),
                    child: const Icon(Icons.print),
                  )
                : const Icon(Icons.print),
            label: 'Queue',
          ),
        ],
      ),
    );
  }
}
