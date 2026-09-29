import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/product.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/print_queue_db.dart';

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
  _CartLine(this.product, this.qty, [this.note = '']) : id = _nextId();

  static int _sequence = 0;
  static String _nextId() => 'L${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';

  final Product product;

  /// Unique per added line. Bundle lines (an item and the add-ons ordered with
  /// it) are never merged, so each roti keeps its own curry on the ticket.
  final String id;

  int qty;

  /// Per-line note, e.g. the sweetness for a drink.
  String note;

  OrderItem toOrderItem() => OrderItem(
        sku: product.sku,
        name: product.name,
        qty: qty,
        unitPrice: product.price,
        lineTotal: (product.price * qty * 100).roundToDouble() / 100,
        station: product.station,
        note: note,
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

  /// Phone layout: whether the order sheet is open.
  bool _orderOpen = false;

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

  static const List<String> _sugarLevels = [
    'Normal sugar',
    'Less sugar',
    'No sugar',
  ];
  static const List<String> _iceLevels = ['Normal ice', 'Less ice', 'No ice'];

  /// Adds an item. Drinks ask for their levels; items that have add-ons ask for
  /// a quantity first and then the add-ons, and the whole bundle stays on its
  /// own cart line so the ticket keep each add-on with its parent.
  void _add(Product product) {
    if (!product.available) {
      _snack('${product.name} is sold out');
      return;
    }

    if (product.isDrink) {
      // Hot drinks (and items with no level to ask) skip the dialog.
      if (!product.askSugar && !product.askIce) {
        _addWithNote(product, '');
        return;
      }
      _askDrinkOptions(product.name, product.askSugar, product.askIce)
          .then((note) {
        if (!mounted || note == null) return;
        _addWithNote(product, note);
      });
      return;
    }

    final addOns = _addOnProductsFor(product);
    if (addOns.isEmpty) {
      _addWithNote(product, '');
      return;
    }

    _askBundle(product, addOns).then((result) {
      if (!mounted || result == null) return;
      setState(() {
        _cart.add(_CartLine(product, result.parentQty, ''));
        for (final entry in result.addOnQty.entries) {
          _cart.add(_CartLine(entry.key, entry.value, ''));
        }
      });
    });
  }

  /// Add-on items available for [parent] (e.g. the Lauk-pauk curries of a Roti
  /// Canai). Their items print on the parent's station.
  List<Product> _addOnProductsFor(Product parent) => _products
      .where((product) =>
          product.available &&
          product.addOnFor.isNotEmpty &&
          product.addOnFor.split('|').contains(parent.category))
      .toList();

  /// Quantity of the item, then a quantity for each add-on. Returns null when
  /// cancelled.
  Future<({int parentQty, Map<Product, int> addOnQty})?> _askBundle(
    Product parent,
    List<Product> addOns,
  ) {
    var parentQty = 1;
    final chosen = <Product, int>{};
    return showDialog<({int parentQty, Map<Product, int> addOnQty})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Widget stepper(String label, int value, ValueChanged<int> onChanged) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
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
                  const Text('Add on',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: addOns
                          .map(
                            (option) => stepper(
                              '${option.name}  ${_settings.currency}${option.price.toStringAsFixed(2)}',
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
                onPressed: parentQty <= 0
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
                  const Text(
                    'Sugar',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
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
                  const Text(
                    'Ice',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
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

  /// Adds a line. Plain items merge with an identical line; bundle lines (an
  /// item ordered with add-ons) never merge, so each keeps its own add-ons.
  void _addWithNote(Product product, String note, {bool merge = true}) {
    setState(() {
      final index = merge
          ? _cart.indexWhere(
              (line) => line.product.sku == product.sku && line.note == note,
            )
          : -1;
      if (index >= 0) {
        _cart[index].qty += 1;
      } else {
        _cart.add(_CartLine(product, 1, note));
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

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 768;
    return wide ? _wideBody(width) : _phoneBody();
  }

  /// Same split as the waiter app: order pane on the left, menu on the right.
  Widget _wideBody(double width) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: width * 0.34,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: _orderPane(),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _menuPane()),
      ],
    );
  }

  /// Phone layout: full-width menu with a cart bar that opens the order sheet.
  Widget _phoneBody() {
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            // Leave room for the cart bar pinned at the bottom.
            padding: const EdgeInsets.only(bottom: 64),
            child: _menuPane(),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: 0, child: _cartBar()),
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
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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

  Widget _buildOrderFields() {
    return Column(
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
          onSelectionChanged: (selection) => _setOrderType(selection.first),
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

  /// Search, quick picks, category chips and the product grid.
  Widget _menuPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
      ],
    );
  }

  int get _cartQty => _cart.fold(0, (sum, line) => sum + line.qty);

  /// Phone layout: a compact bar that opens the order sheet.
  Widget _cartBar() {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        onTap: () => setState(() => _orderOpen = true),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Badge(
                    isLabelVisible: _cartQty > 0,
                    label: Text('$_cartQty'),
                    child: const Icon(Icons.receipt_long),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _cart.isEmpty
                              ? 'No items'
                              : '$_cartQty item${_cartQty == 1 ? '' : 's'}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'TOTAL ${_settings.currency}${_totals.total.toStringAsFixed(2)}',
                          style:
                              const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    onPressed: () => setState(() => _orderOpen = true),
                    child: const Text('View order'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Order details: type/table/server, lines, note, totals and the actions.
  Widget _orderPane({bool sheet = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              'Order',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Text(
              _cart.isEmpty ? 'No items' : '$_cartQty item(s)',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
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
        _buildOrderFields(),
        const SizedBox(height: 12),
        if (_cart.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                'Tap items to add them to the order',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
          )
        else
          ..._cart.map(_cartLine),
        const SizedBox(height: 10),
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
        const SizedBox(height: 12),
        Row(
          children: [
            Text('Tax ${_settings.currency}${_totals.tax.toStringAsFixed(2)}'),
            const Spacer(),
            Text(
              'TOTAL ${_settings.currency}${_totals.total.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (_busy || _cart.isEmpty)
                ? null
                : () => _runAction(_sendToKitchen, sheet: sheet),
            icon: const Icon(Icons.receipt_long),
            label: const Text('Create order'),
          ),
        ),
      ],
    );
  }

  /// Runs an order action, then closes the phone sheet.
  Future<void> _runAction(Future<void> Function() action,
      {required bool sheet}) async {
    await action();
    if (mounted && sheet) setState(() => _orderOpen = false);
  }

  Widget _cartLine(_CartLine line) {
    final lineTotal = line.product.price * line.qty;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Text(
        '${line.qty}x',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      title: Text(line.product.name),
      subtitle: Text(
        line.note.isEmpty
            ? line.product.station
            : '${line.product.station} · ${line.note}',
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _changeQty(line, -1),
          ),
          Text('${_settings.currency}${lineTotal.toStringAsFixed(2)}'),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _changeQty(line, 1),
          ),
        ],
      ),
    );
  }
}
