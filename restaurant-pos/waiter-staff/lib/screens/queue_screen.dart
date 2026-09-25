import 'package:flutter/material.dart';

import '../models/order_record.dart';
import '../services/order_history.dart';
import '../services/order_sender.dart';

/// Orders that have not reached the hub yet — a failed send stays here so it
/// can be sent again. Successful sends move to the order history.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  List<OrderRecord> _records = [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await OrderHistory.pending();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _timeLabel(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<void> _send(OrderRecord record) async {
    setState(() => _busyId = record.id);
    try {
      final outcome = await OrderSender.send(record);
      _snack(outcome.merged
          ? 'Added to ${outcome.orderNo}'
          : 'Sent ${outcome.orderNo}');
    } catch (error) {
      await OrderHistory.update(record.copyWith(
        error: error.toString().replaceFirst('Exception: ', ''),
      ));
      _snack('Still queued: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busyId = null);
      await _load();
    }
  }

  Future<void> _sendAll() async {
    for (final record in List<OrderRecord>.of(_records)) {
      await _send(record);
    }
  }

  Future<void> _delete(OrderRecord record) async {
    await OrderHistory.remove(record.id);
    await _load();
  }

  void _showDetail(OrderRecord record) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              record.isTakeAway
                  ? 'Take Away (not sent)'
                  : 'Table ${record.table} (not sent)',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (record.server.isNotEmpty) record.server,
                _timeLabel(record.createdAt),
              ].join(' · '),
              style: const TextStyle(color: Colors.grey),
            ),
            if (record.error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(record.error,
                  style: const TextStyle(color: Colors.redAccent)),
            ],
            const Divider(height: 24),
            ...record.items.map((item) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text((item['name'] ?? '').toString()),
                  subtitle: Text((item['station'] ?? '').toString()),
                  leading: Text('${item['qty'] ?? 0}x'),
                )),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busyId == record.id
                  ? null
                  : () {
                      Navigator.pop(context);
                      _send(record);
                    },
              icon: const Icon(Icons.send),
              label: const Text('Send now'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _delete(record);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queued orders'),
        actions: [
          if (_records.isNotEmpty)
            TextButton.icon(
              onPressed: _busyId == null ? _sendAll : null,
              icon: const Icon(Icons.send, size: 18),
              label: const Text('Send all'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nothing queued.\nOrders that fail to send wait here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      final record = _records[index];
                      final busy = _busyId == record.id;
                      return Card(
                        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(record.isTakeAway
                                ? 'TA'
                                : (record.table.isEmpty ? '—' : record.table)),
                          ),
                          title: Text(
                            record.isTakeAway
                                ? 'Take Away'
                                : 'Table ${record.table}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text([
                            '${record.itemCount} item(s)',
                            _timeLabel(record.createdAt),
                            if (record.error.isNotEmpty) record.error,
                          ].join(' · '), maxLines: 2),
                          trailing: busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : FilledButton(
                                  onPressed: () => _send(record),
                                  child: const Text('Send'),
                                ),
                          onTap: () => _showDetail(record),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
