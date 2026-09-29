import mongoose from 'mongoose';
import MenuItem from '@/lib/models/MenuItem';
import MenuGroup from '@/lib/models/MenuGroup';
import Station from '@/lib/models/Station';
import Setting from '@/lib/models/Setting';
import PriceHistory from '@/lib/models/PriceHistory';
import { DEFAULT_SETTINGS_KEY, DEFAULT_STATIONS } from '@/lib/constants';
import { SEED_GROUPS } from '@/lib/seedData';

// Every helper takes the tenant it works for, so one portal deployment can
// serve several restaurants without their data mixing.

/// Guards the create-on-read helpers: a missing tenant used to slip through and
/// write documents with `tenant: null`, which then collided on the unique
/// indexes. Fail loudly instead.
function assertTenant(tenant, caller) {
  if (!tenant) {
    throw new Error(`${caller}() requires a tenant`);
  }
  return tenant;
}

export async function getSettings(tenant) {
  assertTenant(tenant, 'getSettings');
  const existing = await Setting.findOne({
    tenant,
    key: DEFAULT_SETTINGS_KEY,
  });
  if (existing) return existing;
  return Setting.create({ tenant, key: DEFAULT_SETTINGS_KEY });
}

export async function ensureStations(tenant) {
  assertTenant(tenant, 'ensureStations');
  const count = await Station.countDocuments({ tenant });
  if (count > 0) return;
  await Station.insertMany(
    DEFAULT_STATIONS.map((name, index) => ({ tenant, name, sortOrder: index }))
  );
}

export async function ensureGroups(tenant) {
  assertTenant(tenant, 'ensureGroups');
  const count = await MenuGroup.countDocuments({ tenant });
  if (count > 0) return;
  await MenuGroup.insertMany(
    SEED_GROUPS.map((group) => ({
      tenant,
      name: group.name,
      description: group.description,
      sortOrder: group.sortOrder,
    }))
  );
}

export async function findMenuItem(tenant, idOrSku) {
  const key = String(idOrSku || '').trim();
  if (!key) return null;
  if (mongoose.isValidObjectId(key)) {
    const byId = await MenuItem.findOne({ _id: key, tenant });
    if (byId) return byId;
  }
  return MenuItem.findOne({ tenant, sku: key });
}

export async function findStation(tenant, idOrName) {
  const key = String(idOrName || '').trim();
  if (!key) return null;
  if (mongoose.isValidObjectId(key)) {
    const byId = await Station.findOne({ _id: key, tenant });
    if (byId) return byId;
  }
  return Station.findOne({ tenant, name: key });
}

export async function findGroup(tenant, idOrName) {
  const key = String(idOrName || '').trim();
  if (!key) return null;
  if (mongoose.isValidObjectId(key)) {
    const byId = await MenuGroup.findOne({ _id: key, tenant });
    if (byId) return byId;
  }
  return MenuGroup.findOne({ tenant, name: key });
}

export async function resolveGroupAssignment(tenant, value) {
  const key = String(value ?? '').trim();
  if (!key || key === 'none' || key === 'ungrouped') {
    return { group: null, groupName: '' };
  }
  const found = await findGroup(tenant, key);
  if (!found) return { error: `Group "${key}" not found` };
  return { group: found._id, groupName: found.name };
}

export async function nextSku(tenant) {
  const items = await MenuItem.find(
    { tenant, sku: /^mi_\d+$/i },
    { sku: 1 }
  ).lean();
  let max = 0;
  for (const item of items) {
    const parsed = Number.parseInt(String(item.sku).slice(3), 10);
    if (Number.isFinite(parsed) && parsed > max) max = parsed;
  }
  return `mi_${String(max + 1).padStart(3, '0')}`;
}

export async function nextSortOrder(tenant) {
  const last = await MenuItem.findOne({ tenant }, { sortOrder: 1 })
    .sort({ sortOrder: -1 })
    .lean();
  return last && Number.isFinite(last.sortOrder) ? last.sortOrder + 1 : 1;
}

export async function nextGroupSortOrder(tenant) {
  const last = await MenuGroup.findOne({ tenant }, { sortOrder: 1 })
    .sort({ sortOrder: -1 })
    .lean();
  return last && Number.isFinite(last.sortOrder) ? last.sortOrder + 1 : 1;
}

export async function logPriceChange({
  tenant,
  item,
  action,
  oldPrice = null,
  newPrice = null,
  changedBy = 'portal',
  note = '',
}) {
  assertTenant(tenant, 'logPriceChange');
  return PriceHistory.create({
    tenant,
    itemId: item?._id ?? null,
    sku: item?.sku ?? '',
    name: item?.name ?? '',
    action,
    oldPrice,
    newPrice,
    station: item?.station ?? '',
    changedBy: changedBy || 'portal',
    note: note || '',
  });
}

export function serializeMenuItem(doc) {
  const item = typeof doc?.toObject === 'function' ? doc.toObject() : doc || {};
  return {
    id: String(item._id),
    sku: item.sku,
    name: item.name,
    price: item.price,
    station: item.station,
    groupId: item.group ? String(item.group) : null,
    group: item.groupName || '',
    options: item.options || '',
    addOnFor: Array.isArray(item.addOnFor) ? item.addOnFor : [],
    description: item.description || '',
    available: item.available !== false,
    sortOrder: item.sortOrder ?? 0,
    createdAt: item.createdAt ? new Date(item.createdAt).toISOString() : null,
    updatedAt: item.updatedAt ? new Date(item.updatedAt).toISOString() : null,
  };
}

export function serializeGroup(doc, itemCount = 0) {
  const group = typeof doc?.toObject === 'function' ? doc.toObject() : doc || {};
  return {
    id: String(group._id),
    name: group.name,
    description: group.description || '',
    color: group.color || '',
    station: group.station || '',
    sortOrder: group.sortOrder ?? 0,
    itemCount,
  };
}

export function serializeSettings(doc) {
  const setting = typeof doc?.toObject === 'function' ? doc.toObject() : doc || {};
  return {
    restaurantName: setting.restaurantName || 'Warong',
    currency: setting.currency || 'RM',
    taxRate: typeof setting.taxRate === 'number' ? setting.taxRate : 0.1,
    updatedBy: setting.updatedBy || '',
    updatedAt: setting.updatedAt
      ? new Date(setting.updatedAt).toISOString()
      : null,
  };
}

export function serializePriceHistory(doc) {
  const entry = typeof doc?.toObject === 'function' ? doc.toObject() : doc || {};
  return {
    id: String(entry._id),
    itemId: entry.itemId ? String(entry.itemId) : null,
    sku: entry.sku,
    name: entry.name,
    action: entry.action,
    oldPrice: entry.oldPrice ?? null,
    newPrice: entry.newPrice ?? null,
    station: entry.station || '',
    changedBy: entry.changedBy || 'portal',
    note: entry.note || '',
    createdAt: entry.createdAt ? new Date(entry.createdAt).toISOString() : null,
  };
}
