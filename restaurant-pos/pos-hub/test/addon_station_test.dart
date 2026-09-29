import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/services/app_settings.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// Add-on groups: a Lauk-pauk curry ordered with a Roti Canai must print on the
/// roti canai (Griddle) ticket, so the stall gets the roti and its curry
/// together. On its own it keeps its own station.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PrintQueueDb.overridePath = inMemoryDatabasePath;
  });

  setUp(() async {
    final db = PrintQueueDb.instance;
    await db.clear();
    await SettingsStore.instance.load();
    await db.replaceProducts(const [
      Product(
        sku: 'rc_01',
        name: 'Roti Kosong',
        price: 1.5,
        station: 'Griddle',
        category: 'Roti Canai',
        available: true,
      ),
      Product(
        sku: 'lp_01',
        name: 'Kari Kambing',
        price: 8,
        station: 'Kitchen',
        category: 'Lauk-pauk',
        available: true,
        addOnFor: 'Roti Canai',
      ),
      Product(
        sku: 'nl_01',
        name: 'Nasi Lemak',
        price: 5,
        station: 'Kitchen',
        category: 'Nasi Lemak',
        available: true,
      ),
    ]);
  });

  OrderItem line(String sku, String name, String station) => OrderItem(
        sku: sku,
        name: name,
        qty: 1,
        unitPrice: 1,
        lineTotal: 1,
        station: station,
      );

  test('a curry ordered with roti canai prints on the Griddle ticket', () async {
    final cashier = CashierService.instance;

    await cashier.createOrder(
      channel: 'counter',
      tableNo: '1',
      items: [
        line('rc_01', 'Roti Kosong', 'Griddle'),
        line('lp_01', 'Kari Kambing', 'Kitchen'),
      ],
    );

    final jobs = await PrintQueueDb.instance.getAllJobs();
    final stations = jobs.map((job) => job.station).toList();

    expect(stations, contains('Griddle'));
    expect(stations, isNot(contains('Kitchen')),
        reason: 'the curry follows the roti station');

    final gridde = jobs.firstWhere((job) => job.station == 'Griddle');
    expect(gridde.payload, contains('Roti Kosong'));
    expect(gridde.payload, contains('Kari Kambing'));
  });

  test('a curry on its own stays on the Kitchen ticket', () async {
    final cashier = CashierService.instance;

    await cashier.createOrder(
      channel: 'counter',
      tableNo: '2',
      items: [
        line('lp_01', 'Kari Kambing', 'Kitchen'),
        line('nl_01', 'Nasi Lemak', 'Kitchen'),
      ],
    );

    final jobs = await PrintQueueDb.instance.getAllJobs();
    expect(jobs, hasLength(1));
    expect(jobs.first.station, 'Kitchen');
    expect(jobs.first.payload, contains('Kari Kambing'));
  });

  test('adding a curry later joins the open bill on the roti station',
      () async {
    final cashier = CashierService.instance;

    final created = await cashier.createOrder(
      channel: 'counter',
      tableNo: '3',
      items: [line('rc_01', 'Roti Kosong', 'Griddle')],
    );

    await cashier.addOrderItems(created.id!, [
      line('lp_01', 'Kari Kambing', 'Kitchen'),
    ]);

    final jobs = await PrintQueueDb.instance.getAllJobs();
    final curryJobs =
        jobs.where((job) => job.payload.contains('Kari Kambing')).toList();

    expect(curryJobs, hasLength(1));
    expect(curryJobs.first.station, 'Griddle',
        reason: 'overrides use the whole order, not just the added lines');
  });

  test('a curry added later through the counter merge prints on Griddle',
      () async {
    final cashier = CashierService.instance;

    final first = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '4',
      idempotencyKey: 'round-1',
      items: [line('rc_01', 'Roti Kosong', 'Griddle')],
    );
    expect(first.merged, isFalse);

    final second = await cashier.createOrAppendOrder(
      channel: 'counter',
      tableNo: '4',
      idempotencyKey: 'round-2',
      items: [line('lp_01', 'Kari Kambing', 'Kitchen')],
    );
    expect(second.merged, isTrue, reason: 'joins the open bill');

    final jobs = await PrintQueueDb.instance.getAllJobs();
    final curryJob =
        jobs.firstWhere((job) => job.payload.contains('Kari Kambing'));
    expect(curryJob.station, 'Griddle');
  });
}
