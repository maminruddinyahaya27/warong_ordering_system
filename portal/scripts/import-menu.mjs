import mongoose from 'mongoose';
import MenuItem from '../lib/models/MenuItem.js';
import MenuGroup from '../lib/models/MenuGroup.js';
import PriceHistory from '../lib/models/PriceHistory.js';
import { MENU } from './menu-data.mjs';
import { connectDb, migrateLegacyData, resolveTenant } from './tenant.mjs';

// Imports the real Warong Pak Jabit menu into the portal and files each item
// under the group the user created.
//
//   node --env-file-if-exists=.env.local scripts/import-menu.mjs [--tenant <slug>] [--update]
//
// Safe to re-run: existing items are left untouched by default, so prices,
// availability (sold out) and other edits made in the portal are preserved.
// Pass --update to refresh existing items from MENU (name/price/station/group);
// even then `available` is never changed.

const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB || undefined;
const updateExisting = process.argv.includes('--update');

if (!uri) {
  console.error('MONGODB_URI is not set. Add it to .env.local or export it first.');
  process.exit(1);
}

async function main() {
  await connectDb(uri, dbName);
  console.log(`Connected to ${dbName || '(default database)'}`);

  const tenant = await resolveTenant();
  console.log(`Importing into tenant "${tenant.name}" (${tenant.slug})`);

  const moved = await migrateLegacyData(tenant);
  const totalMoved = Object.values(moved).reduce((sum, n) => sum + n, 0);
  if (totalMoved > 0) {
    console.log(`Attached pre-existing data to this tenant (${totalMoved} documents)`);
  }

  const groups = await MenuGroup.find({ tenant: tenant._id }).lean();
  const groupByName = new Map(groups.map((group) => [group.name, group]));

  const missingGroups = new Set();
  let created = 0;
  let updated = 0;
  let unchanged = 0;

  for (const [index, entry] of MENU.entries()) {
    const group = groupByName.get(entry.group);
    if (!group) missingGroups.add(entry.group);

    const fields = {
      name: entry.name,
      price: entry.price,
      station: entry.station,
      group: group ? group._id : null,
      groupName: group ? group.name : '',
      options: entry.options || '',
      sortOrder: index + 1,
    };

    const existing = await MenuItem.findOne({ tenant: tenant._id, sku: entry.sku });

    if (!existing) {
      const item = await MenuItem.create({
        tenant: tenant._id,
        sku: entry.sku,
        available: true,
        ...fields,
      });
      await PriceHistory.create({
        tenant: tenant._id,
        itemId: item._id,
        sku: item.sku,
        name: item.name,
        action: 'create',
        oldPrice: null,
        newPrice: item.price,
        station: item.station,
        changedBy: 'import',
        note: 'Imported from menu_makanan.jpeg / menu_air.jpeg',
      });
      created += 1;
      continue;
    }

    if (!updateExisting) {
      unchanged += 1;
      continue;
    }

    // Refresh from MENU, but never touch `available` (the portal controls it).
    const changed =
      existing.name !== fields.name ||
      existing.price !== fields.price ||
      existing.station !== fields.station ||
      String(existing.group || '') !== String(fields.group || '') ||
      existing.groupName !== fields.groupName ||
      existing.options !== fields.options ||
      existing.sortOrder !== fields.sortOrder;

    if (!changed) {
      unchanged += 1;
      continue;
    }

    const oldPrice = existing.price;
    Object.assign(existing, fields);
    await existing.save();

    if (oldPrice !== fields.price) {
      await PriceHistory.create({
        tenant: tenant._id,
        itemId: existing._id,
        sku: existing.sku,
        name: existing.name,
        action: 'update',
        oldPrice,
        newPrice: existing.price,
        station: existing.station,
        changedBy: 'import',
        note: 'Imported from menu_makanan.jpeg / menu_air.jpeg',
      });
    }
    updated += 1;
  }

  console.log(
    `Menu items — created: ${created}, updated: ${updated}, unchanged: ${unchanged}`
  );
  if (!updateExisting && unchanged > 0) {
    console.log('Existing items were left as-is. Use --update to refresh them from MENU.');
  }
  if (missingGroups.size > 0) {
    console.warn(
      `WARNING: groups not found, items left ungrouped: ${[...missingGroups].join(', ')}`
    );
  }

  const [total, ungrouped] = await Promise.all([
    MenuItem.countDocuments({ tenant: tenant._id }),
    MenuItem.countDocuments({ tenant: tenant._id, group: null }),
  ]);
  console.log(`Total menu items: ${total} (ungrouped: ${ungrouped})`);

  const perGroup = await MenuGroup.aggregate([
    { $match: { tenant: tenant._id } },
    { $lookup: {
        from: 'menu_items',
        localField: '_id',
        foreignField: 'group',
        as: 'items',
    } },
    { $project: { _id: 0, name: 1, count: { $size: '$items' } } },
    { $sort: { name: 1 } },
  ]);
  for (const row of perGroup) {
    console.log(`  ${row.name}: ${row.count}`);
  }
}

main()
  .catch((error) => {
    console.error('Import failed:', error.message);
    process.exitCode = 1;
  })
  .finally(async () => {
    await mongoose.disconnect().catch(() => {});
  });
