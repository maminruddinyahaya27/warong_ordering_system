import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/screens/counter_screen.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// Regression: the Order tab must be ready for the next order immediately
/// after creating one — the cart has to clear.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PrintQueueDb.overridePath = inMemoryDatabasePath;
  });

  setUp(() async {
    final db = PrintQueueDb.instance;
    final raw = await db.database;
    await raw.delete('order_items');
    await raw.delete('orders');
    await raw.delete('jobs');
    await raw.delete('products');
    await db.replaceProducts(const [
      Product(
        sku: 'bv_001',
        name: 'Teh O (Panas)',
        price: 2.0,
        station: 'Beverage',
        category: 'Minuman',
        available: true,
      ),
      Product(
        sku: 'bv_002',
        name: 'Teh Tarik (Panas)',
        price: 2.5,
        station: 'Beverage',
        category: 'Minuman',
        available: true,
      ),
    ]);
  });

  /// Lets real (non-fake) async work — SQLite — finish.
  Future<void> settleAsync(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
    }
  }

  testWidgets('the cart is cleared after Create order', (tester) async {
    final db = PrintQueueDb.instance;

    // Run at the counter tablet's size so the menu grid has room.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CounterScreen())),
    );
    await settleAsync(tester);
    expect(find.text('Teh O (Panas)'), findsWidgets,
        reason: 'cached menu should load');

    await tester.tap(find.text('Teh O (Panas)').first);
    await tester.pump();
    await tester.tap(find.text('Teh Tarik (Panas)').first);
    await tester.pump();
    expect(find.text('1x'), findsNWidgets(2), reason: 'two cart lines');
    expect(find.text('Total RM4.95'), findsOneWidget);

    // Dine-in requires a table.
    await tester.enterText(find.byType(TextField).at(0), '5');
    await tester.pump();

    await tester.tap(find.text('Create order'));
    await tester.pump();
    await settleAsync(tester, 40);

    final orders = await tester.runAsync(() => db.getOrders(status: 'OPEN'));

    // The order exists…
    expect(orders, isNotNull);
    expect(orders!, hasLength(1));
    expect(orders.first.items.length, 2);
    expect(orders.first.tableNo, '5');

    // …and the cart is empty again.
    expect(find.text('1x'), findsNothing, reason: 'cart should be cleared');
    expect(find.text('Total RM0.00'), findsOneWidget);

    // The table field is blank, ready for the next order.
    final tableField = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(tableField.controller?.text, isEmpty,
        reason: 'table number should reset');
  });
}
