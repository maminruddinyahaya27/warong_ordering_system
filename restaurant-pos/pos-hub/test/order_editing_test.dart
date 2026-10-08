import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// Exercises the real SQLite persistence behind order editing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PrintQueueDb.overridePath = inMemoryDatabasePath;
    // Start from an empty database for every run.
    final db = await PrintQueueDb.instance.database;
    await db.delete('order_items');
    await db.delete('orders');
  });

  OrderItem line(String name, double price, int qty) => OrderItem(
        name: name,
        qty: qty,
        unitPrice: price,
        lineTotal: price * qty,
        station: 'Kitchen',
      );

  test('adding, changing and removing lines recomputes totals', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'waiter',
      tableNo: '12',
      serverName: 'Aina',
      items: [line('Roti Kosong', 1.5, 2)],
    );

    // 2 x 1.50 = 3.00, +10% tax = 0.30
    expect(order.subtotal, closeTo(3.00, 0.001));
    expect(order.tax, closeTo(0.30, 0.001));
    expect(order.total, closeTo(3.30, 0.001));

    // Add a line: + 1 x 9.00
    final added = await cashier.addOrderItems(order.id!, [line('Nasi Lemak Ayam', 9.0, 1)]);
    expect(added.items.length, 2);
    expect(added.subtotal, closeTo(12.00, 0.001));
    expect(added.total, closeTo(13.20, 0.001));

    // Increase the first line to 3: +1.50
    final firstItem = added.items.firstWhere((item) => item.name == 'Roti Kosong');
    final increased = await cashier.setOrderItemQty(order.id!, firstItem.id!, 3);
    expect(increased.subtotal, closeTo(13.50, 0.001));
    expect(increased.total, closeTo(14.85, 0.001));

    // Decrease back to 1: -3.00
    final decreased = await cashier.setOrderItemQty(order.id!, firstItem.id!, 1);
    expect(decreased.subtotal, closeTo(10.50, 0.001));

    // Remove the added line entirely.
    final secondItem =
        decreased.items.firstWhere((item) => item.name == 'Nasi Lemak Ayam');
    final removed = await cashier.setOrderItemQty(order.id!, secondItem.id!, 0);
    expect(removed.items.length, 1);
    expect(removed.subtotal, closeTo(1.50, 0.001));
    expect(removed.total, closeTo(1.65, 0.001));

    // The persisted order matches what was returned.
    final stored = await db.getOrder(order.id!);
    expect(stored!.items.length, 1);
    expect(stored.total, closeTo(1.65, 0.001));
  });

  test('removing the last line is refused', () async {
    final cashier = CashierService.instance;
    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '3',
      items: [line('Teh O (Panas)', 2.0, 1)],
    );
    final only = order.items.first;
    expect(only.id, isNotNull);
    await expectLater(
      cashier.setOrderItemQty(order.id!, only.id!, 0),
      throwsA(isA<Exception>()),
    );
  });

  test('paid orders cannot be edited', () async {
    final cashier = CashierService.instance;
    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '9',
      items: [line('Kopi O (Panas)', 1.5, 2)],
    );
    final item = order.items.first;
    await cashier.payOrder(order.id!, method: 'cash', tendered: 10);

    await expectLater(
      cashier.setOrderItemQty(order.id!, item.id!, 5),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      cashier.addOrderItems(order.id!, [line('Milo (Panas)', 3.0, 1)]),
      throwsA(isA<Exception>()),
    );
  });

  test('kitchen tickets show the order number and the table',
      () async {
    final db = PrintQueueDb.instance;
    await db.clear();

    final cashier = CashierService.instance;
    final order = await cashier.createOrder(
      channel: 'waiter',
      tableNo: '12',
      serverName: 'Aina',
      items: [line('Roti Kosong', 1.5, 2)],
    );

    final jobs = await db.getAllJobs();
    expect(jobs, hasLength(1));
    final payload = jobs.first.payload;
    expect(payload, contains('ORDER - ${order.orderNo}'));
    expect(payload, contains('TABLE - 12'));
  });

  test('take away is marked on the ticket and the receipt', () async {
    final db = PrintQueueDb.instance;
    await db.clear();

    final cashier = CashierService.instance;
    final order = await cashier.createOrder(
      channel: 'counter',
      orderType: 'take_away',
      items: [line('Nasi Lemak Ayam', 9.0, 1)],
    );

    expect(order.orderType, 'take_away');

    final jobs = await db.getAllJobs();
    expect(jobs, isNotEmpty, reason: 'creating an order queues its tickets');
    // A take-away ticket identifies itself by its TA number, the same as the
    // section the bill shows.
    final sheets = await CashierService.instance.ticketSheets(order);
    expect(sheets, isNotEmpty);
    expect(sheets.first.text, contains('ORDER - TA - ${order.takeAwayNo}'));
    expect(sheets.first.text, contains('TABLE - TAKE AWAY'));
    expect(order.orderNo, endsWith('-TA-${order.takeAwayNo}'));
    expect(order.takeAwayLabel, 'TA - ${order.takeAwayNo}');

    final preview = await cashier.receiptPreview(order);
    expect(preview, contains('TAKE AWAY'));
    expect(preview, contains(order.orderNo));

    // Round-trips through SQLite.
    final stored = await db.getOrder(order.id!);
    expect(stored!.orderType, 'take_away');
  });

  test('dine-in is the default and prints as such on the receipt', () async {
    final cashier = CashierService.instance;
    final order = await cashier.createOrder(
      channel: 'waiter',
      tableNo: '5',
      items: [line('Teh O (Panas)', 2.0, 1)],
    );
    expect(order.orderType, 'dine_in');
    expect(await cashier.receiptPreview(order), contains('Dine-in'));
  });

  test('dine-in orders require a table number', () async {
    final cashier = CashierService.instance;
    await expectLater(
      cashier.createOrder(channel: 'counter', items: [line('Teh O', 2.0, 1)]),
      throwsA(isA<Exception>()),
    );
    // Take away is fine without a table, and gets a TA-prefixed number.
    final takeaway = await cashier.createOrder(
      channel: 'counter',
      orderType: 'take_away',
      items: [line('Teh O', 2.0, 1)],
    );
    expect(takeaway.orderNo, matches(RegExp(r'^\d{6}-TA-\d{3}$')));
  });

  test('order numbers are YYMMDD-NNN-table', () async {
    final cashier = CashierService.instance;
    final first = await cashier.createOrder(
      channel: 'counter',
      tableNo: '12',
      items: [line('Roti Kosong', 1.5, 1)],
    );
    expect(first.orderNo, matches(RegExp(r'^\d{6}-\d{3}-12$')));

    final second = await cashier.createOrder(
      channel: 'counter',
      tableNo: '7',
      items: [line('Roti Telur', 3.0, 1)],
    );
    expect(second.orderNo, matches(RegExp(r'^\d{6}-\d{3}-7$')));

    final firstRunning = int.parse(first.orderNo.split('-')[1]);
    final secondRunning = int.parse(second.orderNo.split('-')[1]);
    expect(secondRunning, firstRunning + 1);
    expect(first.orderNo.split('-').first, second.orderNo.split('-').first);
  });

  test('the running number starts again on a new date', () async {
    final cashier = CashierService.instance;

    // Two orders on the 5th (a date no other test numbers against)…
    final first = await cashier.createOrder(
      channel: 'counter',
      tableNo: '3',
      items: [line('Roti Kosong', 1.5, 1)],
      at: DateTime(2026, 1, 5, 23, 50),
    );
    final second = await cashier.createOrder(
      channel: 'counter',
      tableNo: '3',
      items: [line('Roti Telur', 3.0, 1)],
      at: DateTime(2026, 1, 5, 23, 55),
    );
    expect(first.orderNo, '260105-001-3');
    expect(second.orderNo, '260105-002-3');

    // …and the first order of the 6th starts that day over at 001.
    final next = await cashier.createOrder(
      channel: 'counter',
      tableNo: '3',
      items: [line('Roti Kosong', 1.5, 1)],
      at: DateTime(2026, 1, 6, 0, 5),
    );
    expect(next.orderNo, '260106-001-3',
        reason: 'a new date restarts the daily running number');
  });

  test('a second dine-in order for the same table joins the open bill',      () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final first = await cashier.createOrder(
      channel: 'waiter',
      tableNo: '6',
      items: [line('Roti Kosong', 1.5, 2)],
    );

    // Another round for the same table — same bill, no new order number.
    final second = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '6',
      items: [line('Teh Tarik (Panas)', 2.5, 1)],
    );
    expect(second.merged, isTrue);
    expect(second.order.id, first.id);
    expect(second.order.orderNo, first.orderNo);
    expect(second.order.items.length, 2);
    expect(second.order.subtotal, closeTo(5.50, 0.001));

    // Only one open order for that table exists.
    final open = await db.getOrders(status: 'OPEN');
    final forTable = open.where((order) => order.tableNo == '6').toList();
    expect(forTable, hasLength(1));
    expect(forTable.first.items.length, 2);

    // Closing the bill pays everything on one receipt.
    final paid = await cashier.payOrder(first.id!, method: 'cash', tendered: 10);
    expect(paid.status, 'PAID');
    expect(paid.items.length, 2);
    expect(paid.total, closeTo(6.05, 0.001));
  });

  test('take-away orders never merge, and a new day bill starts fresh',
      () async {
    final cashier = CashierService.instance;

    final first = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      items: [line('Teh O', 2.0, 1)],
    );
    final second = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      items: [line('Teh O', 2.0, 1)],
    );
    expect(first.merged, isFalse);
    expect(second.merged, isFalse);
    expect(second.order.id, isNot(first.order.id));

    // A dine-in bill for a different table is its own order too.
    final tableA = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '21',
      items: [line('Roti Telur', 3.0, 1)],
    );
    final tableB = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '22',
      items: [line('Roti Telur', 3.0, 1)],
    );
    expect(tableA.merged, isFalse);
    expect(tableB.merged, isFalse);
    expect(tableA.order.id, isNot(tableB.order.id));
  });

  test('a take-away with a table joins that table\'s open bill', () async {
    final cashier = CashierService.instance;

    // The table is already eating.
    final dining = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '51',
      items: [line('Roti Telur', 3.0, 1)],
    );
    expect(dining.merged, isFalse);

    // The table adds something to take home: it lands on the same bill.
    final takeAway = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '51',
      items: [line('Teh O', 2.0, 2)],
    );
    expect(takeAway.merged, isTrue,
        reason: 'a take-away for the table joins its open bill');
    expect(takeAway.order.id, dining.order.id);
    expect(takeAway.order.items.length, 2);
    expect(takeAway.order.tableNo, '51');

    // The take-away lines carry their own TA number, so the bill rules them off
    // from the table's own lines.
    final dineInLines =
        takeAway.order.items.where((item) => item.section.isEmpty).toList();
    final taLines =
        takeAway.order.items.where((item) => item.section.isNotEmpty).toList();
    expect(dineInLines.length, 1, reason: 'the table keeps its own line');
    expect(taLines.length, 1, reason: 'the take-away is its own section');
    expect(taLines.single.section, startsWith('TA - '));

    // The kitchen ticket for those lines prints as take-away, with the table it
    // came from, so the pass knows to pack it.
    final taNo = taLines.single.section.replaceFirst('TA - ', '');
    final sheets = await CashierService.instance.ticketSheets(takeAway.order);
    final taSheet = sheets.firstWhere((sheet) => sheet.section.isNotEmpty,
        orElse: () => (station: '', section: '', text: ''));
    final ticket = taSheet.text;
    expect(ticket, contains('ORDER - TA - $taNo'),
        reason: 'the merged ticket carries the take-away number');
    expect(ticket, contains('TABLE - TAKE AWAY'),
        reason: 'a merged take-away prints as take-away');
    expect(ticket, contains('(table 51)'),
        reason: 'and names the table it was rung up for');

    // A take-away with no table number keeps its own TA bill.
    final bag = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      items: [line('Teh O', 2.0, 1)],
    );
    expect(bag.merged, isFalse);
    expect(bag.order.id, isNot(dining.order.id));
  });

  test('clearing history wipes the orders, their lines and the payments',
      () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '77',
      items: [line('Roti Kosong', 1.5, 1)],
    );
    await cashier.addPayment(order.id!, method: 'cash', tendered: 2.0);
    expect(await db.getOrders(), isNotEmpty);

    await db.clearTransactions();

    expect(await db.getOrders(), isEmpty);
    expect(await db.getOrder(order.id!), isNull);
    expect(await db.paidTotal(order.id!), 0);
  });

  test('a trading day summarises its takings between start and end', () async {
    final cashier = CashierService.instance;

    // Make sure no day is left open from another test.
    final open = await cashier.activeDay();
    if (open != null) await cashier.closeDay(by: 'test');

    await cashier.openDay(by: 'test');
    expect(await cashier.activeDay(), isNotNull);

    final order = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '4',
      items: [line('Nasi Lemak Ayam', 9.0, 1)],
    );
    await cashier.payOrder(order.order.id!, method: 'cash', tendered: 20);

    final summary = await cashier.closeDay(by: 'test');
    expect(summary['orders'], greaterThanOrEqualTo(1));
    expect(summary['sales'], greaterThanOrEqualTo(9.0));
    expect(summary['cash'], greaterThanOrEqualTo(9.0));
    expect(await cashier.activeDay(), isNull);
  });

  test('a bill can be split across several payments', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '8',
      items: [line('Nasi Lemak Ayam', 9.0, 1)],
    );
    expect(order.total, closeTo(9.90, 0.001));
    expect(order.paid, 0);
    expect(order.isSettled, isFalse);

    // First person pays cash 5.00 — the bill stays open.
    final part =
        await cashier.addPayment(order.id!, method: 'cash', tendered: 5.0);
    expect(part.status, 'OPEN');
    expect(part.paid, closeTo(5.00, 0.001));
    expect(part.balance, closeTo(4.90, 0.001));

    // Second person clears the rest by card.
    final settled = await cashier.addPayment(order.id!, method: 'card');
    expect(settled.status, 'PAID');
    expect(settled.paid, closeTo(9.90, 0.001));
    expect(settled.balance, 0);
    expect(settled.paymentMethod, 'split', reason: 'summary for mixed tenders');

    final tenders = await db.getOrderPayments(order.id!);
    expect(tenders, hasLength(2));
    expect(tenders.first['method'], 'cash');
    expect(tenders.last['method'], 'card');

    // The receipt lists both tenders.
    final preview = await cashier.receiptPreview(settled);
    expect(preview, contains('Cash'));
    expect(preview, contains('Card'));
    expect(preview, contains('Total'));
  });

  test('the day report counts mixed tenders by method', () async {
    final cashier = CashierService.instance;

    final open = await cashier.activeDay();
    if (open != null) await cashier.closeDay(by: 'test');
    await cashier.openDay(by: 'test');

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '9',
      items: [line('Roti Kosong', 1.5, 2)],
    );
    expect(order.total, closeTo(3.30, 0.001));

    await cashier.addPayment(order.id!, method: 'cash', tendered: 2.0);
    await cashier.addPayment(order.id!, method: 'ewallet');

    final summary = await cashier.closeDay(by: 'test');
    expect(summary['cash'], greaterThanOrEqualTo(2.0));
    expect(summary['ewallet'], greaterThanOrEqualTo(1.30));
    expect(summary['sales'], greaterThanOrEqualTo(3.30));
  });

  test('a part-paid bill cannot be voided', () async {    final cashier = CashierService.instance;
    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '11',
      items: [line('Teh O (Panas)', 2.0, 1)],
    );
    await cashier.addPayment(order.id!, method: 'cash', tendered: 1.0);

    await expectLater(
      cashier.voidOrder(order.id!),
      throwsA(isA<Exception>()),
      reason: 'money has been taken — refund rather than void',
    );
  });

  test('a retried send does not create a second order', () async {
    final cashier = CashierService.instance;

    final first = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '31',
      idempotencyKey: 'retry-1',
      items: [line('Roti Kosong', 1.5, 2)],
    );
    expect(first.duplicate, isFalse);

    // Same retry key: the original order comes back, nothing new is created.
    final again = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '31',
      idempotencyKey: 'retry-1',
      items: [line('Roti Kosong', 1.5, 2)],
    );
    expect(again.duplicate, isTrue);
    expect(again.order.id, first.order.id);
    // One line of two, not the line added twice.
    expect(again.order.items, hasLength(1));
    expect(again.order.items.first.qty, 2);

    final open = await PrintQueueDb.instance.getOrders(status: 'OPEN');
    expect(open.where((order) => order.tableNo == '31'), hasLength(1));
  });

  test('a retried merge does not add the items twice', () async {
    final cashier = CashierService.instance;

    final bill = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '32',
      items: [line('Teh O (Panas)', 2.0, 1)],
    );
    expect(bill.merged, isFalse);

    final round = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '32',
      idempotencyKey: 'round-1',
      items: [line('Roti Telur', 3.0, 1)],
    );
    expect(round.merged, isTrue);
    expect(round.order.items.length, 2);

    // Retrying the same round must not append it again.
    final retry = await cashier.createOrAppendOrder(
      channel: 'waiter',
      tableNo: '32',
      idempotencyKey: 'round-1',
      items: [line('Roti Telur', 3.0, 1)],
    );
    expect(retry.duplicate, isTrue);
    expect(retry.order.id, round.order.id);
    expect(retry.order.items.length, 2);
  });
}
