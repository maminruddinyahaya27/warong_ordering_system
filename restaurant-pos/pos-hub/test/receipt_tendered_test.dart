import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/services/app_settings.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// Regression: a cash receipt must print what the customer handed over
/// (e.g. 30.00 on a 24.20 bill) plus the change — not the amount charged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PrintQueueDb.overridePath = inMemoryDatabasePath;
  });

  setUp(() async {
    final db = await PrintQueueDb.instance.database;
    await db.delete('order_items');
    await db.delete('orders');
    await db.delete('order_payments');
    await SettingsStore.instance.load();
  });

  OrderItem line(String name, double price, int qty) => OrderItem(
        name: name,
        qty: qty,
        unitPrice: price,
        lineTotal: price * qty,
        station: 'Kitchen',
      );

  test('cash receipt shows the amount tendered and the change', () async {
    final cashier = CashierService.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '5',
      items: [
        line('Nasi Lemak Ayam', 9.0, 2),
        line('Teh Tarik', 2.0, 2),
      ],
    );
    // 2 x 9.00 + 2 x 2.00 = 22.00, +10% tax = 24.20
    expect(order.total, closeTo(24.20, 0.001));

    final settled =
        await cashier.addPayment(order.id!, method: 'cash', tendered: 30);

    expect(settled.status, 'PAID');
    expect(settled.tendered, closeTo(30.00, 0.001),
        reason: 'order stores what the customer handed over');
    expect(settled.changeDue, closeTo(5.80, 0.001));

    final receipt = await cashier.receiptPreview(settled);
    expect(receipt, contains('Cash'));
    expect(receipt, contains('30.00'), reason: 'cash line shows the handover');
    expect(receipt, contains('Change'));
    expect(receipt, contains('5.80'));
    expect(receipt, contains('24.20'), reason: 'TOTAL stays the amount charged');
  });

  test('a cash payment with no over-tender still prints the amount', () async {
    final cashier = CashierService.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '6',
      items: [line('Roti Kosong', 2.0, 1)],
    );
    // 2.00 + 0.20 tax = 2.20
    final settled =
        await cashier.addPayment(order.id!, method: 'cash', tendered: 2.20);

    expect(settled.tendered, closeTo(2.20, 0.001));
    expect(settled.changeDue, 0);
    final receipt = await cashier.receiptPreview(settled);
    expect(receipt, contains('Cash'));
    expect(receipt, contains('2.20'));
    expect(receipt, isNot(contains('Change')));
  });

  test('a part payment leaves a balance and keeps the bill open', () async {
    final cashier = CashierService.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '7',
      items: [line('Nasi Lemak Ayam', 10.0, 2)],
    );
    // 20.00 + 2.00 tax = 22.00
    expect(order.total, closeTo(22.00, 0.001));

    // Card for part of the bill.
    final part = await cashier.addPayment(order.id!, method: 'card', amount: 5.0);
    expect(part.isSettled, isFalse);
    expect(part.paid, closeTo(5.0, 0.001));
    expect(part.balance, closeTo(17.0, 0.001));

    // Cash for less than the balance is also a part payment.
    final partTwo =
        await cashier.addPayment(order.id!, method: 'cash', tendered: 10.0);
    expect(partTwo.isSettled, isFalse);
    expect(partTwo.paid, closeTo(15.0, 0.001));
    expect(partTwo.balance, closeTo(7.0, 0.001));

    // The rest settles it.
    final settled = await cashier.addPayment(
      order.id!,
      method: 'cash',
      tendered: 7.0,
    );
    expect(settled.isSettled, isTrue);
    expect(settled.balance, closeTo(0, 0.001));
  });

  test('part payment can mark the lines it covered as paid', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '8',
      items: [
        line('Roti Kosong', 1.5, 1),
        line('Kari Kambing', 8.0, 1),
        line('Teh O (Panas)', 2.0, 1),
      ],
    );

    // Pay the first line, marking just that one.
    final first = order.items.first;
    expect(first.id, isNotNull);
    await db.markOrderItemsPaid(order.id!, [first.id!]);

    final afterFirst = (await db.getOrder(order.id!))!;
    expect(afterFirst.items.first.paid, isTrue);
    expect(afterFirst.items[1].paid, isFalse);

    // Settling the rest marks everything.
    await db.markAllOrderItemsPaid(order.id!);
    final all = (await db.getOrder(order.id!))!;
    expect(all.items.every((item) => item.paid), isTrue);
  });

  test('change from an over-tendered part payment is not taken as paid',
      () async {
    // One table bill, paid in rounds by three customers.
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '1',
      items: [
        line('Nasi Lemak', 4.0, 1),
        line('Ais Kosong', 0.8, 1),
        line('Nasi Lemak + Lauk', 4.0, 1),
        line('Rendang Daging', 5.0, 1),
        line('Nasi Lemak', 4.0, 1),
      ],
    );
    expect(order.subtotal, closeTo(17.8, 0.001));

    // Customer 1: their items are RM4.80, they hand RM5 and keep the 20 sen.
    final first = await cashier.addPayment(order.id!,
        method: 'cash', amount: 4.8, tendered: 5.0);
    expect(first.paid, closeTo(4.8, 0.001),
        reason: 'only the RM4.80 charged is taken');

    // Customer 2: their items are RM9.00, they hand RM10.
    final second = await cashier.addPayment(order.id!,
        method: 'cash', amount: 9.0, tendered: 10.0);
    expect(second.paid, closeTo(13.8, 0.001),
        reason: 'the RM1 change is not taken either');

    // Customer 3 owes their own RM4.00 — not RM4.00 minus the two changes.
    expect(second.balance, greaterThan(4.0),
        reason: 'the RM1.20 of change was not banked as paid');
    expect(await db.paidTotal(order.id!), closeTo(13.8, 0.001));
  });

  test('a split bill receipt lists every tender with its own change', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '2',
      items: [
        line('Nasi Lemak', 4.0, 1),
        line('Ais Kosong', 0.8, 1),
        line('Roti Canai', 2.0, 1),
      ],
    );

    // The customer's share is RM4.80 and they hand RM5; the rest goes on
    // e-wallet.
    final afterCash = await cashier.addPayment(order.id!,
        method: 'cash', amount: 4.8, tendered: 5.0);
    await cashier.addPayment(order.id!,
        method: 'ewallet', amount: afterCash.balance);

    final paid = (await db.getOrder(order.id!))!;
    final preview = await cashier.receiptPreview(paid);

    expect(preview, contains('Cash'));
    expect(preview, contains('5.00'),
        reason: 'what was handed over, not the RM4.80 charged');
    expect(preview, contains('0.20'), reason: 'the change on that tender');
    expect(preview, contains('E-Wallet'),
        reason: 'every tender is listed, not just the last');
  });

  test('a split bill reports how many payments it took', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '2',
      items: [line('Nasi Lemak', 4.0, 1), line('Roti Canai', 2.0, 1)],
    );
    await cashier.addPayment(order.id!,
        method: 'cash', amount: 4.0, tendered: 5.0);
    final afterCash = (await db.getOrder(order.id!))!;
    await cashier.addPayment(order.id!,
        method: 'ewallet', amount: afterCash.balance);

    expect(await db.paymentCounts(), {order.id!: 2},
        reason: 'the history screen shows Payments (2) for it');
  });

  test('a payment receipt lists only the items that payment covered',
      () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '2',
      items: [line('Nasi Lemak', 4.0, 1), line('Roti Canai', 2.0, 1)],
    );
    await cashier.addPayment(
      order.id!,
      method: 'cash',
      amount: 4.0,
      tendered: 5.0,
      covers: const [
        {
          'name': 'Nasi Lemak',
          'qty': 1,
          'price': 4.0,
          'line': 4.0,
          'addOn': false,
        },
      ],
    );

    final preview = await cashier.paymentPreview(
        (await db.getOrder(order.id!))!, 0);

    expect(preview, contains('Nasi Lemak'));
    expect(preview, isNot(contains('Roti Canai')),
        reason: 'the other item belongs to another payment');
    expect(preview, contains('Subtotal'));
    expect(preview, contains('Total'));
    expect(preview, contains('Cash tendered'));
    expect(preview, contains('5.00'));
    expect(preview, contains('Change'));
    expect(preview, isNot(contains('Balance')));
    expect(preview, isNot(contains('Paid so far')));
    expect(preview, isNot(contains('Payment 1 of')),
        reason: 'the payment number is not printed');
  });

  test('a full payment receipt lists the whole bill', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '3',
      items: [line('Nasi Lemak', 4.0, 1), line('Roti Canai', 2.0, 1)],
    );

    // A full payment snapshots the whole bill, exactly as the till does.
    await cashier.addPayment(
      order.id!,
      method: 'cash',
      amount: order.balance,
      tendered: order.balance,
      covers: [
        for (final item in order.items)
          {
            'name': item.name,
            'qty': item.qty,
            'price': item.unitPrice,
            'line': item.lineTotal,
            'addOn': false,
          },
      ],
    );

    final preview = await cashier.paymentPreview(
        (await db.getOrder(order.id!))!, 0);

    expect(preview, contains('Nasi Lemak'));
    expect(preview, contains('Roti Canai'),
        reason: 'a full payment covers the whole bill');
    expect(preview, contains('4.00'));
    expect(preview, contains('2.00'));
  });

  test('a cancelled payment counts as no money taken', () async {
    final cashier = CashierService.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '9',
      items: [line('Roti Kosong', 1.5, 1)],
    );

    // Backing out of the payment dialog leaves the order unchanged: the items
    // picked for this round must not be marked paid.
    expect(CashierService.tookPayment(order, order), isFalse);

    // A real part payment does count.
    final part =
        await cashier.addPayment(order.id!, method: 'cash', tendered: 1.0);
    expect(CashierService.tookPayment(order, part), isTrue);
    expect(part.balance, greaterThan(0));
  });

  test('paying one of two plates splits the line into a paid one', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '4',
      items: [line('Nasi Lemak Biasa', 4.0, 2)],
    );
    final whole = order.items.single;
    expect(whole.qty, 2);

    // Pay one plate of the two.
    await cashier.recordPartPayment(order, {whole.id!: 1});

    final after = (await db.getOrder(order.id!))!;
    expect(after.items.length, 2, reason: 'the paid plate is its own line');
    final paid = after.items.where((item) => item.paid).toList();
    final open = after.items.where((item) => !item.paid).toList();
    expect(paid.single.qty, 1, reason: 'the paid plate is slashed on its own');
    expect(open.single.qty, 1, reason: 'the other plate stays open');
    expect(after.items.fold<double>(0, (sum, i) => sum + i.qty), 2,
        reason: 'no plate is lost or duplicated');
  });

  test('a part payment receipt lists only the items paid', () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '10',
      items: [
        line('Roti Kosong', 1.5, 1),
        line('Kari Kambing', 8.0, 1),
        line('Teh O (Panas)', 2.0, 1),
      ],
    );

    final first = order.items.first;
    await cashier.printPartialReceipt(order, [first.id!], 1.65);

    final jobs = await db.getAllJobs();
    final receipt = jobs.firstWhere((job) => job.kind == 'receipt');
    expect(receipt.payload, contains('Roti Kosong'));
    expect(receipt.payload, isNot(contains('Kari Kambing')),
        reason: 'only what the customer paid this round');
    expect(receipt.payload, isNot(contains('Teh O')));
    expect(receipt.payload, contains('"balance"'));
  });

  // Kept last: it changes the stored tax rate for the rest of the file.
  test('a partial receipt carries no tax when the rate is zero', () async {
    await SettingsStore.instance.save({'tax_rate': '0'});
    await SettingsStore.instance.load();

    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '11',
      items: [line('Roti Kosong', 1.5, 2)],
    );
    // No tax configured anywhere in the restaurant.
    expect(order.tax, 0);

    final first = order.items.first;
    await cashier.printPartialReceipt(order, [first.id!], first.lineTotal);

    final receipt =
        (await db.getAllJobs()).firstWhere((job) => job.kind == 'receipt');
    final payload = jsonDecode(receipt.payload) as Map<String, dynamic>;
    expect(payload['tax'], 0);
    expect(payload['subtotal'], closeTo(3.0, 0.001));
    expect(payload['total'], closeTo(3.0, 0.001));
  });
}
