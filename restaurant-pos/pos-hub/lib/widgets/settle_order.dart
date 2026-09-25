import 'package:flutter/material.dart';

import '../models/order.dart';
import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import 'payment_dialog.dart';

/// Takes payment for [order] — possibly across several tenders, because a bill
/// can be split between two people or paid part cash / part card.
///
/// Returns the order after the cashier finishes: fully settled, part-paid, or
/// unchanged when they cancel out of the first payment.
Future<Order?> settleOrder(BuildContext context, Order order) async {
  final cashier = CashierService.instance;
  final settings = SettingsStore.instance;
  var current = order;

  while (!current.isSettled) {
    if (!context.mounted) return current.paid > 0 ? current : null;
    final balance = current.balance;
    final payment = await showPaymentDialog(
      context,
      total: balance,
      currency: settings.currency,
      title: current.paid > 0
          ? 'Balance ${settings.currency}${balance.toStringAsFixed(2)} '
              'of ${settings.currency}${current.total.toStringAsFixed(2)}'
          : null,
      payableFor: (method) => cashier.payableTotal(balance, method),
    );
    if (payment == null) return current.paid > 0 ? current : null;

    try {
      current = await cashier.addPayment(
        current.id!,
        method: payment.method,
        tendered: payment.tendered,
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

    // Part paid: offer another tender (split bill) or stop here.
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
