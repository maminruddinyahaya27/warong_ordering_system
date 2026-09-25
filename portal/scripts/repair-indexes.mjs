import mongoose from 'mongoose';
import MenuItem from '../lib/models/MenuItem.js';
import MenuGroup from '../lib/models/MenuGroup.js';
import Station from '../lib/models/Station.js';
import Setting from '../lib/models/Setting.js';
import PriceHistory from '../lib/models/PriceHistory.js';
import { SEED_GROUPS } from '../lib/seedData.js';
import { connectDb, resolveTenant } from './tenant.mjs';

// Repairs databases that were created before (or during) the move to
// multi-tenant data. Symptom it fixes:
//
//   E11000 duplicate key error ... settings index: key_1 dup key: { key: "global" }
//   E11000 duplicate key error ... settings index: tenant_1_key_1 dup key: { tenant: null, ... }
//
// Steps:
//   1. drop the unique indexes (stale single-field ones, and the compound ones
//      that would reject the repair writes),
//   2. attach documents with no `tenant` to the chosen tenant,
//   3. collapse documents that then share a tenant + unique key,
//   4. delete empty leftover demo groups,
//   5. rebuild the correct { tenant, ... } indexes.
//
//   node --env-file-if-exists=.env.local scripts/repair-indexes.mjs [--tenant <slug>]

const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB || undefined;

// collection -> indexes to drop before repairing (stale + compound unique).
const INDEXES_TO_DROP = {
  settings: ['key_1', 'tenant_1_key_1'],
  menu_items: ['sku_1', 'tenant_1_sku_1'],
  menu_groups: ['name_1', 'tenant_1_name_1'],
  stations: ['name_1', 'tenant_1_name_1'],
};

// The unique key each collection must have per tenant.
const UNIQUE_KEYS = [
  { model: Setting, key: 'key' },
  { model: MenuGroup, key: 'name', repointItems: true },
  { model: Station, key: 'name' },
  { model: MenuItem, key: 'sku' },
];

const ALL_MODELS = [MenuItem, MenuGroup, Station, Setting, PriceHistory];

async function dropIndexes() {
  let dropped = 0;
  for (const [collectionName, names] of Object.entries(INDEXES_TO_DROP)) {
    const collection = mongoose.connection.collection(collectionName);
    const existing = new Set(
      (await collection.indexes().catch(() => [])).map((index) => index.name)
    );
    for (const name of names) {
      if (!existing.has(name)) continue;
      await collection.dropIndex(name);
      console.log(`Dropped ${collectionName}.${name}`);
      dropped += 1;
    }
  }
  if (dropped === 0) console.log('No conflicting indexes to drop');
}

async function backfillTenant(tenantId) {
  for (const model of ALL_MODELS) {
    const result = await model.updateMany(
      { tenant: null },
      { $set: { tenant: tenantId } }
    );
    const moved = result.modifiedCount ?? 0;
    if (moved > 0) {
      console.log(`Attached ${moved} tenant-less ${model.collection.collectionName} document(s)`);
    }
  }
}

// A tenant-less document whose unique key already exists for the tenant is a
// stale duplicate: delete it (not backfill it), otherwise attaching the tenant
// would violate the unique index. For groups, repoint any items first.
async function dropCollidingTenantless(tenantId) {
  let removed = 0;
  for (const { model, key, repointItems } of UNIQUE_KEYS) {
    const tenantless = await model.find({ tenant: null }).lean();
    for (const doc of tenantless) {
      const existing = await model
        .findOne({ tenant: tenantId, [key]: doc[key] })
        .lean();
      if (!existing) continue;
      if (repointItems) {
        // No tenant filter: items may still be tenant-less at this point (the
        // backfill runs afterwards), and they must not be left pointing at a
        // group id that is about to be deleted.
        await MenuItem.updateMany(
          { group: doc._id },
          { $set: { group: existing._id } }
        );
      }
      await model.deleteOne({ _id: doc._id });
      removed += 1;
      console.log(
        `Removed tenant-less ${model.collection.collectionName} ${key}="${doc[key]}" (tenant already has one)`
      );
    }
  }
  if (removed === 0) console.log('No colliding tenant-less documents');
}

async function dedupe(tenantId) {
  let removed = 0;
  for (const { model, key, repointItems } of UNIQUE_KEYS) {
    const groups = await model.collection
      .aggregate([
        { $match: { tenant: tenantId } },
        {
          $group: {
            _id: { tenant: '$tenant', key: `$${key}` },
            ids: { $push: '$_id' },
            n: { $sum: 1 },
          },
        },
        { $match: { n: { $gt: 1 } } },
      ])
      .toArray();

    for (const group of groups) {
      const sorted = [...group.ids].sort();
      const [keep, ...drop] = sorted;
      if (repointItems) {
        await MenuItem.updateMany(
          { tenant: tenantId, group: { $in: drop } },
          { $set: { group: keep } }
        );
      }
      await model.deleteMany({ _id: { $in: drop } });
      removed += drop.length;
      console.log(
        `Merged duplicate ${model.collection.collectionName} ${key}="${group._id.key}" (kept ${keep}, removed ${drop.length})`
      );
    }
  }
  if (removed === 0) console.log('No duplicate documents to merge');
}

async function removeEmptyDemoGroups(tenantId) {
  let removed = 0;
  for (const group of SEED_GROUPS) {
    const docs = await MenuGroup.find({ tenant: tenantId, name: group.name }).lean();
    for (const doc of docs) {
      const count = await MenuItem.countDocuments({ tenant: tenantId, group: doc._id });
      if (count === 0) {
        await MenuGroup.deleteOne({ _id: doc._id });
        removed += 1;
      }
    }
  }
  if (removed > 0) console.log(`Removed ${removed} empty demo group(s)`);
}

async function main() {
  await connectDb(uri, dbName, { autoIndex: false });
  console.log(`Connected to ${dbName || '(default database)'}`);

  const tenant = await resolveTenant();
  console.log(`Repairing tenant "${tenant.name}" (${tenant.slug})`);

  await dropIndexes();
  await dropCollidingTenantless(tenant._id);
  await backfillTenant(tenant._id);
  await dedupe(tenant._id);
  await removeEmptyDemoGroups(tenant._id);

  for (const model of ALL_MODELS) {
    await model.createIndexes();
  }
  console.log('Indexes rebuilt');

  const [settings, groups, items] = await Promise.all([
    Setting.countDocuments({ tenant: tenant._id }),
    MenuGroup.countDocuments({ tenant: tenant._id }),
    MenuItem.countDocuments({ tenant: tenant._id }),
  ]);
  console.log(`Done. settings=${settings}, groups=${groups}, menu_items=${items}`);
}

main()
  .catch((error) => {
    console.error('repair-indexes failed:', error.message);
    process.exitCode = 1;
  })
  .finally(async () => {
    await mongoose.disconnect().catch(() => {});
  });
