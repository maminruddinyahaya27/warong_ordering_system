import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:waiter_staff/main.dart';
import 'package:waiter_staff/models/menu_item.dart';
import 'package:waiter_staff/models/order_record.dart';
import 'package:waiter_staff/services/order_history.dart';

void main() {
  test('menu item parses from JSON with station', () {
    final item = MenuItem.fromJson({
      'name': 'Grilled Burger',
      'station': 'GRIDDLE',
      'price': 9.99,
      'category': 'Food',
    });
    expect(item.name, 'Grilled Burger');
    expect(item.station, 'GRIDDLE');
    expect(item.price, 9.99);
  });

  test('menu item defaults station to KITCHEN when missing', () {
    final item = MenuItem.fromJson({'name': 'Pizza'});
    expect(item.station, 'KITCHEN');
  });

  test('menu item reads group colour and availability', () {
    final item = MenuItem.fromJson({
      'name': 'Teh O (Panas)',
      'station': 'Beverage',
      'category': 'Minuman',
      'color': '#1565C0',
      'available': false,
    });
    expect(item.color, '#1565C0');
    expect(item.category, 'Minuman');
    expect(item.available, false);
  });

  test('history splits queued orders from sent ones', () async {
    SharedPreferences.setMockInitialValues({});
    await OrderHistory.clear();

    // A sent order.
    await OrderHistory.add(const OrderRecord(
      id: 'a',
      orderNo: '260925-001-5',
      table: '5',
      server: 'Aina',
      createdAt: 1,
      items: [
        {'name': 'Teh O (Panas)', 'qty': 2, 'price': 2.0, 'station': 'Beverage'}
      ],
    ));
    // A send that failed: it waits in the queue, note included.
    await OrderHistory.add(const OrderRecord(
      id: 'b',
      orderType: 'take_away',
      note: 'no chilli',
      createdAt: 2,
      status: 'pending',
      error: 'Host unreachable',
      items: [
        {'name': 'Roti Kosong', 'qty': 1, 'price': 1.5, 'station': 'Griddle'}
      ],
    ));

    final records = await OrderHistory.load();
    expect(records.map((record) => record.id).toList(), ['b', 'a']);

    // Queue holds the pending one, history the sent one.
    expect((await OrderHistory.pending()).map((r) => r.id).toList(), ['b']);
    expect((await OrderHistory.settled()).map((r) => r.id).toList(), ['a']);
    expect((await OrderHistory.pending()).first.note, 'no chilli');
    expect((await OrderHistory.pending()).first.isTakeAway, isTrue);

    // Sending it moves the entry into history.
    await OrderHistory.update(records.first
        .copyWith(status: 'sent', orderNo: '260925-TA-002', error: ''));
    expect(await OrderHistory.pending(), isEmpty);
    expect((await OrderHistory.settled()).first.orderNo, '260925-TA-002');
    expect((await OrderHistory.settled()).first.error, isEmpty);

    // Consolidation: the bill is found by order number, and the queue entry
    // that joined it can be dropped.
    final bill = await OrderHistory.findByOrderNo('260925-001-5');
    expect(bill, isNotNull);
    expect(bill!.table, '5');
    await OrderHistory.remove('b');
    expect((await OrderHistory.load()).map((r) => r.id).toList(), isNot(contains('b')));

    // Round-trips through JSON.
    final restored = OrderRecord.fromJson(bill.toJson());
    expect(restored.orderNo, '260925-001-5');
    expect(restored.itemCount, 2);

    await OrderHistory.clear();
    expect(await OrderHistory.load(), isEmpty);
  });

  testWidgets('v2 layout renders quick picks and the group dropdown',
      (tester) async {
    // Skip the first-run dialogs; no host means the menu fetch fails and the
    // demo menu is used.
    SharedPreferences.setMockInitialValues({
      'waiter_name': 'Tester',
      'host_ip': '127.0.0.1',
    });

    await tester.pumpWidget(const WaiterStaffApp());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    // Search box, quick picks row and the group dropdown are all present.
    expect(find.textContaining('Search all'), findsOneWidget);
    expect(find.text('QUICK PICKS'), findsOneWidget);
    expect(find.text('Menu group'), findsOneWidget);
    expect(find.text('Minuman'), findsWidgets);

    // The first group (portal order) is shown with its items.
    expect(find.text('Teh O (Panas)'), findsWidgets);

    // Tapping a tile adds it to the cart, reflected in the order summary.
    await tester.tap(find.text('Teh O (Panas)').first);
    await tester.pump(const Duration(milliseconds: 200));
    // Every item offers its quantity and a note first.
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('item'), findsWidgets);

    // The dropdown switches the group, like the POS Hub's order page.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Roti Canai').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Roti Canai'), findsWidgets);
  });
}
