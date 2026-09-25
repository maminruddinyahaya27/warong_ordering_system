import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import MenuItem from '@/lib/models/MenuItem';
import {
  ensureGroups,
  ensureStations,
  findGroup,
  logPriceChange,
  nextSku,
  nextSortOrder,
  resolveGroupAssignment,
  serializeMenuItem,
} from '@/lib/menu-service';
import { validateMenuItem } from '@/lib/validate';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function getMenu(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  const { searchParams } = new URL(request.url);
  const search = (searchParams.get('search') || '').trim();
  const station = (searchParams.get('station') || '').trim();
  const group = (searchParams.get('group') || '').trim();
  const availability = (searchParams.get('available') || '').trim();

  const query = { tenant: tenantId };
  if (search) {
    const safe = escapeRegex(search);
    query.$or = [
      { name: { $regex: safe, $options: 'i' } },
      { sku: { $regex: safe, $options: 'i' } },
    ];
  }
  if (station) query.station = station;
  if (availability === 'available') query.available = true;
  if (availability === 'unavailable') query.available = false;

  if (group) {
    if (group === 'none' || group === 'ungrouped') {
      query.group = null;
    } else {
      const found = await findGroup(tenantId, group);
      if (!found) {
        return NextResponse.json({ items: [], count: 0 });
      }
      query.group = found._id;
    }
  }

  const items = await MenuItem.find(query).sort({ sortOrder: 1, name: 1 });
  return NextResponse.json({
    items: items.map(serializeMenuItem),
    count: items.length,
  });
}

async function createMenu(request) {
  await dbConnect();
  const { tenantId } = await requireSession();
  await ensureStations(tenantId);
  await ensureGroups(tenantId);

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { values, errors } = validateMenuItem(body);
  if (errors.length) {
    return NextResponse.json({ error: errors.join('; '), errors }, { status: 400 });
  }

  const assignment = await resolveGroupAssignment(tenantId, values.group);
  if (assignment.error) {
    return NextResponse.json({ error: assignment.error }, { status: 400 });
  }

  const sku = values.sku || (await nextSku(tenantId));
  const existing = await MenuItem.findOne({ tenant: tenantId, sku });
  if (existing) {
    return NextResponse.json(
      { error: `SKU ${sku} already exists` },
      { status: 409 }
    );
  }

  const { group: _ignoredGroup, ...rest } = values;
  const sortOrder = values.sortOrder ?? (await nextSortOrder(tenantId));
  const item = await MenuItem.create({
    ...rest,
    tenant: tenantId,
    sku,
    sortOrder,
    group: assignment.group,
    groupName: assignment.groupName,
  });

  await logPriceChange({
    tenant: tenantId,
    item,
    action: 'create',
    oldPrice: null,
    newPrice: item.price,
    changedBy: body.changedBy,
    note: body.note,
  });

  return NextResponse.json({ item: serializeMenuItem(item) }, { status: 201 });
}

export const GET = withApiError(getMenu);
export const POST = withApiError(createMenu);
