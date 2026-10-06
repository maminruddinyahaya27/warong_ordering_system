import 'package:flutter/material.dart';

/// Shows exactly what each station's ticket will say before anything prints,
/// and lets the cashier send one station's ticket on its own.
///
/// [tickets] maps each station to the text its printer receives, so a wrong
/// station or an add-on that did not follow its parent is caught at the till
/// instead of at the pass.
Future<void> showTicketPreview(
  BuildContext context, {
  required String orderNo,
  required Map<String, String> tickets,
  required Future<void> Function(String station) onPrint,
}) {
  final stations = tickets.keys.toList()..sort();
  // Survives the dialog's rebuilds, unlike a local inside the builder below.
  final queued = <String>{};

  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        Future<void> print(String station) async {
          await onPrint(station);
          if (!context.mounted) return;
          setDialogState(() => queued.add(station));
        }

        return AlertDialog(
          title: Text('Ticket preview · $orderNo'),
          content: SizedBox(
            width: 420,
            child: stations.isEmpty
                ? const Text('This order has no items to print.')
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final station in stations)
                          _StationTicket(
                            label: station.trim().isEmpty
                                ? 'KITCHEN'
                                : station.toUpperCase(),
                            text: tickets[station] ?? '',
                            queued: queued.contains(station),
                            onPrint: () => print(station),
                          ),
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

/// One station's ticket: a header with its own print button, then the ticket
/// text as the printer receives it.
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
