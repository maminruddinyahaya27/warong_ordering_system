import 'package:flutter/material.dart';

class PaymentResult {
  /// The amount entered: the cash received for cash, otherwise the amount to
  /// collect now. It may be less than the balance — that is a part payment.
  final double amount;
  final String method;
  const PaymentResult(this.method, this.amount);
}

/// Cash / e-wallet tender dialog. Returns null if cancelled.
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
  final FocusNode _amountFocus = FocusNode();
  bool _selectedOnce = false;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: widget.total.toStringAsFixed(2));
    // Focused and pre-selected, so the cashier just types what was handed over.
    _amountFocus.addListener(() {
      if (_amountFocus.hasFocus && !_selectedOnce) {
        _selectedOnce = true;
        _amount.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _amount.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  void _setAmount(double value) {
    _amount.text = value.toStringAsFixed(2);
    _amount.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _amount.text.length,
    );
    setState(() {});
  }

  /// The notes a cashier is likely handed: the exact amount, then the next
  /// round notes up to RM100.
  List<double> get _quickCash {
    final payable = widget.payableFor?.call('cash') ?? widget.total;
    final options = <double>[payable];
    for (final note in const [1, 5, 10, 20, 50, 100]) {
      if (note >= payable - 0.0001) options.add(note.toDouble());
    }
    return options.take(4).toList();
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
    // Cash can be over-tendered (change given); e-wallet cannot.
    final collected = isCash ? (entered < payable ? entered : payable) : entered;
    final change = isCash && entered > payable ? entered - payable : 0.0;
    final overCard = !isCash && entered > payable + 0.0001;
    final balanceAfter = payable - collected;
    final valid = entered > 0 && !overCard;
    final theme = Theme.of(context);

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: Text(widget.title ??
          'Charge ${widget.currency}${payable.toStringAsFixed(2)}'),
      content: SizedBox(
        // Roomy, so the amount being keyed in is easy to read and hit.
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'cash', label: Text('Cash')),
                ButtonSegment(value: 'ewallet', label: Text('E-Wallet')),
              ],
              selected: {_method},
              onSelectionChanged: (selection) =>
                  setState(() => _method = selection.first),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _amount,
              focusNode: _amountFocus,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
              decoration: InputDecoration(
                labelText: isCash ? 'Cash received' : 'Amount to pay',
                prefixText: '${widget.currency} ',
                prefixStyle: const TextStyle(fontSize: 22),
                filled: true,
                fillColor: theme.colorScheme.primary.withOpacity(0.08),
                border: const OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide:
                      BorderSide(color: theme.colorScheme.primary, width: 2),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide:
                      BorderSide(color: theme.colorScheme.primary, width: 3),
                ),
                helperText: 'Enter less for a part payment',
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (isCash) ...[
              const SizedBox(height: 10),
              // Common notes, so the cashier taps instead of typing.
              Wrap(
                spacing: 8,
                children: [
                  for (final amount in _quickCash)
                    ActionChip(
                      label: Text('${widget.currency}'
                          '${amount.toStringAsFixed(2)}'),
                      onPressed: () => _setAmount(amount),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Paying now: ${widget.currency}${collected.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (balanceAfter > 0.0001)
              Text(
                'Balance left: ${widget.currency}'
                '${balanceAfter.toStringAsFixed(2)}',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            if (change > 0)
              Text(
                'Change: ${widget.currency}${change.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.green.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (overCard)
              Text(
                'E-wallet cannot be more than the balance',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
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
