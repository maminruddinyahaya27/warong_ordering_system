import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/widgets/partial_picker.dart';

/// The partial-payment list is shaped like the order: one row per ordered line
/// carrying its quantity, with that line's add-ons nested under it.
void main() {
  // Two Capati lines: three plain, then two with a curry — the example the
  // counter works with.
  Order twoCapatiLines({bool secondPaid = false}) => Order(
        orderNo: '251007-001-1',
        tableNo: '1',
        items: [
          const OrderItem(
            id: 1,
            sku: 'cap_01',
            name: 'Capati',
            qty: 3,
            unitPrice: 1.5,
            lineTotal: 4.5,
            station: 'roti_capati',
          ),
          OrderItem(
            id: 2,
            sku: 'cap_01',
            name: 'Capati',
            qty: 2,
            unitPrice: 1.5,
            lineTotal: 3,
            station: 'roti_capati',
            paid: secondPaid,
          ),
          const OrderItem(
            id: 3,
            sku: 'lp_01',
            name: 'Kari Kambing',
            qty: 1,
            unitPrice: 5,
            lineTotal: 5,
            station: 'nasi_lemak_lontong',
          ),
        ],
        subtotal: 12.5,
        total: 12.5,
      );

  const products = [
    Product(
      sku: 'cap_01',
      name: 'Capati',
      price: 1.5,
      station: 'roti_capati',
      category: 'Capati',
      available: true,
    ),
    Product(
      sku: 'lp_01',
      name: 'Kari Kambing',
      price: 5,
      station: 'nasi_lemak_lontong',
      category: 'Lauk-pauk',
      available: true,
      addOnFor: 'Capati',
    ),
  ];

  Future<void> openPicker(WidgetTester tester, Order order) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showPartialPicker(
                context,
                order: order,
                products: products,
                currency: 'RM',
              ),
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();
  }

  /// Opens the picker, ticks the lines at [lines], and returns the result.
  Future<({double amount, Map<int, int> paidUnits})?> pick(
    WidgetTester tester, {
    required List<int> lines,
    Order? order,
  }) async {
    ({double amount, Map<int, int> paidUnits})? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                picked = await showPartialPicker(
                  context,
                  order: order ?? twoCapatiLines(),
                  products: products,
                  currency: 'RM',
                );
              },
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();

    for (final line in lines) {
      await tester.tap(find.byType(CheckboxListTile).at(line));
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('a line keeps its quantity and its add-ons nest under it',
      (tester) async {
    await openPicker(tester, twoCapatiLines());

    // One row per ordered line — not one per plate.
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text('1. Capati x 3'), findsOneWidget);
    expect(find.text('2. Capati x 2'), findsOneWidget);
    // The curry ordered with the second Capati is nested under it.
    expect(find.text('- Kari Kambing'), findsOneWidget);

    // Its own price per line, like the order list.
    expect(find.text('RM4.50'), findsOneWidget);
    expect(find.text('RM3.00'), findsOneWidget);
    expect(find.text('RM5.00'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Back'));
    await tester.pumpAndSettle();
  });

  testWidgets('picking a line charges the line and its add-ons',
      (tester) async {
    // The second Capati line (x2) carries the curry.
    final picked = await pick(tester, lines: [1]);
    expect(picked?.amount, 8.0, reason: '2 x 1.50 + 5.00 curry');
    expect(picked?.paidUnits, {2: 2, 3: 1},
        reason: 'the line and its add-on are both marked paid');
  });

  testWidgets('a part-paid bill shares only what is still owed', (tester) async {
    // RM5 of the RM12.50 bill is already paid.
    final partPaid = Order(
      orderNo: '251007-001-1',
      tableNo: '1',
      items: twoCapatiLines().items,
      subtotal: 12.5,
      total: 12.5,
      paid: 5,
    );

    // The picked pair is worth RM8.00, but only RM7.50 is still owed, so that
    // is what this round charges — the bill settles and the earlier RM5 is not
    // charged again.
    final picked = await pick(tester, lines: [1], order: partPaid);
    expect(picked?.amount, 7.5);

    // An untouched line on its own keeps its own value.
    final other = await pick(tester, lines: [0], order: partPaid);
    expect(other?.amount, 4.5);
  });

  testWidgets('a line already paid shows as paid and cannot be picked again',
      (tester) async {
    await openPicker(tester, twoCapatiLines(secondPaid: true));

    // Only the unpaid line is a checkbox.
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.text('paid'), findsOneWidget);

    final paidTitle = tester.widget<Text>(find.text('2. Capati x 2'));
    expect(paidTitle.style?.decoration, TextDecoration.lineThrough,
        reason: 'a paid line is shown slashed');
    // Its add-on is slashed with it.
    final curry = tester.widget<Text>(find.text('- Kari Kambing'));
    expect(curry.style?.decoration, TextDecoration.lineThrough);
  });
}
