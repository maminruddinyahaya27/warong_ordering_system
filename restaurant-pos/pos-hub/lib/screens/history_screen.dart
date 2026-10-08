import 'package:flutter/material.dart';

import '../models/order.dart';
import '../services/app_events.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/print_queue_db.dart';

/// Settled orders, with receipt preview and reprint.
/// Opened from the side menu; the shell provides the Scaffold.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final PrintQueueDb _db = PrintQueueDb.instance;
  final CashierService _cashier = CashierService.instance;
  final SettingsStore _settings = SettingsStore.instance;
  final TextEditingController _search = TextEditingController();

  List<Order> _orders = [];

  /// Payments per order, so a split bill shows how many tenders it took.
  Map<int, int> _payments = {};
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    AppEvents.ordersRevision.addListener(_load);
  }

  @override
  void dispose() {
    AppEvents.ordersRevision.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orders = await _db.getOrders(limit: 200);
    final counts = await _db.paymentCounts();
    if (!mounted) return;
    setState(() {
      _orders = orders.where((order) => order.status != 'OPEN').toList();
      _payments = counts;
      _loading = false;
    });
  }

  /// The receipt for one payment of a split bill.
  Future<void> _previewPayment(Order order, int index) async {
    final text = await _cashier.paymentPreview(order, index);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Payment ${index + 1} · ${order.orderNo}'),
        content: SizedBox(
          width: 360,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.35,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _printPayment(Order order, int index) async {
    await _cashier.printPayment(order, index);
    _snack('Receipt queued · ${order.orderNo} (payment ${index + 1})');
  }

  /// The split payments behind one order, by order number.
  Future<void> _showPayments(Order order) async {
    if (order.id == null) return;
    final payments = await _db.getOrderPayments(order.id!);
    if (!mounted) return;
    final currency = _settings.currency;
    var total = 0.0;
    for (final payment in payments) {
      total += ((payment['amount'] as num?) ?? 0).toDouble();
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Payments · ${order.orderNo}'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < payments.length; i += 1)
                _paymentRow(order, payments[i], i, currency),
              const Divider(),
              Row(
                children: [
                  const Expanded(
                    child: Text('Total paid',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Text(
                    '$currency${total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// One payment, with its own Preview and Print — the receipt for that
  /// tender alone.
  Widget _paymentRow(
    Order order,
    Map<String, dynamic> payment,
    int index,
    String currency,
  ) {
    final method = (payment['method'] ?? '').toString();
    final amount = ((payment['amount'] as num?) ?? 0).toDouble();
    final tendered = ((payment['tendered'] as num?) ?? 0).toDouble();
    final change = ((payment['change_due'] as num?) ?? 0).toDouble();
    final when = ((payment['created_at'] as num?) ?? 0).toInt();
    final cashHanded = method == 'cash' && tendered > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('${index + 1}. ${_methodLabel(method)} · '
                    '${_timeLabel(when)}'),
              ),
              Text('$currency${amount.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              TextButton(
                onPressed: () => _previewPayment(order, index),
                child: const Text('Preview'),
              ),
              TextButton(
                onPressed: () => _printPayment(order, index),
                child: const Text('Print'),
              ),
            ],
          ),
          if (cashHanded)
            Text(
              '      Cash $currency${tendered.toStringAsFixed(2)}'
              '${change > 0 ? ' · change $currency${change.toStringAsFixed(2)}' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  List<Order> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _orders;
    return _orders.where((order) {
      return order.orderNo.toLowerCase().contains(query) ||
          order.tableNo.toLowerCase().contains(query) ||
          order.serverName.toLowerCase().contains(query);
    }).toList();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Wipes the settled history — the orders, the take-aways and the payments
  /// taken with them. Products, prices and settings are kept.
  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'Every settled order and take-away is deleted, together with the '
          'payments taken for them. Products, prices and settings are kept, '
          'and order numbers start again from 001.\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _db.clearTransactions();
    AppEvents.ordersChanged();
    await _load();
    _snack('History cleared');
  }

  Future<void> _reprint(Order order) async {
    await _cashier.reprintReceipt(order);
    _snack('Receipt queued for ${order.orderNo}');
  }


  String _timeLabel(int? millis) {
    if (millis == null || millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _methodLabel(String method) {
    switch (method) {
      case 'cash':
        return 'Cash';
      case 'card':
        return 'Card';
      case 'ewallet':
        return 'E-Wallet';
      default:
        return method;
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search order no, table or server',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              const Text(
                'Paid orders',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Text('${orders.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const Spacer(),
              TextButton.icon(
                onPressed: orders.isEmpty ? null : _clearHistory,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('Clear history'),
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : orders.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? 'Nothing settled yet'
                            : 'No paid orders match "$_query"',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        itemCount: orders.length,
                        itemBuilder: (context, index) {
                          final order = orders[index];
                          return Card(
                            margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        // A take-away shows its TA number.
                                        child: Text(order.tableNo.isNotEmpty
                                            ? order.tableNo
                                            : order.takeAwayLabel),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(order.orderNo,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            const SizedBox(height: 2),
                                            Text(
                                              [
                                                if (order.orderType ==
                                                    'take_away')
                                                  'Take away',
                                                if (order.tableNo.isNotEmpty)
                                                  'Table ${order.tableNo}',
                                                if (order.serverName.isNotEmpty)
                                                  order.serverName,
                                                _timeLabel(order.paidAt),
                                                if (order.paymentMethod
                                                    .isNotEmpty)
                                                  _methodLabel(
                                                      order.paymentMethod),
                                              ].where((s) => s.isNotEmpty).join(
                                                  ' · '),
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Text(
                                        '${_settings.currency}${order.total.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  ...order.items.map((item) => Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                                '${item.qty}× ${item.name}',
                                                style: const TextStyle(
                                                    fontSize: 13)),
                                          ),
                                          Text(
                                            '${_settings.currency}${item.lineTotal.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey),
                                          ),
                                        ],
                                      )),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      if ((_payments[order.id] ?? 0) == 1) ...[
                                        const SizedBox(width: 8),
                                        // One tender: straight to its receipt.
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _previewPayment(order, 0),
                                          icon: const Icon(
                                              Icons.payments_outlined,
                                              size: 18),
                                          label: const Text('Payment'),
                                        ),
                                      ] else if ((_payments[order.id] ?? 0) >
                                          1) ...[
                                        const SizedBox(width: 8),
                                        // Split bill: the tender breakdown.
                                        OutlinedButton.icon(
                                          onPressed: () => _showPayments(order),
                                          icon: const Icon(Icons.payments_outlined,
                                              size: 18),
                                          label: Text(
                                              'Payments (${_payments[order.id]})'),
                                        ),
                                      ],
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: () => _reprint(order),
                                        icon: const Icon(Icons.print, size: 18),
                                        label: const Text('Reprint'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}
