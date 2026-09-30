import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/screens/orders_screen.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// The counter's open order list: bills are ordered by table number and the
/// search box picks a table, so a cashier can find a bill without scrolling.
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

    for (final order in const [
      Order(orderNo: '250930-001-10', tableNo: '10', total: 10),
      Order(orderNo: '250930-002-2', tableNo: '2', total: 2),
      Order(orderNo: '250930-003-1', tableNo: '1', total: 1),
      Order(orderNo: '250930-004-VIP 2', tableNo: 'VIP 2', total: 4),
      Order(
        orderNo: '250930-TA-005',
        orderType: 'take_away',
        total: 5,
      ),
    ]) {
      await db.insertOrder(order);
    }
  });

  /// Lets real (non-fake) async work — SQLite — finish.
  Future<void> settleAsync(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
    }
  }

  /// The table badges of the visible rows, in the order they are shown.
  List<String> badges(WidgetTester tester) => tester
      .widgetList<CircleAvatar>(find.byType(CircleAvatar))
      .map((avatar) => (avatar.child as Text).data!)
      .toList();

  Future<void> openList(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: OrdersScreen())),
    );
    await settleAsync(tester);
  }

  testWidgets('open bills are ordered by table number', (tester) async {
    await openList(tester);

    expect(badges(tester), ['1', '2', '10', 'VIP 2', 'TA'],
        reason: 'tables count like a human counts, take-away last');
  });

  testWidgets('the search box finds a bill by its table number', (tester) async {
    await openList(tester);

    // A number picks that table — not table 10, and never a table-less bill.
    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();
    expect(badges(tester), ['1']);

    // Leading zeros and stray letters still mean the same table.
    await tester.enterText(find.byType(TextField), '002');
    await tester.pump();
    expect(badges(tester), ['2']);

    // Other text is matched loosely.
    await tester.enterText(find.byType(TextField), 'vip');
    await tester.pump();
    expect(badges(tester), ['VIP 2']);

    // No match says so.
    await tester.enterText(find.byType(TextField), '99');
    await tester.pump();
    expect(find.text('No open order for table "99"'), findsOneWidget);

    // Clearing the box brings the whole list back, still ordered.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(badges(tester), ['1', '2', '10', 'VIP 2', 'TA']);
  });

  testWidgets('searching a table of the day never matches the order number',
      (tester) async {
    await openList(tester);

    // Every order number contains the date, so `0930` used to match all bills.
    await tester.enterText(find.byType(TextField), '0930');
    await tester.pump();
    expect(badges(tester), isEmpty);
    expect(find.text('No open order for table "0930"'), findsOneWidget);

    // The list is unmounted so the screen's refresh timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });
}
