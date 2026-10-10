import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/product.dart';
import '../services/app_events.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/order_grouping.dart';
import '../services/print_queue_db.dart';

/// One bill, full screen: its lines with each add-on nested under the item it
/// was ordered with, its totals, and the actions the till offers for it.
class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({
    super.key,
    required this.order,
    required this.onCharge,
    required this.onVoid,
    required this.onPreviewTickets,
    required this.onResendTickets,
    required this.onReprintReceipt,
  });

  final Order order;
  final void Function(Order order) onCharge;
  final void Function(Order order) onVoid;
  final void Function(Order order) onPreviewTickets;
  final void Function(Order order) onResendTickets;
  final void Function(Order order) onReprintReceipt;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  final PrintQueueDb _db = PrintQueueDb.instance;
  final CashierService _cashier = CashierService.instance;
  final SettingsStore _settings = SettingsStore.instance;

  late Order _order = widget.order;
  List<Product> _products = const [];

  @override
  void initState() {
    super.initState();
    _db.getProducts().then((products) {
      if (mounted) setState(() => _products = products);
    });
  }

  bool get _editable => _order.status == 'OPEN';

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _run(
    Future<Order> Function() action,
    String Function(Order) message,
  ) async {
    try {
      final updated = await action();
      if (!mounted) return;
      setState(() => _order = updated);
      AppEvents.ordersChanged();
      _snack(message(updated));
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  /// The bill's lines, grouped by the items they were ordered with: the
  /// table's own first, then each take-away section, each add-on nested under
  /// its parent.
  List<GroupedOrderLine> _lines() {
    final grouped = groupOrderItems(_order.items, productsBySku(_products));
    final table = grouped.where((line) => line.item.section.isEmpty).toList();
    final sections =
        grouped.where((line) => line.item.section.isNotEmpty).toList();
    return [...table, ...sections];
  }

  @override
  Widget build(BuildContext context) {
    final editable = _editable;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _order.orderType == 'take_away'
              ? _order.takeAwayLabel
              : _order.orderNo,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          Center(child: _statusChip(_order.status)),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            [
              if (_order.tableNo.isNotEmpty) 'Table ${_order.tableNo}',
              if (_order.serverName.isNotEmpty) 'Server ${_order.serverName}',
              '${_order.items.fold<int>(0, (sum, item) => sum + item.qty)} item(s)',
            ].join(' · '),
            style: const TextStyle(color: Colors.grey),
          ),
          if (_order.note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Note: ${_order.note}'),
          ],
          const Divider(height: 24),
          ..._billLines(editable),
          const Divider(height: 24),
          _totalRow('Subtotal', _order.subtotal),
          _totalRow('Tax', _order.tax),
          if (_order.discount > 0) _totalRow('Discount', -_order.discount),
          _totalRow('Total', _order.total, bold: true),
          if (_order.paid > 0) ...[
            _totalRow('Paid', _order.paid),
            if (!_order.isSettled)
              _totalRow('Balance', _order.balance, bold: true),
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
                    widget.onCharge(_order);
                  },
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Charge'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onVoid(_order);
                  },
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Void'),
                ),
              ],
              if (_order.isSettled)
                OutlinedButton.icon(
                  onPressed: () => widget.onReprintReceipt(_order),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Receipt'),
                ),
              OutlinedButton.icon(
                onPressed: () => widget.onPreviewTickets(_order),
                icon: const Icon(Icons.preview_outlined),
                label: const Text('Preview'),
              ),
              OutlinedButton.icon(
                onPressed: () => widget.onResendTickets(_order),
                icon: const Icon(Icons.print),
                label: const Text('Tickets'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The lines with each add-on nested under the item it was ordered with,
  /// and a rule before each take-away section.
  List<Widget> _billLines(bool editable) {
    final rows = <Widget>[];
    String? lastSection;
    for (final line in _lines()) {
      if (line.item.section.isNotEmpty && line.item.section != lastSection) {
        rows.add(const Divider(height: 20));
        rows.add(Row(
          children: [
            const Icon(Icons.shopping_bag_outlined, size: 16),
            const SizedBox(width: 6),
            Text(
              line.item.section,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ));
        rows.add(const SizedBox(height: 4));
      }
      lastSection = line.item.section;
      rows.add(_orderLine(line.item, editable: editable));
      for (final child in line.children) {
        rows.add(_orderLine(child,
            editable: editable, nested: true));
      }
    }
    return rows;
  }

  Widget _orderLine(
    OrderItem item, {
    required bool editable,
    bool nested = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: nested ? 22 : 0),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: nested
            ? const Icon(Icons.subdirectory_arrow_right,
                size: 16, color: Colors.grey)
            : null,
        title: Text(
          item.name,
          style: item.paid
              ? const TextStyle(
                  decoration: TextDecoration.lineThrough, color: Colors.grey)
              : (nested ? const TextStyle(fontSize: 13) : null),
        ),
        subtitle: Text(
          [
            if (item.note.trim().isNotEmpty) item.note.trim(),
            if (item.paid) 'paid',
          ].join(' · '),
          style: item.paid ? const TextStyle(color: Colors.grey) : null,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (editable)
              IconButton(
                tooltip: 'Reduce',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => _run(
                  () => _cashier.setOrderItemQty(
                      _order.id!, item.id!, item.qty - 1),
                  (updated) => '${item.name} \u00d7 ${item.qty - 1}',
                ),
              )
            else
              Text('${item.qty}x'),
            if (editable)
              Text('${item.qty}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text('${_settings.currency}${item.lineTotal.toStringAsFixed(2)}'),
            if (editable)
              IconButton(
                tooltip: 'Add one',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _run(
                  () => _cashier.setOrderItemQty(
                      _order.id!, item.id!, item.qty + 1),
                  (updated) => '${item.name} \u00d7 ${item.qty + 1}',
                ),
              ),
            if (editable)
              IconButton(
                tooltip: 'Remove line',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await _confirm(
                    title: 'Remove ${item.name}?',
                    message: 'The line is removed from this order.',
                    confirmLabel: 'Remove',
                  );
                  if (ok != true) return;
                  await _run(
                    () => _cashier.setOrderItemQty(_order.id!, item.id!, 0),
                    (updated) => '${item.name} removed',
                  );
                },
              ),
          ],
        ),
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
          Text('${_settings.currency}${value.toStringAsFixed(2)}',
              style: style),
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
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.bold),
      side: BorderSide(color: color.withOpacity(0.5)),
      backgroundColor: color.withOpacity(0.08),
    );
  }
}
