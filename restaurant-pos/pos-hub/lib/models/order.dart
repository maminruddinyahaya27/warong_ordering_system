class OrderItem {
  final int? id;
  final int? orderId;
  final String sku;
  final String name;
  final int qty;
  final double unitPrice;
  final double lineTotal;
  final String station;
  final String note;

  /// True once a part payment has covered this line, so the cashier can see at
  /// a glance what is still owed (paid lines print struck through).
  final bool paid;

  /// A stable key for this line, and for an add-on the key of the line it was
  /// ordered with. An empty [parentKey] means the line was ordered on its own —
  /// even when the product could be an add-on for something else, e.g. a
  /// Rendang Ayam taken straight from the Lauk-pauk group.
  final String lineKey;
  final String parentKey;

  /// The part of the bill this line belongs to, e.g. `TA - 009` for a take-away
  /// the table added on. Empty for the table's own lines; the bill prints a rule
  /// before a new section.
  final String section;

  const OrderItem({
    this.id,
    this.orderId,
    this.sku = '',
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    required this.station,
    this.note = '',
    this.paid = false,
    this.lineKey = '',
    this.parentKey = '',
    this.section = '',
  });

  OrderItem copyWith({int? qty, bool? paid, String? section}) => OrderItem(
        id: id,
        orderId: orderId,
        sku: sku,
        name: name,
        qty: qty ?? this.qty,
        unitPrice: unitPrice,
        lineTotal: (qty ?? this.qty) * unitPrice,
        station: station,
        note: note,
        paid: paid ?? this.paid,
        lineKey: lineKey,
        parentKey: parentKey,
        section: section ?? this.section,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'order_id': orderId,
        'sku': sku,
        'name': name,
        'qty': qty,
        'unit_price': unitPrice,
        'line_total': lineTotal,
        'station': station,
        'note': note,
        'paid': paid ? 1 : 0,
        'line_key': lineKey,
        'parent_key': parentKey,
        'section': section,
      };

  factory OrderItem.fromMap(Map<String, dynamic> map) => OrderItem(
        id: map['id'] as int?,
        orderId: map['order_id'] as int?,
        sku: map['sku'] as String? ?? '',
        name: map['name'] as String? ?? '',
        qty: map['qty'] as int? ?? 1,
        unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0,
        lineTotal: (map['line_total'] as num?)?.toDouble() ?? 0,
        station: map['station'] as String? ?? '',
        note: map['note'] as String? ?? '',
        paid: (map['paid'] as int? ?? 0) == 1,
        lineKey: map['line_key'] as String? ?? '',
        parentKey: map['parent_key'] as String? ?? '',
        section: map['section'] as String? ?? '',
      );
}

class Order {
  final int? id;
  final String orderNo;
  final String tableNo;
  final String serverName;
  final String note;
  final String channel; // counter | waiter
  final String status; // OPEN | PAID | VOID

  /// 'dine_in' or 'take_away' — shown on kitchen tickets and the receipt.
  final String orderType;
  final double subtotal;
  final double tax;
  final double discount;
  final double total;
  final String paymentMethod;
  final double tendered;
  final double changeDue;
  final int createdAt;
  final int? paidAt;
  final List<OrderItem> items;

  /// Total tendered so far (a bill can be split across several payments).
  final double paid;

  /// Lets a client retry a send without creating a second order.
  final String idempotencyKey;

  /// The take-away running number — `001` from `261007-TA-001` — or empty for
  /// a dine-in order.
  String get takeAwayNo {
    if (orderType != 'take_away') return '';
    final parts = orderNo.split('-');
    return parts.isEmpty ? '' : parts.last;
  }

  /// The short take-away label, e.g. `TA - 009`, for the order list and tickets.
  String get takeAwayLabel => takeAwayNo.isEmpty ? 'TA' : 'TA - $takeAwayNo';

  const Order({
    this.id,
    this.orderNo = '',
    this.tableNo = '',
    this.serverName = '',
    this.note = '',
    this.channel = 'counter',
    this.status = 'OPEN',
    this.orderType = 'dine_in',
    this.subtotal = 0,
    this.tax = 0,
    this.discount = 0,
    this.total = 0,
    this.paymentMethod = '',
    this.tendered = 0,
    this.changeDue = 0,
    this.createdAt = 0,
    this.paidAt,
    this.items = const [],
    this.paid = 0,
    this.idempotencyKey = '',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'order_no': orderNo,
        'table_no': tableNo,
        'server_name': serverName,
        'note': note,
        'channel': channel,
        'status': status,
        'order_type': orderType,
        'subtotal': subtotal,
        'tax': tax,
        'discount': discount,
        'total': total,
        'payment_method': paymentMethod,
        'tendered': tendered,
        'change_due': changeDue,
        'created_at': createdAt,
        'paid_at': paidAt,
        'idempotency_key': idempotencyKey,
      };

  factory Order.fromMap(
    Map<String, dynamic> map, {
    List<OrderItem> items = const [],
    double paid = 0,
  }) =>
      Order(
        id: map['id'] as int?,
        orderNo: map['order_no'] as String? ?? '',
        tableNo: map['table_no'] as String? ?? '',
        serverName: map['server_name'] as String? ?? '',
        note: map['note'] as String? ?? '',
        channel: map['channel'] as String? ?? 'counter',
        status: map['status'] as String? ?? 'OPEN',
        orderType: map['order_type'] as String? ?? 'dine_in',
        subtotal: (map['subtotal'] as num?)?.toDouble() ?? 0,
        tax: (map['tax'] as num?)?.toDouble() ?? 0,
        discount: (map['discount'] as num?)?.toDouble() ?? 0,
        total: (map['total'] as num?)?.toDouble() ?? 0,
        paymentMethod: map['payment_method'] as String? ?? '',
        tendered: (map['tendered'] as num?)?.toDouble() ?? 0,
        changeDue: (map['change_due'] as num?)?.toDouble() ?? 0,
        createdAt: map['created_at'] as int? ?? 0,
        paidAt: map['paid_at'] as int?,
        items: items,
        paid: paid,
        idempotencyKey: map['idempotency_key'] as String? ?? '',
      );

  /// What is still owed on this bill.
  double get balance {
    final remaining = total - paid;
    return remaining <= 0.005 ? 0 : remaining;
  }

  bool get isSettled => balance <= 0;

  Order copyWith({List<OrderItem>? items}) => Order(
        id: id,
        orderNo: orderNo,
        tableNo: tableNo,
        serverName: serverName,
        note: note,
        channel: channel,
        status: status,
        orderType: orderType,
        subtotal: subtotal,
        tax: tax,
        discount: discount,
        total: total,
        paymentMethod: paymentMethod,
        tendered: tendered,
        changeDue: changeDue,
        createdAt: createdAt,
        paidAt: paidAt,
        items: items ?? this.items,
        paid: paid,
        idempotencyKey: idempotencyKey,
      );
}
