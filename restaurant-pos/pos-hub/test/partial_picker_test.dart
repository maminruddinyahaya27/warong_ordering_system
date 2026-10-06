import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/widgets/partial_picker.dart';

/// The partial-payment picker: a dish ordered twice is two numbered rows, so
/// one plate can be paid on its own.
void main() {
  Order orderOfTwo() => const Order(
        orderNo: '251006-001-1',
        tableNo: '1',
        items: [
          OrderItem(
            id: 1,
            sku: 'nl_01',
            name: 'Nasi Lemak Biasa',
            qty: 2,
            unitPrice: 4,
            lineTotal: 8,
            station: 'nasi_lemak_lontong',
          ),
          OrderItem(
            id: 2,
            sku: 'rc_01',
            name: 'Roti Canai',
            qty: 1,
            unitPrice: 2,
            lineTotal: 2,
            station: 'roti_capati',
          ),
        ],
        subtotal: 10,
        total: 10,
      );

  Future<({double amount, List<int> itemIds})?> pick(
    WidgetTester tester, {
    required int taps,
  }) async {
    ({double amount, List<int> itemIds})? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showPartialPicker(
                    context,
                    order: orderOfTwo(),
                    products: const [],
                    currency: 'RM',
                  );
                },
                child: const Text('pick'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();

    for (var i = 0; i < taps; i += 1) {
      await tester.tap(find.byType(CheckboxListTile).at(i));
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('a dish ordered twice is two rows', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showPartialPicker(
                context,
                order: orderOfTwo(),
                products: const [],
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

    // Two nasi lemak rows plus the roti.
    expect(find.byType(CheckboxListTile), findsNWidgets(3));
    expect(find.text('1. Nasi Lemak Biasa'), findsOneWidget);
    expect(find.text('2. Nasi Lemak Biasa'), findsOneWidget);
    expect(find.text('3. Roti Canai'), findsOneWidget);
    // Each row carries that one plate's price, not the line total.
    expect(find.text('RM4.00'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(TextButton, 'Back'));
    await tester.pumpAndSettle();
  });

  testWidgets('one of two plates charges one plate and keeps the line open',
      (tester) async {
    final picked = await pick(tester, taps: 1);
    expect(picked?.amount, 4);
    expect(picked?.itemIds, isEmpty,
        reason: 'a half-picked line is not marked paid');
  });

  testWidgets('both plates mark the line paid', (tester) async {
    final picked = await pick(tester, taps: 2);
    expect(picked?.amount, 8);
    expect(picked?.itemIds, [1]);
  });
}
