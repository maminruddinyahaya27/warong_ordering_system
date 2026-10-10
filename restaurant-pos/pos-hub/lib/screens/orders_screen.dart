import 'dart:async';

import 'package:flutter/material.dart';

import '../models/order.dart';
import '../services/app_events.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/order_grouping.dart';
import '../services/print_queue_db.dart';
import 'order_detail_screen.dart';
import '../widgets/charge_mode_dialog.dart';
import '../widgets/partial_picker.dart';
import '../widgets/receipt_prompt.dart';
import '../widgets/settle_order.dart';
import '../widgets/ticket_preview.dart';

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

    // Paying item by item: after each part payment the picker comes back, with
    // what was just paid already struck through, until the bill settles or the
    // cashier stops.
    var current = order;
    while (true) {
      double? partial;
      var partialUnits = const <int, int>{};
      var covers = const <Map<String, dynamic>>[];
      // The covers are snapshotted onto the payment that takes the money, so
      // its receipt can list the items: the whole bill for a full payment, the
      // picked lines for a part payment.
      final products = await _db.getProducts();
      if (!mounted) return;
      final childIds = <int>{
        for (final line in groupOrderItems(current.items, productsBySku(products)))
          for (final child in line.children)
            if (child.id != null) child.id!,
      };
      if (mode != 'partial') {
        covers = [
          for (final item in current.items)
            <String, dynamic>{
              'name': item.name,
              'qty': item.qty,
              'price': item.unitPrice,
              'line': item.lineTotal,
              'addOn': childIds.contains(item.id),
            },
        ];
      }
      if (mode == 'partial') {
        final picked = await showPartialPicker(
          context,
          order: current,
          products: products,
          currency: _settings.currency,
        );
        if (!mounted || picked == null || picked.amount <= 0) return;
        partial = picked.amount;
        partialUnits = picked.paidUnits;
        // Snapshot what this round covers, for the payment's own receipt.
        covers = [
          for (final entry in picked.paidUnits.entries)
            for (final item in current.items)
              if (item.id == entry.key)
                <String, dynamic>{
                  'name': item.name,
                  'qty': entry.value,
                  'price': item.unitPrice,
                  'line': (item.unitPrice * entry.value * 100).roundToDouble() /
                      100,
                  'addOn': childIds.contains(item.id),
                },
        ];
      }

      // The loop can come back round after reloading the bill, so re-check
      // before using the context again.
      if (!mounted) return;
      final settled = await settleOrder(
        context,
        current,
        firstAmount: partial,
        // The picker flow asks again itself.
        askForMore: mode != 'partial',
        covers: covers,
      );
      if (settled == null || !mounted) return;

      // The cashier may have backed out of the payment dialog. Nothing was
      // taken this round, so the bill is left as it was — the picked items are
      // not marked paid (which matters when the bill was already part paid,
      // where the settle loop returns the untouched order instead of null).
      if (!CashierService.tookPayment(current, settled)) {
        if (partialUnits.isNotEmpty) {
          _snack('No payment taken — the bill is unchanged');
        }
        return;
      }

      // The money is taken, so record the units it covered straight away —
      // before the receipt question — otherwise declining the receipt would
      // leave an already paid item selectable in the picker.
      var paidIds = const <int>[];
      if (current.id != null) {
        if (partialUnits.isNotEmpty) {
          paidIds = await _cashier.recordPartPayment(current, partialUnits);
        } else if (settled.isSettled) {
          await _db.markAllOrderItemsPaid(current.id!);
        }
      }
      AppEvents.ordersChanged();
      if (!mounted) return;

      // Always offer the receipt — including after a part payment, where the
      // printed receipt is the record of what was paid this round.
      final print = await askPrintReceipt(context, settled.orderNo);
      if (print) {
        if (paidIds.isNotEmpty && partial != null) {
          // Part payment: the receipt covers only the units paid this round.
          final fresh = await _db.getOrder(current.id!) ?? settled;
          await _cashier.printPartialReceipt(fresh, paidIds, partial);
        } else {
          await _cashier.reprintReceipt(settled);
        }
      }
      if (!mounted) return;

      if (settled.isSettled) {
        _snack('${settled.orderNo} closed');
        return;
      }

      // Part paid. Reload the bill first, so the lines this round covered come
      // back struck through in the picker, then pick the rest.
      current = await _db.getOrder(settled.id!) ?? settled;
      if (mode != 'partial') {
        _snack('${settled.orderNo} part-paid — balance '
            '$_money${settled.balance.toStringAsFixed(2)}');
        return;
      }
    }
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

  /// Shows what each ticket will say, without printing anything — one per
  /// station and per take-away section — and lets one be sent on its own.
  Future<void> _previewTickets(Order order) async {
    final sheets = await _cashier.ticketSheets(order);
    if (!mounted) return;
    await showTicketPreview(
      context,
      orderNo: order.orderType == 'take_away'
          ? order.takeAwayLabel
          : order.orderNo,
      tickets: [
        for (final sheet in sheets)
          (
            label: _sheetLabel(order, sheet.station, sheet.section),
            text: sheet.text,
          ),
      ],
      onPrint: (index) => _cashier.sendStationTicket(
        order,
        sheets[index].station,
        sheets[index].section,
      ),
    );
  }

  /// How a ticket is titled in the preview: its station, and the document it
  /// belongs to — the bill's order number, or the `TA - 009` a take-away the
  /// table added on carries.
  static String _sheetLabel(Order order, String station, String section) {
    final name = station.trim().isEmpty ? 'KITCHEN' : station.toUpperCase();
    final document = section.isNotEmpty
        ? section
        : (order.orderType == 'take_away'
            ? order.takeAwayLabel
            : order.orderNo);
    return '$name \u00b7 $document';
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
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => OrderDetailScreen(
            order: order,
            onCharge: _pay,
            onVoid: _void,
            onPreviewTickets: _previewTickets,
            onResendTickets: _resendTickets,
            onReprintReceipt: _reprintReceipt,
          ),
        ))
        .then((_) {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final dineIn = _visibleOrders
        .where((order) => order.orderType != 'take_away')
        .toList();
    final bags = _visibleOrders
        .where((order) => order.orderType == 'take_away')
        .toList();
    final searched = _query.text.trim();

    // No pull-to-refresh: the list refreshes itself every few seconds.
    return Column(
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
        if (_visibleOrders.isEmpty && searched.isNotEmpty)
          Expanded(
            child: Center(
              child: Text('No open order for table "$searched"'),
            ),
          )
        // Dine-in bills on the left, take-aways on the right: two thirds for
        // the tables, one third for the bags.
        else
          Expanded(
            child: Row(
              // Stretch, so each pane has a tight height and its list is
              // bounded.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 7,
                  child: _buildPane(title: 'Dine-in', orders: dineIn),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 3,
                  child:
                      _buildPane(title: 'Take away', orders: bags, compact: true),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// One side of the cashier: a heading and its circles, scrolling on its own.
  Widget _buildPane({
    required String title,
    required List<Order> orders,
    bool compact = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text('${orders.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        Expanded(
          child: orders.isEmpty
              ? const Center(
                  child: Text('None',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                )
              : _buildTableGrid(orders, compact: compact),
        ),
      ],
    );
  }

  Widget _buildTableGrid(List<Order> orders, {bool compact = false}) {
    // Fixed-size circles in a Wrap inside a scroll view: bounded by the pane,
    // and nothing asks for an intrinsic size — which is what made an earlier
    // attempt at this layout hang when the grid sat in the page's own list.
    final side = compact ? 92.0 : 104.0;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final order in orders)
            SizedBox(width: side, height: side, child: _buildTableBubble(order)),
        ],
      ),
    );
  }

  Widget _buildTableBubble(Order order) {
    // A take-away is a take-away whether or not it kept a table number.
    final takeAway = order.orderType == 'take_away';
    final table = order.tableNo.trim();
    // A take-away is labelled `TA` with its take-away number under it, so two
    // waiting bags are told apart; a dine-in shows its table.
    final label = takeAway ? 'TA' : table.toUpperCase();
    // The take-away number sits under the `TA`, and the table the bag kept, if
    // any, after it.
    final sub = takeAway
        ? [
            if (order.takeAwayNo.isNotEmpty) order.takeAwayNo,
            if (table.isNotEmpty) table.toUpperCase(),
          ].join(' · ')
        : '';
    final partPaid = order.paid > 0 && !order.isSettled;
    // A take-away still stands on its own in blue; once it joins a table order
    // the bill is the table's, so it turns green and shows the table number.
    final color = partPaid
        ? Colors.orange
        : (takeAway ? Colors.blue.shade600 : Colors.green.shade600);
    final items = order.items.fold<int>(0, (sum, item) => sum + item.qty);

    return Tooltip(
      message: '${order.orderNo}\n$items item(s) · $_money'
          '${order.total.toStringAsFixed(2)}',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _openOrder(order),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(0.12),
            border: Border.all(color: color, width: 3),
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(6),
          // Sized text with an ellipsis: a bubble must never need a second
          // layout pass, and a two-line take-away bubble must not overflow.
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  key: ValueKey('bill-${order.orderNo}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: label.length > 5 ? 18 : 24,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
              if (sub.isNotEmpty)
                Text(
                  sub,
                  key: ValueKey('bill-table-${order.orderNo}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: color.withOpacity(0.8),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
