import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/services/app_settings.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// Station ticket layout:
///
///   ORDER - 260929-001-5
///   TABLE - 5
///   ------------------------------
///   1. Teh O (Panas) X 1
///       - Normal sugar, Normal ice
///
///   ------------------------------
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PrintQueueDb.overridePath = inMemoryDatabasePath;
  });

  setUp(() async {
    await PrintQueueDb.instance.clear();
    await SettingsStore.instance.load();
  });

  OrderItem item(
    String name,
    String station, {
    String? sku,
    int qty = 1,
    String note = '',
  }) =>
      OrderItem(
        sku: sku ?? name,
        name: name,
        qty: qty,
        unitPrice: 2.0,
        lineTotal: 2.0 * qty,
        station: station,
        note: note,
      );

  test('tickets show ORDER / TABLE and print drink options', () async {
    final cashier = CashierService.instance;

    final order = await cashier.createOrder(
      channel: 'counter',
      tableNo: '5',
      items: [
        item('Teh O (Panas)', 'Beverage', note: 'Normal sugar, Normal ice'),
        item('Roti Kosong', 'Griddle', qty: 2),
      ],
    );

    final jobs = await PrintQueueDb.instance.getAllJobs();
    final beverage = jobs.firstWhere((job) => job.station == 'Beverage');
    expect(beverage.payload, contains('ORDER - ${order.orderNo}'));
    expect(beverage.payload, contains('TABLE - 5'));
    expect(
      beverage.payload,
      contains('1. Teh O (Panas) X 1\n    - Normal sugar, Normal ice'),
    );
    expect(beverage.payload, isNot(contains('Station:')));

    final griddle = jobs.firstWhere((job) => job.station == 'Griddle');
    expect(griddle.payload, contains('1. Roti Kosong X 2'));
  });

  test('an add-on prints indented under the item it came with', () async {
    await PrintQueueDb.instance.replaceProducts(const [
      Product(
        sku: 'rc_01',
        name: 'Roti Kosong',
        price: 1.5,
        station: 'Griddle',
        category: 'Roti Canai',
        available: true,
      ),
      Product(
        sku: 'lp_09',
        name: 'Kari Kambing',
        price: 8,
        station: 'Kitchen',
        category: 'Lauk-pauk',
        available: true,
        addOnFor: 'Roti Canai',
      ),
    ]);

    await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '6',
      items: [
        item('Roti Kosong', 'Griddle', sku: 'rc_01'),
        item('Kari Kambing', 'Kitchen', sku: 'lp_09'),
      ],
    );

    final jobs = await PrintQueueDb.instance.getAllJobs();
    expect(jobs, hasLength(1), reason: 'the curry follows the roti station');
    expect(jobs.first.station, 'Griddle');
    expect(
      jobs.first.payload,
      contains('1. Roti Kosong X 1\n    - Kari Kambing'),
    );
  });

  test('two identical items each keep their own add-on', () async {
    await PrintQueueDb.instance.replaceProducts(const [
      Product(
        sku: 'rc_01',
        name: 'Roti Kosong',
        price: 1.5,
        station: 'Griddle',
        category: 'Roti Canai',
        available: true,
      ),
      Product(
        sku: 'rt_01',
        name: 'Roti Telur',
        price: 2.5,
        station: 'Griddle',
        category: 'Roti Canai',
        available: true,
      ),
      Product(
        sku: 'lp_09',
        name: 'Kari Kambing',
        price: 8,
        station: 'Kitchen',
        category: 'Lauk-pauk',
        available: true,
        addOnFor: 'Roti Canai',
      ),
    ]);

    await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '7',
      items: [
        item('Roti Kosong', 'Griddle', sku: 'rc_01'),
        item('Kari Kambing', 'Kitchen', sku: 'lp_09'),
        item('Roti Telur', 'Griddle', sku: 'rt_01'),
        item('Roti Telur', 'Griddle', sku: 'rt_01'),
        item('Kari Kambing', 'Kitchen', sku: 'lp_09'),
      ],
    );

    final jobs = await PrintQueueDb.instance.getAllJobs();
    expect(jobs, hasLength(1));
    final payload = jobs.first.payload;

    expect(payload, contains('1. Roti Kosong X 1\n    - Kari Kambing'));
    expect(
      payload,
      contains('2. Roti Telur X 1\n\n3. Roti Telur X 1\n    - Kari Kambing'),
    );
  });

  test('the receipt nests add-ons under their item too', () async {
    await PrintQueueDb.instance.replaceProducts(const [
      Product(
        sku: 'rc_01',
        name: 'Roti Kosong',
        price: 1.5,
        station: 'Griddle',
        category: 'Roti Canai',
        available: true,
      ),
      Product(
        sku: 'lp_09',
        name: 'Kari Kambing',
        price: 8,
        station: 'Kitchen',
        category: 'Lauk-pauk',
        available: true,
        addOnFor: 'Roti Canai',
      ),
    ]);

    final order = await CashierService.instance.createOrder(
      channel: 'counter',
      tableNo: '9',
      items: [
        item('Roti Kosong', 'Griddle', sku: 'rc_01'),
        item('Kari Kambing', 'Kitchen', sku: 'lp_09'),
      ],
    );

    final receipt = await CashierService.instance.receiptPreview(order);
    expect(receipt, contains('1. Roti Kosong'));
    expect(receipt, contains('   1 X 2.00'));
    expect(receipt, contains('    - Kari Kambing'));
    expect(receipt, contains('       1 X 2.00'));
  });
}
