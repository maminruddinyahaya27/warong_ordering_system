class OrderItem {
  /// Unique per added line. Two identical items (e.g. two Roti Telur, one with a
  /// curry and one without) must stay independent so the +/- and remove buttons
  /// affect only the line they belong to.
  final String id;

  final String name;
  final int qty;
  final double price;
  final String station;

  /// Per-line note, e.g. the sweetness level for a drink.
  final String note;

  OrderItem({
    String? id,
    required this.name,
    required this.qty,
    required this.price,
    this.station = 'KITCHEN',
    this.note = '',
  }) : id = id ?? _nextId();

  static int _sequence = 0;

  static String _nextId() =>
      'L${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
}
