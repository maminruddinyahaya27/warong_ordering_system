import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// An add-on must print on the station of the item it was ordered with, which
/// is the most recent item of a group it is an add-on for — not the first such
/// group on the bill, which used to send a nasi lemak's curry to the roti
/// station whenever the table also had a roti canai.
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
        name: 'Nasi Lemak Biasa',
        price: 4,
        station: 'nasi_lemak_lontong',
        category: 'Nasi Lemak',
        available: true,
      ),
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
        sku: 'lp_07',
        name: 'Kari Ayam',
        price: 5,
        station: 'dapur',
        category: 'Lauk-pauk',
        available: true,
        addOnFor: 'Roti Canai|Roti Jala|Capati|Lempeng|Nasi Lemak|Lontong',
      ),
      Product(
        sku: 'lp_06',
        name: 'Rendang Kerang',
        price: 5,
        station: 'nasi_lemak_lontong',
        category: 'Lauk-pauk',
        available: true,
        // Roti Canai comes first, exactly as the portal stores it.
        addOnFor: 'Roti Canai|Roti Jala|Lempeng|Capati|Nasi Lemak|Lontong',
      ),
    ]);
  });

  OrderItem line(
    String sku,
    String name,
    double price, {
    String key = '',
    String parent = '',
    String section = '',
  }) =>
      OrderItem(
        sku: sku,
        name: name,
        qty: 1,
        unitPrice: price,
        lineTotal: price,
        station: sku == 'rc_01'
            ? 'roti_capati'
            : sku == 'dr_01'
                ? 'minuman'
                : sku == 'nl_03'
                    ? 'nasi_lemak'
                    : sku == 'lp_07'
                        ? 'dapur'
                        : 'nasi_lemak_lontong',
        lineKey: key,
        parentKey: parent,
        section: section,
      );

  /// The ticket text queued for [station], or null when nothing was queued.
  Future<String?> ticketFor(String station) async {
    final raw = await PrintQueueDb.instance.database;
    final rows = await raw.query(
      'jobs',
      where: 'station = ?',
      whereArgs: [station],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['payload'] as String;
  }

  test('a curry ordered with the nasi lemak prints on the nasi lemak ticket',
      () async {
    await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '7',
      items: [
        line('rc_01', 'Roti Canai', 2.5),
        line('nl_01', 'Nasi Lemak Biasa', 4),
        line('lp_06', 'Rendang Kerang', 5),
      ],
    );

    final roti = await ticketFor('roti_capati');
    expect(roti, isNotNull, reason: 'the roti canai still needs its ticket');
    expect(roti, contains('Roti Canai'));
    expect(roti, isNot(contains('Rendang Kerang')),
        reason: 'the curry belongs to the nasi lemak, not the roti');

    final nasiLemak = await ticketFor('nasi_lemak_lontong');
    expect(nasiLemak, isNotNull);
    expect(nasiLemak, contains('Nasi Lemak Biasa'));
    expect(nasiLemak, contains('    - Rendang Kerang'),
        reason: 'the curry prints nested under the nasi lemak');
  });

  test('an add-on with no parent on the bill keeps its own station', () async {
    await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '3',
      items: [line('lp_06', 'Rendang Kerang', 5)],
    );

    final own = await ticketFor('nasi_lemak_lontong');
    expect(own, isNotNull);
    expect(own, contains('Rendang Kerang'));
    expect(await ticketFor('roti_capati'), isNull);
  });

  test('the preview shows the same tickets that would print', () async {
    final order = await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '7',
      items: [
        line('rc_01', 'Roti Canai', 2.5),
        line('nl_01', 'Nasi Lemak Biasa', 4),
        line('lp_06', 'Rendang Kerang', 5),
      ],
    );

    final sheets = await CashierService.instance.ticketSheets(order);
    expect(sheets.map((sheet) => sheet.station).toSet(),
        {'roti_capati', 'nasi_lemak_lontong'});
    final rotiSheet =
        sheets.firstWhere((sheet) => sheet.station == 'roti_capati');
    final nasiSheet =
        sheets.firstWhere((sheet) => sheet.station == 'nasi_lemak_lontong');
    expect(rotiSheet.text, await ticketFor('roti_capati'));
    expect(nasiSheet.text, await ticketFor('nasi_lemak_lontong'));
  });

  test('one station can be printed again on its own', () async {
    final db = PrintQueueDb.instance;
    final order = await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '7',
      items: [
        line('rc_01', 'Roti Canai', 2.5),
        line('nl_01', 'Nasi Lemak Biasa', 4),
        line('lp_06', 'Rendang Kerang', 5),
      ],
    );

    // Forget what creating the order queued, then print one station only.
    final raw = await db.database;
    await raw.delete('jobs');

    await CashierService.instance.sendStationTicket(order, 'roti_capati', '');

    expect(await ticketFor('roti_capati'), contains('Roti Canai'));
    expect(await ticketFor('nasi_lemak_lontong'), isNull,
        reason: 'the other stations are not printed by a single-station print');
  });

  test('an item with no station queues no ticket at all', () async {
    // The portal can leave an item without a station — the kitchen never makes
    // it, so nothing is queued for it.
    await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '6',
      items: [
        const OrderItem(
          sku: 'drink_01',
          name: 'Air Botol',
          qty: 1,
          unitPrice: 2,
          lineTotal: 2,
          station: '',
          lineKey: 'L1',
        ),
      ],
    );

    final sheets = await CashierService.instance.ticketSheets(
      (await PrintQueueDb.instance.getOrders(status: 'OPEN')).single,
    );
    expect(sheets, isEmpty, reason: 'no station, no ticket');

    // Adding one to an open bill queues nothing for it either.
    final open = await CashierService.instance.createOrAppendOrder(
      channel: 'counter',
      tableNo: '6',
      items: [line('rc_01', 'Roti Canai', 2.5, key: 'L9')],
    );
    final before = (await PrintQueueDb.instance.getAllJobs()).length;
    await CashierService.instance.addOrderItems(open.order.id!, [
      const OrderItem(
        sku: 'drink_01',
        name: 'Air Botol',
        qty: 1,
        unitPrice: 2,
        lineTotal: 2,
        station: '',
        lineKey: 'L10',
      ),
    ]);
    final after = (await PrintQueueDb.instance.getAllJobs()).length;
    expect(after, before, reason: 'nothing is queued for a stationless item');
  });

  test('a take-away with a table keeps its add-on on the parent station',
      () async {
    final cashier = CashierService.instance;

    // A table is already eating, then the table adds a take-away with an
    // add-on. The curry must print under its parent, on the parent's station,
    // in the take-away's own ticket.
    await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '93',
      items: [line('rc_01', 'Roti Canai', 2.5, key: 'T1')],
    );
    final bill = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '93',
      items: [
        // The curry's own station is nasi_lemak_lontong, but it is an add-on
        // for the roti, so it must print on the roti's roti_capati ticket.
        line('rc_01', 'Roti Canai', 2.5, key: 'T2'),
        line('lp_06', 'Rendang Kerang', 5, key: 'T3', parent: 'T2'),
      ],
    );

    final sheets = await cashier.ticketSheets(bill.order);
    final taSheets = sheets
        .where((sheet) => sheet.section.isNotEmpty)
        .toList();
    expect(taSheets, isNotEmpty, reason: 'the take-away has its own ticket');
    expect(taSheets.single.text, contains('Roti Canai'));
    expect(taSheets.single.text, contains('    - Rendang Kerang'),
        reason: 'the add-on follows its parent');
    expect(taSheets.single.station, 'roti_capati',
        reason: 'on the parent station, not the curry\'s own');
  });

  test('an add-on rung for a dish already on the table follows it', () async {
    final cashier = CashierService.instance;

    // Round 1: the table is eating a roti.
    await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '94',
      items: [line('rc_01', 'Roti Canai', 2.5, key: 'R1')],
    );
    // Round 2: the table adds a take-away curry — its parent is the roti from
    // round 1, so the recorded parent key cannot match; it must still nest by
    // the product rule and print on the roti's station.
    final bill = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '94',
      items: [
        line('lp_06', 'Rendang Kerang', 5, key: 'R2', parent: 'R1'),
      ],
    );

    final sheets = await cashier.ticketSheets(bill.order);
    // The curry prints with the roti it belongs to — the table's own ticket —
    // so it is one ticket, and on the roti's station.
    expect(sheets.map((sheet) => sheet.station).toSet(), {'roti_capati'},
        reason: 'no second ticket on the curry\'s own station');
    final rotiSheet = sheets.firstWhere((sheet) => sheet.station == 'roti_capati');
    expect(rotiSheet.text, contains('Rendang Kerang'));
    expect(rotiSheet.section, '',
        reason: 'it prints as part of the table order it belongs to');
  });

  test('a curry rung beside a Nasi Lemak + Lauk joins it', () async {
    // The table's own round: the combo (which exists to take a lauk) plus the
    // curry on its own line — the curry must print with the combo.
    final cashier = CashierService.instance;
    final order = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '96',
      items: [
        line('nl_03', 'Nasi Lemak + Lauk', 4, key: 'Q1'),
        line('lp_07', 'Kari Ayam', 5, key: 'Q2'),
      ],
    );

    final sheets = await cashier.ticketSheets(order.order);
    expect(sheets.length, 1,
        reason: 'the curry prints on the combo ticket, not its own');
    expect(sheets.single.station, 'nasi_lemak');
    expect(sheets.single.text, contains('    - Kari Ayam'),
        reason: 'nested under the combo');
  });

  test('a curry taken beside a plain dish keeps its own station', () async {
    // The earlier rule still holds: a curry rung on its own for a dish that is
    // not a combo prints on its own station.
    final cashier = CashierService.instance;
    final order = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '97',
      items: [
        line('nl_01', 'Nasi Lemak Biasa', 4, key: 'R1'),
        line('lp_06', 'Rendang Kerang', 5, key: 'R2'),
      ],
    );

    final sheets = await cashier.ticketSheets(order.order);
    // The curry stays a line of its own — not nested under the nasi lemak.
    expect(sheets.single.text, isNot(contains('    - Rendang Kerang')),
        reason: 'a plain dish does not collect the curry');
    expect(sheets.single.text, contains('Rendang Kerang'));
  });

  test('a take-away curry joins the dish already on the table', () async {
    // The exact counter scenario: table 1 with an item and its add-on, then a
    // take-away for table 1. The take-away's curry must follow the parent it
    // belongs to, not print at its own station.
    final cashier = CashierService.instance;

    // Table 1: a roti with its curry.
    final table = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '95',
      items: [
        line('rc_01', 'Roti Canai', 2.5, key: 'M1'),
        line('lp_06', 'Rendang Kerang', 5, key: 'M2', parent: 'M1'),
      ],
    );
    expect(table.merged, isFalse);

    // TA for the same table: the curry rung on its own (no parent in this
    // round) — it belongs to the roti above.
    final merged = await cashier.createOrAppendOrder(
      channel: 'counter',
      orderType: 'take_away',
      tableNo: '95',
      items: [line('lp_06', 'Rendang Kerang', 5, key: 'M3')],
    );
    expect(merged.merged, isTrue);

    final sheets = await cashier.ticketSheets(merged.order);
    // One ticket, on the roti's station, with the curry nested under it — the
    // take-away curry prints with the dish it was ordered for.
    expect(sheets.map((sheet) => sheet.station).toSet(), {'roti_capati'},
        reason: 'the curry follows the roti, not its own station');
    final rotiSheet = sheets.firstWhere((sheet) => sheet.station == 'roti_capati');
    expect(rotiSheet.text, contains('    - Rendang Kerang'),
        reason: 'nested under the roti it was ordered for');
  });

  test('a take-away added to a table prints its items on the TA ticket',
      () async {
    final cashier = CashierService.instance;
    final db = PrintQueueDb.instance;

    // A table bill, then a take-away the table adds on — its line carries the
    // TA section, and the merge path must print it on that ticket.
    final bill = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '92',
      items: [line('nl_01', 'Nasi Lemak', 4, key: 'L1')],
    );
    await cashier.addOrderItems(bill.order.id!, [
      line('dr_01', 'Teh O', 2, key: 'L2', section: 'TA - 001'),
    ]);

    final jobs = await db.getAllJobs();
    final taTicket = jobs
        .where((job) => job.payload.contains('TA - 001'))
        .map((job) => job.payload)
        .toList();
    expect(taTicket, isNotEmpty, reason: 'the take-away gets its own ticket');
    expect(taTicket.first, contains('Teh O'),
        reason: 'and its item prints on it, not filtered out');
    expect(taTicket.first, contains('ORDER - TA - 001'));
  });

  test('a curry taken from its own group is not somebody else\'s add-on',
      () async {
    // Roti Canai and a Rendang Ayam rung up on their own lines: the curry must
    // keep its own line and print at its own station, not follow the roti.
    await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '4',
      items: [
        line('rc_01', 'Roti Canai', 2.5, key: 'L1'),
        line('lp_06', 'Rendang Kerang', 5, key: 'L2'),
      ],
    );

    final roti = await ticketFor('roti_capati');
    expect(roti, isNotNull);
    expect(roti, contains('Roti Canai'));
    expect(roti, isNot(contains('Rendang Kerang')),
        reason: 'the curry was taken on its own, so it is not an add-on');

    final curry = await ticketFor('nasi_lemak_lontong');
    expect(curry, isNotNull);
    expect(curry, contains('Rendang Kerang'),
        reason: 'it prints at its own station');
  });

  test('an add-on still follows the line it was ordered with', () async {
    // The same curry, this time rung up as the roti's add-on.
    await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '4',
      items: [
        line('rc_01', 'Roti Canai', 2.5, key: 'L1'),
        line('lp_06', 'Rendang Kerang', 5, key: 'L2', parent: 'L1'),
      ],
    );

    final roti = await ticketFor('roti_capati');
    expect(roti, isNotNull);
    expect(roti, contains('Roti Canai'));
    expect(roti, contains('    - Rendang Kerang'),
        reason: 'the add-on prints with the line it was ordered with');

    expect(await ticketFor('nasi_lemak_lontong'), isNull,
        reason: 'and not at its own station');
  });
}
