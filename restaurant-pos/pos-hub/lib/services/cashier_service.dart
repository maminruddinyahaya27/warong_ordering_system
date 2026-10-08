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

  /// The next take-away number for today, e.g. `009`.
  ///
  /// Take-away orders and the take-away lines a table adds on ("one more to
  /// take home") share one sequence, so the number on the bill's `TA` section
  /// never clashes with a bag's.
  Future<String> _nextTakeAwayNo() async {
    final prefix = orderDayPrefix(DateTime.now());
    final key = 'ta_seq_$prefix';
    final settings = await _db.getAllSettings();
    final stamped = int.tryParse(settings[key] ?? '') ?? 0;
    final used = await _db.countOrdersWithPrefix('$prefix-TA');
    final next = (stamped > used ? stamped : used) + 1;
    await _db.setSetting(key, '$next');
    return next.toString().padLeft(3, '0');
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

    // A table's open bill takes everything rung up for that table, including a
    // take-away the table adds on ("one more to take home"): a take-away with a
    // table number joins that bill. Without a table number it stays its own TA
    // bill, as before.
    if (tableNo.trim().isNotEmpty && _settings.autoMergeTableOrders) {
      final open = await _db.findOpenOrderForTable(tableNo);
      if (open != null) {
        if (items.isEmpty) throw Exception('Order has no items');
        // A take-away that took the table first becomes the table's bill: its
        // own lines turn into a `TA - nnn` section — exactly as they would have
        // if the table order had come first — and the bill's type takes over.
        if (type == 'dine_in' && open.orderType == 'take_away') {
          await _db.setSectionForUnsectioned(open.id!, 'TA - ${open.takeAwayNo}');
          await _db.updateOrderType(open.id!, 'dine_in');
        }
        // A take-away gets one TA number and is tagged as its own section, so
        // the bill can rule it off from the table's own lines.
        final label =
            type == 'take_away' ? 'TA - ${await _nextTakeAwayNo()}' : '';
        final merged = label.isEmpty
            ? items
            : [for (final item in items) item.copyWith(section: label)];
        final updated = await addOrderItems(open.id!, merged);
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
      item.station.trim();

  String _stationFor(OrderItem item, Map<int, String> byItemId) =>
      byItemId[_itemKey(item)] ?? _ownStation(item);

  /// The tickets a bill prints: one per station, and one more for each
  /// take-away section the table added on, so a bag's ticket never mixes with
  /// the table's.
  Future<List<({String station, String section, String text})>> ticketSheets(
    Order order,
  ) async {
    final plan = await _stationPlan(order);
    final sheets = <String, ({String station, String section})>{};
    for (final item in order.items) {
      final station = _stationFor(item, plan.byItemId);
      // An item the portal left without a station prints nowhere: no ticket is
      // queued for it (a bottled drink, say, that the kitchen never makes).
      if (station.trim().isEmpty) continue;
      sheets['$station\u0000${item.section}'] =
          (station: station, section: item.section);
    }
    return [
      for (final sheet in sheets.values)
        (
          station: sheet.station,
          section: sheet.section,
          text: _ticketPayload(sheet.station, order, plan,
              section: sheet.section),
        ),
    ];
  }

  Future<void> sendStationTickets(Order order) async {
    for (final sheet in await ticketSheets(order)) {
      await _db.enqueue(sheet.station, '', sheet.text);
    }
    // Printing runs in the background: awaiting it would keep the caller (and
    // the UI, or the waiter's HTTP request) waiting for every Bluetooth ticket
    // plus the per-printer cooldown.
    _kickPrinter();
  }

  /// Queues one ticket on its own — the preview's per-ticket print.
  Future<void> sendStationTicket(
    Order order,
    String station,
    String section,
  ) async {
    // Nothing to send for an item with no station.
    if (station.trim().isEmpty) return;
    final plan = await _stationPlan(order);
    await _db.enqueue(
      station,
      '',
      _ticketPayload(station, order, plan, section: section),
    );
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
    List<Map<String, dynamic>> covers = const [],
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
      // An explicit charge — the items a part payment covers. Cash handed over
      // above it is change, not money taken.
      value = _round2(amount);
      if (method == 'cash') {
        final handed = _round2(tendered);
        if (handed > value + 0.0001) change = _round2(handed - value);
      }
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
      // The snapshot lets this payment's receipt be previewed or reprinted
      // later, item by item.
      itemsJson: covers.isEmpty ? '' : jsonEncode(covers),
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
      for (final item in items)
        // An item the portal left without a station prints nowhere: it is on
        // the bill and the receipt, but nothing is queued for the kitchen.
        if (_stationFor(item, plan.byItemId).trim().isNotEmpty)
          _stationFor(item, plan.byItemId),
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
                'section': item.section,
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

  /// The items one payment covered, from the snapshot stored with it.
  List<Map<String, dynamic>> _coveredItems(Map<String, dynamic> payment) {
    final raw = (payment['items'] ?? '').toString();
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map) Map<String, dynamic>.from(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The receipt for one payment of a bill: the items it covered and its own
  /// totals — subtotal, total, cash tendered and change.
  Future<String> paymentPreview(Order order, int index) async {
    final payments = order.id == null
        ? const <Map<String, dynamic>>[]
        : await _db.getOrderPayments(order.id!);
    if (index < 0 || index >= payments.length) return '';
    final payment = payments[index];
    String money(Object? value) =>
        ((value as num?) ?? 0).toDouble().toStringAsFixed(2);

    final tendered = ((payment['tendered'] as num?) ?? 0).toDouble();
    final change = ((payment['change_due'] as num?) ?? 0).toDouble();
    final covered = _coveredItems(payment);
    var subtotal = 0.0;
    for (final item in covered) {
      subtotal += ((item['line'] as num?) ?? 0).toDouble();
    }
    const width = 32;
    String row(String left, String right) {
      final space = width - right.length - left.length;
      return space > 0 ? '$left${' ' * space}$right' : '$left $right';
    }

    // The same item shape as the bill receipt: each add-on nested under its
    // item, and every line priced.
    final items = <String>[];
    var number = 0;
    for (final item in covered) {
      final name = (item['name'] ?? '').toString();
      final qty = ((item['qty'] as num?) ?? 1).toInt();
      final price = ((item['price'] as num?) ?? 0).toDouble();
      final line = ((item['line'] as num?) ?? 0).toDouble();
      if (item['addOn'] == true) {
        items.add('    - $name');
        items.add(row('       $qty X ${money(price)}', money(line)));
      } else {
        number += 1;
        items.add('$number. $name');
        items.add(row('   $qty X ${money(price)}', money(line)));
      }
    }
    final lines = <String>[
      _settings.restaurantName.isEmpty ? '' : _settings.restaurantName,
      'ORDER ${order.orderNo}',
      if (order.tableNo.isNotEmpty) 'TABLE ${order.tableNo}',
      _formatDateTime(((payment['created_at'] as num?) ?? 0).toInt()),
      '------------------------------',
      ...items,
      '------------------------------',
      '${'Subtotal'.padRight(20)}${subtotal.toStringAsFixed(2)}',
      '${'Total'.padRight(20)}${money(payment['amount'])}',
      if (tendered > 0) '${'Cash tendered'.padRight(20)}${money(tendered)}',
      if (change > 0) '${'Change'.padRight(20)}${money(change)}',
    ];
    return lines.where((line) => line.isNotEmpty).join('\n');
  }

  /// Queues one payment's receipt — the per-payment Print in History.
  Future<void> printPayment(Order order, int index) async {
    final payments = order.id == null
        ? const <Map<String, dynamic>>[]
        : await _db.getOrderPayments(order.id!);
    if (index < 0 || index >= payments.length) return;
    final payment = payments[index];
    final covered = _coveredItems(payment);
    var subtotal = 0.0;
    for (final item in covered) {
      subtotal += ((item['line'] as num?) ?? 0).toDouble();
    }
    final payload = {
      'restaurantName': _settings.restaurantName,
      'footer': _settings.receiptFooter,
      'currency': _settings.currency,
      'orderNo': order.orderNo,
      'table': order.tableNo,
      'server': order.serverName,
      'channel': order.channel,
      'orderType': order.orderType,
      'when': _formatDateTime(((payment['created_at'] as num?) ?? 0).toInt()),
      'items': covered,
      'subtotal': _round2(subtotal),
      'tax': _round2(((payment['amount'] as num?) ?? 0).toDouble() - subtotal),
      'taxRate': _settings.taxRate,
      'taxInclusive': _settings.taxInclusive,
      'discount': 0,
      'total': ((payment['amount'] as num?) ?? 0).toDouble(),
      'balance': 0,
      'payment': (payment['method'] ?? 'cash').toString(),
      'tendered': ((payment['tendered'] as num?) ?? 0).toDouble(),
      'change': ((payment['change_due'] as num?) ?? 0).toDouble(),
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
      // Split bill: every tender, each with the change it gave back.
      for (final payment in payments) {
        final method = (payment['method'] ?? '').toString();
        final tendered = ((payment['tendered'] as num?) ?? 0).toDouble();
        final paid = ((payment['amount'] as num?) ?? 0).toDouble();
        lines.add(row(
          methodLabel(method),
          '$currency${money(method == 'cash' && tendered > 0 ? tendered : paid)}',
        ));
        final change = ((payment['change_due'] as num?) ?? 0).toDouble();
        if (change > 0) {
          lines.add(row('Change', '$currency${money(change)}'));
        }
      }
    } else if (payments.length == 1) {
      final payment = payments.first;
      final method = (payment['method'] ?? '').toString();
      lines.add(row(
          methodLabel(method),
          '$currency${money(((payment['tendered'] as num?) ?? 0).toDouble())}'));
      final change = ((payment['change_due'] as num?) ?? 0).toDouble();
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
    ({Map<int, String> byItemId, Map<String, Product> bySku}) plan, {
    String section = '',
  }) {
    final bySku = plan.bySku;
    final sb = StringBuffer();
    final takeAway = order.orderType == 'take_away';
    const rule = '------------------------------';

    // A take-away rung up for a table joins that table's bill as its own
    // section (`TA - 009`) and prints as its own take-away ticket, with the
    // table it came from. Its order line carries the TA number, the same as the
    // section shown on the bill.
    final takeAwayNo = order.orderType == 'take_away'
        ? order.takeAwayNo
        : section.replaceFirst('TA - ', '').trim();
    final isTakeAway = takeAway || takeAwayNo.isNotEmpty;

    if (isTakeAway) {
      sb.writeln('ORDER - TA - $takeAwayNo');
      sb.writeln('TABLE - TAKE AWAY'
          '${order.tableNo.isEmpty ? '' : '  (table ${order.tableNo})'}');
    } else {
      sb.writeln('ORDER - ${order.orderNo}');
      sb.writeln(
        'TABLE - ${order.tableNo.isEmpty ? 'No table' : order.tableNo}',
      );
    }
    sb.writeln(rule);

    final onStation = order.items
        .where((item) =>
            _stationFor(item, plan.byItemId) == station &&
            item.section == section)
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
    // The tender rows are the source of truth: cash shows what was handed over
    // and what was given back, summed across every payment — an order's own
    // columns only hold the last tender once a bill is split, which made a
    // split bill's receipt show the wrong cash and change.
    var tenderedOut = 0.0;
    var changeOut = 0.0;
    for (final payment in payments) {
      if ((payment['method'] ?? '').toString() == 'cash') {
        tenderedOut += ((payment['tendered'] as num?) ?? 0).toDouble();
      }
      changeOut += ((payment['change_due'] as num?) ?? 0).toDouble();
    }
    if (payments.isEmpty) {
      tenderedOut = order.tendered;
      changeOut = order.changeDue;
    }
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
                'section': i.section,
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
