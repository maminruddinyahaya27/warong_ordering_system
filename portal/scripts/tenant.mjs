import mongoose from 'mongoose';
import Tenant from '../lib/models/Tenant.js';
import MenuItem from '../lib/models/MenuItem.js';
import MenuGroup from '../lib/models/MenuGroup.js';
import Station from '../lib/models/Station.js';
import Setting from '../lib/models/Setting.js';
import PriceHistory from '../lib/models/PriceHistory.js';

// Shared helpers for the maintenance scripts so seed/import/create-tenant all
// agree on which restaurant they are working for.

export function readArg(flag) {
  const index = process.argv.indexOf(flag);
  if (index === -1) return '';
  return process.argv[index + 1] || '';
}

export function connectDb(uri, dbName, options = {}) {
  if (!uri) {
    console.error('MONGODB_URI is not set. Add it to .env.local or export it first.');
    process.exit(1);
  }
  if (uri.includes('REPLACE_WITH_DB_PASSWORD')) {
    console.error(
      'MONGODB_URI still contains REPLACE_WITH_DB_PASSWORD. Put the real password in .env.local.'
    );
    process.exit(1);
  }
  return mongoose.connect(uri, { dbName, ...options });
}

/// `--tenant <slug|id|apiKey>` wins, then `TENANT`, then the oldest active
/// tenant. Throws with a helpful message when there is nothing to pick.
export async function resolveTenant() {
  const selector = readArg('--tenant') || process.env.TENANT || '';
  if (selector) {
    const tenant = mongoose.isValidObjectId(selector)
      ? await Tenant.findById(selector)
      : await Tenant.findOne({ $or: [{ slug: selector }, { apiKey: selector }] });
    if (!tenant) throw new Error(`Tenant "${selector}" was not found`);
    return tenant;
  }

  const tenant = await Tenant.findOne({ active: true }).sort({ createdAt: 1 });
  if (!tenant) {
    throw new Error(
      'No tenant exists yet. Create one first:\n' +
        '  npm run create-tenant -- --slug warong --username owner --password "change-me"'
    );
  }
  return tenant;
}

/// Backfills `tenant` on documents created before multi-tenant support, so the
/// existing single-restaurant data keeps working under the first tenant.
export async function migrateLegacyData(tenant) {
  const models = {
    menuItems: MenuItem,
    menuGroups: MenuGroup,
    stations: Station,
    settings: Setting,
    priceHistory: PriceHistory,
  };
  const missing = {
    $or: [{ tenant: { $exists: false } }, { tenant: null }],
  };

  const counts = {};
  for (const [name, model] of Object.entries(models)) {
    const result = await model.updateMany(missing, { $set: { tenant: tenant._id } });
    counts[name] = result.modifiedCount ?? 0;
  }
  return counts;
}
