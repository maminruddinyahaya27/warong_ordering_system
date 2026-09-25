import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/order_record.dart';

/// Local outbox/history of orders this device sent to the hub.
/// Keeps the last [maxEntries] so a failed send can be seen and retried.
class OrderHistory {
  static const String _key = 'waiter_history';
  static const int maxEntries = 100;

  static Future<List<OrderRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((entry) => OrderRecord.fromJson(Map<String, dynamic>.from(entry)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<OrderRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
  }

  /// Adds a record to the top, trimming the oldest beyond [maxEntries].
  static Future<void> add(OrderRecord record) async {
    final records = await load()
      ..insert(0, record);
    await _save(records.take(maxEntries).toList());
  }

  /// Replaces a record with the same id (e.g. after a successful retry).
  static Future<void> update(OrderRecord record) async {
    final records = await load();
    final index = records.indexWhere((entry) => entry.id == record.id);
    if (index < 0) {
      records.insert(0, record);
    } else {
      records[index] = record;
    }
    await _save(records);
  }

  static Future<void> clear() => _save([]);

  /// Removes a record, e.g. the queue entry for a bill that was consolidated.
  static Future<void> remove(String id) async {
    final records = await load()..removeWhere((record) => record.id == id);
    await _save(records);
  }

  /// The sent/merged entry for an order number, used to consolidate a merged
  /// round into the bill it joined.
  static Future<OrderRecord?> findByOrderNo(String orderNo) async {
    if (orderNo.isEmpty) return null;
    final records = await load();
    for (final record in records) {
      if (record.orderNo == orderNo && !record.isPending) return record;
    }
    return null;
  }

  /// Records still waiting to reach the hub.
  static Future<List<OrderRecord>> pending() async =>
      (await load()).where((record) => record.isPending).toList();

  /// Orders that reached the hub.
  static Future<List<OrderRecord>> settled() async =>
      (await load()).where((record) => !record.isPending).toList();
}
