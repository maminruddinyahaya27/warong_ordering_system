/// A locally kept record of an order the waiter sent (or tried to send) to the
/// hub, so it can be reviewed and retried from the History page.
class OrderRecord {
  final String id;
  final String orderNo;
  final String table;
  final String server;
  final String orderType;
  final String note;
  final int createdAt;
  final String status; // pending (queued) | sent | merged
  final String error;
  final int printJobs;
  final double total;
  final List<Map<String, dynamic>> items;

  /// True while the order has not reached the hub yet — it belongs to the
  /// queue rather than the history.
  bool get isPending => status == 'pending';

  const OrderRecord({
    required this.id,
    this.orderNo = '',
    this.table = '',
    this.server = '',
    this.orderType = 'dine_in',
    this.note = '',
    required this.createdAt,
    this.status = 'sent',
    this.error = '',
    this.printJobs = 0,
    this.total = 0,
    this.items = const [],
  });

  int get itemCount =>
      items.fold<int>(0, (sum, item) => sum + ((item['qty'] as num?) ?? 0).toInt());

  bool get isTakeAway => orderType == 'take_away';

  OrderRecord copyWith({
    String? orderNo,
    String? status,
    String? error,
    int? printJobs,
    double? total,
    List<Map<String, dynamic>>? items,
  }) =>
      OrderRecord(
        id: id,
        orderNo: orderNo ?? this.orderNo,
        table: table,
        server: server,
        orderType: orderType,
        note: note,
        createdAt: createdAt,
        status: status ?? this.status,
        error: error ?? this.error,
        printJobs: printJobs ?? this.printJobs,
        total: total ?? this.total,
        items: items ?? this.items,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'order_no': orderNo,
        'table': table,
        'server': server,
        'order_type': orderType,
        'note': note,
        'created_at': createdAt,
        'status': status,
        'error': error,
        'print_jobs': printJobs,
        'total': total,
        'items': items,
      };

  factory OrderRecord.fromJson(Map<String, dynamic> json) => OrderRecord(
        id: json['id']?.toString() ?? '',
        orderNo: json['order_no']?.toString() ?? '',
        table: json['table']?.toString() ?? '',
        server: json['server']?.toString() ?? '',
        orderType: json['order_type']?.toString() ?? 'dine_in',
        note: json['note']?.toString() ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        status: json['status']?.toString() ?? 'sent',
        error: json['error']?.toString() ?? '',
        printJobs: (json['print_jobs'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toDouble() ?? 0,
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
      );
}
