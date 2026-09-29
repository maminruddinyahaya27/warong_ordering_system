class OrderItem {
  final String name;
  final int qty;
  final double price;
  final String station;

  /// Per-line note, e.g. the sweetness level for a drink.
  final String note;

  OrderItem({
    required this.name,
    required this.qty,
    required this.price,
    this.station = 'KITCHEN',
    this.note = '',
  });
}
