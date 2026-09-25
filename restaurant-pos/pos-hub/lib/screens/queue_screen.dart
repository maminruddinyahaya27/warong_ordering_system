import 'dart:async';

import 'package:flutter/material.dart';

import '../models/print_job.dart';
import '../services/app_events.dart';
import '../services/print_queue_db.dart';
import '../services/queue_dispatcher.dart';

/// Print queue: every ticket/receipt job, with retry and clear.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final PrintQueueDb _db = PrintQueueDb.instance;
  final QueueDispatcher _dispatcher = QueueDispatcher.instance;

  List<PrintJob> _jobs = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    AppEvents.queueRevision.addListener(_load);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    AppEvents.queueRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final jobs = await _db.getAllJobs();
    if (!mounted) return;
    setState(() {
      _jobs = jobs;
      _loading = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  int _count(String status) =>
      _jobs.where((job) => job.status == status).length;

  Future<void> _retry(PrintJob job) async {
    await _dispatcher.retryJob(job.id!);
    await _load();
    _snack('Retrying #${job.id} (${job.station})');
  }

  Future<void> _retryFailed() async {
    final failed = _jobs.where((job) => job.status == 'FAILED').toList();
    if (failed.isEmpty) {
      _snack('No failed jobs');
      return;
    }
    for (final job in failed) {
      await _db.retry(job.id!);
    }
    await _dispatcher.loadBondedPrinters();
    await _dispatcher.dispatchNext();
    await _load();
    _snack('Retrying ${failed.length} job(s)');
  }

  Future<void> _clear() async {
    if (_jobs.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the print queue?'),
        content: const Text('Removes all jobs, including any still pending.'),
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
    await _db.clear();
    await _load();
    _snack('Queue cleared');
  }

  Color _color(String status) {
    switch (status) {
      case 'DONE':
        return Colors.green;
      case 'FAILED':
        return Colors.red;
      case 'PRINTING':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final pending = _count('PENDING');
    final failed = _count('FAILED');

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Text('Print queue',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text(
                'pending $pending · failed $failed · total ${_jobs.length}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: failed == 0 ? null : _retryFailed,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text('Retry failed ($failed)'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _jobs.isEmpty ? null : _clear,
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text('Clear'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _jobs.isEmpty
              ? const Center(child: Text('Queue is empty'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _jobs.length,
                    itemBuilder: (context, index) {
                      final job = _jobs[index];
                      final color = _color(job.status);
                      final subtitle = job.error.isNotEmpty
                          ? job.error
                          : (job.printerMac.isEmpty
                              ? 'auto-routed'
                              : job.printerMac);
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withOpacity(0.2),
                          child: Text(
                            job.kind == 'receipt' ? 'R' : '#${job.id}',
                            style: TextStyle(
                                color: color,
                                fontSize: job.kind == 'receipt' ? 14 : 11),
                          ),
                        ),
                        title: Text(
                            '${job.station} · ${job.kind == 'receipt' ? 'receipt' : 'ticket'}'),
                        subtitle: Text(subtitle,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(job.status,
                                style: TextStyle(
                                    color: color,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                            if (job.status == 'FAILED' ||
                                job.status == 'PENDING')
                              IconButton(
                                tooltip: 'Retry',
                                icon: const Icon(Icons.refresh),
                                color: Colors.blue,
                                onPressed: () => _retry(job),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
