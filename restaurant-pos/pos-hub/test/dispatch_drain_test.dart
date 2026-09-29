import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/print_queue_db.dart';
import 'package:restaurant_pos_hub/services/queue_dispatcher.dart';

/// Reproduces the "only the first station prints" bug: one dispatch must drain
/// every job an order created, not just the first one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PrintQueueDb.overridePath = inMemoryDatabasePath;
    final db = await PrintQueueDb.instance.database;
    await db.delete('jobs');
    await db.delete('order_items');
    await db.delete('orders');
    await db.delete('station_printers');
  });

  test('an order spanning three stations queues and drains three tickets',
      () async {
    final db = PrintQueueDb.instance;
    final cashier = CashierService.instance;

    OrderItem line(String name, String station) => OrderItem(
          name: name,
          qty: 1,
          unitPrice: 2.0,
          lineTotal: 2.0,
          station: station,
        );

    final order = await cashier.createOrder(
      channel: 'waiter',
      tableNo: '7',
      items: [
        line('Roti Kosong', 'Griddle'),
        line('Teh O (Panas)', 'Beverage'),
        line('Nasi Lemak Ayam', 'Kitchen'),
        // Second item on an existing station must not create another ticket.
        line('Roti Telur', 'Griddle'),
      ],
    );
    expect(order.orderNo, isNotEmpty);

    // Printing is dispatched in the background, so wait for the queue to drain
    // (nudging it in case the background pass is still in flight).
    for (var i = 0; i < 50; i++) {
      await QueueDispatcher.instance.dispatchNext();
      final pending = await db.getPendingJobs();
      if (pending.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final jobs = await db.getAllJobs();
    expect(jobs.length, 3, reason: 'one ticket per distinct station');
    expect(jobs.map((job) => job.station).toSet(),
        {'Griddle', 'Beverage', 'Kitchen'});

    // No printers are assigned in this test, so each job fails — but the point
    // is that ALL of them were attempted by the single dispatch that the order
    // triggered. Before the fix, two stayed PENDING forever.
    expect(await _pendingCount(db), 0, reason: 'nothing left stuck PENDING');
    expect(jobs.where((job) => job.status == 'FAILED').length, 3);
  });

  test('a stuck pending job is picked up by a later dispatch', () async {
    final db = PrintQueueDb.instance;
    await db.enqueue('Wok', '', 'Station: Wok\n------------------------------\nMee Goreng x 1');

    await QueueDispatcher.instance.dispatchNext();

    expect(await _pendingCount(db), 0);
  });
}

Future<int> _pendingCount(PrintQueueDb db) async {
  final jobs = await db.getPendingJobs();
  return jobs.length;
}
