import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/cashier_service.dart';
import '../services/print_queue_db.dart';

/// Takings for a chosen date range, plus the recent trading days.
/// Rendered inside a Scaffold provided by the shell/drawer.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final CashierService _cashier = CashierService.instance;
  final PrintQueueDb _db = PrintQueueDb.instance;
  final SettingsStore _settings = SettingsStore.instance;

  late DateTime _from;
  late DateTime _to;
  Map<String, double>? _summary;
  List<Map<String, dynamic>> _days = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, now.day);
    _to = DateTime(now.year, now.month, now.day, 23, 59, 59);
    _run();
  }

  Future<void> _run() async {
    setState(() => _loading = true);
    final summary = await _cashier.salesBetween(_from, _to);
    final days = await _db.getDaySessions(limit: 14);
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _days = days;
      _loading = false;
    });
  }

  void _setRange(DateTime from, DateTime to) {
    _from = DateTime(from.year, from.month, from.day);
    _to = DateTime(to.year, to.month, to.day, 23, 59, 59);
    _run();
  }

  Future<void> _pick(bool isFrom) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked == null) return;
    if (isFrom) {
      _setRange(picked, _to);
    } else {
      _setRange(_from, picked);
    }
  }

  String _day(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year}';
  }

  String _stamp(int? millis) {
    if (millis == null || millis <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String get _currency => _settings.currency;

  String _money(double value) => '$_currency${value.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pick(true),
                        icon: const Icon(Icons.calendar_today, size: 18),
                        label: Text('From ${_day(_from)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pick(false),
                        icon: const Icon(Icons.event, size: 18),
                        label: Text('To ${_day(_to)}'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ActionChip(
                      label: const Text('Today'),
                      onPressed: () {
                        final now = DateTime.now();
                        _setRange(now, now);
                      },
                    ),
                    ActionChip(
                      label: const Text('Yesterday'),
                      onPressed: () {
                        final now = DateTime.now();
                        final y = now.subtract(const Duration(days: 1));
                        _setRange(y, y);
                      },
                    ),
                    ActionChip(
                      label: const Text('Last 7 days'),
                      onPressed: () {
                        final now = DateTime.now();
                        _setRange(now.subtract(const Duration(days: 6)), now);
                      },
                    ),
                    ActionChip(
                      label: const Text('This month'),
                      onPressed: () {
                        final now = DateTime.now();
                        _setRange(DateTime(now.year, now.month, 1), now);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${_day(_from)} – ${_day(_to)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 8),
                      _row('Orders', (summary?['orders'] ?? 0).toInt().toString()),
                      _row('Sales', _money(summary?['sales'] ?? 0)),
                      _row('Cash', _money(summary?['cash'] ?? 0)),
                      _row('Card', _money(summary?['card'] ?? 0)),
                      _row('E-wallet', _money(summary?['ewallet'] ?? 0)),
                      _row('Take away',
                          (summary?['takeaway'] ?? 0).toInt().toString()),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Trading days',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 8),
                if (_days.isEmpty)
                  const Text('No days recorded yet',
                      style: TextStyle(color: Colors.grey))
                else
                  ..._days.map((day) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${_stamp(day['started_at'] as int?)} → '
                                '${day['ended_at'] == null ? 'open' : _stamp(day['ended_at'] as int?)}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Text(
                              day['ended_at'] == null ? 'open' : 'closed',
                              style: TextStyle(
                                fontSize: 12,
                                color: day['ended_at'] == null
                                    ? Colors.green
                                    : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      )),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
