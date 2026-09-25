import '../models/order_record.dart';
import 'order_history.dart';
import 'order_service.dart';

/// Sends a queued order to the hub and folds the outcome back into the local
/// history: a merged round is consolidated into the bill it joined, a plain
/// send becomes a history entry, and a failure keeps the queue entry.
class OrderSender {
  static Future<({bool merged, bool duplicate, String orderNo})> send(
      OrderRecord record) async {
    final result = await OrderService.submitOrder(
      table: record.table,
      server: record.server,
      orderType: record.orderType,
      note: record.note,
      items: record.items,
      // The record id doubles as the retry key, so a resend of the same entry
      // can never create a second order on the hub.
      idempotencyKey: record.id,
    );

    final merged = result['merged'] == true;
    final duplicate = result['duplicate'] == true;
    final orderNo = (result['order_no'] ?? '').toString();
    final hubItems = _items(result['items']);
    final total =
        ((result['totals']?['total']) as num?)?.toDouble() ?? record.total;
    final jobs = (result['print_jobs'] as num?)?.toInt() ?? 0;

    if (merged && orderNo.isNotEmpty) {
      // A round for a table with an open bill: keep ONE history entry for the
      // bill, with the consolidated item list.
      final existing = await OrderHistory.findByOrderNo(orderNo);
      if (existing != null && existing.id != record.id) {
        await OrderHistory.update(existing.copyWith(
          status: 'merged',
          items: hubItems.isNotEmpty
              ? hubItems
              : [...existing.items, ...record.items],
          total: total,
          printJobs: existing.printJobs + jobs,
          error: '',
        ));
        await OrderHistory.remove(record.id);
        return (merged: true, duplicate: duplicate, orderNo: orderNo);
      }
    }

    await OrderHistory.update(record.copyWith(
      status: merged ? 'merged' : 'sent',
      orderNo: orderNo.isEmpty ? record.orderNo : orderNo,
      items: hubItems.isNotEmpty ? hubItems : record.items,
      total: total,
      printJobs: jobs,
      error: '',
    ));
    return (merged: merged, duplicate: duplicate, orderNo: orderNo);
  }

  static List<Map<String, dynamic>> _items(dynamic raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
      : const [];
}
