import 'dart:convert';

import 'package:http/http.dart' as http;

import 'hub_config.dart';

/// Sends orders to the host tablet's embedded POS server over local Wi-Fi.
/// Each order item carries its own station, so the host can split a single
/// order across multiple printers (e.g. burger -> GRIDDLE, coffee -> BEVERAGE).
class OrderService {
  static Future<bool> checkHealth() async {
    if (!HubConfig.hasHost) return false;
    try {
      final resp = await http.get(
        Uri.parse('${HubConfig.baseUrl}/health'),
        headers: HubConfig.authHeaders,
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> submitOrder({
    required String table,
    required String server,
    required List<Map<String, dynamic>> items,
    String note = '',
    String channel = 'waiter',
    String orderType = 'dine_in',
    String idempotencyKey = '',
  }) async {
    if (!HubConfig.hasHost) {
      throw Exception('Host IP is not configured');
    }

    final resp = await http
        .post(
          Uri.parse('${HubConfig.baseUrl}/order'),
          headers: {
            'Content-Type': 'application/json',
            ...HubConfig.authHeaders,
          },
          body: jsonEncode({
            'table': table,
            'server': server,
            'note': note,
            'channel': channel,
            'orderType': orderType,
            // Same key on a retry: the hub returns the original order.
            if (idempotencyKey.isNotEmpty) 'idempotencyKey': idempotencyKey,
            'items': items,
          }),
        )
        .timeout(const Duration(seconds: 8));

    if (resp.statusCode == 200) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
    if (resp.statusCode == 401) {
      throw Exception('Host rejected the credentials (401)');
    }
    throw Exception('Host returned ${resp.statusCode}');
  }
}
