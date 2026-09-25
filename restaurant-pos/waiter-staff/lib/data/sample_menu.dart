import '../models/menu_item.dart';

/// Demo menu shown when the POS Hub / menu feed cannot be reached, so waiters
/// can still browse and rehearse the flow. Mirrors the web mockup's sample
/// data and uses the same item names as the real imported menu so the
/// quick-picks row is populated. Prices are not used by the waiter app (the hub
/// prices orders from its own catalog), so they are left at zero.
const List<MenuItem> kSampleMenu = [
  MenuItem(name: 'Teh O (Panas)', station: 'Beverage', category: 'Minuman', color: '#1565C0'),
  MenuItem(name: 'Teh O (Sejuk)', station: 'Beverage', category: 'Minuman', color: '#1565C0'),
  MenuItem(name: 'Teh Tarik (Panas)', station: 'Beverage', category: 'Minuman', color: '#1565C0'),
  MenuItem(name: 'Milo (Panas)', station: 'Beverage', category: 'Minuman', color: '#1565C0'),
  MenuItem(name: 'Nasi Lemak Biasa', station: 'Kitchen', category: 'Nasi Lemak', color: '#EF6C00'),
  MenuItem(name: 'Nasi Lemak Ayam', station: 'Kitchen', category: 'Nasi Lemak', color: '#EF6C00'),
  MenuItem(name: 'Roti Kosong', station: 'Griddle', category: 'Roti Canai', color: '#6A1B9A'),
  MenuItem(name: 'Roti Telur', station: 'Griddle', category: 'Roti Canai', color: '#6A1B9A'),
  MenuItem(name: 'Roti Sardin', station: 'Griddle', category: 'Roti Canai', color: '#6A1B9A', available: false),
  MenuItem(name: 'Mee Goreng Mamak', station: 'Wok', category: 'Goreng-goreng', color: '#D84315'),
];
