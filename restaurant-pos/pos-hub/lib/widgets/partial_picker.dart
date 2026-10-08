import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/product.dart';
import '../services/order_grouping.dart';

/// Lets the cashier tick the lines to pay now. Returns the amount to charge —
/// tax shared in proportion to the ticked lines — plus the units to mark paid
/// per line id, or null when cancelled.
Future<({double amount, Map<int, int> paidUnits})?> showPartialPicker(
  BuildContext context, {
  required Order order,
  required List<Product> products,
  required String currency,
}) {
  return showDialog<({double amount, Map<int, int> paidUnits})>(
    context: context,
    builder: (context) => _PartialPicker(
      order: order,
      products: products,
      currency: currency,
    ),
  );
}

class _PartialPicker extends StatefulWidget {
  const _PartialPicker({
    required this.order,
    required this.products,
    required this.currency,
  });

  final Order order;
  final List<Product> products;
  final String currency;

  @override
  State<_PartialPicker> createState() => _PartialPickerState();
}

class _PartialPickerState extends State<_PartialPicker> {
  late final List<GroupedOrderLine> _lines;

  /// The lines ticked so far, by index. The list is shaped like the order —
  /// one row per ordered line, its add-ons nested under it — so `Capati x 3` is
  /// a single row and the curry ordered with the second Capati rides with it.
  final Set<int> _picked = {};

  @override
  void initState() {
    super.initState();
    _lines = groupOrderItems(
      widget.order.items,
      productsBySku(widget.products),
    );
  }

  int get _paidCount => _lines.where((line) => line.item.paid).length;

  double get _pickedSubtotal {
    var sum = 0.0;
    for (final index in _picked) {
      final line = _lines[index];
      sum += line.item.unitPrice * line.item.qty;
      // A picked line takes its add-ons with it.
      for (final child in line.children) {
        sum += child.unitPrice * child.qty;
      }
    }
    return (sum * 100).roundToDouble() / 100;
  }

  /// The subtotal of everything still owed — the lines no part payment has
  /// covered, with their add-ons.
  double get _unpaidSubtotal {
    var sum = 0.0;
    for (final line in _lines) {
      if (line.item.paid) continue;
      sum += line.item.unitPrice * line.item.qty;
      for (final child in line.children) {
        sum += child.unitPrice * child.qty;
      }
    }
    return (sum * 100).roundToDouble() / 100;
  }

  /// The money still owed on the bill.
  double get _remaining =>
      ((widget.order.total - widget.order.paid) * 100).roundToDouble() / 100;

  /// The picked share of what is still owed, so tax is included in proportion.
  double get _amount {
    final unpaid = _unpaidSubtotal;
    if (unpaid <= 0) return 0;
    final picked = _pickedSubtotal;
    // Picking everything still owed clears the bill exactly, even when an
    // earlier part payment was an arbitrary cash amount.
    if (picked + 0.0001 >= unpaid) return _remaining;
    return ((_remaining * (picked / unpaid)) * 100).roundToDouble() / 100;
  }

  /// The units to mark paid, per line id: a picked line takes its whole
  /// quantity, and its add-ons come with it.
  Map<int, int> get _paidUnits {
    final units = <int, int>{};
    for (final index in _picked) {
      final line = _lines[index];
      if (line.item.id != null) units[line.item.id!] = line.item.qty;
      for (final child in line.children) {
        if (child.id != null) units[child.id!] = child.qty;
      }
    }
    return units;
  }

  @override
  Widget build(BuildContext context) {
    final currency = widget.currency;
    return AlertDialog(
      title: const Text('Select items to pay'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (var index = 0; index < _lines.length; index += 1)
                    ..._row(index),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Selected $currency${_amount.toStringAsFixed(2)} · '
              '${_picked.length} line(s) of '
              '$currency${_remaining.toStringAsFixed(2)} still owed'
              '${_paidCount > 0 ? ' · $_paidCount paid' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    (amount: _amount, paidUnits: _paidUnits),
                  ),
          child: const Text('Continue'),
        ),
      ],
    );
  }

  List<Widget> _row(int index) {
    final line = _lines[index];
    final currency = widget.currency;
    final paid = line.item.paid;
    const struck = TextStyle(
      decoration: TextDecoration.lineThrough,
      color: Colors.grey,
    );
    // The same shape as the order list: the quantity on the line, the add-ons
    // nested under it.
    final title = '${index + 1}. ${line.item.name}'
        '${line.item.qty > 1 ? ' x ${line.item.qty}' : ''}';

    // A line already paid is shown as paid — not as a ticked box, which reads
    // like something still picked.
    if (paid) {
      return [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading:
              const Icon(Icons.check_circle, size: 22, color: Colors.green),
          title: Text(title, style: struck),
          subtitle: const Text(
            'paid',
            style: TextStyle(fontSize: 11, color: Colors.green),
          ),
          trailing: Text(
            '$currency${_ownAmount(line).toStringAsFixed(2)}',
            style: struck,
          ),
        ),
        ..._childRows(line, covered: true, struck: struck),
      ];
    }
    return [
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _picked.contains(index),
        onChanged: (value) => setState(() {
          if (value == true) {
            _picked.add(index);
          } else {
            _picked.remove(index);
          }
        }),
        title: Text(title),
        secondary: Text('$currency${_ownAmount(line).toStringAsFixed(2)}'),
      ),
      ..._childRows(line, covered: false, struck: struck),
    ];
  }

  /// What this line itself costs; its add-ons are priced on their own rows.
  double _ownAmount(GroupedOrderLine line) =>
      ((line.item.unitPrice * line.item.qty) * 100).roundToDouble() / 100;

  /// The add-ons under a line: struck through once the line is paid.
  List<Widget> _childRows(
    GroupedOrderLine line, {
    required bool covered,
    required TextStyle struck,
  }) {
    final currency = widget.currency;
    return [
      for (final child in line.children)
        Padding(
          padding: const EdgeInsets.only(left: 34, right: 8, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '- ${child.name}${child.qty > 1 ? ' x ${child.qty}' : ''}',
                  style: covered || child.paid
                      ? struck
                      : const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              Text(
                '$currency${child.lineTotal.toStringAsFixed(2)}',
                style: covered || child.paid
                    ? struck
                    : const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
    ];
  }
}
