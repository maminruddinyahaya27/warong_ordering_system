import mongoose from 'mongoose';
import MenuItem from '../lib/models/MenuItem.js';
import MenuGroup from '../lib/models/MenuGroup.js';
import Station from '../lib/models/Station.js';
import Setting from '../lib/models/Setting.js';
import PriceHistory from '../lib/models/PriceHistory.js';
import { SEED_GROUPS, SEED_MENU_ITEMS } from '../lib/seedData.js';
import { DEFAULT_STATIONS } from '../lib/constants.js';
import { connectDb, migrateLegacyData, resolveTenant } from './tenant.mjs';

const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB || undefined;
const updatePrices = process.argv.includes('--update-prices');
const skipMigrate = process.argv.includes('--skip-migrate');
const forceDemo = process.argv.includes('--with-demo-items');

// Usage:
//   node --env-file-if-exists=.env.local scripts/seed.mjs [--tenant <slug>] [--update-prices]
//
// Sets up a restaurant. Stations and settings are always ensured; the demo
// groups and menu are only added when the tenant has no menu items yet, so a
// real imported menu is never mixed with the sample data.

async function main() {
  await connectDb(uri, dbName);
  console.log(`Connected to ${dbName || '(default database)'}`);

  const tenant = await resolveTenant();
  console.log(`Seeding tenant "${tenant.name}" (${tenant.slug})`);

  if (!skipMigrate) {
    const moved = await migrateLegacyData(tenant);
    const totalMoved = Object.values(moved).reduce((sum, n) => sum + n, 0);
    if (totalMoved > 0) {
      console.log(
        `Attached pre-existing data to this tenant: ${Object.entries(moved)
          .filter(([, n]) => n > 0)
          .map(([name, n]) => `${name}=${n}`)
          .join(', ')}`
      );
    }
  }

  for (const [index, name] of DEFAULT_STATIONS.entries()) {
    await Station.updateOne(
      { tenant: tenant._id, name },
      { $setOnInsert: { tenant: tenant._id, name, sortOrder: index, printerName: '' } },
      { upsert: true }
    );
  }
  console.log(`Stations ready (${DEFAULT_STATIONS.length})`);

  await Setting.updateOne(
    { tenant: tenant._id, key: 'global' },
    {
      $setOnInsert: {
        tenant: tenant._id,
        key: 'global',
        restaurantName: 'Warong',
        currency: 'RM',
        taxRate: 0.1,
      },
    },
    { upsert: true }
  );
  console.log('Settings ready');

  const existingItems = await MenuItem.countDocuments({ tenant: tenant._id });
  const addDemoItems = existingItems === 0 || forceDemo;

  if (!addDemoItems) {
    console.log(
      `Tenant already has ${existingItems} menu item(s); skipping the demo groups and menu. ` +
        'Pass --with-demo-items to add them anyway.'
    );
  } else {
    for (const group of SEED_GROUPS) {
      await MenuGroup.updateOne(
        { tenant: tenant._id, name: group.name },
        {
          $setOnInsert: {
            tenant: tenant._id,
            name: group.name,
            description: group.description,
            sortOrder: group.sortOrder,
          },
        },
        { upsert: true }
      );
    }
    const groupDocs = await MenuGroup.find({ tenant: tenant._id }).lean();
    const groupByName = new Map(groupDocs.map((group) => [group.name, group]));
    console.log(`Groups ready (${SEED_GROUPS.length})`);

    let created = 0;
    let grouped = 0;
    let priceUpdated = 0;
    let skipped = 0;

    for (const [index, seed] of SEED_MENU_ITEMS.entries()) {
      const group = seed.group ? groupByName.get(seed.group) : null;
      const groupFields = {
        group: group ? group._id : null,
        groupName: group ? group.name : '',
      };

      const existing = await MenuItem.findOne({ tenant: tenant._id, sku: seed.sku });

      if (!existing) {
        const item = await MenuItem.create({
          tenant: tenant._id,
          sku: seed.sku,
          name: seed.name,
          price: seed.price,
          station: seed.station,
          options: seed.options || '',
          available: true,
          sortOrder: index + 1,
          ...groupFields,
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
          changedBy: 'seed',
          note: 'Seeded from index2.html MENU',
        });
        created += 1;
        continue;
      }

      let changed = false;

      if (!existing.group && groupFields.group) {
        existing.group = groupFields.group;
        existing.groupName = groupFields.groupName;
        changed = true;
        grouped += 1;
      }

      if (updatePrices && existing.price !== seed.price) {
        const oldPrice = existing.price;
        existing.price = seed.price;
        existing.name = seed.name;
        existing.station = seed.station;
        await existing.save();
        await PriceHistory.create({
          tenant: tenant._id,
          itemId: existing._id,
          sku: existing.sku,
          name: existing.name,
          action: 'update',
          oldPrice,
          newPrice: existing.price,
          station: existing.station,
          changedBy: 'seed',
          note: 'Reset to seed price',
        });
        priceUpdated += 1;
        continue;
      }

      if (changed) await existing.save();
      else skipped += 1;
    }

    console.log(
      `Menu items — created: ${created}, newly grouped: ${grouped}, price-updated: ${priceUpdated}, unchanged: ${skipped}`
    );
    if (!updatePrices && skipped > 0) {
      console.log('Existing items keep their current prices. Use --update-prices to reset them.');
    }
  }

  const [total, ungrouped] = await Promise.all([
    MenuItem.countDocuments({ tenant: tenant._id }),
    MenuItem.countDocuments({ tenant: tenant._id, group: null }),
  ]);
  console.log(`Total menu items: ${total} (ungrouped: ${ungrouped})`);
}

main()
  .catch((error) => {
    console.error('Seed failed:', error.message);
    process.exitCode = 1;
  })
  .finally(async () => {
    await mongoose.disconnect().catch(() => {});
  });
