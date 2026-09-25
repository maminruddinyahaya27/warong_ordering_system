/// A sellable menu item, cached from the portal's `/api/export` feed.
class Product {
  final String sku;
  final String name;
  final double price;
  final String station;
  final String category;
  final bool available;

  /// Group colour (hex, e.g. `#1565C0`) inherited from the portal's group.
  final String color;

  const Product({
    required this.sku,
    required this.name,
    required this.price,
    required this.station,
    required this.category,
    required this.available,
    this.color = '',
  });

  Map<String, dynamic> toMap() => {
        'sku': sku,
        'name': name,
        'price': price,
        'station': station,
        'category': category,
        'available': available ? 1 : 0,
        'color': color,
      };

  factory Product.fromMap(Map<String, dynamic> map) => Product(
        sku: map['sku'] as String,
        name: map['name'] as String? ?? '',
        price: (map['price'] as num?)?.toDouble() ?? 0,
        station: map['station'] as String? ?? 'KITCHEN',
        category: map['category'] as String? ?? '',
        available: map['available'] == 1 || map['available'] == true,
        color: map['color'] as String? ?? '',
      );
}
