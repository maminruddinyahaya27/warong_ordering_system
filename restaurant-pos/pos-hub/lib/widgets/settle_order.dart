import 'package:flutter/material.dart';

import '../models/order.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import 'payment_dialog.dart';

/// Takes payment for [order] — possibly across several tenders, because a bill
/// can be split between two people or paid part cash / part card.
///
/// [firstAmount] charges that amount first (a partial payment for picked
/// items) instead of the whole balance; later tenders use the real balance.
///
/// Returns the order after the cashier finishes: fully settled, part-paid, or
/// unchanged when they cancel out of the first payment.
Future<Order?> settleOrder(
  BuildContext context,
  Order order, {
  double? firstAmount,
  bool askForMore = true,
  List<Map<String, dynamic>> covers = const [],
}) async {
  final cashier = CashierService.instance;
  final settings = SettingsStore.instance;
  var current = order;
  var first = true;

  while (!current.isSettled) {
    if (!context.mounted) return current.paid > 0 ? current : null;
    final partialFirst = first && firstAmount != null && firstAmount > 0;
    final isFirst = first;
    final amount = partialFirst ? firstAmount : current.balance;
    first = false;
    final payment = await showPaymentDialog(
      context,
      total: amount,
      currency: settings.currency,
      title: partialFirst
          ? 'Part payment ${settings.currency}${amount.toStringAsFixed(2)}'
          : current.paid > 0
              ? 'Balance ${settings.currency}${current.balance.toStringAsFixed(2)} '
                  'of ${settings.currency}${current.total.toStringAsFixed(2)}'
              : null,
      payableFor: (method) => cashier.payableTotal(amount, method),
    );
    if (payment == null) return current.paid > 0 ? current : null;

    try {
      // Cash passes what was handed over (so change is recorded); card and
      // e-wallet pass the amount collected, which may be a part payment.
      final isCash = payment.method == 'cash';
      current = await cashier.addPayment(
        current.id!,
        method: payment.method,
        // The items picked are what this round charges, so cash handed over
        // above them is change rather than a bigger payment. Later rounds have
        // no charge of their own and take the balance.
        amount: isCash && !partialFirst ? null : amount,
        tendered: isCash ? payment.amount : 0,
        // The items this payment covers, snapshotted onto it so its receipt
        // can be shown again later — the whole bill for a full payment, the
        // picked lines for a part payment.
        covers: isFirst ? covers : const [],
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ));
      }
      return current.paid > 0 ? current : null;
    }

    if (current.isSettled) break;

    // Part paid: offer another tender (split bill) or stop here. The item
    // picker flow asks for itself instead, so it does not prompt here.
    if (!askForMore) break;
    if (!context.mounted) break;
    final another = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            'Part paid — balance ${settings.currency}${current.balance.toStringAsFixed(2)}'),
        content: const Text('Take another payment for the rest of this bill?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add payment'),
          ),
        ],
      ),
    );
    if (another != true) break;
  }

  return current;
}
