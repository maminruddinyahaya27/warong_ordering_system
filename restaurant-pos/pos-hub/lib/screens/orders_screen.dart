import 'dart:async';

import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/product.dart';
import '../services/app_events.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/print_queue_db.dart';
import '../widgets/receipt_prompt.dart';
import '../widgets/settle_order.dart';

/// Open orders list — the counter's main screen. Tapping a row opens the order
/// for amending; Close settles it.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key, this.onNewOrder});

  /// Switches to the Order tab (the menu) to start a new order.
  final VoidCallback? onNewOrder;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final PrintQueueDb _db = PrintQueueDb.instance;
  final CashierService _cashier = CashierService.instance;
  final SettingsStore _settings = SettingsStore.instance;

  List<Order> _orders = [];
  bool _loading = true;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load();
    AppEvents.ordersRevision.addListener(_load);
    // Orders can arrive from waiter devices at any time, so keep the list
    // fresh even if an event is missed.
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    AppEvents.ordersRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final orders = await _db.getOrders(status: 'OPEN', limit: 200);
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _loading = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String get _money => _settings.currency;

  Future<void> _pay(Order order) async {
    final settled = await settleOrder(context, order);
    if (settled == null) return;
    AppEvents.ordersChanged();
    if (!mounted) return;
    if (!settled.isSettled) {
      _snack('${settled.orderNo} part-paid — balance '
          '$_money${settled.balance.toStringAsFixed(2)}');
      return;
    }
    final print = await askPrintReceipt(context, settled.orderNo);
    if (print) {
      await _cashier.reprintReceipt(settled);
    }
    _snack('${settled.orderNo} closed');
  }

  Future<void> _void(Order order) async {
    final confirmed = await _confirm(
      title: 'Void ${order.orderNo}?',
      message: 'This cannot be undone.',
      confirmLabel: 'Void',
    );
    if (confirmed != true) return;
    try {
      await _cashier.voidOrder(order.id!);
      _snack('${order.orderNo} voided');
      AppEvents.ordersChanged();
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _reprintReceipt(Order order) async {
    await _cashier.reprintReceipt(order);
    _snack('Receipt queued for ${order.orderNo}');
  }

  Future<void> _resendTickets(Order order) async {
    await _cashier.sendStationTickets(order);
    _snack('Kitchen tickets queued for ${order.orderNo}');
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  void _openOrder(Order order) {
    var current = order;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final editable = current.status == 'OPEN';

            Future<void> run(Future<Order> Function() action,
                String Function(Order) message) async {
              try {
                final updated = await action();
                setSheetState(() => current = updated);
                AppEvents.ordersChanged();
                _snack(message(updated));
              } catch (error) {
                _snack(error.toString().replaceFirst('Exception: ', ''));
              }
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.72,
              maxChildSize: 0.95,
              builder: (context, controller) {
                return ListView(
                  controller: controller,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            current.orderType == 'take_away'
                                ? 'Take Away - ${current.orderNo}'
                                : current.orderNo,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _statusChip(current.status),
                        const Spacer(),
                        // Take-away is already in the title.
                        if (current.orderType != 'take_away') ...[
                          const Chip(
                            label: Text('Dine-in'),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Chip(
                          label: Text(current.channel),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (current.tableNo.isNotEmpty)
                          'Table ${current.tableNo}',
                        if (current.serverName.isNotEmpty)
                          'Server ${current.serverName}',
                        '${current.items.fold<int>(0, (sum, item) => sum + item.qty)} item(s)',
                      ].join(' · '),
                      style: const TextStyle(color: Colors.grey),
                    ),
                    if (current.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Note: ${current.note}'),
                    ],
                    if (editable) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Adjust quantities, remove a line, or add items — totals recompute automatically.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                    const Divider(height: 24),
                    ...current.items.map((item) => _orderLine(
                          item,
                          editable: editable,
                          onDecrease: () => run(
                            () => _cashier.setOrderItemQty(
                                current.id!, item.id!, item.qty - 1),
                            (updated) => '${item.name} × ${item.qty - 1}',
                          ),
                          onIncrease: () => run(
                            () => _cashier.setOrderItemQty(
                                current.id!, item.id!, item.qty + 1),
                            (updated) => '${item.name} × ${item.qty + 1}',
                          ),
                          onRemove: () async {
                            final ok = await _confirm(
                              title: 'Remove ${item.name}?',
                              message: 'The line is removed from this order.',
                              confirmLabel: 'Remove',
                            );
                            if (ok != true) return;
                            await run(
                              () => _cashier.setOrderItemQty(
                                  current.id!, item.id!, 0),
                              (updated) => '${item.name} removed',
                            );
                          },
                        )),
                    const Divider(height: 24),
                    _totalRow('Subtotal', current.subtotal),
                    _totalRow('Tax', current.tax),
                    if (current.discount > 0)
                      _totalRow('Discount', -current.discount),
                    _totalRow('Total', current.total, bold: true),
                    if (current.paid > 0) ...[
                      _totalRow('Paid', current.paid),
                      if (!current.isSettled)
                        _totalRow('Balance', current.balance, bold: true),
                    ],
                    if (editable) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _showAddItems(current, (updated) {
                          setSheetState(() => current = updated);
                          AppEvents.ordersChanged();
                        }),
                        icon: const Icon(Icons.add),
                        label: const Text('Add items to this order'),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (editable) ...[
                          FilledButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              _pay(current);
                            },
                            icon: const Icon(Icons.point_of_sale),
                            label: const Text('Charge'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              _void(current);
                            },
                            icon: const Icon(Icons.cancel_outlined),
                            label: const Text('Void'),
                          ),
                        ],
                        OutlinedButton.icon(
                          onPressed: () => _reprintReceipt(current),
                          icon: const Icon(Icons.receipt_long),
                          label: const Text('Receipt'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _resendTickets(current),
                          icon: const Icon(Icons.print),
                          label: const Text('Tickets'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showAddItems(
    Order order,
    void Function(Order) onUpdated,
  ) async {
    final products = await _db.getProducts(availableOnly: true);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, controller) => _AddItemsSheet(
          products: products,
          currency: _settings.currency,
          scrollController: controller,
          onAdd: (product) async {
            final updated = await _cashier.addOrderItems(order.id!, [
              OrderItem(
                sku: product.sku,
                name: product.name,
                qty: 1,
                unitPrice: product.price,
                lineTotal: product.price,
                station: product.station,
              ),
            ]);
            onUpdated(updated);
            _snack('${product.name} added to ${updated.orderNo}');
          },
          onError: (message) => _snack(message),
        ),
      ),
    );
  }

  Widget _orderLine(
    OrderItem item, {
    required bool editable,
    required VoidCallback onDecrease,
    required VoidCallback onIncrease,
    required VoidCallback onRemove,
  }) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(item.name),
      subtitle: Text(item.station),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editable)
            IconButton(
              tooltip: 'Reduce',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: onDecrease,
            )
          else
            Text('${item.qty}x'),
          if (editable)
            Text('${item.qty}',
                style: const TextStyle(fontWeight: FontWeight.bold))
          else
            const SizedBox.shrink(),
          if (editable)
            IconButton(
              tooltip: 'Add one',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: onIncrease,
            ),
          const SizedBox(width: 8),
          Text('$_money${item.lineTotal.toStringAsFixed(2)}'),
          if (editable)
            IconButton(
              tooltip: 'Remove line',
              icon: const Icon(Icons.delete_outline),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, double value, {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label, style: style),
          const Spacer(),
          Text('$_money${value.toStringAsFixed(2)}', style: style),
        ],
      ),
    );
  }

  Widget _statusChip(String status) {
    final color = switch (status) {
      'PAID' => Colors.green,
      'VOID' => Colors.red,
      _ => Colors.orange,
    };
    return Chip(
      label: Text(status),
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.bold),
      side: BorderSide(color: color.withOpacity(0.5)),
      backgroundColor: color.withOpacity(0.08),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text(
                  'Open orders (${_orders.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const Spacer(),
                if (widget.onNewOrder != null)
                  FilledButton.icon(
                    onPressed: widget.onNewOrder,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New order'),
                  ),
              ],
            ),
          ),
          if (_orders.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: Text('No open orders')),
            )
          else
            ..._orders.map((order) => Card(
                  margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      // Identify the bill by its table, not the order number.
                      child: Text(order.tableNo.isNotEmpty
                          ? order.tableNo
                          : 'TA'),
                    ),
                    title: Text(
                      order.orderType == 'take_away'
                          ? 'Take Away - ${order.orderNo}'
                          : order.orderNo,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text([
                      if (order.tableNo.isNotEmpty) 'Table ${order.tableNo}',
                      if (order.serverName.isNotEmpty) order.serverName,
                      order.channel,
                      '${order.items.fold<int>(0, (sum, item) => sum + item.qty)} item(s)',
                    ].join(' · ')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$_money${order.total.toStringAsFixed(2)}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            if (order.paid > 0 && !order.isSettled)
                              Text(
                                'paid $_money${order.paid.toStringAsFixed(2)}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.orange),
                              ),
                          ],
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => _pay(order),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                    onTap: () => _openOrder(order),
                  ),
                )),
        ],
      ),
    );
  }
}

/// Searchable catalogue picker used to append items to an open order.
class _AddItemsSheet extends StatefulWidget {
  const _AddItemsSheet({
    required this.products,
    required this.currency,
    required this.scrollController,
    required this.onAdd,
    required this.onError,
  });

  final List<Product> products;
  final String currency;
  final ScrollController scrollController;
  final Future<void> Function(Product product) onAdd;
  final void Function(String message) onError;

  @override
  State<_AddItemsSheet> createState() => _AddItemsSheetState();
}

class _AddItemsSheetState extends State<_AddItemsSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String _category = 'ALL';
  String? _busySku;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> get _categories {
    final set = <String>{};
    for (final product in widget.products) {
      if (product.category.isNotEmpty) set.add(product.category);
    }
    final list = set.toList()..sort();
    return ['ALL', ...list];
  }

  List<Product> get _filtered {
    final query = _query.trim().toLowerCase();
    return widget.products.where((product) {
      if (_category != 'ALL' && product.category != _category) return false;
      if (query.isEmpty) return true;
      return product.name.toLowerCase().contains(query) ||
          product.station.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _add(Product product) async {
    setState(() => _busySku = product.sku);
    try {
      await widget.onAdd(product);
    } catch (error) {
      widget.onError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busySku = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Text('Add items',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text('${products.length}',
                  style: const TextStyle(color: Colors.grey)),
              const Spacer(),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _search,
            autofocus: true,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search the catalogue',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: _categories.map((category) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(category),
                  selected: _category == category,
                  onSelected: (_) => setState(() => _category = category),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: products.isEmpty
              ? const Center(child: Text('No items match'))
              : ListView.builder(
                  controller: widget.scrollController,
                  itemCount: products.length,
                  itemBuilder: (context, index) {
                    final product = products[index];
                    final busy = _busySku == product.sku;
                    return ListTile(
                      dense: true,
                      title: Text(product.name),
                      subtitle: Text(product.category),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                              '${widget.currency}${product.price.toStringAsFixed(2)}'),
                          const SizedBox(width: 8),
                          busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : IconButton(
                                  tooltip: 'Add to order',
                                  icon: const Icon(Icons.add_circle),
                                  onPressed: () => _add(product),
                                ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
