import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/product.dart';
import '../services/order_grouping.dart';

/// Lets the cashier tick the items to pay now. Returns the amount to charge —
/// tax shared in proportion to the ticked items — plus the line ids to mark as
/// paid, or null when cancelled.
Future<({double amount, List<int> itemIds})?> showPartialPicker(
  BuildContext context, {
  required Order order,
  required List<Product> products,
  required String currency,
}) {
  return showDialog<({double amount, List<int> itemIds})>(
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

  /// The units ticked so far, keyed "lineIndex:unit". A line of two shows two
  /// rows so one plate can be paid without the other.
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    _lines = groupOrderItems(
      widget.order.items,
      productsBySku(widget.products),
    );
  }

  int get _paidCount => _lines.where((line) => line.item.paid).length;

  /// How many of a line's units are ticked.
  int _pickedUnits(int index) {
    var count = 0;
    for (var unit = 0; unit < _lines[index].item.qty; unit += 1) {
      if (_picked.contains('$index:$unit')) count += 1;
    }
    return count;
  }

  /// A line counts as paid once every one of its units is ticked, and then its
  /// add-ons are covered too.
  bool _fullyPicked(int index) =>
      _pickedUnits(index) == _lines[index].item.qty;

  /// The receipt-style number of a line's first unit.
  int _firstNumber(int index) {
    var number = 1;
    for (var i = 0; i < index; i += 1) {
      number += _lines[i].item.qty;
    }
    return number;
  }

  double get _pickedSubtotal {
    var sum = 0.0;
    for (var index = 0; index < _lines.length; index += 1) {
      final line = _lines[index];
      sum += line.item.unitPrice * _pickedUnits(index);
      if (_fullyPicked(index)) {
        for (final child in line.children) {
          sum += child.unitPrice * child.qty;
        }
      }
    }
    return (sum * 100).roundToDouble() / 100;
  }

  /// The picked share of the bill's total, so tax is included in proportion.
  double get _amount {
    final subtotal = widget.order.subtotal;
    if (subtotal <= 0) return 0;
    final picked = _pickedSubtotal;
    return ((widget.order.total * (picked / subtotal)) * 100).roundToDouble() /
        100;
  }

  List<int> get _pickedIds {
    final ids = <int>[];
    for (var index = 0; index < _lines.length; index += 1) {
      if (!_fullyPicked(index)) continue;
      final line = _lines[index];
      // A fully picked item covers its add-ons too, so the receipt and the
      // paid markers include the whole bundle.
      if (line.item.id != null) ids.add(line.item.id!);
      for (final child in line.children) {
        if (child.id != null) ids.add(child.id!);
      }
    }
    return ids;
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
              '${_picked.length} item(s) of '
              '$currency${widget.order.total.toStringAsFixed(2)}'
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
                    (amount: _amount, itemIds: _pickedIds),
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
    final qty = line.item.qty;
    final first = _firstNumber(index);
    const struck = TextStyle(
      decoration: TextDecoration.lineThrough,
      color: Colors.grey,
    );
    return [
      // One row per unit: two of the same dish are two numbered lines, so one
      // plate can be paid on its own.
      for (var unit = 0; unit < qty; unit += 1)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: paid || _picked.contains('$index:$unit'),
          // An item already covered by a part payment cannot be picked again.
          onChanged: paid
              ? null
              : (value) => setState(() {
                    final key = '$index:$unit';
                    if (value == true) {
                      _picked.add(key);
                    } else {
                      _picked.remove(key);
                    }
                  }),
          title: Text(
            '${first + unit}. ${line.item.name}',
            style: paid ? struck : null,
          ),
          secondary: Text(
            '$currency${line.item.unitPrice.toStringAsFixed(2)}',
            style: paid ? struck : null,
          ),
        ),
      for (final child in line.children)
        Padding(
          padding: const EdgeInsets.only(left: 34, right: 8, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '- ${child.name}${child.qty > 1 ? ' x ${child.qty}' : ''}',
                  style: paid || child.paid
                      ? struck
                      : const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              Text(
                '$currency${child.lineTotal.toStringAsFixed(2)}',
                style: paid || child.paid
                    ? struck
                    : const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
    ];
  }
}
