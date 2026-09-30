import 'dart:async';

import 'package:flutter/material.dart';

import '../models/order.dart';
import '../services/app_events.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/print_queue_db.dart';
import '../widgets/charge_mode_dialog.dart';
import '../widgets/partial_picker.dart';
import '../widgets/receipt_prompt.dart';
import '../widgets/settle_order.dart';

/// Open orders list — the counter's main screen. Tapping a row opens the order
/// for amending; Close settles it. The search box filters the bills by table.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

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

  /// Filters the open bills by table number.
  final TextEditingController _query = TextEditingController();

  /// The table's number when its label is a number — `5`, `05`, `T5` or
  /// `Table 5` — or null for a named table such as `VIP 2`.
  static int? _tableNumber(String table) {
    final label = table
        .toLowerCase()
        .trim()
        .replaceFirst(RegExp(r'^(table|t)\s*'), '');
    if (label.isEmpty || label.length > 6) return null;
    if (!RegExp(r'^[0-9]+$').hasMatch(label)) return null;
    return int.parse(label);
  }

  /// The bills the search box currently shows, ordered by table number.
  ///
  /// A number finds the table with that number, while other text is matched
  /// loosely (`vip` finds `VIP 2`). The order number is never matched: it ends
  /// with the table number (`YYMMDD-NNN-TABLE`), which made every search hit
  /// every bill.
  List<Order> get _visibleOrders {
    final needle = _query.text.trim().toLowerCase();
    final needleNumber = _tableNumber(needle);
    final matches = needle.isEmpty
        ? List<Order>.of(_orders)
        : _orders.where((order) {
            final table = order.tableNo.trim().toLowerCase();
            if (needleNumber == null) return table.contains(needle);
            return _tableNumber(table) == needleNumber;
          }).toList();
    matches.sort(_byTable);
    return matches;
  }

  /// Table number ascending — numbered tables first, then named ones, with
  /// take-away bills (no table) at the bottom.
  static int _byTable(Order a, Order b) {
    final tableA = a.tableNo.trim();
    final tableB = b.tableNo.trim();
    if (tableA.isEmpty != tableB.isEmpty) return tableA.isEmpty ? 1 : -1;
    final numberA = _tableNumber(tableA);
    final numberB = _tableNumber(tableB);
    if ((numberA != null) != (numberB != null)) return numberA != null ? -1 : 1;
    if (numberA != null && numberB != null && numberA != numberB) {
      return numberA.compareTo(numberB);
    }
    final byText = tableA.toLowerCase().compareTo(tableB.toLowerCase());
    return byText != 0 ? byText : a.orderNo.compareTo(b.orderNo);
  }

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
    _query.dispose();
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
    // Full bill, or the items the customer is paying for now.
    final mode = await showChargeModeDialog(
      context,
      title: 'Charge ${order.orderNo} · '
          '$_money${order.balance.toStringAsFixed(2)}',
    );
    if (!mounted || mode == null) return;

    double? partial;
    var partialIds = const <int>[];
    if (mode == 'partial') {
      final products = await _db.getProducts();
      if (!mounted) return;
      final picked = await showPartialPicker(
        context,
        order: order,
        products: products,
        currency: _settings.currency,
      );
      if (!mounted || picked == null || picked.amount <= 0) return;
      partial = picked.amount;
      partialIds = picked.itemIds;
    }

    final settled = await settleOrder(context, order, firstAmount: partial);
    if (settled == null || !mounted) return;
    AppEvents.ordersChanged();

    // Always offer the receipt — including after a part payment, where the
    // printed receipt is the record of what was paid this round.
    final print = await askPrintReceipt(context, settled.orderNo);

    // Lines are only flagged as paid once the receipt actually prints, so an
    // abandoned flow leaves the picker untouched.
    if (print) {
      if (partialIds.isNotEmpty && partial != null) {
        // Part payment: the receipt covers only the items paid this round.
        await _cashier.printPartialReceipt(order, partialIds, partial);
      } else {
        await _cashier.reprintReceipt(settled);
      }
      if (order.id != null) {
        if (partialIds.isNotEmpty) {
          await _db.markOrderItemsPaid(order.id!, partialIds);
        } else {
          await _db.markAllOrderItemsPaid(order.id!);
        }
      }
    }

    if (!mounted) return;
    if (!settled.isSettled) {
      _snack('${settled.orderNo} part-paid — balance '
          '$_money${settled.balance.toStringAsFixed(2)}');
      return;
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
                        // A receipt is only meaningful once the bill is closed.
                        if (current.isSettled)
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
      // A line covered by a part payment is struck through.
      title: Text(
        item.name,
        style: item.paid
            ? const TextStyle(
                decoration: TextDecoration.lineThrough,
                color: Colors.grey,
              )
            : null,
      ),
      subtitle: Text(
        item.paid ? '${item.station} · paid' : item.station,
        style: item.paid ? const TextStyle(color: Colors.grey) : null,
      ),
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _query,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Search table',
                hintText: 'Table number',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(_query.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_visibleOrders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text(
                  _query.text.trim().isEmpty
                      ? 'No open orders'
                      : 'No open order for table "${_query.text.trim()}"',
                ),
              ),
            )
          else
            ..._visibleOrders.map((order) => Card(
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
