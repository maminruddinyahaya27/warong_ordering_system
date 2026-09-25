import 'package:flutter/material.dart';

import '../models/order_record.dart';
import '../services/order_history.dart';

/// Orders this device has sent to the hub, newest first. Failed sends can be
/// retried from here.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<OrderRecord> _records = [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // History holds what actually reached the hub; queued sends live in Queue.
    final records = await OrderHistory.settled();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Color _statusColor(String status) =>
      status == 'merged' ? Colors.blue : Colors.green;

  String _statusLabel(String status) => status == 'merged' ? 'MERGED' : 'SENT';

  String _timeLabel(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<void> _clear() async {
    if (_records.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear order history?'),
        content: const Text('This only clears history on this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await OrderHistory.clear();
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    record.isTakeAway
                        ? 'Take Away - ${record.orderNo}'
                        : (record.orderNo.isEmpty
                            ? 'Not sent'
                            : record.orderNo),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text(_statusLabel(record.status)),
                  labelStyle: TextStyle(
                    color: _statusColor(record.status),
                    fontWeight: FontWeight.bold,
                  ),
                  side: BorderSide(color: _statusColor(record.status)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (record.isTakeAway) 'Take away',
                if (record.table.isNotEmpty) 'Table ${record.table}',
                if (record.server.isNotEmpty) record.server,
                _timeLabel(record.createdAt),
              ].where((part) => part.isNotEmpty).join(' · '),
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
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order history'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            onPressed: _records.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_sweep),
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
                      'No orders sent yet.\nOrders you send appear here.',
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
                                ? 'Take Away - ${record.orderNo}'
                                : (record.orderNo.isEmpty
                                    ? 'Not sent'
                                    : record.orderNo),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text([
                            if (record.table.isNotEmpty && !record.isTakeAway)
                              'Table ${record.table}',
                            '${record.itemCount} item(s)',
                            _timeLabel(record.createdAt),
                          ].join(' · ')),
                          trailing: busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      _statusLabel(record.status),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: _statusColor(record.status),
                                      ),
                                    ),
                                    if (record.printJobs > 0)
                                      Text(
                                        '${record.printJobs} ticket(s)',
                                        style: const TextStyle(
                                            fontSize: 11, color: Colors.grey),
                                      ),
                                  ],
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
