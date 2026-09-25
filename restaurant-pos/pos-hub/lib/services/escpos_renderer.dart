import 'dart:convert';
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

/// Renders kitchen tickets and customer receipts into ESC/POS bytes for
/// 58mm MPT-11 / MPT-58 printers.
class EscPosRenderer {
  static const _profileName = 'default';
  static const int _width = 32;

  static Future<CapabilityProfile> _profile() =>
      CapabilityProfile.load(name: _profileName);

  /// Station order ticket (no prices).
  static Future<Uint8List> renderOrder(String station, String payload) async {
    final generator = Generator(PaperSize.mm58, await _profile());
    final out = <int>[];

    out.addAll(generator.setStyles(const PosStyles(
      align: PosAlign.center,
      bold: true,
      height: PosTextSize.size2,
      width: PosTextSize.size2,
    )));
    out.addAll(generator.text('RESTAURANT ORDER'));

    out.addAll(generator.setStyles(const PosStyles(
      align: PosAlign.center,
      bold: true,
    )));
    out.addAll(generator.text('[$station]'));

    out.addAll(generator.setStyles(const PosStyles(align: PosAlign.left)));
    out.addAll(generator.hr());
    for (final line in const LineSplitter().convert(payload)) {
      out.addAll(generator.text(line));
    }

    // No footer on station tickets: the payload already ends with a rule, and
    // kitchen tickets should use as little paper as possible.
    out.addAll(generator.feed(2));
    out.addAll(generator.cut(mode: PosCutMode.partial));
    return Uint8List.fromList(out);
  }

  /// Customer receipt rendered from a JSON payload produced by CashierService.
  static Future<Uint8List> renderReceipt(String payloadJson) async {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(payloadJson) as Map<String, dynamic>;
    } catch (_) {
      return renderOrder('CASHIER', payloadJson);
    }

    final currency = (data['currency'] ?? '').toString();
    final generator = Generator(PaperSize.mm58, await _profile());
    final out = <int>[];

    void line(String text, {PosStyles? style}) {
      if (style != null) out.addAll(generator.setStyles(style));
      out.addAll(generator.text(text));
    }

    line((data['restaurantName'] ?? 'RECEIPT').toString().toUpperCase(),
        style: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ));
    final when = (data['when'] ?? '').toString();
    if (when.isNotEmpty) {
      line(when, style: const PosStyles(align: PosAlign.center));
    }
    line('', style: const PosStyles(align: PosAlign.left));
    out.addAll(generator.hr());

    final orderNo = (data['orderNo'] ?? '').toString();
    if (orderNo.isNotEmpty) line('Order: $orderNo');
    final table = (data['table'] ?? '').toString();
    if (table.isNotEmpty) line('Table: $table');
    final orderType = (data['orderType'] ?? '').toString();
    if (orderType.isNotEmpty) {
      line(orderType == 'take_away' ? 'Type:  TAKE AWAY' : 'Type:  Dine-in');
    }
    final server = (data['server'] ?? '').toString();
    if (server.isNotEmpty) line('Server: $server');
    out.addAll(generator.hr());

    final items = (data['items'] as List?) ?? const [];
    for (final raw in items) {
      if (raw is! Map) continue;
      final name = (raw['name'] ?? '').toString();
      final qty = raw['qty'] ?? 1;
      final price = _money(raw['price']);
      final amount = _money(raw['line']);
      line(name);
      line(_row('  $qty x $price', amount));
    }
    out.addAll(generator.hr());

    line(_row('Subtotal', '$currency${_money(data['subtotal'])}'));
    final tax = _toDouble(data['tax']);
    if (tax > 0) {
      final rate = _toDouble(data['taxRate']) * 100;
      final rateText = rate > 0 ? ' (${_trimNumber(rate)}%)' : '';
      line(_row('Tax$rateText', '$currency${_money(data['tax'])}'));
    }
    final discount = _toDouble(data['discount']);
    if (discount > 0) {
      line(_row('Discount', '-$currency${_money(discount)}'));
    }

    line(_row('TOTAL', '$currency${_money(data['total'])}'),
        style: const PosStyles(bold: true));

    final payment = (data['payment'] ?? '').toString();
    final payments = (data['payments'] as List?) ?? const [];
    if (payments.length > 1) {
      // Split bill: one line per tender.
      for (final raw in payments) {
        if (raw is! Map) continue;
        line(_row(_paymentLabel((raw['method'] ?? '').toString()),
            '$currency${_money(raw['amount'])}'));
      }
    } else if (payment.isNotEmpty) {
      line(_row(_paymentLabel(payment), '$currency${_money(data['tendered'])}'));
    }
    final change = _toDouble(data['change']);
    if (change > 0) {
      line(_row('Change', '$currency${_money(change)}'));
    }

    out.addAll(generator.hr());
    final footer = (data['footer'] ?? '').toString();
    if (footer.isNotEmpty) {
      line(footer, style: const PosStyles(align: PosAlign.center));
    }

    out.addAll(generator.feed(2));
    out.addAll(generator.cut(mode: PosCutMode.partial));
    return Uint8List.fromList(out);
  }

  static String _row(String left, String right) {
    final space = _width - right.length - left.length;
    if (space <= 0) {
      return '$left $right';
    }
    return '$left${' ' * space}$right';
  }

  static String _paymentLabel(String method) {
    switch (method) {
      case 'cash':
        return 'Cash';
      case 'card':
        return 'Card';
      case 'ewallet':
        return 'E-Wallet';
      default:
        return method;
    }
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _money(dynamic value) => _toDouble(value).toStringAsFixed(2);

  static String _trimNumber(double value) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }
}
