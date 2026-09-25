export const SEED_GROUPS = [
  { name: 'Roti & Toast', description: 'Griddle breads and toast', sortOrder: 1 },
  { name: 'Rice', description: 'Rice dishes', sortOrder: 2 },
  { name: 'Noodles', description: 'Noodle dishes', sortOrder: 3 },
  { name: 'Sides', description: 'Add-ons and sides', sortOrder: 4 },
  { name: 'Drinks', description: 'Beverages', sortOrder: 5 },
];

export const SEED_MENU_ITEMS = [
  { sku: 'mi_001', name: 'Roti Canai', price: 2.5, station: 'Griddle', group: 'Roti & Toast' },
  { sku: 'mi_002', name: 'Roti Telur', price: 4.0, station: 'Griddle', group: 'Roti & Toast' },
  { sku: 'mi_003', name: 'Nasi Lemak', price: 5.5, station: 'Kitchen', group: 'Rice' },
  { sku: 'mi_004', name: 'Nasi Lemak Ayam', price: 8.5, station: 'Kitchen', group: 'Rice' },
  { sku: 'mi_005', name: 'Mee Goreng', price: 7.0, station: 'Wok', group: 'Noodles' },
  { sku: 'mi_006', name: 'Mee Goreng Mamak', price: 8.5, station: 'Wok', group: 'Noodles' },
  { sku: 'mi_007', name: 'Char Kway Teow', price: 8.0, station: 'Wok', group: 'Noodles' },
  { sku: 'mi_008', name: 'Nasi Goreng', price: 7.5, station: 'Wok', group: 'Rice' },
  { sku: 'mi_009', name: 'Kuey Teow Sup', price: 7.5, station: 'Wok', group: 'Noodles' },
  { sku: 'mi_010', name: 'Lontong', price: 6.5, station: 'Kitchen', group: 'Rice' },
  { sku: 'mi_011', name: 'Half-Boiled Eggs', price: 2.0, station: 'Kitchen', group: 'Sides' },
  { sku: 'mi_012', name: 'Roti Bakar', price: 4.5, station: 'Griddle', group: 'Roti & Toast' },
  { sku: 'mi_013', name: 'Kaya Toast', price: 4.0, station: 'Griddle', group: 'Roti & Toast' },
  { sku: 'mi_014', name: 'Teh Tarik', price: 3.0, station: 'Beverage', options: 'drink', group: 'Drinks' },
  { sku: 'mi_015', name: 'Kopi O', price: 2.8, station: 'Beverage', options: 'drink', group: 'Drinks' },
  { sku: 'mi_016', name: 'Milo Ais', price: 3.5, station: 'Beverage', options: 'drink', group: 'Drinks' },
  { sku: 'mi_017', name: 'Teh O Limau', price: 3.2, station: 'Beverage', options: 'drink', group: 'Drinks' },
  { sku: 'mi_018', name: 'Air Sirap', price: 3.0, station: 'Beverage', options: 'drink', group: 'Drinks' },
];

export const UNGROUPED_LABEL = 'Ungrouped';
