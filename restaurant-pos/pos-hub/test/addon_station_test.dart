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
  }) =>
      OrderItem(
        sku: sku,
        name: name,
        qty: 1,
        unitPrice: price,
        lineTotal: price,
        station: sku == 'rc_01' ? 'roti_capati' : 'nasi_lemak_lontong',
        lineKey: key,
        parentKey: parent,
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
