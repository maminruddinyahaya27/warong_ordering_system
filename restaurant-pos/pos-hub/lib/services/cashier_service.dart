import 'dart:async';
import 'dart:convert';

import '../models/order.dart';
import '../models/product.dart';
import 'app_settings.dart';
import 'order_grouping.dart';
import 'print_queue_db.dart';
import 'queue_dispatcher.dart';

class OrderTotals {
  final double subtotal;
  final double tax;
  final double discount;
  final double total;
  const OrderTotals({
    required this.subtotal,
    required this.tax,
    required this.discount,
    required this.total,
  });
}

/// Creates, prices and settles orders, and pushes the matching print jobs.
class CashierService {
  static final CashierService instance = CashierService._internal();
  CashierService._internal();

  final PrintQueueDb _db = PrintQueueDb.instance;
  final SettingsStore _settings = SettingsStore.instance;
  final QueueDispatcher _dispatcher = QueueDispatcher.instance;

  static const String receiptStation = 'CASHIER';

  double _round2(double value) => (value * 100).roundToDouble() / 100;

  double _roundToStep(double value, double step) {
    if (step <= 0) return _round2(value);
    return _round2((value / step).roundToDouble() * step);
  }

  /// Amount actually collected for [method]. Cash is rounded to the configured
  /// step (e.g. nearest 0.05); cards/e-wallets pay the exact total.
  double payableTotal(double total, String method) => method == 'cash'
      ? _roundToStep(total, _settings.roundingStep)
      : _round2(total);

  // ---------------------------------------------------------- order numbers

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// YYMMDD for the order's creation date.
  static String orderDayPrefix(DateTime when) =>
      '${_two(when.year % 100)}${_two(when.month)}${_two(when.day)}';

  /// Order numbers look like `260922-001-12` (date, daily running number,
  /// table). Take-away has no table: `260922-TA-001`.
  Future<String> _nextOrderNo(DateTime when, String tableNo) async {
    final prefix = orderDayPrefix(when);
    final existing = await _db.countOrdersWithPrefix(prefix);
    final running = (existing + 1).toString().padLeft(3, '0');
    final table = tableNo.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (table.isEmpty) return '$prefix-TA-$running';
    return '$prefix-$running-$table';
  }

  // ----------------------------------------------------------- trading day

  Future<Map<String, dynamic>?> activeDay() => _db.getActiveDay();

  Future<Map<String, dynamic>> openDay({String by = 'cashier'}) async {
    final existing = await _db.getActiveDay();
    if (existing != null) {
      throw Exception('The day is already open');
    }
    final id = await _db.openDay(by);
    return {
      'id': id,
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'ended_at': null,
    };
  }

  /// Closes the open day and returns its takings.
  Future<Map<String, double>> closeDay({String by = 'cashier'}) async {
    final active = await _db.getActiveDay();
    if (active == null) {
      throw Exception('No day is open');
    }
    final start = (active['started_at'] as int?) ?? 0;
    final summary = await _db.salesBetween(
        start, DateTime.now().millisecondsSinceEpoch);
    await _db.closeDay(active['id'] as int, by);
    return summary;
  }

  Future<Map<String, double>> salesBetween(DateTime from, DateTime to) =>
      _db.salesBetween(from.millisecondsSinceEpoch, to.millisecondsSinceEpoch);

  OrderTotals computeTotals(List<OrderItem> items, {double discount = 0}) {    final subtotal = items.fold<double>(0, (sum, item) => sum + item.lineTotal);
    final rate = _settings.taxRate;
    final double tax;
    final double gross;
    if (_settings.taxInclusive) {
      // Prices already include tax: back the tax portion out of the subtotal.
      tax = subtotal - subtotal / (1 + rate);
      gross = subtotal;
    } else {
      tax = subtotal * rate;
      gross = subtotal + tax;
    }
    return OrderTotals(
      subtotal: _round2(subtotal),
      tax: _round2(tax),
      discount: _round2(discount),
      total: _round2(gross - discount),
    );
  }

  Future<Order> createOrder({
    required String channel,
    required List<OrderItem> items,
    String tableNo = '',
    String serverName = '',
    String note = '',
    String orderType = 'dine_in',
    String idempotencyKey = '',
    DateTime? at,
  }) async {
    if (items.isEmpty) {
      throw Exception('Order has no items');
    }

    final type = orderType == 'take_away' ? 'take_away' : 'dine_in';
    if (type == 'dine_in' && tableNo.trim().isEmpty) {
      throw Exception('Table number is required for dine-in orders');
    }
    final totals = computeTotals(items);
    // `at` lets a caller (and the tests) place an order on a given date; the
    // running number is counted per date, so a new date starts again at 001.
    final createdAt = (at ?? DateTime.now()).millisecondsSinceEpoch;

    final orderId = await _db.insertOrder(Order(
      tableNo: tableNo.trim(),
      serverName: serverName.trim(),
      note: note.trim(),
      channel: channel,
      status: 'OPEN',
      orderType: type,
      subtotal: totals.subtotal,
      tax: totals.tax,
      discount: totals.discount,
      total: totals.total,
      createdAt: createdAt,
      idempotencyKey: idempotencyKey,
    ));
    final orderNo =
        await _nextOrderNo(DateTime.fromMillisecondsSinceEpoch(createdAt), tableNo);
    await _db.setOrderNo(orderId, orderNo);
    await _db.insertOrderItems(orderId, items);

    final order = Order(
      id: orderId,
      orderNo: orderNo,
      tableNo: tableNo.trim(),
      serverName: serverName.trim(),
      note: note.trim(),
      channel: channel,
      status: 'OPEN',
      orderType: type,
      subtotal: totals.subtotal,
      tax: totals.tax,
      discount: totals.discount,
      total: totals.total,
      createdAt: createdAt,
      items: items,
    );

    await sendStationTickets(order);
    // Re-read so the returned order carries the persisted line ids, which
    // clients need to amend the order later.
    return (await _db.getOrder(orderId))!;
  }

  /// The open dine-in bill for a table, if any.
  Future<Order?> findOpenOrderForTable(String tableNo) =>
      _db.findOpenOrderForTable(tableNo.trim());

  /// Creates an order, or — when a dine-in table already has an open bill —
  /// appends the items to that bill so the table pays on one receipt.
  ///
  /// [idempotencyKey] makes the call safe to retry: repeating it returns the
  /// order the first attempt produced instead of creating/adding again.
  Future<({Order order, bool merged, bool duplicate})> createOrAppendOrder({
    required String channel,
    required List<OrderItem> items,
    String tableNo = '',
    String serverName = '',
    String note = '',
    String orderType = 'dine_in',
    String idempotencyKey = '',
  }) async {
    if (idempotencyKey.isNotEmpty) {
      final handledOrderId = await _db.orderIdForRequest(idempotencyKey);
      if (handledOrderId != null) {
        final existing = await _db.getOrder(handledOrderId);
        if (existing != null) {
          return (order: existing, merged: false, duplicate: true);
        }
      }
    }

    final type = orderType == 'take_away' ? 'take_away' : 'dine_in';
    if (type == 'dine_in' && tableNo.trim().isEmpty) {
      throw Exception('Table number is required for dine-in orders');
    }

    if (type == 'dine_in' && _settings.autoMergeTableOrders) {
      final open = await _db.findOpenOrderForTable(tableNo);
      if (open != null) {
        if (items.isEmpty) throw Exception('Order has no items');
        final updated = await addOrderItems(open.id!, items);
        await _db.recordRequest(idempotencyKey, open.id!);
        return (order: updated, merged: true, duplicate: false);
      }
    }

    final created = await createOrder(
      channel: channel,
      items: items,
      tableNo: tableNo,
      serverName: serverName,
      note: note,
      orderType: type,
      idempotencyKey: idempotencyKey,
    );
    if (created.id != null) {
      await _db.recordRequest(idempotencyKey, created.id!);
    }
    return (order: created, merged: false, duplicate: false);
  }

  /// Kicks the printer queue without blocking the caller. Tickets print in the
  /// background, so creating an order never waits on Bluetooth.
  void _kickPrinter() {
    unawaited(_dispatcher.dispatchNext().catchError((Object _) {}));
  }

  /// The station each line prints at, plus the product lookup tickets need.
  ///
  /// An add-on prints on the station of the item it was ordered with — the most
  /// recent item whose group it is an add-on for — so `Nasi Lemak Biasa` with
  /// `Rendang Kerang` prints together on the nasi lemak station even when the
  /// same bill also holds a roti canai. When that parent is not on the bill the
  /// add-on keeps its own station.
  Future<({Map<int, String> byItemId, Map<String, Product> bySku})>
      _stationPlan(Order order) async {
    final bySku = productsBySku(await _db.getProducts());
    final byItemId = <int, String>{};

    for (final line in groupOrderItems(order.items, bySku)) {
      final station = _ownStation(line.item);
      byItemId[_itemKey(line.item)] = station;
      // An add-on is printed under its parent, on the parent's ticket.
      for (final child in line.children) {
        byItemId[_itemKey(child)] = station;
      }
    }
    return (byItemId: byItemId, bySku: bySku);
  }

  /// Lines are matched by id; a line that was never stored falls back to its
  /// identity so two identical items never share a station.
  static int _itemKey(OrderItem item) => item.id ?? identityHashCode(item);

  static String _ownStation(OrderItem item) =>
      item.station.isEmpty ? 'KITCHEN' : item.station;

  String _stationFor(OrderItem item, Map<int, String> byItemId) =>
      byItemId[_itemKey(item)] ?? _ownStation(item);

  Future<void> sendStationTickets(Order order) async {
    final plan = await _stationPlan(order);
    final stations = <String>{
      for (final item in order.items) _stationFor(item, plan.byItemId),
    };
    for (final station in stations) {
      await _db.enqueue(station, '', _ticketPayload(station, order, plan));
    }
    // Printing runs in the background: awaiting it would keep the caller (and
    // the UI, or the waiter's HTTP request) waiting for every Bluetooth ticket
    // plus the per-printer cooldown.
    _kickPrinter();
  }

  /// The exact text each station's ticket will carry, without printing it.
  /// Used by the till's ticket preview so a bill can be checked before it is
  /// sent to the kitchen.
  Future<Map<String, String>> ticketPreviews(Order order) async {
    final plan = await _stationPlan(order);
    final stations = <String>{
      for (final item in order.items) _stationFor(item, plan.byItemId),
    };
    return {
      for (final station in stations)
        station: _ticketPayload(station, order, plan),
    };
  }

  /// Queues one station's ticket on its own — the preview's per-station print.
  Future<void> sendStationTicket(Order order, String station) async {
    final plan = await _stationPlan(order);
    await _db.enqueue(station, '', _ticketPayload(station, order, plan));
    _kickPrinter();
  }

  /// Takes one tender against a bill — the balance is charged when a bill is
  /// split between several payments. The order is only marked PAID once the
  /// tenders cover the total.
  ///
  /// Cash may cover part of the balance (what the customer hands over); card
  /// and e-wallet settle the rest unless [amount] is given.
  Future<Order> addPayment(
    int id, {
    required String method,
    double? amount,
    double tendered = 0,
  }) async {
    final order = await _db.getOrder(id);
    if (order == null) {
      throw Exception('Order not found');
    }
    if (order.status == 'PAID') {
      throw Exception('Order ${order.orderNo} is already paid');
    }

    final balance = order.balance;
    if (balance <= 0) {
      throw Exception('Order ${order.orderNo} has nothing left to pay');
    }

    // Cash is rounded to the configured step on the amount collected.
    final payable = payableTotal(balance, method);

    double value;
    double change = 0;
    if (amount != null) {
      value = _round2(amount);
    } else if (method == 'cash') {
      final handed = _round2(tendered);
      if (handed + 0.0001 >= payable) {
        // Enough (or more) for the whole balance.
        value = payable;
        change = _round2(handed - payable);
      } else {
        // Part payment.
        value = handed;
      }
    } else {
      value = payable;
    }

    if (value <= 0) {
      throw Exception('Payment amount must be more than zero');
    }
    if (value > payable + 0.0001) {
      throw Exception('Payment is more than the balance');
    }

    await _db.insertOrderPayment(
      id,
      method: method,
      amount: value,
      tendered: method == 'cash' ? _round2(tendered) : value,
      change: change,
    );

    final paidNow = _round2(order.paid + value);
    if (paidNow + 0.0001 >= order.total) {
      final tenders = await _db.countOrderPayments(id);
      final isSplit = tenders > 1;
      // A single cash payment records what the customer actually handed over
      // (e.g. 30 on a 26.50 bill), so the receipt shows Cash 30.00 + Change.
      final handed = (!isSplit && method == 'cash' && _round2(tendered) > 0)
          ? _round2(tendered)
          : paidNow;
      await _db.settleOrder(
        id,
        method: isSplit ? 'split' : method,
        tendered: handed,
        changeDue: change,
      );
    }

    return (await _db.getOrder(id))!;
  }

  /// Pays the whole outstanding balance in one go.
  Future<Order> payOrder(
    int id, {
    required String method,
    double tendered = 0,
    bool printReceipt = true,
  }) async {
    final order = await _db.getOrder(id);
    if (order == null) {
      throw Exception('Order not found');
    }
    if (order.status == 'PAID') {
      throw Exception('Order ${order.orderNo} is already paid');
    }

    final updated = await addPayment(id, method: method, tendered: tendered);
    // The caller can print on demand (the UI asks first).
    if (printReceipt && updated.status == 'PAID') {
      await reprintReceipt(updated);
    }
    return updated;
  }

  Future<void> voidOrder(int id) async {
    final order = await _db.getOrder(id);
    if (order == null) throw Exception('Order not found');
    if (order.status == 'PAID') {
      throw Exception('Paid orders cannot be voided');
    }
    if (order.paid > 0) {
      throw Exception(
          'Order ${order.orderNo} is part-paid — settle or refund it instead of voiding');
    }
    await _db.updateOrderStatus(id, 'VOID');
  }

  // ------------------------------------------------------- editing an order

  Future<Order> _requireOpen(int orderId) async {
    final order = await _db.getOrder(orderId);
    if (order == null) throw Exception('Order not found');
    if (order.status != 'OPEN') {
      throw Exception(
          '${order.orderNo} is ${order.status.toLowerCase()} — cannot edit');
    }
    return order;
  }

  /// Recomputes the order's totals from its stored lines.
  Future<Order> _recalculate(int orderId) async {
    final items = await _db.getOrderItems(orderId);
    if (items.isEmpty) {
      throw Exception('Order has no items left — void it instead');
    }
    final totals = computeTotals(items);
    await _db.updateOrderTotals(
      orderId,
      subtotal: totals.subtotal,
      tax: totals.tax,
      discount: totals.discount,
      total: totals.total,
    );
    final updated = await _db.getOrder(orderId);
    return updated!;
  }

  /// Sets a line's quantity; 0 (or less) removes the line.
  Future<Order> setOrderItemQty(int orderId, int itemId, int qty) async {
    final order = await _requireOpen(orderId);
    final matches = order.items.where((item) => item.id == itemId).toList();
    if (matches.isEmpty) throw Exception('Item not found on ${order.orderNo}');

    if (qty <= 0) {
      await _db.deleteOrderItem(itemId);
    } else {
      final item = matches.first;
      await _db.updateOrderItemQty(
          itemId, qty, _round2(item.unitPrice * qty));
    }
    return _recalculate(orderId);
  }

  /// Adds lines to an open order and prints tickets for just those lines.
  Future<Order> addOrderItems(int orderId, List<OrderItem> items) async {
    await _requireOpen(orderId);
    if (items.isEmpty) throw Exception('No items to add');

    for (final item in items) {
      await _db.insertOrderItem(orderId, item);
    }
    final updated = await _recalculate(orderId);
    await _sendTicketsFor(updated, items);
    return updated;
  }

  /// Enqueues kitchen tickets for a subset of an order's items.
  Future<void> _sendTicketsFor(Order order, List<OrderItem> items) async {
    // The plan is computed from the whole order, so an add-on added later
    // still lands on its parent's station.
    final plan = await _stationPlan(order);
    final stations = <String>{
      for (final item in items) _stationFor(item, plan.byItemId),
    };
    final partial = order.copyWith(items: items);
    for (final station in stations) {
      await _db.enqueue(station, '', _ticketPayload(station, partial, plan));
    }
    _kickPrinter();
  }

  Future<void> reprintReceipt(Order order) async {
    final payload = jsonEncode(await _receiptPayload(order));
    await _db.enqueue(receiptStation, '', payload, kind: 'receipt');
    _kickPrinter();
  }

  /// Receipt for a part payment: only the items the customer paid for this
  /// round, the amount taken, and what is left on the bill.
  /// Whether a settle round actually took money — only then may the items it
  /// covered be recorded as paid. Backing out of the payment dialog leaves the
  /// bill exactly as it was, even when it was already part paid.
  static bool tookPayment(Order before, Order after) =>
      after.paid - before.paid > 0.005;

  /// Records the units a part payment covered and returns those line ids.
  ///
  /// A line picked in full is flagged paid. A line picked in part is split: the
  /// units paid become their own paid line (so the picker shows them as paid,
  /// not as something to pick again) and the remaining units stay open.
  ///
  /// This runs as soon as the money is taken — not when the receipt prints — so
  /// declining the receipt cannot leave paid items selectable.
  Future<List<int>> recordPartPayment(
    Order order,
    Map<int, int> paidUnits,
  ) async {
    final orderId = order.id;
    if (orderId == null) return const [];

    final paidIds = <int>[];
    for (final entry in paidUnits.entries) {
      OrderItem? item;
      for (final line in order.items) {
        if (line.id == entry.key) {
          item = line;
          break;
        }
      }
      if (item == null || item.id == null) continue;
      final units = entry.value.clamp(0, item.qty);
      if (units <= 0) continue;

      if (units >= item.qty) {
        await _db.markOrderItemsPaid(orderId, [item.id!]);
        paidIds.add(item.id!);
        continue;
      }
      final splitIds = await _db.insertOrderItems(orderId, [
        OrderItem(
          sku: item.sku,
          name: item.name,
          qty: units,
          unitPrice: item.unitPrice,
          lineTotal: _round2(item.unitPrice * units),
          station: item.station,
          note: item.note,
          paid: true,
        ),
      ]);
      final remaining = item.qty - units;
      await _db.updateOrderItemQty(
        item.id!,
        remaining,
        _round2(item.unitPrice * remaining),
      );
      paidIds.addAll(splitIds);
    }
    return paidIds;
  }

  Future<void> printPartialReceipt(
    Order order,
    List<int> itemIds,
    double amount,
  ) async {
    final picked = order.items
        .where((item) => item.id != null && itemIds.contains(item.id))
        .toList();
    if (picked.isEmpty) {
      await reprintReceipt(order);
      return;
    }

    final payments = order.id == null
        ? const <Map<String, dynamic>>[]
        : await _db.getOrderPayments(order.id!);
    final last = payments.isNotEmpty ? payments.last : null;

    var bySku = const <String, Product>{};
    try {
      bySku = productsBySku(await _db.getProducts());
    } catch (_) {
      bySku = const <String, Product>{};
    }
    final childItems = <OrderItem>{};
    for (final line in groupOrderItems(picked, bySku)) {
      childItems.addAll(line.children);
    }

    final subtotal = _round2(
      picked.fold<double>(0, (sum, item) => sum + item.lineTotal),
    );
    final payload = {
      'restaurantName': _settings.restaurantName,
      'footer': _settings.receiptFooter,
      'currency': _settings.currency,
      'orderNo': order.orderNo,
      'table': order.tableNo,
      'server': order.serverName,
      'channel': order.channel,
      'orderType': order.orderType,
      'when': _formatDateTime(DateTime.now().millisecondsSinceEpoch),
      'items': picked
          .map((item) => {
                'name': item.name,
                'qty': item.qty,
                'price': item.unitPrice,
                'line': item.lineTotal,
                'addOn': childItems.contains(item),
              })
          .toList(),
      'subtotal': subtotal,
      // The rest of the charge is this receipt's share of the tax.
      'tax': _round2(amount - subtotal),
      'taxRate': _settings.taxRate,
      'taxInclusive': _settings.taxInclusive,
      'discount': 0,
      'total': amount,
      'balance': _round2(order.balance - amount),
      'payment': (last?['method'] ?? 'cash').toString(),
      'tendered': ((last?['tendered'] as num?) ?? amount).toDouble(),
      'change': ((last?['change_due'] as num?) ?? 0).toDouble(),
      'payments': const <Map<String, dynamic>>[],
    };

    await _db.enqueue(receiptStation, '', jsonEncode(payload), kind: 'receipt');
    _kickPrinter();
  }

  /// Plain-text, 32-column receipt used for the on-screen preview on the
  /// History page. Mirrors what [EscPosRenderer.renderReceipt] prints.
  Future<String> receiptPreview(Order order) async {
    const width = 32;
    final currency = _settings.currency;
    final rule = '-' * width;

    String center(String text) {
      if (text.isEmpty) return '';
      final pad = ((width - text.length) / 2).floor();
      return '${' ' * (pad < 0 ? 0 : pad)}$text';
    }

    String row(String left, String right) {
      final space = width - right.length - left.length;
      return space > 0 ? '$left${' ' * space}$right' : '$left $right';
    }

    String money(double value) => value.toStringAsFixed(2);

    String methodLabel(String method) {
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

    final lines = <String>[
      center(_settings.restaurantName.toUpperCase()),
      center(_formatDateTime(order.paidAt ?? order.createdAt)),
      rule,
      'Order: ${order.orderNo}',
      if (order.tableNo.isNotEmpty) 'Table: ${order.tableNo}',
      order.orderType == 'take_away' ? 'Type:  TAKE AWAY' : 'Type:  Dine-in',
      if (order.serverName.isNotEmpty) 'Server: ${order.serverName}',
      rule,
    ];

    // Numbered items, with each add-on nested under the item it came with.
    // The catalogue may be unavailable (preview before a sync), in which case
    // every line simply prints as a normal item.
    var bySku = const <String, Product>{};
    try {
      bySku = productsBySku(await _db.getProducts());
    } catch (_) {
      bySku = const <String, Product>{};
    }
    var itemNumber = 0;
    for (final line in groupOrderItems(order.items, bySku)) {
      itemNumber += 1;
      lines.add('$itemNumber. ${line.item.name}');
      lines.add(row('   ${line.item.qty} X ${money(line.item.unitPrice)}',
          money(line.item.lineTotal)));
      for (final child in line.children) {
        lines.add('    - ${child.name}');
        lines.add(row('       ${child.qty} X ${money(child.unitPrice)}',
            money(child.lineTotal)));
      }
    }

    lines.add(rule);
    lines.add(row('Subtotal', '$currency${money(order.subtotal)}'));
    if (order.tax > 0) {
      final rate = (_settings.taxRate * 100);
      final rateText = rate == rate.roundToDouble()
          ? rate.toInt().toString()
          : rate.toStringAsFixed(2);
      lines.add(row('Tax ($rateText%)', '$currency${money(order.tax)}'));
    }
    if (order.discount > 0) {
      lines.add(row('Discount', '-$currency${money(order.discount)}'));
    }
    final collected = order.paid > 0 ? _round2(order.paid) : order.total;
    lines.add(row('Total', '$currency${money(collected)}'));

    final payments = order.id == null
        ? const <Map<String, dynamic>>[]
        : await _db.getOrderPayments(order.id!);
    if (payments.length > 1) {
      // Split bill: list every tender.
      for (final payment in payments) {
        lines.add(row(
          methodLabel((payment['method'] ?? '').toString()),
          '$currency${money(((payment['amount'] as num?) ?? 0).toDouble())}',
        ));
      }
      final change = order.changeDue;
      if (change > 0) {
        lines.add(row('Change', '$currency${money(change)}'));
      }
    } else if (order.paymentMethod.isNotEmpty) {
      lines.add(
          row(methodLabel(order.paymentMethod), '$currency${money(order.tendered)}'));
      if (order.changeDue > 0) {
        lines.add(row('Change', '$currency${money(order.changeDue)}'));
      }
    }
    lines.add(rule);
    lines.add(center(_settings.receiptFooter));
    return lines.join('\n');
  }

  String _ticketPayload(
    String station,
    Order order,
    ({Map<int, String> byItemId, Map<String, Product> bySku}) plan,
  ) {
    final bySku = plan.bySku;
    final sb = StringBuffer();
    final takeAway = order.orderType == 'take_away';
    const rule = '------------------------------';

    sb.writeln('ORDER - ${order.orderNo}');
    // Dine-in is identified by its table, take-away by its TA number.
    if (takeAway) {
      sb.writeln('TABLE - ${order.orderNo}');
    } else {
      sb.writeln(
        'TABLE - ${order.tableNo.isEmpty ? 'No table' : order.tableNo}',
      );
    }
    sb.writeln(rule);

    final onStation = order.items
        .where((item) => _stationFor(item, plan.byItemId) == station)
        .toList();

    var number = 0;
    for (final line in groupOrderItems(onStation, bySku)) {
      number += 1;
      sb.writeln('$number. ${line.item.name} X ${line.item.qty}');
      if (line.item.note.isNotEmpty) sb.writeln('    - ${line.item.note}');
      for (final addOn in line.children) {
        final qty = addOn.qty > 1 ? ' X ${addOn.qty}' : '';
        sb.writeln('    - ${addOn.name}$qty');
        // An add-on keeps its own note, e.g. "gravy on the side".
        if (addOn.note.isNotEmpty) sb.writeln('    - ${addOn.note}');
      }
      sb.writeln('');
    }

    sb.writeln(rule);
    if (order.note.isNotEmpty) {
      sb.writeln('Note: ${order.note}');
      sb.writeln(rule);
    }
    return sb.toString();
  }

  Future<Map<String, dynamic>> _receiptPayload(Order order) async {
    final payments = order.id == null
        ? const <Map<String, dynamic>>[]
        : await _db.getOrderPayments(order.id!);
    // Add-ons print indented under the item they came with.
    var bySku = const <String, Product>{};
    try {
      bySku = productsBySku(await _db.getProducts());
    } catch (_) {
      bySku = const <String, Product>{};
    }
    final childItems = <OrderItem>{};
    for (final line in groupOrderItems(order.items, bySku)) {
      childItems.addAll(line.children);
    }
    // What the customer actually paid: the sum of tenders once settled.
    final collected = order.paid > 0 ? _round2(order.paid) : order.total;
    // The tender row is the source of truth for a single payment (cash shows
    // what was handed over, not the amount charged), which also makes reprints
    // of earlier orders correct.
    final single = payments.length == 1 ? payments.first : null;
    final tenderedOut = single != null
        ? ((single['tendered'] as num?) ?? 0).toDouble()
        : order.tendered;
    final changeOut = single != null
        ? ((single['change_due'] as num?) ?? 0).toDouble()
        : order.changeDue;
    return {
      'restaurantName': _settings.restaurantName,
      'footer': _settings.receiptFooter,
      'currency': _settings.currency,
      'orderNo': order.orderNo,
      'table': order.tableNo,
      'server': order.serverName,
      'channel': order.channel,
      'orderType': order.orderType,
      'when': _formatDateTime(order.paidAt ?? order.createdAt),
      'items': order.items
          .map((i) => {
                'name': i.name,
                'qty': i.qty,
                'price': i.unitPrice,
                'line': i.lineTotal,
                'addOn': childItems.contains(i),
              })
          .toList(),
      'subtotal': order.subtotal,
      'tax': order.tax,
      'taxRate': _settings.taxRate,
      'taxInclusive': _settings.taxInclusive,
      'discount': order.discount,
      'total': collected,
      'payment': order.paymentMethod,
      'tendered': tenderedOut,
      'change': changeOut,
      'payments': payments
          .map((payment) => {
                'method': (payment['method'] ?? '').toString(),
                'amount': ((payment['amount'] as num?) ?? 0).toDouble(),
                'tendered': ((payment['tendered'] as num?) ?? 0).toDouble(),
                'change': ((payment['change_due'] as num?) ?? 0).toDouble(),
              })
          .toList(),
    };
  }

  static String _formatDateTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
