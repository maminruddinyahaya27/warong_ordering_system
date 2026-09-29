import 'package:flutter/material.dart';

/// Asks how much of a bill to charge. Returns 'full', 'partial' or null when
/// the cashier cancels.
Future<String?> showChargeModeDialog(
  BuildContext context, {
  required String title,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: const Text(
        'Pay the whole bill, or tick the items to pay now. A part payment '
        'leaves the rest of the bill open.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, 'partial'),
          child: const Text('Partial'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'full'),
          child: const Text('Full'),
        ),
      ],
    ),
  );
}
