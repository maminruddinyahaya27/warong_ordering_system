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
  Map<String, Product> bySku, {
  // A take-away's lines always nest by the product rule, even when the sender
  // did not record which line an add-on was ordered with (a QR order, say).
  bool nestLoose = false,
}) {
  // Any line key means the order was rung up with this information, so a line
  // without a parent key was taken on its own and must not be nested by the
  // product rule. Only orders with no keys at all fall back to that rule.
  final hasLineKeys =
      items.any((item) => item.lineKey.isNotEmpty || item.parentKey.isNotEmpty);

  final lines = <GroupedOrderLine>[];
  final byKey = <String, GroupedOrderLine>{};

  // Nests an item under the most recent dish it can be an add-on for: the
  // product's "add-on for" rule. A take-away line may attach to a dish on the
  // table's own lines, which is how a later "one more curry" joins the nasi
  // lemak already ordered.
  bool nestByRule(OrderItem item, {bool dishesOnly = false}) {
    final forGroups = bySku[item.sku]?.addOnFor ?? '';
    if (forGroups.isEmpty) return false;
    for (final line in lines.reversed) {
      final parentSection = line.item.section;
      if (parentSection.isNotEmpty && parentSection != item.section) continue;
      final parentProduct = bySku[line.item.sku];
      // A dish that exists to take a lauk (`Nasi Lemak + Lauk`) collects the
      // curries rung beside it; a plain dish (`Lontong Kuah`) does not, so a
      // curry taken with it prints on its own station as before.
      if (dishesOnly && parentProduct?.requireAddOn != true) continue;
      final parentCategory = parentProduct?.category ?? '';
      if (forGroups.split('|').contains(parentCategory)) {
        line.children.add(item);
        return true;
      }
    }
    return false;
  }

  if (hasLineKeys) {
    for (final item in items) {
      if (item.parentKey.isEmpty) {
        // A dish taken on its own stays on its own — unless it is an add-on
        // rung beside a dish that exists to take one (Nasi Lemak + Lauk), or it
        // came in as a take-away line, or the whole order is a take-away, where
        // it can be an add-on for a dish on the same order or already on the
        // table.
        // A `requireAddOn` dish beside it collects the curry, whatever kind of
        // order this is.
        if (nestByRule(item, dishesOnly: true)) continue;
        // Otherwise only a take-away line (or a whole take-away order) is
        // treated as an add-on for a dish on the table.
        if ((nestLoose || item.section.isNotEmpty) && nestByRule(item)) {
          continue;
        }
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
      // Its recorded parent is not on this order — e.g. the add-on was rung in
      // an earlier round — so fall back to the product's add-on rule and keep
      // the add-on on its parent's station.
      if (nestByRule(item)) continue;
      // No parent at all: keep it visible on its own.
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
