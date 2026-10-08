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
/// A line nests under another only when it was ordered as that line's add-on,
/// recorded as a parent key when the bundle was rung up. Anything ordered on its
/// own stays a line of its own — a Rendang Ayam taken straight from the
/// Lauk-pauk group keeps its own line and its own station, even though it can
/// also be a Lempeng or Lontong add-on.
///
/// Orders with no line keys at all (rung up before the keys existed) fall back
/// to the product's "add-on for" rule: the item counts as an add-on when its
/// product lists the group of another item on the same order, and it attaches
/// to the most recent such item, so two rotis each keep their own curry.
List<GroupedOrderLine> groupOrderItems(
  List<OrderItem> items,
  Map<String, Product> bySku,
) {
  // Any line key means the order was rung up with this information, so a line
  // without a parent key was taken on its own and must not be nested by the
  // product rule. Only orders with no keys at all fall back to that rule.
  final hasLineKeys =
      items.any((item) => item.lineKey.isNotEmpty || item.parentKey.isNotEmpty);

  final lines = <GroupedOrderLine>[];
  final byKey = <String, GroupedOrderLine>{};

  if (hasLineKeys) {
    for (final item in items) {
      if (item.parentKey.isEmpty) {
        final line = GroupedOrderLine(item);
        lines.add(line);
        if (item.lineKey.isNotEmpty) byKey[item.lineKey] = line;
        continue;
      }
      final parent = byKey[item.parentKey];
      if (parent != null) {
        parent.children.add(item);
        continue;
      }
      // Its parent is not on the order: keep it visible on its own.
      lines.add(GroupedOrderLine(item));
    }
    return lines;
  }

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

/// A bill's lines in reading order: the table's own lines first, then each
/// take-away section — so a bill reads the same whether the table order or the
/// take-away was rung up first.
List<OrderItem> billLines(Order order) => [
      ...order.items.where((line) => line.section.isEmpty),
      ...order.items.where((line) => line.section.isNotEmpty),
    ];
