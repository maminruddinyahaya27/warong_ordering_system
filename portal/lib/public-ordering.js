import { dbConnect } from '@/lib/mongodb';
import Tenant from '@/lib/models/Tenant';
import Table from '@/lib/models/Table';
import MenuItem from '@/lib/models/MenuItem';
import MenuGroup from '@/lib/models/MenuGroup';
import { getSettings } from '@/lib/menu-service';
import { HttpError } from '@/lib/auth';

export const UNGROUPED_LABEL = 'Ungrouped';
export const MAX_ITEMS_PER_ORDER = 30;
export const MAX_QTY_PER_ITEM = 20;

/// Resolves the restaurant + table a customer's QR code refers to. The QR
/// carries the tenant id (`t`) and the table token (`table`), so a code printed
/// for one restaurant can never place an order at another. A slug is still
/// accepted so any earlier link keeps working.
export async function resolveTable({ tenantRef, tableToken }) {
  await dbConnect();

  const ref = String(tenantRef || '').trim();
  const token = String(tableToken || '').trim();
  if (!ref || !token) {
    throw new HttpError(400, 'Missing restaurant or table code');
  }

  const tenant = /^[0-9a-f]{24}$/i.test(ref)
    ? await Tenant.findOne({ _id: ref, active: true })
    : await Tenant.findOne({ slug: ref.toLowerCase(), active: true });
  if (!tenant) throw new HttpError(404, 'Restaurant not found');

  const table = await Table.findOne({
    tenant: tenant._id,
    token,
    active: true,
  });
  if (!table) throw new HttpError(404, 'This table code is not valid');

  return { tenant, table };
}

/// The menu a customer sees: available items only, in the portal's group order.
export async function buildPublicMenu(tenant, table) {
  const [items, groups, settings] = await Promise.all([
    MenuItem.find({ tenant: tenant._id, available: true })
      .sort({ sortOrder: 1, name: 1 })
      .lean(),
    MenuGroup.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
    getSettings(tenant._id),
  ]);

  const groupRank = new Map(groups.map((group, index) => [group.name, index]));
  const ungroupedRank = groups.length;
  const rankOf = (item) =>
    groupRank.has(item.groupName) ? groupRank.get(item.groupName) : ungroupedRank;

  const ordered = [...items].sort((a, b) => {
    const rankA = rankOf(a);
    const rankB = rankOf(b);
    if (rankA !== rankB) return rankA - rankB;
    const orderA = Number.isFinite(a.sortOrder) ? a.sortOrder : 0;
    const orderB = Number.isFinite(b.sortOrder) ? b.sortOrder : 0;
    if (orderA !== orderB) return orderA - orderB;
    return String(a.name).localeCompare(String(b.name));
  });

  const counts = new Map();
  for (const item of ordered) {
    const key = item.groupName || UNGROUPED_LABEL;
    counts.set(key, (counts.get(key) || 0) + 1);
  }

  const groupList = groups
    .map((group) => ({
      name: group.name,
      count: counts.get(group.name) || 0,
    }))
    .filter((group) => group.count > 0);
  const ungrouped = counts.get(UNGROUPED_LABEL) || 0;
  if (ungrouped > 0) groupList.push({ name: UNGROUPED_LABEL, count: ungrouped });

  return {
    restaurant: settings?.restaurantName || tenant.name,
    currency: settings?.currency || 'RM',
    taxRate: settings?.taxRate ?? 0.1,
    table: { label: table.label },
    groups: groupList,
    menu: ordered.map((item) => ({
      sku: item.sku,
      name: item.name,
      price: item.price,
      station: item.station || '',
      group: item.groupName || UNGROUPED_LABEL,
      options: item.options || '',
      addOnFor: Array.isArray(item.addOnFor) ? item.addOnFor : [],
      requireAddOn: item.requireAddOn === true,
    })),
  };
}

/// Prices a customer's requested items against the live menu, rejecting
/// anything that is off the menu, sold out or has a silly quantity.
export async function priceOrder(tenant, requested) {
  const list = Array.isArray(requested) ? requested : [];
  if (list.length === 0) throw new HttpError(400, 'Your order is empty');
  if (list.length > MAX_ITEMS_PER_ORDER) {
    throw new HttpError(400, `An order can have at most ${MAX_ITEMS_PER_ORDER} items`);
  }

  const skus = [...new Set(list.map((raw) => String(raw?.sku || '')))].filter(Boolean);
  const docs = await MenuItem.find({ tenant: tenant._id, sku: { $in: skus } }).lean();
  const bySku = new Map(docs.map((doc) => [doc.sku, doc]));

  const errors = [];
  const items = [];

  for (const raw of list) {
    const sku = String(raw?.sku || '').trim();
    const item = bySku.get(sku);
    if (!item) {
      errors.push(`${sku || 'item'} is no longer on the menu`);
      continue;
    }
    if (item.available === false) {
      errors.push(`${item.name} is sold out`);
      continue;
    }
    const qty = Number.parseInt(raw?.qty, 10);
    if (!Number.isFinite(qty) || qty < 1 || qty > MAX_QTY_PER_ITEM) {
      errors.push(`${item.name}: quantity must be 1-${MAX_QTY_PER_ITEM}`);
      continue;
    }
    items.push({
      sku: item.sku,
      name: item.name,
      qty,
      price: item.price,
      station: item.station || '',
      note: String(raw?.note || '').slice(0, 120),
    });
  }

  if (errors.length > 0) {
    throw new HttpError(400, errors.join('; '));
  }
  return items;
}

const REF_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export function createOrderRef() {
  let out = '';
  for (let index = 0; index < 6; index += 1) {
    out += REF_ALPHABET[Math.floor(Math.random() * REF_ALPHABET.length)];
  }
  return out;
}
