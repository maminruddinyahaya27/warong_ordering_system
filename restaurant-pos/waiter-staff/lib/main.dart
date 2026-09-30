import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/sample_menu.dart';
import 'models/menu_item.dart';
import 'models/order_item.dart';
import 'models/order_record.dart';
import 'screens/history_screen.dart';
import 'screens/queue_screen.dart';
import 'services/hub_config.dart';
import 'services/menu_service.dart';
import 'services/order_history.dart';
import 'services/order_sender.dart';
import 'services/order_service.dart';

// Shared dark palette.
const Color kBg = Color(0xFF202020);
const Color kSurface = Color(0xFF2A2A2A);
const Color kSurface2 = Color(0xFF333333);
const Color kLine = Color(0xFF3D3D3D);
const Color kMuted = Color(0xFFA6A6A6);
const Color kWarn = Color(0xFFFBBF24);
const Color kWarnSoft = Color(0x1AFBBF24);
const Color kWarnLine = Color(0x4DFBBF24);
const Color kStar = Color(0xFFFFD54F);

/// Items pinned to the quick-picks row on first run (filtered to whatever the
/// loaded menu actually contains).
const List<String> kDefaultFavourites = [
  'Teh O (Panas)',
  'Teh O (Sejuk)',
  'Roti Kosong',
  'Nasi Lemak Biasa',
  'Kopi O (Panas)',
  'Milo (Panas)',
  'Roti Telur',
  'Mee Goreng Mamak',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WaiterStaffApp());
}

class WaiterStaffApp extends StatelessWidget {
  const WaiterStaffApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Waiter Staff',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: Border(bottom: BorderSide(color: kLine)),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: kLine),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF2E7D32), width: 1.5),
          ),
        ),
      ),
      home: const OrderScreen(),
    );
  }
}

/// A menu group (portal category) with its colour and items.
class _MenuGroup {
  final String name;
  final Color? color;
  final List<MenuItem> items;
  const _MenuGroup(this.name, this.color, this.items);
}

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key});

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  static const List<String> _ungroupedNames = [
    'ungrouped',
    'menu',
    'others',
    'other',
    '',
  ];

  final TextEditingController _table = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _search = TextEditingController();

  String _waiter = '';
  String _query = '';
  String _activeGroup = '';
  String _orderType = 'dine_in';
  List<String> _favs = [];
  bool _orderOpen = false;

  final List<OrderItem> _items = [];
  List<MenuItem> _menu = [];
  bool _loadingMenu = false;
  bool _sending = false;
  bool _hostOnline = false;
  bool _demoMenu = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _table.dispose();
    _note.dispose();
    _search.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- connection

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    HubConfig.hostIp = prefs.getString('host_ip') ?? '';
    HubConfig.hostPort = prefs.getInt('host_port') ?? 8080;
    HubConfig.user = prefs.getString('hub_user') ?? '';
    HubConfig.pass = prefs.getString('hub_pass') ?? '';
    HubConfig.menuUrl = prefs.getString('menu_url') ?? '';
    _waiter = prefs.getString('waiter_name') ?? '';
    _activeGroup = prefs.getString('waiter_group') ?? '';
    _favs = _decodeFavs(prefs.getString('waiter_favs'));

    if (HubConfig.hasHost) {
      _checkHost();
    } else {
      await _promptConfig();
    }

    if (_waiter.isEmpty && mounted) {
      await _promptWaiter();
    }

    // Always attempt the menu; a failure falls back to the demo menu.
    await _loadMenu();
  }

  List<String> _decodeFavs(String? raw) {
    if (raw == null || raw.isEmpty) return kDefaultFavourites.toList();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return kDefaultFavourites.toList();
  }

  Future<void> _persist(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is List<String>) {
      await prefs.setString(key, jsonEncode(value));
    }
  }

  /// The waiter name is required before ordering; it is stamped on every
  /// order and kitchen ticket.
  Future<void> _promptWaiter() async {
    final controller = TextEditingController(text: _waiter);
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: _waiter.isNotEmpty,
      builder: (context) => AlertDialog(
        title: const Text('Who is serving?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The waiter name is stamped on every order and kitchen ticket.',
              style: TextStyle(fontSize: 13, color: kMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Waiter name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => Navigator.pop(context, value.trim()),
            ),
          ],
        ),
        actions: [
          if (_waiter.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    controller.dispose();
    if (name == null) return;
    if (name.isEmpty) {
      _snack('Enter the waiter name');
      return;
    }
    setState(() => _waiter = name);
    await _persist('waiter_name', name);
  }

  Future<void> _promptConfig() async {
    final hostController = TextEditingController(text: HubConfig.hostIp);
    final portController =
        TextEditingController(text: HubConfig.hostPort.toString());
    final userController = TextEditingController(text: HubConfig.user);
    final passController = TextEditingController(text: HubConfig.pass);
    final menuController = TextEditingController(text: HubConfig.menuUrl);

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to POS Hub'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Host IP',
                  hintText: 'e.g. 192.168.1.50',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: '8080',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: userController,
                decoration: const InputDecoration(
                  labelText: 'Hub user (if auth enabled)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: passController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Hub password',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: menuController,
                decoration: const InputDecoration(
                  labelText: 'Menu URL (optional)',
                  hintText: 'Defaults to the hub /menu',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'host_ip': hostController.text.trim(),
              'host_port': portController.text.trim(),
              'hub_user': userController.text.trim(),
              'hub_pass': passController.text,
              'menu_url': menuController.text.trim(),
            }),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    hostController.dispose();
    portController.dispose();
    userController.dispose();
    passController.dispose();
    menuController.dispose();

    if (result == null) return;

    HubConfig.hostIp = result['host_ip'] ?? '';
    HubConfig.hostPort = int.tryParse(result['host_port'] ?? '') ?? 8080;
    HubConfig.user = result['hub_user'] ?? '';
    HubConfig.pass = result['hub_pass'] ?? '';
    HubConfig.menuUrl = result['menu_url'] ?? '';

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('host_ip', HubConfig.hostIp);
    await prefs.setInt('host_port', HubConfig.hostPort);
    await prefs.setString('hub_user', HubConfig.user);
    await prefs.setString('hub_pass', HubConfig.pass);
    await prefs.setString('menu_url', HubConfig.menuUrl);

    if (HubConfig.hasHost) {
      _checkHost();
      _loadMenu();
    }
  }

  Future<void> _loadMenu() async {
    setState(() => _loadingMenu = true);
    try {
      final items = await MenuService.fetchMenu();
      if (items.isEmpty) throw Exception('menu feed is empty');
      if (mounted) {
        setState(() {
          _menu = items;
          _demoMenu = false;
          _hostOnline = true;
          _syncFavs();
        });
      }
    } catch (error) {
      // Offline fallback: keep the waiter usable with a demo menu.
      if (!mounted) return;
      setState(() {
        _menu = kSampleMenu;
        _demoMenu = true;
        _hostOnline = false;
        _syncFavs();
      });
      _snack('Host unavailable — using demo menu');
    } finally {
      if (mounted) setState(() => _loadingMenu = false);
    }
  }

  /// Drop favourites that are not on the current menu.
  void _syncFavs() {
    final names = _menu.map((item) => item.name).toSet();
    _favs = _favs.where(names.contains).toList();
  }

  void _toggleFav(String name) {
    setState(() {
      if (_favs.contains(name)) {
        _favs.remove(name);
      } else {
        _favs.add(name);
      }
    });
    _persist('waiter_favs', _favs);
  }

  Future<void> _checkHost() async {
    final ok = await OrderService.checkHealth();
    if (mounted) setState(() => _hostOnline = ok);
  }

  // -------------------------------------------------------------- order cart

  /// Switching to take-away clears the table, since it will not be used.
  void _setOrderType(String type) {
    setState(() {
      _orderType = type;
      if (type == 'take_away') _table.clear();
    });
  }

  static const List<String> _sugarLevels = [
    'Normal sugar',
    'Less sugar',
    'No sugar',
  ];
  static const List<String> _iceLevels = ['Normal ice', 'Less ice', 'No ice'];

  /// Asks for the levels the item wants (sugar and/or ice). Returns the note to
  /// print — always set, e.g. "Normal sugar, Less ice" — or null if cancelled.
  Future<String?> _askDrinkOptions(
    String itemName,
    bool askSugar,
    bool askIce,
  ) {
    var sugar = _sugarLevels.first;
    var ice = _iceLevels.first;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(itemName),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (askSugar) ...[
                  const Text('Sugar',
                      style: TextStyle(fontSize: 12, color: kMuted)),
                  Wrap(
                    spacing: 6,
                    children: _sugarLevels
                        .map(
                          (level) => ChoiceChip(
                            label: Text(level),
                            selected: sugar == level,
                            onSelected: (_) =>
                                setDialogState(() => sugar = level),
                          ),
                        )
                        .toList(),
                  ),
                ],
                if (askSugar && askIce) const SizedBox(height: 10),
                if (askIce) ...[
                  const Text('Ice',
                      style: TextStyle(fontSize: 12, color: kMuted)),
                  Wrap(
                    spacing: 6,
                    children: _iceLevels
                        .map(
                          (level) => ChoiceChip(
                            label: Text(level),
                            selected: ice == level,
                            onSelected: (_) =>
                                setDialogState(() => ice = level),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                [
                  if (askSugar) sugar,
                  if (askIce) ice,
                ].join(', '),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  /// Adds an item. Drinks ask for their levels; items that have add-ons ask for
  /// a quantity first and then the add-ons, and the bundle stays on its own
  /// line so each add-on prints under the item it came with.
  void _addItem(MenuItem item) {
    if (!item.available) {
      _snack('${item.name} is sold out');
      return;
    }
    if (item.isDrink) {
      // Hot drinks (and items with no level to ask) skip the dialog.
      if (!item.askSugar && !item.askIce) {
        _addItemWithNote(item, '');
        return;
      }
      _askDrinkOptions(item.name, item.askSugar, item.askIce).then((note) {
        if (!mounted || note == null) return;
        _addItemWithNote(item, note);
      });
      return;
    }

    final addOns = _addOnItemsFor(item);
    if (addOns.isEmpty) {
      // A required add-on with nothing to choose from cannot be ordered.
      if (item.requireAddOn) {
        _snack('${item.name} needs an add-on, but none are configured');
        return;
      }
      _addItemWithNote(item, '');
      return;
    }

    _askBundle(item, addOns).then((result) {
      if (!mounted || result == null) return;
      setState(() {
        _addItemWithNote(item, '', merge: false, qty: result.parentQty);
        for (final entry in result.addOnQty.entries) {
          _addItemWithNote(entry.key, '', merge: false, qty: entry.value);
        }
      });
    });
  }

  /// Add-on items available for [parent] (e.g. the Lauk-pauk curries of a Roti
  /// Canai). They print on the parent's station.
  List<MenuItem> _addOnItemsFor(MenuItem parent) => _menu
      .where((item) =>
          item.available &&
          item.addOnFor.isNotEmpty &&
          item.addOnFor.split('|').contains(parent.category))
      .toList();

  /// Quantity of the item, then a quantity for each add-on. Null if cancelled.
  Future<({int parentQty, Map<MenuItem, int> addOnQty})?> _askBundle(
    MenuItem parent,
    List<MenuItem> addOns,
  ) {
    var parentQty = 1;
    final chosen = <MenuItem, int>{};
    return showDialog<({int parentQty, Map<MenuItem, int> addOnQty})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Widget stepper(String label, int value, ValueChanged<int> onChanged) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: value <= 0 ? null : () => onChanged(value - 1),
                  ),
                  Text('$value',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => onChanged(value + 1),
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            title: Text(parent.name),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  stepper(
                    'Quantity',
                    parentQty,
                    (value) => setDialogState(() => parentQty = value),
                  ),
                  const Divider(),
                  Text(
                    parent.requireAddOn
                        ? 'Add on — pick at least one to continue'
                        : 'Add on',
                    style: TextStyle(
                      fontSize: 12,
                      color: parent.requireAddOn ? kWarn : kMuted,
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: addOns
                          .map(
                            (option) => stepper(
                              option.name,
                              chosen[option] ?? 0,
                              (value) => setDialogState(() {
                                if (value <= 0) {
                                  chosen.remove(option);
                                } else {
                                  chosen[option] = value;
                                }
                              }),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: parentQty <= 0 ||
                        (parent.requireAddOn &&
                            chosen.values.every((qty) => qty <= 0))
                    ? null
                    : () => Navigator.of(dialogContext)
                        .pop((parentQty: parentQty, addOnQty: Map.of(chosen))),
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _addItemWithNote(
    MenuItem item,
    String note, {
    bool merge = true,
    int qty = 1,
  }) {
    setState(() {
      final index = merge
          ? _items.indexWhere((i) => i.name == item.name && i.note == note)
          : -1;
      if (index >= 0) {
        _items[index] = OrderItem(
          id: _items[index].id,
          name: item.name,
          qty: _items[index].qty + qty,
          price: item.price,
          station: item.station,
          note: note,
        );
      } else {
        _items.add(OrderItem(
          name: item.name,
          qty: qty,
          price: item.price,
          station: item.station,
          note: note,
        ));
      }
    });
  }

  void _changeQty(OrderItem item, int delta) {
    setState(() {
      final index = _items.indexWhere((i) => i.id == item.id);
      if (index < 0) return;
      final next = _items[index].qty + delta;
      if (next <= 0) {
        _items.removeAt(index);
      } else {
        _items[index] = OrderItem(
          id: _items[index].id,
          name: _items[index].name,
          qty: next,
          price: _items[index].price,
          station: _items[index].station,
          note: _items[index].note,
        );
      }
    });
  }

  void _removeItem(OrderItem item) {
    setState(() => _items.removeWhere((i) => i.id == item.id));
  }

  void _clearOrder() {
    setState(() {
      _items.clear();
      _note.clear();
    });
  }

  int get _cartQty => _items.fold(0, (sum, item) => sum + item.qty);

  Future<void> _submitOrder() async {
    if (!HubConfig.hasHost) {
      await _promptConfig();
      if (!HubConfig.hasHost) return;
    }
    if (_waiter.isEmpty) {
      await _promptWaiter();
      if (_waiter.isEmpty) return;
    }
    if (_items.isEmpty) {
      _snack('Add at least one item');
      return;
    }
    if (_orderType == 'dine_in' && _table.text.trim().isEmpty) {
      _snack('Enter a table number for dine-in — or switch to Take away');
      return;
    }

    setState(() => _sending = true);
    final table = _table.text.trim();
    final note = _note.text.trim();
    final items = _items
        .map((i) => {
              'qty': i.qty,
              'name': i.name,
              'price': i.price,
              'station': i.station,
              'note': i.note,
            })
        .toList();

    // Queued first: if the send fails, the order waits in the Queue page and
    // can be sent again without creating a duplicate.
    final pending = OrderRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      table: table,
      server: _waiter,
      orderType: _orderType,
      note: note,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: 'pending',
      items: items,
    );
    await OrderHistory.add(pending);

    try {
      final outcome = await OrderSender.send(pending);
      if (outcome.duplicate) {
        _snack('Already sent ${outcome.orderNo}');
      } else if (outcome.merged) {
        _snack('Added to ${outcome.orderNo}${table.isEmpty ? '' : ' (table $table)'}');
      } else {
        _snack('Sent ${outcome.orderNo}');
      }
      setState(() {
        _items.clear();
        _note.clear();
        // Ready for the next table.
        _table.clear();
        _orderOpen = false;
      });
    } catch (e) {
      // Stays queued with the reason, ready to retry.
      await OrderHistory.update(pending.copyWith(
        error: e.toString().replaceFirst('Exception: ', ''),
      ));
      _snack('Failed to send — kept in the queue');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // --------------------------------------------------------------- grouping

  bool _isUngrouped(String name) =>
      _ungroupedNames.contains(name.trim().toLowerCase());

  Color? _parseColor(String hex) {
    var value = hex.replaceAll('#', '').trim();
    if (value.length == 3) {
      value =
          '${value[0]}${value[0]}${value[1]}${value[1]}${value[2]}${value[2]}';
    }
    if (value.length != 6) return null;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return null;
    return Color(0xFF000000 | parsed);
  }

  List<_MenuGroup> get _groups {
    final query = _query.trim().toLowerCase();
    final map = <String, List<MenuItem>>{};
    final colors = <String, Color?>{};
    final order = <String>[];

    for (final item in _menu) {
      if (query.isNotEmpty &&
          !item.name.toLowerCase().contains(query) &&
          !item.station.toLowerCase().contains(query)) {
        continue;
      }
      final key = item.category.trim().isEmpty ? 'Others' : item.category.trim();
      if (!map.containsKey(key)) {
        map[key] = [];
        order.add(key);
      }
      map[key]!.add(item);
      colors.putIfAbsent(key, () => _parseColor(item.color));
    }

    // Keep the portal's group order (first appearance); ungrouped last.
    final names = [
      ...order.where((name) => !_isUngrouped(name)),
      ...order.where(_isUngrouped),
    ];
    return names
        .map((name) => _MenuGroup(name, colors[name], map[name]!))
        .toList();
  }

  List<({MenuItem item, String group})> _searchResults(List<_MenuGroup> groups) {
    final results = <({MenuItem item, String group})>[];
    for (final group in groups) {
      for (final item in group.items) {
        results.add((item: item, group: group.name));
      }
    }
    return results;
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  // ------------------------------------------------------------------ build

  int _columnsFor(double width) {
    if (width >= 1200) return 4;
    if (width >= 900) return 3;
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 768;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Waiter Staff'),
        actions: [
          IconButton(
            tooltip: 'Queued orders',
            icon: const Icon(Icons.outbox),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const QueueScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Order history',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ),
          ),
          TextButton.icon(
            onPressed: _promptWaiter,
            icon: const Icon(Icons.person, size: 18),
            label: Text(_waiter.isEmpty ? 'Set waiter' : _waiter),
          ),
          IconButton(
            icon: Icon(_hostOnline ? Icons.cloud_done : Icons.cloud_off,
                color: _hostOnline ? Colors.green : Colors.red),
            onPressed: () async {
              await _checkHost();
              _snack(_hostOnline ? 'Host online' : 'Host offline');
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _promptConfig,
          ),
        ],
      ),
      body: wide ? _wideBody(width) : _phoneBody(),
      bottomNavigationBar: wide ? null : _cartBar(),
    );
  }

  Widget _wideBody(double width) {
    // Tablet / iPad: 30% order (left), 70% menu (right).
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: width * 0.30,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _orderPane(),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _menuPane(width * 0.70),
          ),
        ),
      ],
    );
  }

  Widget _phoneBody() {
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: _menuPane(MediaQuery.of(context).size.width),
          ),
        ),
        if (_orderOpen) ...[
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _orderOpen = false),
              child: const ColoredBox(color: Colors.black54),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.8,
              ),
              child: Material(
                color: kSurface,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  side: BorderSide(color: kLine),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: _orderPane(sheet: true),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _cartBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: const BoxDecoration(
          color: kSurface,
          border: Border(top: BorderSide(color: kLine)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_cartQty item${_cartQty == 1 ? '' : 's'}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  Text(
                    _items.isEmpty
                        ? 'Tap a category or quick pick'
                        : 'Ready to send',
                    style: const TextStyle(fontSize: 11, color: kMuted),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              onPressed: () => setState(() => _orderOpen = !_orderOpen),
              child: Text(_orderOpen ? 'Hide order' : 'View order'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _sending || _items.isEmpty ? null : _submitOrder,
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuPane(double availableWidth) {
    final groups = _groups;
    final searching = _query.trim().isNotEmpty;
    final results = searching ? _searchResults(groups) : const [];
    final activeName = searching
        ? 'Search results'
        : (groups.any((g) => g.name == _activeGroup)
            ? _activeGroup
            : (groups.isEmpty ? '' : groups.first.name));
    final active = groups.where((g) => g.name == activeName).toList();

    final visibleItems = searching
        ? results.map((r) => r.item).toList()
        : (active.isEmpty ? <MenuItem>[] : active.first.items);
    final activeColor = active.isEmpty ? null : active.first.color;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchField(),
        if (!searching) ...[
          if (_favs.isNotEmpty) _quickPicks(),
          _chips(groups),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                searching
                    ? 'Search results'
                    : (activeName.isEmpty ? 'Menu' : activeName),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              searching
                  ? '${results.length} match${results.length == 1 ? '' : 'es'}'
                  : '${visibleItems.length} item${visibleItems.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 12, color: kMuted),
            ),
            IconButton(
              icon: _loadingMenu
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _loadingMenu ? null : _loadMenu,
            ),
          ],
        ),
        if (_demoMenu) ...[
          const SizedBox(height: 4),
          _demoBanner(),
        ],
        const SizedBox(height: 8),
        if (_loadingMenu && _menu.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (visibleItems.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                searching
                    ? 'No items match "${_query.trim()}"'
                    : 'No items in this group',
                style: const TextStyle(color: kMuted),
              ),
            ),
          )
        else
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: _columnsFor(availableWidth),
            childAspectRatio: 2.0,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            children: searching
                ? results
                    .map((r) => _tile(r.item, groupLabel: r.group))
                    .toList()
                : visibleItems
                    .map((item) =>
                        _tile(item, color: activeColor, coloured: true))
                    .toList(),
          ),
      ],
    );
  }

  Widget _searchField() {
    final searching = _query.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: _search,
        onChanged: (value) => setState(() => _query = value),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search all ${_menu.length} items...',
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: searching
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                )
              : null,
        ),
      ),
    );
  }

  Widget _quickPicks() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'QUICK PICKS',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: .8,
              fontWeight: FontWeight.bold,
              color: kMuted,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _favs.map((name) {
                final match =
                    _menu.where((item) => item.name == name).toList();
                if (match.isEmpty) return const SizedBox.shrink();
                final item = match.first;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton.icon(
                    onPressed: () => _addItem(item),
                    icon: const Icon(Icons.star, size: 14, color: kStar),
                    label: Text(item.name),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: kLine),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chips(List<_MenuGroup> groups) {
    if (groups.isEmpty) return const SizedBox.shrink();
    final activeName = groups.any((g) => g.name == _activeGroup)
        ? _activeGroup
        : groups.first.name;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: groups.map((group) {
            final isActive = group.name == activeName;
            final color = group.color;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: isActive
                    ? (color ?? const Color(0xFF2E7D32))
                    : kSurface2,
                shape: StadiumBorder(
                  side: BorderSide(
                    color: isActive
                        ? (color ?? const Color(0xFF2E7D32))
                        : (color?.withOpacity(0.55) ?? kLine),
                  ),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () {
                    setState(() => _activeGroup = group.name);
                    _persist('waiter_group', group.name);
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: Row(
                      children: [
                        Text(
                          group.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isActive ? Colors.white : (color ?? kMuted),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '${group.items.length}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isActive
                                ? Colors.white70
                                : kMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _tile(
    MenuItem item, {
    Color? color,
    bool coloured = false,
    String? groupLabel,
  }) {
    final radius = BorderRadius.circular(10);
    final tint = coloured ? color : null;
    final isFav = _favs.contains(item.name);

    return Material(
      color: tint != null ? tint.withOpacity(0.18) : kSurface2,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: tint != null ? tint.withOpacity(0.5) : kLine,
        ),
      ),
      child: InkWell(
        onTap: item.available ? () => _addItem(item) : null,
        borderRadius: radius,
        child: Opacity(
          opacity: item.available ? 1 : 0.5,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 20),
                      child: Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: tint != null ? Colors.white : null,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            groupLabel ?? item.station,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: tint != null ? Colors.white70 : kMuted,
                            ),
                          ),
                        ),
                        if (!item.available)
                          Text(
                            'SOLD OUT',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: tint != null ? kStar : const Color(0xFFF87171),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: -6,
                  right: -6,
                  child: IconButton(
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    tooltip: isFav
                        ? 'Remove from quick picks'
                        : 'Add to quick picks',
                    icon: Icon(
                      isFav ? Icons.star : Icons.star_border,
                      color: isFav
                          ? kStar
                          : (tint != null ? Colors.white54 : kMuted),
                    ),
                    onPressed: () => _toggleFav(item.name),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _orderPane({bool sheet = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('Order',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text(
              _items.isEmpty ? 'No items' : '$_cartQty item(s)',
              style: const TextStyle(fontSize: 12, color: kMuted),
            ),
            const Spacer(),
            if (sheet)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => setState(() => _orderOpen = false),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'dine_in',
              label: Text('Dine-in'),
              icon: Icon(Icons.table_restaurant, size: 16),
            ),
            ButtonSegment(
              value: 'take_away',
              label: Text('Take away'),
              icon: Icon(Icons.shopping_bag_outlined, size: 16),
            ),
          ],
          selected: {_orderType},
          onSelectionChanged: (selection) => _setOrderType(selection.first),
        ),
        // Take-away has no table, so the field is hidden entirely.
        if (_orderType == 'dine_in') ...[
          const SizedBox(height: 8),
          TextField(
            controller: _table,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Table',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (_items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text('Tap items to add them to the order',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kMuted, fontSize: 13)),
            ),
          )
        else
          ..._items.map(_orderLine),
        const SizedBox(height: 8),
        TextField(
          controller: _note,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Note',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _sending ? null : _submitOrder,
          icon: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send),
          label: Text(_sending ? 'Sending…' : 'Send Order'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _items.isEmpty ? null : _clearOrder,
          child: const Text('Clear order'),
        ),
      ],
    );
  }

  Widget _orderLine(OrderItem item) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(item.name),
      // The station is an internal detail; only the note (e.g. drink options)
      // is worth showing under an order line.
      subtitle: item.note.isEmpty
          ? null
          : Text(item.note,
              style: const TextStyle(fontSize: 11, color: kMuted)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _changeQty(item, -1),
          ),
          Text('${item.qty}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _changeQty(item, 1),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _removeItem(item),
          ),
        ],
      ),
    );
  }

  Widget _demoBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: kWarnSoft,
        border: Border.all(color: kWarnLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off, size: 18, color: kWarn),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Offline — using the demo menu. Check the hub settings to reconnect.',
              style: TextStyle(fontSize: 12, color: kWarn),
            ),
          ),
          TextButton(
            onPressed: _promptConfig,
            child: const Text(
              'Settings',
              style: TextStyle(color: kWarn, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
