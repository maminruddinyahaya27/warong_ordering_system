class MenuItem {
  final String name;
  final String station;
  final double price;
  final String category;

  /// Group colour (hex, e.g. `#1565C0`) from the portal, via the hub feed.
  final String color;

  final bool available;

  const MenuItem({
    required this.name,
    this.station = 'KITCHEN',
    this.price = 0,
    this.category = '',
    this.color = '',
    this.available = true,
  });

  factory MenuItem.fromJson(Map<String, dynamic> json) {
    return MenuItem(
      name: json['name']?.toString() ?? '',
      station: json['station']?.toString() ?? 'KITCHEN',
      price: (json['price'] is num) ? (json['price'] as num).toDouble() : 0,
      category: json['category']?.toString() ?? '',
      color: (json['color'] ?? json['groupColor'])?.toString() ?? '',
      available: json['available'] != false,
    );
  }
}
