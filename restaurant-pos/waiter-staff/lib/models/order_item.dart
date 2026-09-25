class OrderItem {
  final String name;
  final int qty;
  final double price;
  final String station;

  OrderItem({
    required this.name,
    required this.qty,
    required this.price,
    this.station = 'KITCHEN',
  });
}
