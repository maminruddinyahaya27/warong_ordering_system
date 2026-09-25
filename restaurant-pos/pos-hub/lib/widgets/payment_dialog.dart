import 'package:flutter/material.dart';

class PaymentResult {
  final String method;
  final double tendered;
  const PaymentResult(this.method, this.tendered);
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
  late final TextEditingController _tendered;

  @override
  void initState() {
    super.initState();
    _tendered = TextEditingController(text: widget.total.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _tendered.dispose();
    super.dispose();
  }

  void _confirm() {
    final tendered = double.tryParse(_tendered.text.trim()) ?? 0;
    Navigator.pop(context, PaymentResult(_method, tendered));
  }

  @override
  Widget build(BuildContext context) {
    final isCash = _method == 'cash';
    final payable = widget.payableFor?.call(_method) ?? widget.total;
    final tendered = double.tryParse(_tendered.text.trim()) ?? 0;
    final change = tendered - payable;

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
          if (isCash) ...[
            TextField(
              controller: _tendered,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Tendered',
                prefixText: '${widget.currency} ',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              change >= 0
                  ? 'Change: ${widget.currency}${change.toStringAsFixed(2)}'
                  : 'Short by ${widget.currency}${(-change).toStringAsFixed(2)}',
              style: TextStyle(
                color: change >= 0 ? Colors.green.shade700 : Colors.red.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (!isCash || change >= -0.0001) ? _confirm : null,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
