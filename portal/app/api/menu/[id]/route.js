import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import MenuItem from '@/lib/models/MenuItem';
import {
  findMenuItem,
  logPriceChange,
  resolveGroupAssignment,
  serializeMenuItem,
} from '@/lib/menu-service';
import { validateMenuItem } from '@/lib/validate';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function getMenuItem(_request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  const item = await findMenuItem(tenantId, id);
  if (!item) {
    return NextResponse.json({ error: 'Menu item not found' }, { status: 404 });
  }

  return NextResponse.json({ item: serializeMenuItem(item) });
}

async function updateMenuItem(request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const item = await findMenuItem(tenantId, id);
  if (!item) {
    return NextResponse.json({ error: 'Menu item not found' }, { status: 404 });
  }

  const { values, errors } = validateMenuItem(body, { partial: true });
  if (errors.length) {
    return NextResponse.json({ error: errors.join('; '), errors }, { status: 400 });
  }
  if (Object.keys(values).length === 0) {
    return NextResponse.json({ error: 'No supported fields to update' }, { status: 400 });
  }

  if (values.sku && values.sku !== item.sku) {
    const duplicate = await MenuItem.findOne({
      tenant: tenantId,
      sku: values.sku,
      _id: { $ne: item._id },
    });
    if (duplicate) {
      return NextResponse.json(
        { error: `SKU ${values.sku} already exists` },
        { status: 409 }
      );
    }
  }

  const { group: groupInput, ...rest } = values;

  if (groupInput !== undefined) {
    const assignment = await resolveGroupAssignment(tenantId, groupInput);
    if (assignment.error) {
      return NextResponse.json({ error: assignment.error }, { status: 400 });
    }
    item.group = assignment.group;
    item.groupName = assignment.groupName;
  }

  const oldPrice = item.price;
  Object.assign(item, rest);
  await item.save();

  await logPriceChange({
    tenant: tenantId,
    item,
    action: 'update',
    oldPrice,
    newPrice: item.price,
    changedBy: body.changedBy,
    note: body.note,
  });

  return NextResponse.json({ item: serializeMenuItem(item) });
}

async function deleteMenuItem(request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  const item = await findMenuItem(tenantId, id);
  if (!item) {
    return NextResponse.json({ error: 'Menu item not found' }, { status: 404 });
  }

  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }

  await logPriceChange({
    tenant: tenantId,
    item,
    action: 'delete',
    oldPrice: item.price,
    newPrice: null,
    changedBy: body?.changedBy,
    note: body?.note,
  });

  await item.deleteOne();

  return NextResponse.json({ ok: true, id: String(item._id), sku: item.sku });
}

export const GET = withApiError(getMenuItem);
export const PATCH = withApiError(updateMenuItem);
export const DELETE = withApiError(deleteMenuItem);
