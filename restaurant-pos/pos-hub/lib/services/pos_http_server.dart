import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/order.dart';
import 'cashier_service.dart';
import 'cors.dart';
import 'hub_auth.dart';
import 'menu_sync_service.dart';
import 'print_queue_db.dart';

/// Embedded HTTP server: menu feed, order intake and cashier endpoints on the
/// local Wi-Fi. All routes except `GET /health` obey HTTP Basic auth when
/// credentials are configured (see [HubAuth]).
class PosHttpServer {
  static final PosHttpServer instance = PosHttpServer._internal(port: 8080);
  PosHttpServer._internal({this.port = 8080});

  final PrintQueueDb db = PrintQueueDb.instance;
  final CashierService cashier = CashierService.instance;
  final MenuSyncService menuSync = MenuSyncService.instance;

  int port;
  HttpServer? _server;

  bool get isRunning => _server != null;

  /// Called when a new order is received. Used to refresh the UI.
  void Function()? onOrderReceived;

  Future<void> start() async {
    final handler = const Pipeline()
        .addMiddleware(corsMiddleware())
        .addMiddleware(HubAuth.middleware())
        .addHandler(_router);

    final candidates = [port, 8081, 8082, 8090];
    for (final p in candidates) {
      try {
        _server = await shelf_io.serve(handler, '0.0.0.0', p);
        port = p;
        return;
      } on SocketException {
        continue;
      }
    }
    throw Exception('No available port to bind HTTP server');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _router(Request request) async {
    final segments =
        request.url.path.split('/').where((s) => s.isNotEmpty).toList();
    final method = request.method;

    try {
      if (method == 'GET' && segments.length == 1 && segments[0] == 'health') {
        return await _health();
      }
      if (method == 'GET' && segments.length == 1 && segments[0] == 'menu') {
        return await _menu();
      }
      if (method == 'POST' &&
          segments.length == 2 &&
          segments[0] == 'menu' &&
          segments[1] == 'sync') {
        return await _syncMenu();
      }
      if (method == 'POST' &&
          segments.length == 1 &&
          segments[0] == 'order') {
        return await _createOrder(request);
      }
      if (method == 'GET' && segments.length == 1 && segments[0] == 'orders') {
        return await _listOrders(request);
      }
      if (method == 'GET' && segments.length == 1 && segments[0] == 'day') {
        return await _dayStatus();
      }
      if (method == 'POST' &&
          segments.length == 2 &&
          segments[0] == 'day' &&
          segments[1] == 'start') {
        return await _startDay(request);
      }
      if (method == 'POST' &&
          segments.length == 2 &&
          segments[0] == 'day' &&
          segments[1] == 'end') {
        return await _endDay(request);
      }
      if (method == 'GET' &&
          segments.length == 1 &&
          segments[0] == 'reports') {
        return await _reports(request);
      }
      if (segments.length >= 2 && segments[0] == 'orders') {
        final id = int.tryParse(segments[1]);
        if (id == null) {
          return _json(400, {'error': 'invalid order id'});
        }
        if (method == 'GET' && segments.length == 2) {
          return await _getOrder(id);
        }
        if (method == 'POST' && segments.length == 3) {
          switch (segments[2]) {
            case 'pay':
              return await _payOrder(request, id);
            case 'void':
              return await _voidOrder(id);
            case 'reprint':
              return await _reprint(id);
            case 'items':
              return await _addOrderItems(request, id);
            case 'payments':
              return await _addPayment(request, id);
          }
        }
        if (method == 'PATCH' &&
            segments.length == 4 &&
            segments[2] == 'items') {
          final itemId = int.tryParse(segments[3]);
          if (itemId == null) {
            return _json(400, {'error': 'invalid item id'});
          }
          return await _setOrderItemQty(request, id, itemId);
        }
      }
      return _json(404, {'error': 'not found'});
    } catch (e) {
      return _json(400, {'error': e.toString().replaceFirst('Exception: ', '')});
    }
  }

  Future<Response> _health() async {
    final pending = await db.getPendingJobs();
    final open = await db.countOrders(status: 'OPEN');
    return _json(200, {
      'status': 'ok',
      'service': 'restaurant-pos-hub',
      'queue': pending.length,
      'openOrders': open,
      'auth': HubAuth.enabled,
    });
  }

  Future<Response> _menu() async {
    final products = await db.getProducts();
    return _json(200, {
      'items': products
          .map((p) => {
                'sku': p.sku,
                'name': p.name,
                'price': p.price,
                'station': p.station,
                'category': p.category,
                'color': p.color,
                'options': p.options,
                'addOnFor': p.addOnFor,
                'requireAddOn': p.requireAddOn,
                'available': p.available,
              })
          .toList(),
      'count': products.length,
    });
  }

  Future<Response> _syncMenu() async {
    final result = await menuSync.sync();
    return _json(200, {
      'count': result.count,
      'syncedAt': result.syncedAt.toIso8601String(),
    });
  }

  Future<Response> _createOrder(Request request) async {
    final body = await _readJson(request);
    if (body == null) {
      return _json(400, {'error': 'invalid JSON body'});
    }

    final items = await _resolveItems(body['items']);
    if (items.isEmpty) {
      return _json(400, {'error': 'order has no items'});
    }

    final table = (body['table'] ?? '').toString().trim();
    final orderType = _orderType(body['orderType']);
    if (orderType == 'dine_in' && table.isEmpty) {
      return _json(400, {
        'error': 'table number is required for dine-in orders',
      });
    }

    // Clients send a retry key so a repeat of the same order is a no-op.
    final retryKey = (request.headers['idempotency-key'] ??
            body['idempotencyKey'] ??
            '')
        .toString()
        .trim();

    final result = await cashier.createOrAppendOrder(
      channel: (body['channel'] ?? 'waiter').toString(),
      tableNo: table,
      serverName: (body['server'] ?? '').toString(),
      note: (body['note'] ?? '').toString(),
      orderType: orderType,
      idempotencyKey: retryKey,
      items: items,
    );
    final order = result.order;

    onOrderReceived?.call();
    final stations = order.items
        .map((item) => item.station.isEmpty ? 'KITCHEN' : item.station)
        .toSet()
        .length;
    return _json(200, {
      'order_id': order.id,
      'order_no': order.orderNo,
      'order_type': order.orderType,
      'merged': result.merged,
      'duplicate': result.duplicate,
      'print_jobs': stations,
      'totals': _totalsJson(order),
      // The full bill, so a client can show the consolidated order.
      'items': order.items
          .map((item) => {
                'sku': item.sku,
                'name': item.name,
                'qty': item.qty,
                'price': item.unitPrice,
                'line_total': item.lineTotal,
                'station': item.station,
                'note': item.note,
              })
          .toList(),
    });
  }

  /// Accepts 'take_away' / 'takeaway' / 'TAKE AWAY'; anything else is dine-in.
  String _orderType(dynamic raw) {
    final value = raw
        ?.toString()
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');
    return value == 'take_away' || value == 'takeaway' ? 'take_away' : 'dine_in';
  }

  Future<Response> _listOrders(Request request) async {
    final status = request.url.queryParameters['status'];
    final orders = await db.getOrders(status: status);
    return _json(200, {
      'orders': orders.map(_orderJson).toList(),
      'count': orders.length,
    });
  }

  /// Open/closed state of the trading day plus the takings so far.
  Future<Response> _dayStatus() async {
    final active = await cashier.activeDay();
    if (active == null) {
      return _json(200, {'open': false, 'orders': 0, 'sales': 0});
    }
    final start = (active['started_at'] as int?) ?? 0;
    final summary = await db.salesBetween(
        start, DateTime.now().millisecondsSinceEpoch);
    return _json(200, {
      'open': true,
      'started_at': start,
      ...summary,
    });
  }

  Future<Response> _startDay(Request request) async {
    final body = await _readJson(request) ?? <String, dynamic>{};
    final day = await cashier.openDay(by: (body['by'] ?? 'cashier').toString());
    return _json(200, {'open': true, ...day});
  }

  Future<Response> _endDay(Request request) async {
    final body = await _readJson(request) ?? <String, dynamic>{};
    final summary =
        await cashier.closeDay(by: (body['by'] ?? 'cashier').toString());
    return _json(200, {'open': false, ...summary});
  }

  /// Takings between two ISO timestamps: /reports?from=...&to=...
  Future<Response> _reports(Request request) async {
    final params = request.url.queryParameters;
    final from = DateTime.tryParse(params['from'] ?? '');
    final to = DateTime.tryParse(params['to'] ?? '');
    if (from == null || to == null) {
      return _json(400, {'error': 'from and to ISO timestamps are required'});
    }
    final summary = await cashier.salesBetween(from, to);
    return _json(200, {
      'from': from.toIso8601String(),
      'to': to.toIso8601String(),
      ...summary,
    });
  }

  Future<Response> _getOrder(int id) async {
    final order = await db.getOrder(id);
    if (order == null) {
      return _json(404, {'error': 'order not found'});
    }
    return _json(200, {'order': _orderJson(order)});
  }

  Future<Response> _payOrder(Request request, int id) async {
    final body = await _readJson(request) ?? <String, dynamic>{};
    final method = (body['method'] ?? 'cash').toString();
    final tendered = _toDouble(body['tendered']);
    final order = await cashier.payOrder(id, method: method, tendered: tendered);
    onOrderReceived?.call();
    return _json(200, {'order': _orderJson(order)});
  }

  Future<Response> _voidOrder(int id) async {
    await cashier.voidOrder(id);
    final order = await db.getOrder(id);
    return _json(200, {'order': order == null ? null : _orderJson(order)});
  }

  Future<Response> _reprint(int id) async {
    final order = await db.getOrder(id);
    if (order == null) {
      return _json(404, {'error': 'order not found'});
    }
    await cashier.reprintReceipt(order);
    return _json(200, {'status': 'queued', 'order_no': order.orderNo});
  }

  /// Adds lines to an open order (used to amend a waiter's order at the till)
  /// and prints tickets for the new lines only.
  Future<Response> _addOrderItems(Request request, int orderId) async {
    final body = await _readJson(request) ?? <String, dynamic>{};
    final items = await _resolveItems(body['items']);
    if (items.isEmpty) {
      return _json(400, {'error': 'no items to add'});
    }
    final order = await cashier.addOrderItems(orderId, items);
    onOrderReceived?.call();
    return _json(200, {'order': _orderJson(order)});
  }

  /// Applies one tender to a bill. Used to split a bill across payments;
  /// the order settles once the tenders cover the total.
  Future<Response> _addPayment(Request request, int orderId) async {
    final body = await _readJson(request) ?? <String, dynamic>{};
    final method = (body['method'] ?? 'cash').toString();
    final tendered = _toDouble(body['tendered']);
    final order = await cashier.addPayment(orderId, method: method, tendered: tendered);
    onOrderReceived?.call();
    return _json(200, {'order': _orderJson(order)});
  }

  /// Sets a line's quantity. `qty: 0` removes the line.
  Future<Response> _setOrderItemQty(
      Request request, int orderId, int itemId) async {
    final body = await _readJson(request) ?? <String, dynamic>{};
    final qty = _toDouble(body['qty']).round();
    final order = await cashier.setOrderItemQty(orderId, itemId, qty);
    onOrderReceived?.call();
    return _json(200, {'order': _orderJson(order)});
  }

  /// Prices order lines from the cached catalog; client prices are only a
  /// fallback when the item is unknown.
  Future<List<OrderItem>> _resolveItems(dynamic rawItems) async {
    if (rawItems is! List) return const [];
    final products = await db.getProducts();
    final bySku = {for (final p in products) p.sku: p};
    final byName = {
      for (final p in products) p.name.toLowerCase(): p,
    };

    final items = <OrderItem>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final name = (map['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final qty = (_toDouble(map['qty']).round()).clamp(1, 999).toInt();
      final product = bySku[(map['sku'] ?? '').toString()] ??
          byName[name.toLowerCase()];
      final unitPrice =
          product?.price ?? _toDouble(map['price']);
      items.add(OrderItem(
        sku: product?.sku ?? (map['sku'] ?? '').toString(),
        name: name,
        qty: qty,
        unitPrice: unitPrice,
        lineTotal: _round2(unitPrice * qty),
        station: product?.station ??
            (map['station'] ?? 'KITCHEN').toString(),
        note: (map['note'] ?? '').toString(),
        // The sender can say how the line was rung up: its own key and, for an
        // add-on, the key of the line it was ordered with.
        lineKey: (map['lineKey'] ?? '').toString(),
        parentKey: (map['parentKey'] ?? '').toString(),
      ));
    }
    return items;
  }

  Future<Map<String, dynamic>?> _readJson(Request request) async {
    try {
      final body = await request.readAsString();
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _orderJson(Order order) => {
        'id': order.id,
        'order_no': order.orderNo,
        'table': order.tableNo,
        'server': order.serverName,
        'note': order.note,
        'channel': order.channel,
        'status': order.status,
        'order_type': order.orderType,
        'payment_method': order.paymentMethod,
        'tendered': order.tendered,
        'change': order.changeDue,
        'created_at': order.createdAt,
        'paid_at': order.paidAt,
        ..._totalsJson(order),
        'items': order.items
            .map((i) => {
                  'sku': i.sku,
                  'name': i.name,
                  'qty': i.qty,
                  'price': i.unitPrice,
                  'line_total': i.lineTotal,
                  'station': i.station,
                  'note': i.note,
                })
            .toList(),
      };

  Map<String, dynamic> _totalsJson(Order order) => {
        'subtotal': order.subtotal,
        'tax': order.tax,
        'discount': order.discount,
        'total': order.total,
        'paid': order.paid,
        'balance': order.balance,
      };

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _round2(double value) => (value * 100).roundToDouble() / 100;

  Response _json(int status, Map<String, dynamic> data) {
    return Response(status, body: jsonEncode(data), headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
    });
  }
}
