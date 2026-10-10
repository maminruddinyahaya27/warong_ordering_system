import 'print_queue_db.dart';

/// Typed, cached access to the hub's persistent settings.
class SettingsStore {
  static final SettingsStore instance = SettingsStore._internal();
  SettingsStore._internal();

  final PrintQueueDb _db = PrintQueueDb.instance;
  final Map<String, String> _cache = {};

  Future<void> load() async {
    final values = await _db.getAllSettings();
    _cache
      ..clear()
      ..addAll(values);
  }

  Map<String, String> get raw => Map.unmodifiable(_cache);

  String _string(String key, [String fallback = '']) =>
      (_cache[key] ?? fallback).trim();

  double _double(String key, double fallback) {
    final parsed = double.tryParse(_cache[key] ?? '');
    return parsed ?? fallback;
  }

  bool _bool(String key, bool fallback) {
    final value = _cache[key];
    if (value == null) return fallback;
    return value == 'true' || value == '1';
  }

  // Menu source (portal)
  String get portalUrl => _string('portal_url');
  String get portalUser => _string('portal_user');
  String get portalPass => _string('portal_pass');

  // Devices -> hub credentials
  String get hubUser => _string('hub_user');
  String get hubPass => _string('hub_pass');
  bool get hubAuthEnabled => hubUser.isNotEmpty || hubPass.isNotEmpty;

  // Receipt / money
  String get restaurantName => _string('restaurant_name', 'WARONG');
  String get currency => _string('currency', 'RM');
  String get receiptFooter => _string('receipt_footer', 'Thank you!');
  double get taxRate => _double('tax_rate', 0.10);
  bool get taxInclusive => _bool('tax_inclusive', false);
  double get roundingStep => _double('rounding_step', 0.05);

  /// Gap between prints to the same printer. Shared printers (two stations on
  /// one device) need this, otherwise the second job fails.
  int get printerCooldownMs =>
      _double('printer_cooldown_ms', 1500).round().clamp(0, 10000);

  /// Text size on kitchen station tickets: 'normal' | 'medium' | 'large' |
  /// 'huge'. Larger text is easier to read from across a hot kitchen; 'medium'
  /// widens the letters without making them taller.
  String get ticketTextSize {
    final value = _string('ticket_text_size', 'large');
    return ['normal', 'medium', 'large', 'huge'].contains(value)
        ? value
        : 'large';
  }

  /// Text size on customer receipts: 'normal' | 'large' | 'huge'. Falls back
  /// to the ticket size, so an install that predates this keeps its look.
  String get receiptTextSize {
    final value = _string('receipt_text_size', '');
    if (['normal', 'medium', 'large', 'huge'].contains(value)) return value;
    return ticketTextSize;
  }

  /// New dine-in orders for a table that still has an open bill are added to
  /// that bill, so the table pays on one receipt.
  bool get autoMergeTableOrders => _bool('auto_merge_table_orders', true);

  /// Import orders customers placed by scanning a table QR code.
  bool get acceptQrOrders => _bool('accept_qr_orders', false);

  String get qrLastPull => _string('qr_last_pull');
  String get qrLastError => _string('qr_last_error');

  /// Minutes of no interaction before the tablet is allowed to sleep. The
  /// screen is kept on while the till is being used.
  int get keepAwakeMinutes =>
      _double('keep_awake_minutes', 30).round().clamp(1, 480);

  String get lastSyncAt => _string('last_sync_at');
  String get lastSyncError => _string('last_sync_error');

  Future<void> save(Map<String, String> values) async {
    await _db.setSettings(values);
    _cache.addAll(values.map((k, v) => MapEntry(k, v)));
  }

  Future<void> put(String key, String value) => save({key: value});
}
