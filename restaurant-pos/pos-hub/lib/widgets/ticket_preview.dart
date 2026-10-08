import 'package:flutter/material.dart';

/// Shows exactly what each ticket will say before anything prints, and lets the
/// cashier send one ticket on its own.
///
/// [tickets] is one entry per ticket — a station, and for a take-away the table
/// added on, its own `TA - 009` ticket — with the text its printer receives, so
/// a wrong station or an add-on that did not follow its parent is caught at the
/// till instead of at the pass.
Future<void> showTicketPreview(
  BuildContext context, {
  required String orderNo,
  required List<({String label, String text})> tickets,
  required Future<void> Function(int index) onPrint,
}) {
  final queued = <int>{};

  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        Future<void> print(int index) async {
          await onPrint(index);
          if (!context.mounted) return;
          setDialogState(() => queued.add(index));
        }

        return AlertDialog(
          title: Text('Ticket preview · $orderNo'),
          content: SizedBox(
            width: 420,
            child: tickets.isEmpty
                ? const Text('This order has no items to print.')
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < tickets.length; i += 1) ...[
                          // Each ticket is ruled off from the last.
                          if (i > 0) const Divider(height: 24, thickness: 1.2),
                          _StationTicket(
                            label: tickets[i].label,
                            text: tickets[i].text,
                            queued: queued.contains(i),
                            onPrint: () => print(i),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}

/// One ticket: a header with its own print button, then the text as the printer
/// receives it.
class _StationTicket extends StatelessWidget {
  const _StationTicket({
    required this.label,
    required this.text,
    required this.queued,
    required this.onPrint,
  });

  final String label;
  final String text;
  final bool queued;
  final Future<void> Function() onPrint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.print_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (queued) ...[
                const Icon(Icons.check_circle, size: 16, color: Colors.green),
                const SizedBox(width: 4),
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text(
                    'Queued',
                    style: TextStyle(fontSize: 12, color: Colors.green),
                  ),
                ),
              ],
              TextButton.icon(
                onPressed: queued ? null : () => onPrint(),
                icon: const Icon(Icons.print, size: 16),
                label: const Text('Print'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              // A ticket is a black-on-white print-out; match it so the text
              // stays readable inside the app's dark theme.
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade400),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(
                color: Colors.black,
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
