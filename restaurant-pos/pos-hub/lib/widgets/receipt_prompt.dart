import 'package:flutter/material.dart';

/// After taking payment, ask whether the customer wants a printed receipt.
Future<bool> askPrintReceipt(BuildContext context, String orderNo) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('$orderNo paid'),
      content: const Text('Print the customer receipt?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('No receipt'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.print, size: 18),
          label: const Text('Print receipt'),
        ),
      ],
    ),
  );
  return result ?? false;
}
