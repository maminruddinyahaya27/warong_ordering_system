class MenuItem {
  final String name;
  final String station;
  final double price;
  final String category;

  /// Group colour (hex, e.g. `#1565C0`) from the portal, via the hub feed.
  final String color;

  /// Portal item options, e.g. `drink` — drives the sweetness prompt.
  final String options;

  /// Parent groups this item is an add-on for (joined with `|`), so a curry
  /// ordered with a roti canai prints on the roti station.
  final String addOnFor;

  final bool available;

  const MenuItem({
    required this.name,
    this.station = 'KITCHEN',
    this.price = 0,
    this.category = '',
    this.color = '',
    this.options = '',
    this.addOnFor = '',
    this.available = true,
  });

  bool get isDrink => options.toLowerCase().contains('drink');

  factory MenuItem.fromJson(Map<String, dynamic> json) {
    return MenuItem(
      name: json['name']?.toString() ?? '',
      station: json['station']?.toString() ?? 'KITCHEN',
      price: (json['price'] is num) ? (json['price'] as num).toDouble() : 0,
      category: json['category']?.toString() ?? '',
      color: (json['color'] ?? json['groupColor'])?.toString() ?? '',
      options: json['options']?.toString() ?? '',
      addOnFor: json['addOnFor']?.toString() ?? '',
      available: json['available'] != false,
    );
  }
}
