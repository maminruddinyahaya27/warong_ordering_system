import 'package:flutter/material.dart';

class PaymentResult {
  /// The amount entered: the cash received for cash, otherwise the amount to
  /// collect now. It may be less than the balance — that is a part payment.
  final double amount;
  final String method;
  const PaymentResult(this.method, this.amount);
}

/// Cash / card / e-wallet tender dialog. Returns null if cancelled.
///
/// [payableFor] maps the selected method to the amount actually collected
/// (cash rounding), keeping the displayed change in step with the backend.
Future<PaymentResult?> showPaymentDialog(
  BuildContext context, {
  required double total,
  String currency = 'RM',
  String? title,
  double Function(String method)? payableFor,
}) {
  return showDialog<PaymentResult>(
    context: context,
    builder: (context) => _PaymentDialog(
      total: total,
      currency: currency,
      title: title,
      payableFor: payableFor,
    ),
  );
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({
    required this.total,
    required this.currency,
    this.title,
    this.payableFor,
  });

  final double total;
  final String currency;
  final String? title;
  final double Function(String method)? payableFor;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String _method = 'cash';
  late final TextEditingController _amount;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: widget.total.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _confirm() {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    Navigator.pop(context, PaymentResult(_method, amount));
  }

  @override
  Widget build(BuildContext context) {
    final isCash = _method == 'cash';
    final payable = widget.payableFor?.call(_method) ?? widget.total;
    final entered = double.tryParse(_amount.text.trim()) ?? 0;
    // Cash can be over-tendered (change given); card/e-wallet cannot.
    final collected = isCash ? (entered < payable ? entered : payable) : entered;
    final change = isCash && entered > payable ? entered - payable : 0.0;
    final overCard = !isCash && entered > payable + 0.0001;
    final balanceAfter = payable - collected;
    final valid = entered > 0 && !overCard;

    return AlertDialog(
      title: Text(widget.title ??
          'Charge ${widget.currency}${payable.toStringAsFixed(2)}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'cash', label: Text('Cash')),
              ButtonSegment(value: 'card', label: Text('Card')),
              ButtonSegment(value: 'ewallet', label: Text('E-Wallet')),
            ],
            selected: {_method},
            onSelectionChanged: (selection) =>
                setState(() => _method = selection.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: isCash ? 'Cash received' : 'Amount to pay',
              prefixText: '${widget.currency} ',
              border: const OutlineInputBorder(),
              helperText: 'Enter less for a part payment',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Text(
            'Paying now: ${widget.currency}${collected.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (balanceAfter > 0.0001)
            Text(
              'Balance left: ${widget.currency}${balanceAfter.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          if (change > 0)
            Text(
              'Change: ${widget.currency}${change.toStringAsFixed(2)}',
              style: TextStyle(
                color: Colors.green.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (overCard)
            Text(
              'Card / e-wallet cannot be more than the balance',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid ? _confirm : null,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
