import '../models/order.dart';
import '../models/product.dart';

/// One item together with the add-ons ordered alongside it.
class GroupedOrderLine {
  GroupedOrderLine(this.item);
  final OrderItem item;
  final List<OrderItem> children = [];
}

/// Numbers items and nests each add-on under the item it was ordered with.
///
/// An item counts as an add-on when its product lists the group of another item
/// on the same order (e.g. Kari Kambing is an add-on for Roti Canai), and it
/// attaches to the most recent such item — so two rotis each keep their own
/// curry.
List<GroupedOrderLine> groupOrderItems(
  List<OrderItem> items,
  Map<String, Product> bySku,
) {
  List<String> parentsOf(OrderItem item) => (bySku[item.sku]?.addOnFor ?? '')
      .split('|')
      .where((value) => value.isNotEmpty)
      .toList();

  bool isAddOn(OrderItem item) {
    final parents = parentsOf(item);
    if (parents.isEmpty) return false;
    return items.any((other) =>
        !identical(other, item) &&
        parents.contains(bySku[other.sku]?.category ?? ''));
  }

  final lines = <GroupedOrderLine>[];
  for (final item in items) {
    if (isAddOn(item)) {
      final parents = parentsOf(item);
      GroupedOrderLine? target;
      for (final line in lines.reversed) {
        if (parents.contains(bySku[line.item.sku]?.category ?? '')) {
          target = line;
          break;
        }
      }
      if (target != null) {
        target.children.add(item);
        continue;
      }
    }
    lines.add(GroupedOrderLine(item));
  }
  return lines;
}

/// Products keyed by SKU, for the grouping above.
Map<String, Product> productsBySku(List<Product> products) => {
      for (final product in products) product.sku: product,
    };
