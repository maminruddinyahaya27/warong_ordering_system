import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/services/app_settings.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/escpos_renderer.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';

/// Index of [needle] inside [bytes], or -1.
int indexOfBytes(List<int> bytes, List<int> needle) {
  for (var i = 0; i <= bytes.length - needle.length; i += 1) {
    var matches = true;
    for (var j = 0; j < needle.length; j += 1) {
      if (bytes[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

/// Station ticket layout:
///
///   ORDER - 260929-001-5
///   TABLE - 5
///   ------------------------------
///   1. Teh O (Panas) X 1
///       - Normal sugar, Normal ice
///
///   ------------------------------
/// Esc/POS alignment byte in effect for [needle] (0x31 = centre, 0x30 = left).
int alignBeforeText(List<int> bytes, List<int> needle) {
  final index = indexOfBytes(bytes, needle);
  if (index < 1) return -1;
  for (var i = index - 1; i >= 1; i -= 1) {
    if (bytes[i - 1] == 0x1B && bytes[i] == 0x61) return bytes[i + 1];
  }
  return -1;
}

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

  test('the printed receipt centres its header and footer', () async {
    final payload = jsonEncode({
      'restaurantName': 'Warong',
      'footer': 'Thank you',
      'currency': 'RM',
      'total': 5.0,
      'items': const [],
    });

    final bytes = await EscPosRenderer.renderReceipt(payload);

    // The nearest alignment command before a piece of text must be "centre".
    // esc_pos_utils encodes it as ESC a '1' (0x31), left is '0'.
    int alignBefore(int textIndex) {
      for (var i = textIndex - 1; i >= 1; i -= 1) {
        if (bytes[i - 1] == 0x1B && bytes[i] == 0x61) return bytes[i + 1];
      }
      return -1;
    }

    final title = indexOfBytes(bytes, 'WARONG'.codeUnits);
    expect(title, greaterThan(2));
    expect(alignBefore(title), 0x31);

    final footer = indexOfBytes(bytes, 'Thank you'.codeUnits);
    expect(footer, greaterThan(2));
    expect(alignBefore(footer), 0x31);
  });

  test('the ticket header is the station only, centred', () async {
    final bytes = await EscPosRenderer.renderOrder('GRIDDLE', 'ORDER - 1\n');
    expect(indexOfBytes(bytes, 'RESTAURANT ORDER'.codeUnits), -1);
    expect(indexOfBytes(bytes, '[GRIDDLE]'.codeUnits), greaterThan(0));
    expect(alignBeforeText(bytes, '[GRIDDLE]'.codeUnits), 0x31);
  });

  test('the ticket header follows the size setting', () async {
    // GS ! n : 0x11 = double width + height.
    const doubleSize = [0x1D, 0x21, 0x11];

    await SettingsStore.instance.save({'ticket_text_size': 'normal'});
    await SettingsStore.instance.load();
    final normal = await EscPosRenderer.renderOrder('GRIDDLE', 'ORDER - 1\n');
    expect(indexOfBytes(normal, doubleSize), -1);

    await SettingsStore.instance.save({'ticket_text_size': 'large'});
    await SettingsStore.instance.load();
    final large = await EscPosRenderer.renderOrder('GRIDDLE', 'ORDER - 1\n');
    expect(indexOfBytes(large, doubleSize), greaterThan(0));
  });

  test('the receipt header and footer follow the size setting', () async {
    final payload = jsonEncode({
      'restaurantName': 'Warong',
      'footer': 'Thank you',
      'currency': 'RM',
      'total': 5.0,
      'items': const [],
    });
    const doubleSize = [0x1D, 0x21, 0x11];

    await SettingsStore.instance.save({'ticket_text_size': 'normal'});
    await SettingsStore.instance.load();
    final normal = await EscPosRenderer.renderReceipt(payload);
    expect(indexOfBytes(normal, doubleSize), -1);

    await SettingsStore.instance.save({'ticket_text_size': 'large'});
    await SettingsStore.instance.load();
    final large = await EscPosRenderer.renderReceipt(payload);
    expect(indexOfBytes(large, doubleSize), greaterThan(0));
  });

  // Kept last: it changes the stored ticket size for the rest of the file.
  test('the ticket body honours the text size setting', () async {
    int countBytes(List<int> bytes, List<int> needle) {
      var count = 0;
      var from = 0;
      while (true) {
        final index = indexOfBytes(bytes.sublist(from), needle);
        if (index == -1) break;
        count += 1;
        from += index + needle.length;
      }
      return count;
    }

    // GS ! n : 0x11 = double width + height.
    const doubleSize = [0x1D, 0x21, 0x11];
    const payload = 'ORDER - 1\nTABLE - 5\n';
    const body = '1. Roti Kosong X 1\n';

    await SettingsStore.instance.save({'ticket_text_size': 'normal'});
    await SettingsStore.instance.load();
    final normal =
        await EscPosRenderer.renderOrder('GRIDDLE', '$payload$body');

    await SettingsStore.instance.save({'ticket_text_size': 'large'});
    await SettingsStore.instance.load();
    final large = await EscPosRenderer.renderOrder('GRIDDLE', '$payload$body');

    expect(
      countBytes(large, doubleSize),
      greaterThan(countBytes(normal, doubleSize)),
      reason: 'the enlarged size must reach the printer',
    );
  });
}
