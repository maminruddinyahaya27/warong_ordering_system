import 'dart:convert';
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import 'app_settings.dart';

/// Renders kitchen tickets and customer receipts into ESC/POS bytes for
/// 58mm MPT-11 / MPT-58 printers.
class EscPosRenderer {
  static const _profileName = 'default';
  static const int _width = 32;

  static Future<CapabilityProfile> _profile() =>
      CapabilityProfile.load(name: _profileName);

  /// Ticket body height, from Settings → Printing → Ticket text size.
  /// 'medium' widens only — the letters get broader without getting taller, so
  /// the ticket stays compact in the hand.
  static PosTextSize _ticketHeight() =>
      switch (SettingsStore.instance.ticketTextSize) {
        'normal' => PosTextSize.size1,
        'medium' => PosTextSize.size1,
        'huge' => PosTextSize.size3,
        _ => PosTextSize.size2,
      };

  /// Ticket body width. Scaling the width as well matters: many 58mm printers
  /// silently ignore a height-only scale, so "large" doubles both and "medium"
  /// doubles this alone.
  static PosTextSize _ticketWidth() =>
      switch (SettingsStore.instance.ticketTextSize) {
        'normal' => PosTextSize.size1,
        'medium' => PosTextSize.size2,
        'huge' => PosTextSize.size3,
        _ => PosTextSize.size2,
      };

  /// Receipt text height, from Settings → Printing → Receipt text size.
  static PosTextSize _receiptHeight() =>
      switch (SettingsStore.instance.receiptTextSize) {
        'normal' => PosTextSize.size1,
        'medium' => PosTextSize.size1,
        'huge' => PosTextSize.size3,
        _ => PosTextSize.size2,
      };

  /// Receipt text width — scaled with the height, since many 58mm printers
  /// ignore a height-only scale.
  static PosTextSize _receiptWidth() =>
      switch (SettingsStore.instance.receiptTextSize) {
        'normal' => PosTextSize.size1,
        'medium' => PosTextSize.size2,
        'huge' => PosTextSize.size3,
        _ => PosTextSize.size2,
      };

  static bool _isRule(String line) {
    final trimmed = line.trim();
    return trimmed.length >= 3 &&
        trimmed.split('').every((char) => char == '-');
  }

  /// Station order ticket (no prices).
  static Future<Uint8List> renderOrder(String station, String payload) async {
    final generator = Generator(PaperSize.mm58, await _profile());
    final out = <int>[];

    // Styles are passed to text(): text() applies the default styles first,
    // which would otherwise undo a previous setStyles() call.
    // Header: the station only, sized by the ticket text size setting.
    out.addAll(generator.text(
      '[$station]',
      styles: PosStyles(
        align: PosAlign.center,
        height: _ticketHeight(),
        width: _ticketWidth(),
      ),
    ));

    // Body: enlarged per the ticket size setting. Dashed rules stay at 1x so
    // they never wrap when the body is doubled in width.
    final bodyStyle = PosStyles(
      align: PosAlign.left,
      height: _ticketHeight(),
      width: _ticketWidth(),
    );
    const ruleStyle = PosStyles(align: PosAlign.left);

    out.addAll(generator.setStyles(ruleStyle));
    out.addAll(generator.hr());
    for (final line in const LineSplitter().convert(payload)) {
      out.addAll(generator.text(
        line,
        styles: _isRule(line) ? ruleStyle : bodyStyle,
      ));
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

    // Styles must be passed to text(): text() applies the default styles first,
    // which would otherwise undo a previous setStyles() call.
    void line(String text, {PosStyles? style}) {
      out.addAll(generator.text(
        text,
        styles: style ??
            PosStyles(
              height: _receiptHeight(),
              width: _receiptWidth(),
            ),
      ));
    }

    line((data['restaurantName'] ?? 'RECEIPT').toString().toUpperCase(),
        style: PosStyles(
          align: PosAlign.center,
          height: _receiptHeight(),
          width: _receiptWidth(),
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
    var itemNumber = 0;
    // A take-away the table added on is ruled off under its own TA number.
    var section = '';
    for (final raw in items) {
      if (raw is! Map) continue;
      final name = (raw['name'] ?? '').toString();
      final qty = _toDouble(raw['qty']);
      final qtyText = _trimNumber(qty);
      final price = _money(raw['price']);
      final amount = _money(raw['line']);
      final nextSection = (raw['section'] ?? '').toString();
      if (nextSection != section) {
        section = nextSection;
        out.addAll(generator.hr());
        if (section.isNotEmpty) line(section);
      }
      if (raw['addOn'] == true) {
        // An add-on sits under the item it was ordered with.
        line('    - $name');
        line(_row('       $qtyText X $price', amount));
      } else {
        itemNumber += 1;
        line('$itemNumber. $name');
        line(_row('   $qtyText X $price', amount));
      }
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

    line(_row('Total', '$currency${_money(data['total'])}'));

    // Part payments print what is still owed.
    final balance = _toDouble(data['balance']);
    if (balance > 0) {
      line(_row('Balance', '$currency${_money(balance)}'));
    }

    final payment = (data['payment'] ?? '').toString();
    final payments = (data['payments'] as List?) ?? const [];
    if (payments.length > 1) {
      // Split bill: one tender per line, each with the change it gave back.
      for (final raw in payments) {
        if (raw is! Map) continue;
        final method = (raw['method'] ?? '').toString();
        final tendered = _toDouble(raw['tendered']);
        final paid = _toDouble(raw['amount']);
        line(_row(
          _paymentLabel(method),
          '$currency${_money(method == 'cash' && tendered > 0 ? tendered : paid)}',
        ));
        final change = _toDouble(raw['change']);
        if (change > 0) {
          line('  ${_row('Change', '$currency${_money(change)}')}');
        }
      }
    } else if (payment.isNotEmpty) {
      line(_row(_paymentLabel(payment), '$currency${_money(data['tendered'])}'));
      final change = _toDouble(data['change']);
      if (change > 0) {
        line(_row('Change', '$currency${_money(change)}'));
      }
    }

    out.addAll(generator.hr());
    final footer = (data['footer'] ?? '').toString();
    if (footer.isNotEmpty) {
      line(footer,
          style: PosStyles(
            align: PosAlign.center,
              height: _receiptHeight(),
            width: _receiptWidth(),
          ));
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
