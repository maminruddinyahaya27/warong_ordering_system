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
      for (final child in line.children) {
        sum += child.unitPrice * child.qty;
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
    for (final index in _picked) {
      final line = _lines[index];
      // A picked item covers its add-ons too, so the receipt and the paid
      // markers include the whole bundle.
      if (line.item.id != null) ids.add(line.item.id!);
      for (final child in line.children) {
        if (child.id != null) ids.add(child.id!);
      }
    }
    return ids;
  }

  double _lineAmount(GroupedOrderLine line) {
    var total = line.item.lineTotal;
    for (final child in line.children) {
      total += child.lineTotal;
    }
    return (total * 100).roundToDouble() / 100;
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
    const struck = TextStyle(
      decoration: TextDecoration.lineThrough,
      color: Colors.grey,
    );
    return [
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: paid ? true : _picked.contains(index),
        // An item already covered by a part payment cannot be picked again.
        onChanged: paid
            ? null
            : (value) => setState(() {
                  if (value == true) {
                    _picked.add(index);
                  } else {
                    _picked.remove(index);
                  }
                }),
        title: Text(
          '${index + 1}. ${line.item.name} x ${line.item.qty}',
          style: paid ? struck : null,
        ),
        secondary: Text(
          '$currency${_lineAmount(line).toStringAsFixed(2)}',
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
