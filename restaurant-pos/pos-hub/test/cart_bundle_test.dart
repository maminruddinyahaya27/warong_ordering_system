import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/screens/counter_screen.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// The counter's cart: an item ordered with add-ons keeps them nested under it,
/// and every line — parent or add-on — can carry its own note.
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
        sku: 'rc_01',
        name: 'Roti Canai',
        price: 2.5,
        station: 'roti_capati',
        category: 'Roti Canai',
        available: true,
      ),
      Product(
        sku: 'lp_01',
        name: 'Kari Kambing',
        price: 5,
        station: 'nasi_lemak_lontong',
        category: 'Lauk-pauk',
        available: true,
        addOnFor: 'Roti Canai',
        // Listed after the roti, so the roti's group opens first.
        sortOrder: 1,
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

  /// The dialog's own text field (not the table field behind it).
  Finder dialogField() => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );

  /// The product tile in the menu grid — the group dropdown and the quick picks
  /// also carry item names, and the grid comes last.
  Finder tile(String name) => find.text(name).last;

  Future<void> openCounter(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CounterScreen())),
    );
    await settleAsync(tester);
  }

  testWidgets('an add-on sits under its parent and keeps its own note',
      (tester) async {
    await openCounter(tester);

    // Add the roti with one curry and a note on the parent.
    await tester.tap(tile('Roti Canai'));
    await tester.pump();
    expect(dialogField(), findsOneWidget,
        reason: 'adding an item offers a note field');
    // The first + is the quantity, the next one is the curry.
    await tester.tap(find.byIcon(Icons.add_circle_outline).at(1));
    await tester.pump();
    await tester.enterText(dialogField(), 'no sambal');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump();

    expect(find.text('no sambal'), findsOneWidget,
        reason: 'the parent line shows the note typed while adding');
    expect(find.text('1x Kari Kambing'), findsOneWidget,
        reason: 'the add-on is drawn as a nested line');

    // Nested: below the parent, and indented to the right of it.
    final parent = tester.getTopLeft(find.text('1x').first);
    final addOn = tester.getTopLeft(find.text('1x Kari Kambing'));
    expect(addOn.dy, greaterThan(parent.dy),
        reason: 'the add-on is drawn under its parent');
    expect(addOn.dx, greaterThan(parent.dx),
        reason: 'the add-on is indented under its parent');

    // The add-on's own note, added from its line.
    await tester.tap(find.text('Add note'));
    await tester.pump();
    await tester.enterText(dialogField(), 'extra gravy');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    expect(find.text('extra gravy'), findsOneWidget);
    expect(find.text('no sambal'), findsOneWidget,
        reason: 'the parent keeps its own note');
  });

  testWidgets('removing the parent takes its add-on with it', (tester) async {
    await openCounter(tester);

    await tester.tap(tile('Roti Canai'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add_circle_outline).at(1));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump();
    expect(find.text('1x Kari Kambing'), findsOneWidget);

    // Drop the roti (qty 1 -> 0).
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pump();

    expect(find.text('1x Kari Kambing'), findsNothing,
        reason: 'the curry goes with the roti it was ordered with');
    expect(find.text('No items'), findsOneWidget);
  });

  testWidgets('the group dropdown lists the groups and switches the grid',
      (tester) async {
    await openCounter(tester);

    // Opens without the ruled entries overflowing their row.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Roti Canai'), findsWidgets);
    expect(find.text('Lauk-pauk'), findsWidgets);

    // Picking a group swaps the grid to that group's items.
    await tester.tap(find.text('Lauk-pauk').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull, reason: 'no layout overflow');
    expect(find.text('Kari Kambing'), findsWidgets);
  });
}
