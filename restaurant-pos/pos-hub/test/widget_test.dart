import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

import 'package:restaurant_pos_hub/models/order.dart';
import 'package:restaurant_pos_hub/models/product.dart';
import 'package:restaurant_pos_hub/services/cashier_service.dart';
import 'package:restaurant_pos_hub/services/cors.dart';
import 'package:restaurant_pos_hub/services/escpos_renderer.dart';
import 'package:restaurant_pos_hub/screens/hub_screen.dart';
import 'package:restaurant_pos_hub/services/hub_auth.dart';
import 'package:restaurant_pos_hub/services/queue_dispatcher.dart';

/// True when the byte stream contains [text] as literal ASCII.
bool containsAscii(List<int> bytes, String text) {
  final needle = text.codeUnits;
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only printer-like Bluetooth names are listed', () {
    // Common thermal receipt printers.
    for (final name in [
      'MPT-II',
      'MPT-58',
      'POS-58',
      'XP-80C',
      'RPP02N',
      'BlueTooth Printer',
      'Thermal Printer',
      'GP-58MB',
    ]) {
      expect(HubScreen.looksLikePrinter(name), isTrue, reason: name);
    }
    // Phones, watches, headsets and unnamed devices stay hidden by default.
    for (final name in [
      'Galaxy Buds3',
      'iPhone',
      'A059',
      'Smart Watch',
      '',
      null,
    ]) {
      expect(HubScreen.looksLikePrinter(name), isFalse, reason: '$name');
    }
  });

  test('station tickets have no footer, receipts keep theirs', () async {
    final ticket = await EscPosRenderer.renderOrder('Kitchen', 'Nasi Lemak x 2');
    expect(containsAscii(ticket, 'Thank you!'), isFalse,
        reason: 'kitchen tickets should stay short');

    final receipt = await EscPosRenderer.renderReceipt(jsonEncode({
      'restaurantName': 'Warong',
      'footer': 'Thank you!',
      'currency': 'RM',
      'orderNo': 'ORD-0001',
      'items': [
        {'name': 'Roti Kosong', 'qty': 1, 'price': 1.5, 'line': 1.5}
      ],
      'subtotal': 1.5,
      'tax': 0.15,
      'total': 1.65,
      'payment': 'cash',
      'tendered': 2.0,
      'change': 0.35,
    }));
    expect(containsAscii(receipt, 'Thank you!'), isTrue);
  });

  test('station names match regardless of case or spacing', () {
    // The portal sends "Griddle" while a printer may be assigned as "GRIDDLE".
    expect(
      QueueDispatcher.normalizeStation('GRIDDLE'),
      QueueDispatcher.normalizeStation('Griddle'),
    );
    expect(QueueDispatcher.normalizeStation('  Kitchen '), 'kitchen');
    expect(QueueDispatcher.normalizeStation('Wok'), 'wok');
  });

  Handler hubPipeline() {
    return const Pipeline()
        .addMiddleware(corsMiddleware())
        .addMiddleware(HubAuth.middleware())
        .addHandler((_) => Response.ok('ok'));
  }

  test('browser preflight is allowed without credentials', () async {
    HubAuth.configure(user: 'waiter', pass: 'secret');
    final handler = hubPipeline();

    final response = await handler(Request(
      'OPTIONS',
      Uri.parse('http://hub.local/order'),
      headers: {
        'origin': 'http://192.168.0.4:3000',
        'access-control-request-method': 'POST',
        'access-control-request-headers': 'authorization,content-type',
      },
    ));

    expect(response.statusCode, 204);
    expect(response.headers['access-control-allow-origin'], '*');
    expect(response.headers['access-control-allow-methods'], contains('POST'));
    expect(response.headers['access-control-allow-headers'],
        contains('authorization'));
    HubAuth.configure(user: '', pass: '');
  });

  test('auth still blocks unauthenticated requests', () async {
    HubAuth.configure(user: 'waiter', pass: 'secret');
    final handler = hubPipeline();

    final denied = await handler(
        Request('POST', Uri.parse('http://hub.local/order')));
    expect(denied.statusCode, 401);

    final allowed = await handler(Request(
      'POST',
      Uri.parse('http://hub.local/order'),
      headers: {
        'authorization':
            'Basic ${base64Encode(utf8.encode('waiter:secret'))}',
      },
    ));
    expect(allowed.statusCode, 200);
    expect(allowed.headers['access-control-allow-origin'], '*');
    HubAuth.configure(user: '', pass: '');
  });

  test('product keeps the group colour from the catalog', () {
    final product = Product.fromMap(const {
      'sku': 'ab_01',
      'name': 'Oren',
      'price': 5.0,
      'station': 'Beverage',
      'category': 'Air Buah',
      'available': 1,
      'color': '#D34AA1',
    });
    expect(product.color, '#D34AA1');
    expect(product.toMap()['color'], '#D34AA1');
  });

  test('receipt preview renders a 32-column receipt', () async {
    const order = Order(
      orderNo: 'ORD-0001',
      tableNo: '7',
      serverName: 'Aina',
      channel: 'waiter',
      status: 'PAID',
      subtotal: 8.0,
      tax: 0.8,
      total: 8.8,
      paymentMethod: 'cash',
      tendered: 9.0,
      changeDue: 0.2,
      createdAt: 1700000000000,
      paidAt: 1700000000000,
      items: [
        OrderItem(
          name: 'Roti Kosong',
          qty: 3,
          unitPrice: 1.5,
          lineTotal: 4.5,
          station: 'Griddle',
        ),
      ],
    );

    final text = await CashierService.instance.receiptPreview(order);

    expect(text, contains('ORD-0001'));
    expect(text, contains('Table: 7'));
    expect(text, contains('Server: Aina'));
    expect(text, contains('Roti Kosong'));
    expect(text, contains('Total'));
    expect(text, contains('Cash'));
    expect(text, contains('Change'));
    // Thermal paper is 32 columns wide.
    for (final line in text.split('\n')) {
      expect(line.length, lessThanOrEqualTo(32), reason: 'line too wide: "$line"');
    }
  });

  test('ESC/POS renderer produces bytes', () async {
    final bytes = await EscPosRenderer.renderOrder('KITCHEN', 'Test order');
    expect(bytes, isNotEmpty);
    // Every ESC/POS stream starts with an escape command (0x1B).
    expect(bytes.first, 0x1B);
    expect(bytes.contains(0x1B), isTrue);
  });

  test('ESC/POS receipt renderer produces bytes', () async {
    final payload = jsonEncode({
      'restaurantName': 'Warong',
      'footer': 'Thank you!',
      'currency': 'RM',
      'orderNo': 'ORD-0001',
      'table': '12',
      'server': 'Alex',
      'channel': 'counter',
      'when': '2026-09-20 15:52',
      'items': [
        {'name': 'Roti Canai', 'qty': 2, 'price': 2.5, 'line': 5.0},
        {'name': 'Teh Tarik', 'qty': 1, 'price': 3.0, 'line': 3.0},
      ],
      'subtotal': 8.0,
      'tax': 0.8,
      'taxRate': 0.1,
      'taxInclusive': false,
      'discount': 0,
      'total': 8.8,
      'payment': 'cash',
      'tendered': 9.0,
      'change': 0.2,
    });

    final bytes = await EscPosRenderer.renderReceipt(payload);
    expect(bytes, isNotEmpty);
    expect(bytes.first, 0x1B);
  });

  test('receipt renderer falls back to a ticket on bad JSON', () async {
    final bytes = await EscPosRenderer.renderReceipt('not json');
    expect(bytes, isNotEmpty);
  });
}
