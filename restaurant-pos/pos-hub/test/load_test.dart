import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// A rush at the till: many orders at once across a handful of tables and
/// take-aways. Each table must still end on one bill, every line must survive,
/// and every station must get a ticket carrying its items — the three things
/// that went wrong under load.
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
        sku: 'nl_01',
        name: 'Nasi Lemak',
        price: 4,
        station: 'nasi_lemak_lontong',
        category: 'Nasi Lemak',
        available: true,
      ),
      Product(
        sku: 'dr_01',
        name: 'Teh O',
        price: 2,
        station: 'minuman',
        category: 'Minuman',
        available: true,
      ),
      // The live pair from the portal: the curry's own station is `dapur`, the
      // combo's is `nasi_lemak`, and the curry is an add-on for `Nasi Lemak`.
      Product(
        sku: 'nl_03',
        name: 'Nasi Lemak + Lauk',
        price: 4,
        station: 'nasi_lemak',
        category: 'Nasi Lemak',
        available: true,
        requireAddOn: true,
      ),
      Product(
        sku: 'lp_04',
        name: 'Rendang Ayam',
        price: 5,
        station: 'dapur',
        category: 'Lauk-pauk',
        available: true,
        addOnFor: 'Roti Canai|Nasi Lemak|Lontong|Capati|Lempeng|Roti Jala',
      ),
    ]);
  });

  OrderItem line(String sku, String name, double price) => OrderItem(
        sku: sku,
        name: name,
        qty: 1,
        unitPrice: price,
        lineTotal: price,
        station: sku == 'rc_01'
            ? 'roti_capati'
            : sku == 'dr_01'
                ? 'minuman'
                : 'nasi_lemak_lontong',
      );

  test('a rush of orders keeps one bill per table, every line and every ticket',
      () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    final tables = [for (var i = 1; i <= 8; i += 1) '$i'];
    final futures = <Future<void>>[];
    for (final table in tables) {
      for (var n = 0; n < 5; n += 1) {
        futures.add(cashier.locked(() => cashier.createOrAppendOrder(
              channel: n.isEven ? 'counter' : 'waiter',
              tableNo: table,
              items: [line('nl_01', 'Nasi Lemak', 4), line('dr_01', 'Teh O', 2)],
            )));
      }
    }
    for (var n = 0; n < 10; n += 1) {
      futures.add(cashier.locked(() => cashier.createOrAppendOrder(
            channel: 'waiter',
            orderType: 'take_away',
            items: [line('rc_01', 'Roti Canai', 2.5)],
          )));
    }
    await Future.wait(futures);

    final open = await db.getOrders(status: 'OPEN', limit: 500);

    // One bill per table, however many orders raced in.
    final perTable = <String, int>{};
    for (final order in open) {
      if (order.tableNo.isEmpty) continue;
      perTable[order.tableNo] = (perTable[order.tableNo] ?? 0) + 1;
    }
    for (final table in tables) {
      expect(perTable[table], 1, reason: 'table $table ends on one bill');
    }

    // Every line landed on the bill.
    for (final order in open) {
      if (order.tableNo.isEmpty) continue;
      expect(order.items.length, 10,
          reason: '5 orders x 2 lines on ${order.orderNo}');
    }

    // The take-aways stayed their own bills.
    final bags = open.where((order) => order.tableNo.isEmpty).toList();
    expect(bags.length, 10, reason: 'take-aways never merge');

    // No duplicate order numbers from the rush.
    final numbers = open.map((order) => order.orderNo).toList();
    expect(numbers.toSet().length, numbers.length);

    // Every station got its ticket, and the ticket carries its items.
    final jobs = await db.getAllJobs();
    for (final order in open) {
      final marker = order.orderType == 'take_away'
          ? 'TA - ${order.takeAwayNo}'
          : order.orderNo;
      for (final station in order.items.map((item) => item.station).toSet()) {
        final matching = jobs
            .where((job) =>
                job.station == station && job.payload.contains(marker))
            .toList();
        expect(matching, isNotEmpty,
            reason: '$station ticket for ${order.orderNo}');
        for (final item in order.items.where((i) => i.station == station)) {
          expect(matching.first.payload, contains(item.name),
              reason: '${item.name} prints on the $station ticket');
        }
      }
    }
  });

  test('the live combo and its curry keep one station through a take-away merge',
      () async {
    final cashier = CashierService.instance;

    // A table is already open…
    await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '77',
      items: [line('dr_01', 'Teh O', 2)],
    );
    // …then a take-away for that table: the combo with its curry, exactly as
    // the counter rings it up.
    final merged = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '77',
      items: [
        const OrderItem(
          sku: 'nl_03',
          name: 'Nasi Lemak + Lauk',
          qty: 1,
          unitPrice: 4,
          lineTotal: 4,
          station: 'nasi_lemak',
          lineKey: 'K1',
        ),
        const OrderItem(
          sku: 'lp_04',
          name: 'Rendang Ayam',
          qty: 1,
          unitPrice: 5,
          lineTotal: 5,
          station: 'dapur',
          lineKey: 'K2',
          parentKey: 'K1',
        ),
      ],
    );
    expect(merged.merged, isTrue);

    final sheets = await cashier.ticketSheets(merged.order);
    final taSheets =
        sheets.where((sheet) => sheet.section.isNotEmpty).toList();
    expect(taSheets.length, 1,
        reason: 'the take-away prints one ticket, not one per item station');
    expect(taSheets.single.station, 'nasi_lemak',
        reason: 'the curry follows the combo, not its own dapur station');
    expect(taSheets.single.text, contains('Rendang Ayam'));
  });

  test('an add-on rung in a later round still prints on the parent ticket',
      () async {
    final cashier = CashierService.instance;

    // The table is open…
    await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '78',
      items: [line('dr_01', 'Teh O', 2)],
    );
    // …the combo is rung as one take-away round…
    final first = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '78',
      items: [
        const OrderItem(
          sku: 'nl_03',
          name: 'Nasi Lemak + Lauk',
          qty: 1,
          unitPrice: 4,
          lineTotal: 4,
          station: 'nasi_lemak',
          lineKey: 'P1',
        ),
      ],
    );
    // …and the curry comes in on its own, as its own take-away round: a second
    // TA number, but it belongs to the combo, so it must print on the combo's
    // ticket rather than one of its own.
    final second = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '78',
      items: [
        const OrderItem(
          sku: 'lp_04',
          name: 'Rendang Ayam',
          qty: 1,
          unitPrice: 5,
          lineTotal: 5,
          station: 'dapur',
          lineKey: 'P2',
          parentKey: 'P1',
        ),
      ],
    );
    expect(first.merged, isTrue);
    expect(second.merged, isTrue);

    final sheets = await cashier.ticketSheets(second.order);
    final taSheets = sheets.where((sheet) => sheet.section.isNotEmpty).toList();
    expect(taSheets.length, 1,
        reason: 'the combo and its curry print one ticket, not two');
    expect(taSheets.single.station, 'nasi_lemak');
    expect(taSheets.single.text, contains('Nasi Lemak + Lauk'));
    expect(taSheets.single.text, contains('Rendang Ayam'),
        reason: 'the curry prints with the combo it belongs to');
  });

  test('a take-away rung without line keys still prints one ticket',
      () async {
    final cashier = CashierService.instance;

    // As a QR or handset take-away arrives: the combo and its curry, with no
    // record of which line the curry was ordered with.
    final order = await cashier.createOrder(
      channel: 'online',
      orderType: 'take_away',
      items: const [
        OrderItem(
          sku: 'nl_03',
          name: 'Nasi Lemak + Lauk',
          qty: 1,
          unitPrice: 4,
          lineTotal: 4,
          station: 'nasi_lemak',
        ),
        OrderItem(
          sku: 'lp_04',
          name: 'Rendang Ayam',
          qty: 1,
          unitPrice: 5,
          lineTotal: 5,
          station: 'dapur',
        ),
      ],
    );

    final sheets = await cashier.ticketSheets(order);
    expect(sheets.length, 1, reason: 'the curry prints with the combo');
    expect(sheets.single.station, 'nasi_lemak',
        reason: 'not on the curry\'s own dapur station');
    expect(sheets.single.text, contains('    - Rendang Ayam'));
  });

  test('a merged take-away queues the add-on on its parent ticket only',
      () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '80',
      items: [line('dr_01', 'Teh O', 2)],
    );
    await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '80',
      items: const [
        OrderItem(
          sku: 'nl_03',
          name: 'Nasi Lemak + Lauk',
          qty: 1,
          unitPrice: 4,
          lineTotal: 4,
          station: 'nasi_lemak',
          lineKey: 'N1',
        ),
        OrderItem(
          sku: 'lp_04',
          name: 'Rendang Ayam',
          qty: 1,
          unitPrice: 5,
          lineTotal: 5,
          station: 'dapur',
          lineKey: 'N2',
          parentKey: 'N1',
        ),
      ],
    );

    // The tickets the merge actually queued.
    final jobs = (await db.getAllJobs())
        .where((job) => job.payload.contains('TA - '))
        .toList();
    expect(jobs.map((job) => job.station).toSet(), {'nasi_lemak'},
        reason: 'the curry prints on the combo ticket, not on dapur');
    expect(jobs.first.payload, contains('Nasi Lemak + Lauk'));
    expect(jobs.first.payload, contains('    - Rendang Ayam'));
  });

  test('a failed ticket is re-queued, then left to the operator', () async {
    final db = PrintQueueDb.instance;
    final id = await db.enqueue('roti_capati', '', 'ticket body');
    await db.fail(id, 'No printer for station "roti_capati"');

    // Too fresh to try again.
    expect(await db.rependFailedJobs(after: const Duration(minutes: 5)), 0);

    // Past the delay it is re-queued, and tried up to the attempt limit.
    expect(await db.rependFailedJobs(after: Duration.zero, maxAttempts: 1), 1);
    await db.fail(id, 'still no printer');
    expect(await db.rependFailedJobs(after: Duration.zero, maxAttempts: 1), 0,
        reason: 'out of attempts, left for the operator');
    expect(await db.attempts(id), 1);
  });
}
