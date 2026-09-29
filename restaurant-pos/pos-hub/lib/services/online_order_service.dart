import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/order.dart';
import 'app_settings.dart';
import 'cashier_service.dart';
import 'print_queue_db.dart';

/// Polls the portal for orders customers placed by scanning a table QR code,
/// merges them into the table's bill on this hub and prints the station
/// tickets, then marks each order imported so it is never pulled twice.
class OnlineOrderService {
  static final OnlineOrderService instance = OnlineOrderService._internal();
  OnlineOrderService._internal();

  final SettingsStore _settings = SettingsStore.instance;
  final PrintQueueDb _db = PrintQueueDb.instance;
  final CashierService _cashier = CashierService.instance;

  Timer? _timer;
  bool _busy = false;
  DateTime? lastPull;
  String? lastError;
  int importedCount = 0;

  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(pullQuietly()),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static String _trim(String base) {
    var value = base.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static String pendingUrl(String base) =>
      '${_trim(base)}/api/online-orders/pending';

  static String ackUrl(String base, String id) =>
      '${_trim(base)}/api/online-orders/$id/ack';

  Map<String, String> _headers() {
    final headers = <String, String>{'Accept': 'application/json'};
    if (_settings.portalUser.isNotEmpty || _settings.portalPass.isNotEmpty) {
      final token = base64Encode(
          utf8.encode('${_settings.portalUser}:${_settings.portalPass}'));
      headers['authorization'] = 'Basic $token';
    }
    return headers;
  }

  /// Never throws: a slow or unreachable portal must not disturb the till.
  Future<void> pullQuietly() async {
    try {
      await pull();
    } catch (error) {
      lastError = error.toString().replaceFirst('Exception: ', '');
      await _settings.save({
        'qr_last_error': lastError!,
        'qr_last_pull': DateTime.now().toIso8601String(),
      });
    }
  }

  /// Fetches and imports pending QR orders. Returns how many were handled.
  Future<int> pull() async {
    if (_busy || !_settings.acceptQrOrders) return 0;
    final base = _settings.portalUrl;
    if (base.isEmpty) return 0;

    _busy = true;
    try {
      final response = await http
          .get(Uri.parse(pendingUrl(base)), headers: _headers())
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 401) {
        throw Exception('Portal rejected the credentials (401)');
      }
      if (response.statusCode != 200) {
        throw Exception('Portal returned ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      final list = (decoded is Map && decoded['orders'] is List)
          ? decoded['orders'] as List
          : const [];

      var handled = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        await _importOrder(Map<String, dynamic>.from(raw));
        handled += 1;
      }

      lastPull = DateTime.now();
      lastError = null;
      importedCount += handled;
      await _settings.save({
        'qr_last_pull': lastPull!.toIso8601String(),
        'qr_last_error': '',
      });
      return handled;
    } finally {
      _busy = false;
    }
  }

  Future<void> _importOrder(Map<String, dynamic> order) async {
    final id = order['id']?.toString() ?? '';
    final table = (order['table'] ?? '').toString().trim();
    final ref = (order['ref'] ?? '').toString();
    final note = (order['note'] ?? '').toString();
    final rawItems = order['items'] is List ? order['items'] as List : const [];

    if (id.isEmpty || table.isEmpty) return;

    final products = await _db.getProducts();
    final bySku = {for (final product in products) product.sku: product};

    final items = <OrderItem>[];
    final missing = <String>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final sku = (raw['sku'] ?? '').toString();
      final qty = (raw['qty'] as num?)?.toInt() ?? 0;
      final product = bySku[sku];
      if (product == null || qty <= 0) {
        missing.add(sku.isEmpty ? 'unknown' : sku);
        continue;
      }
      items.add(OrderItem(
        sku: product.sku,
        name: product.name,
        qty: qty,
        unitPrice: product.price,
        lineTotal: product.price * qty,
        station: product.station,
        note: (raw['note'] ?? '').toString(),
      ));
    }

    if (items.isEmpty) {
      await _ack(
        id,
        status: 'rejected',
        reason: missing.isEmpty
            ? 'No items in the order'
            : 'Not on this menu: ${missing.join(', ')}',
      );
      throw Exception('QR order $ref rejected (items not on this menu)');
    }

    // 'qr' channel keeps QR orders identifiable next to counter/waiter ones.
    // Idempotent by portal id, so a retry never doubles the items.
    final result = await _cashier.createOrAppendOrder(
      channel: 'qr',
      tableNo: table,
      note: [
        if (note.isNotEmpty) note,
        if (missing.isNotEmpty) 'QR item not on menu: ${missing.join(', ')}',
      ].join(' | '),
      items: items,
      idempotencyKey: 'online:$id',
    );

    await _ack(id, status: 'imported', hubOrderNo: result.order.orderNo);
  }

  Future<void> _ack(
    String id, {
    required String status,
    String hubOrderNo = '',
    String reason = '',
  }) async {
    final base = _settings.portalUrl;
    if (base.isEmpty) return;
    final response = await http
        .post(
          Uri.parse(ackUrl(base, id)),
          headers: {..._headers(), 'Content-Type': 'application/json'},
          body: jsonEncode({
            'status': status,
            'hubOrderNo': hubOrderNo,
            'reason': reason,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Portal ack returned ${response.statusCode}');
    }
  }
}
