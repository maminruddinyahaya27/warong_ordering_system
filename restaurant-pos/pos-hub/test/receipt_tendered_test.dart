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
}
