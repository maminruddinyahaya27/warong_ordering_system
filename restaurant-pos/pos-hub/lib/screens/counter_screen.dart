import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/product.dart';
import '../services/app_events.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/print_queue_db.dart';
import '../widgets/receipt_prompt.dart';
import '../widgets/settle_order.dart';

/// Items pinned to the counter's quick-pick row on first run (filtered to
/// whatever the cached catalog actually contains).
const List<String> kCounterDefaultFavs = [
  'Teh O (Panas)',
  'Teh O (Sejuk)',
  'Roti Kosong',
  'Nasi Lemak Biasa',
  'Kopi O (Panas)',
  'Milo (Panas)',
  'Roti Telur',
  'Mee Goreng Mamak',
];

class _CartLine {
  _CartLine(this.product, this.qty);
  final Product product;
  int qty;

  OrderItem toOrderItem() => OrderItem(
        sku: product.sku,
        name: product.name,
        qty: qty,
        unitPrice: product.price,
        lineTotal: (product.price * qty * 100).roundToDouble() / 100,
        station: product.station,
      );
}

/// Cashier counter: category chips + quick picks + search to build a cart.
/// Open waiter/counter orders are recalled for payment on the Orders tab.
class CounterScreen extends StatefulWidget {
  const CounterScreen({super.key});

  @override
  State<CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends State<CounterScreen> {
  final PrintQueueDb _db = PrintQueueDb.instance;
  final CashierService _cashier = CashierService.instance;
  final SettingsStore _settings = SettingsStore.instance;

  final TextEditingController _table = TextEditingController();
  final TextEditingController _server = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _search = TextEditingController();

  final List<_CartLine> _cart = [];
  List<Product> _products = [];

  String _query = '';
  String _activeGroup = '';
  String _orderType = 'dine_in';
  List<String> _favs = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _loadProducts());
  }

  @override
  void dispose() {
    _table.dispose();
    _server.dispose();
    _note.dispose();
    _search.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ prefs

  Future<void> _loadPrefs() async {
    final settings = await _db.getAllSettings();
    _activeGroup = settings['counter_group'] ?? '';
    final raw = settings['counter_favs'];
    if (raw == null || raw.isEmpty) {
      _favs = kCounterDefaultFavs.toList();
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      _favs = decoded is List
          ? decoded.map((e) => e.toString()).toList()
          : kCounterDefaultFavs.toList();
    } catch (_) {
      _favs = kCounterDefaultFavs.toList();
    }
  }

  Future<void> _persist(String key, String value) => _db.setSetting(key, value);

  void _toggleFav(String name) {
    setState(() {
      if (_favs.contains(name)) {
        _favs.remove(name);
      } else {
        _favs.add(name);
      }
    });
    _persist('counter_favs', jsonEncode(_favs));
  }

  // ------------------------------------------------------------------ data

  Future<void> _loadProducts() async {
    setState(() => _loading = true);
    final products = await _db.getProducts();
    if (!mounted) return;
    setState(() {
      _products = products;
      _loading = false;
      final names = products.map((p) => p.name).toSet();
      _favs = _favs.where(names.contains).toList();
    });
  }

  List<String> get _groups {
    final seen = <String>[];
    for (final product in _products) {
      final name =
          product.category.trim().isEmpty ? 'Others' : product.category.trim();
      if (!seen.contains(name)) seen.add(name);
    }
    return seen;
  }

  String get _activeName => _groups.contains(_activeGroup)
      ? _activeGroup
      : (_groups.isEmpty ? '' : _groups.first);

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

  Color? get _activeColor {
    for (final product in _products) {
      final name =
          product.category.trim().isEmpty ? 'Others' : product.category.trim();
      if (name == _activeName) return _parseColor(product.color);
    }
    return null;
  }

  List<Product> get _visibleItems {
    final query = _query.trim().toLowerCase();
    if (query.isNotEmpty) {
      return _products.where((p) {
        return p.name.toLowerCase().contains(query) ||
            p.sku.toLowerCase().contains(query) ||
            p.category.toLowerCase().contains(query) ||
            p.station.toLowerCase().contains(query);
      }).toList();
    }
    return _products.where((p) {
      final name = p.category.trim().isEmpty ? 'Others' : p.category.trim();
      return name == _activeName;
    }).toList();
  }

  List<Product> _matches(String name) =>
      _products.where((p) => p.name == name).toList();

  // ------------------------------------------------------------------ cart

  List<OrderItem> get _orderItems =>
      _cart.map((line) => line.toOrderItem()).toList();

  OrderTotals get _totals => _cashier.computeTotals(_orderItems);

  void _add(Product product) {
    if (!product.available) {
      _snack('${product.name} is sold out');
      return;
    }
    setState(() {
      final index =
          _cart.indexWhere((line) => line.product.sku == product.sku);
      if (index >= 0) {
        _cart[index].qty += 1;
      } else {
        _cart.add(_CartLine(product, 1));
      }
    });
  }

  void _changeQty(_CartLine line, int delta) {
    setState(() {
      line.qty += delta;
      if (line.qty <= 0) _cart.remove(line);
    });
  }

  void _clearCart() {
    setState(() {
      _cart.clear();
      _note.clear();
      // Ready for the next table.
      _table.clear();
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Dine-in orders must carry a table number before they can be sent.
  bool _tableOk() {
    if (_orderType == 'dine_in' && _table.text.trim().isEmpty) {
      _snack('Enter a table number for dine-in — or switch to Take away');
      return false;
    }
    return true;
  }

  /// Switching to take-away clears the table, since it will not be used.
  void _setOrderType(String type) {
    setState(() {
      _orderType = type;
      if (type == 'take_away') _table.clear();
    });
  }

  Future<void> _sendToKitchen() async {
    if (_cart.isEmpty) {
      _snack('Cart is empty');
      return;
    }
    if (!_tableOk()) return;
    setState(() => _busy = true);
    try {
      final result = await _cashier.createOrAppendOrder(
        channel: 'counter',
        items: _orderItems,
        tableNo: _table.text,
        serverName: _server.text,
        note: _note.text,
        orderType: _orderType,
      );
      _clearCart();
      _snack(result.merged
          ? 'Added to ${result.order.orderNo} (table ${result.order.tableNo} bill)'
          : 'Created ${result.order.orderNo}');
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Creates the order from the cart, then takes payment for it — possibly in
  /// several tenders if the bill is split.
  Future<void> _charge() async {
    if (_cart.isEmpty) {
      _snack('Cart is empty');
      return;
    }
    if (!_tableOk()) return;

    setState(() => _busy = true);
    Order? created;
    try {
      final result = await _cashier.createOrAppendOrder(
        channel: 'counter',
        items: _orderItems,
        tableNo: _table.text,
        serverName: _server.text,
        note: _note.text,
        orderType: _orderType,
      );
      created = result.order;
      _clearCart();
      AppEvents.ordersChanged();
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    final settled = await settleOrder(context, created);
    if (settled == null || !mounted) return;
    if (!settled.isSettled) {
      _snack('${settled.orderNo} part-paid — balance '
          '${_settings.currency}${settled.balance.toStringAsFixed(2)}');
      return;
    }

    final print = await askPrintReceipt(context, settled.orderNo);
    if (print) {
      await _cashier.reprintReceipt(settled);
    }
    final lines = settled.items.fold<int>(0, (sum, item) => sum + item.qty);
    _snack('${settled.orderNo} closed — $lines item(s) on one receipt');
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildOrderFields(),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Expanded(child: _buildSearch()),
              IconButton(
                tooltip: 'Reload menu',
                onPressed: _loading ? null : _loadProducts,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_favs.isNotEmpty) _buildQuickPicks(),
        _buildChips(),
        Expanded(child: _buildProductGrid()),
        _buildCart(),
      ],
    );
  }

  Widget _buildOrderFields() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
            onSelectionChanged: (selection) =>
                _setOrderType(selection.first),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Take-away has no table, so the field is hidden entirely.
              if (_orderType == 'dine_in') ...[
                Expanded(
                  child: TextField(
                    controller: _table,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Table',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextField(
                  controller: _server,
                  decoration: const InputDecoration(
                    labelText: 'Server',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    final searching = _query.trim().isNotEmpty;
    return TextField(
      controller: _search,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 20),
        hintText: 'Search all ${_products.length} items',
        isDense: true,
        border: const OutlineInputBorder(),
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
      onChanged: (value) => setState(() => _query = value),
    );
  }

  Widget _buildQuickPicks() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: SizedBox(
        height: 38,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: _favs.map((name) {
            final match = _matches(name);
            if (match.isEmpty) return const SizedBox.shrink();
            final product = match.first;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: () => _add(product),
                icon:
                    const Icon(Icons.star, size: 14, color: Color(0xFFFFD54F)),
                label: Text(product.name),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildChips() {
    final groups = _groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final active = _activeName;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: groups.map((name) {
            final isActive = name == active;
            Color? color;
            for (final product in _products) {
              final key = product.category.trim().isEmpty
                  ? 'Others'
                  : product.category.trim();
              if (key == name) {
                color = _parseColor(product.color);
                break;
              }
            }
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(name),
                selected: isActive,
                onSelected: (_) {
                  setState(() {
                    _activeGroup = name;
                    _query = '';
                    _search.clear();
                  });
                  _persist('counter_group', name);
                },
                selectedColor: color ?? Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: isActive ? Colors.white : null,
                  fontWeight: FontWeight.w600,
                ),
                side: BorderSide(
                  color: color?.withOpacity(0.6) ?? Colors.grey.shade600,
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildProductGrid() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_products.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No menu cached yet.\nSync the menu in Settings → Hub.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final searching = _query.trim().isNotEmpty;
    final products = _visibleItems;
    if (products.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            searching
                ? 'No items match "${_query.trim()}"'
                : 'No items in $_activeName',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    final activeColor = _activeColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          child: Row(
            children: [
              Text(
                searching ? 'Search results' : _activeName,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Text(
                searching
                    ? '${products.length} match${products.length == 1 ? '' : 'es'}'
                    : '${products.length} item${products.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              childAspectRatio: 1.6,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: products.length,
            itemBuilder: (context, index) {
              final product = products[index];
              final isFav = _favs.contains(product.name);
              final tint = searching ? null : activeColor;
              return Material(
                color: tint != null
                    ? tint.withOpacity(0.18)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: tint != null
                        ? tint.withOpacity(0.5)
                        : Colors.grey.shade700,
                  ),
                ),
                child: InkWell(
                  onTap: product.available ? () => _add(product) : null,
                  borderRadius: BorderRadius.circular(10),
                  child: Opacity(
                    opacity: product.available ? 1 : 0.5,
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
                                  product.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: tint != null ? Colors.white : null,
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      searching
                                          ? product.category
                                          : _settings.currency +
                                              product.price.toStringAsFixed(2),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: tint != null
                                            ? Colors.white70
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                  if (!product.available)
                                    const Text('SOLD OUT',
                                        style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.redAccent)),
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
                              constraints: const BoxConstraints(
                                  minWidth: 32, minHeight: 32),
                              tooltip: isFav
                                  ? 'Remove from quick picks'
                                  : 'Add to quick picks',
                              icon: Icon(
                                isFav ? Icons.star : Icons.star_border,
                                color: isFav
                                    ? const Color(0xFFFFD54F)
                                    : (tint != null ? Colors.white54 : Colors.grey),
                              ),
                              onPressed: () => _toggleFav(product.name),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCart() {
    final totals = _totals;
    return Material(
      elevation: 8,
      child: SizedBox(
        height: 300,
        child: Column(
          children: [
            if (_cart.isNotEmpty)
              Expanded(
                child: ListView.builder(
                  itemCount: _cart.length,
                  itemBuilder: (context, index) {
                    final line = _cart[index];
                    final lineTotal = line.product.price * line.qty;
                    return ListTile(
                      dense: true,
                      title: Text(line.product.name),
                      subtitle: Text(line.product.station),
                      leading: Text('${line.qty}x'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => _changeQty(line, -1),
                          ),
                          Text(
                            '${_settings.currency}${lineTotal.toStringAsFixed(2)}',
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: () => _changeQty(line, 1),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              )
            else
              const Expanded(
                child: Center(
                  child: Text('Tap items to add them to the order'),
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Order note sits with the rest of the bottom section.
                  TextField(
                    controller: _note,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Order note',
                      hintText: 'Allergies, serving notes…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              'Tax ${_settings.currency}${totals.tax.toStringAsFixed(2)}'),
                          Text(
                            'TOTAL ${_settings.currency}${totals.total.toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed:
                            _busy || _cart.isEmpty ? null : _sendToKitchen,
                        child: const Text('Create order'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _busy || _cart.isEmpty ? null : _charge,
                        icon: const Icon(Icons.point_of_sale),
                        label: const Text('Charge'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
