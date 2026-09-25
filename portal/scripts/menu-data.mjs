// Real Warong Pak Jabit menu, transcribed from menu_makanan.jpeg and
// menu_air.jpeg. Group names must match the groups created in the portal.
// Stations must be one of: Griddle, Kitchen, Wok, Beverage.

const GRIDDLE = 'Griddle';
const KITCHEN = 'Kitchen';
const WOK = 'Wok';
const BEVERAGE = 'Beverage';

// [name, hot price, cold price] — the drinks board prices panas / sejuk
// separately, so each becomes two menu items.
const DRINKS = [
  ['Teh O', 2.0, 3.0],
  ['Teh O Limau', 2.5, 3.5],
  ['Teh', 2.5, 3.5],
  ['Kopi O', 1.5, 3.0],
  ['Kopi', 2.5, 3.5],
  ['Milo', 3.0, 4.0],
  ['Milo O', 2.5, 3.5],
  ['Nescafe', 3.0, 4.0],
  ['Neslo', 3.5, 4.0],
  ['Horlick', 3.5, 4.0],
  ['Teh Halia', 3.0, 4.0],
  ['Teh O Halia', 2.5, 3.5],
  ['Barli', 3.0, 4.0],
  ['Laici', 3.0, 4.0],
  ['Limau', 2.0, 3.0],
  ['Sirap', 2.0, 3.0],
  ['Sirap Limau', 2.5, 3.5],
  ['Sirap Bandung', 2.5, 3.5],
  ['Extra Joss', 3.5, 4.0],
];

function drinkItems() {
  const items = [];
  DRINKS.forEach(([name, hot, cold], index) => {
    const base = `min_d${String(index + 1).padStart(2, '0')}`;
    items.push({
      sku: `${base}_p`,
      name: `${name} (Panas)`,
      price: hot,
      station: BEVERAGE,
      group: 'Minuman',
      options: 'drink',
    });
    items.push({
      sku: `${base}_s`,
      name: `${name} (Sejuk)`,
      price: cold,
      station: BEVERAGE,
      group: 'Minuman',
      options: 'drink',
    });
  });
  return items;
}

export const MENU = [
  // --- Roti Canai -----------------------------------------------------------
  { sku: 'rc_01', name: 'Roti Kosong', price: 1.5, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_02', name: 'Roti Telur', price: 3.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_03', name: 'Roti Tampal', price: 3.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_04', name: 'Roti Kawin', price: 4.5, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_05', name: 'Roti Sardin', price: 4.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_06', name: 'Roti Tisu', price: 3.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_07', name: 'Roti Bom', price: 3.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_08', name: 'Roti Planta', price: 3.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_09', name: 'Roti Bawang', price: 2.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_10', name: 'Roti Jantan', price: 4.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_11', name: 'Roti Sarang Berlauk', price: 9.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_12', name: 'Roti Sarang Serunding Daging', price: 9.0, station: GRIDDLE, group: 'Roti Canai' },
  { sku: 'rc_13', name: 'Roti Sarang Kambing', price: 14.0, station: GRIDDLE, group: 'Roti Canai' },

  // --- Roti Bakar -----------------------------------------------------------
  { sku: 'rb_01', name: 'Roti Bakar', price: 3.0, station: GRIDDLE, group: 'Roti Bakar' },
  { sku: 'rb_02', name: 'Roti Jala (1 set 5 keping)', price: 4.0, station: GRIDDLE, group: 'Roti Bakar' },
  { sku: 'rb_03', name: 'Roti Jala + Lauk', price: 9.0, station: GRIDDLE, group: 'Roti Bakar' },
  { sku: 'rb_04', name: 'Roti Jala + Kambing', price: 14.0, station: GRIDDLE, group: 'Roti Bakar' },

  // --- Lempeng & Capati -----------------------------------------------------
  { sku: 'lc_01', name: 'Lempeng Kelapa', price: 3.0, station: GRIDDLE, group: 'Lempeng & Capati' },
  { sku: 'lc_02', name: 'Lempeng Kelapa + Lauk', price: 8.0, station: GRIDDLE, group: 'Lempeng & Capati' },
  { sku: 'lc_03', name: 'Lempeng Kelapa + Kambing', price: 13.0, station: GRIDDLE, group: 'Lempeng & Capati' },
  { sku: 'lc_04', name: 'Capati', price: 1.5, station: GRIDDLE, group: 'Lempeng & Capati' },

  // --- Lauk-pauk (sahaja) ---------------------------------------------------
  { sku: 'lp_01', name: 'Sambal Udang', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_02', name: 'Sambal Sardin', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_03', name: 'Sambal Kerang', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_04', name: 'Rendang Ayam', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_05', name: 'Rendang Daging', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_06', name: 'Rendang Kerang', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_07', name: 'Kari Ayam', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_08', name: 'Kari Daging', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_09', name: 'Kari Kambing', price: 10.0, station: KITCHEN, group: 'Lauk-pauk' },
  { sku: 'lp_10', name: 'Asam Pedas Daging', price: 5.0, station: KITCHEN, group: 'Lauk-pauk' },

  // --- Goreng-goreng panas --------------------------------------------------
  { sku: 'gg_01', name: 'Nasi Goreng Ayam', price: 9.0, station: WOK, group: 'Goreng-goreng' },
  { sku: 'gg_02', name: 'Nasi Goreng Cili Padi', price: 8.0, station: WOK, group: 'Goreng-goreng' },
  { sku: 'gg_03', name: 'Nasi Goreng Cina', price: 8.0, station: WOK, group: 'Goreng-goreng' },
  { sku: 'gg_04', name: 'Mee / Kuey Teow / Bihun Goreng', price: 8.0, station: WOK, group: 'Goreng-goreng' },
  { sku: 'gg_05', name: 'Mee Goreng Mamak', price: 8.0, station: WOK, group: 'Goreng-goreng' },
  { sku: 'gg_06', name: 'Mee / Kuey Teow / Bihun (Hailam / Basah)', price: 8.0, station: WOK, group: 'Goreng-goreng' },

  // --- Nasi Lemak -----------------------------------------------------------
  { sku: 'nl_01', name: 'Nasi Lemak Biasa', price: 4.0, station: KITCHEN, group: 'Nasi Lemak' },
  { sku: 'nl_02', name: 'Nasi Lemak Ayam', price: 9.0, station: KITCHEN, group: 'Nasi Lemak' },
  { sku: 'nl_03', name: 'Nasi Lemak Berlauk', price: 9.0, station: KITCHEN, group: 'Nasi Lemak' },
  { sku: 'nl_04', name: 'Nasi Lemak Kambing', price: 14.0, station: KITCHEN, group: 'Nasi Lemak' },

  // --- Lontong --------------------------------------------------------------
  { sku: 'lt_01', name: 'Lontong Kuah', price: 6.0, station: KITCHEN, group: 'Lontong' },
  { sku: 'lt_02', name: 'Lontong Goreng', price: 6.0, station: KITCHEN, group: 'Lontong' },
  { sku: 'lt_03', name: 'Lontong Darat Berlauk', price: 9.0, station: KITCHEN, group: 'Lontong' },
  { sku: 'lt_04', name: 'Lontong Darat Kambing', price: 14.0, station: KITCHEN, group: 'Lontong' },

  // --- Mee / Kuey Teow / Bihun ---------------------------------------------
  { sku: 'mee_01', name: 'Nasi / Mee / Bihun Soto', price: 6.0, station: KITCHEN, group: 'Mee / Kuey Teow / Bihun' },
  { sku: 'mee_02', name: 'Mee / Bihun / Kuey Teow Sup', price: 6.0, station: KITCHEN, group: 'Mee / Kuey Teow / Bihun' },
  { sku: 'mee_03', name: 'Mee Kari Udang', price: 8.0, station: KITCHEN, group: 'Mee / Kuey Teow / Bihun' },
  { sku: 'mee_04', name: 'Mee Kari Ayam', price: 8.0, station: KITCHEN, group: 'Mee / Kuey Teow / Bihun' },

  // --- Lain-lain (telur & ayam) --------------------------------------------
  { sku: 'll_01', name: 'Ayam Goreng / Berempah', price: 5.0, station: KITCHEN, group: 'Lain-lain' },
  { sku: 'll_02', name: 'Telur Mata', price: 1.5, station: KITCHEN, group: 'Lain-lain' },
  { sku: 'll_03', name: 'Telur Dadar', price: 2.5, station: KITCHEN, group: 'Lain-lain' },
  { sku: 'll_04', name: 'Telur Masak Separuh Masak (2 biji)', price: 3.0, station: KITCHEN, group: 'Lain-lain' },

  // --- Minuman (panas / sejuk) ---------------------------------------------
  ...drinkItems(),

  // --- Air Buah -------------------------------------------------------------
  { sku: 'ab_01', name: 'Oren', price: 5.0, station: BEVERAGE, group: 'Air Buah', options: 'drink' },
  { sku: 'ab_02', name: 'Tembikai', price: 5.0, station: BEVERAGE, group: 'Air Buah', options: 'drink' },
  { sku: 'ab_03', name: 'Apple', price: 5.0, station: BEVERAGE, group: 'Air Buah', options: 'drink' },
  { sku: 'ab_04', name: 'Apple Asam Boi', price: 5.0, station: BEVERAGE, group: 'Air Buah', options: 'drink' },
  { sku: 'ab_05', name: 'Carrot O', price: 5.0, station: BEVERAGE, group: 'Air Buah', options: 'drink' },
  { sku: 'ab_06', name: 'Carrot Susu', price: 5.0, station: BEVERAGE, group: 'Air Buah', options: 'drink' },

  // --- Cendol ---------------------------------------------------------------
  { sku: 'cen_01', name: 'Cendol Biasa', price: 3.5, station: BEVERAGE, group: 'Cendol', options: 'drink' },
  { sku: 'cen_02', name: 'Cendol Jagung', price: 4.0, station: BEVERAGE, group: 'Cendol', options: 'drink' },
  { sku: 'cen_03', name: 'Cendol Kacang', price: 4.0, station: BEVERAGE, group: 'Cendol', options: 'drink' },
];
