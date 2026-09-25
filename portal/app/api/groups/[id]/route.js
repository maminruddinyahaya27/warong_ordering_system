import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import MenuGroup from '@/lib/models/MenuGroup';
import MenuItem from '@/lib/models/MenuItem';
import { findGroup, serializeGroup } from '@/lib/menu-service';
import { validateGroup } from '@/lib/validate';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function getGroup(_request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  const group = await findGroup(tenantId, id);
  if (!group) {
    return NextResponse.json({ error: 'Group not found' }, { status: 404 });
  }

  const itemCount = await MenuItem.countDocuments({
    tenant: tenantId,
    group: group._id,
  });
  return NextResponse.json({ group: serializeGroup(group, itemCount) });
}

async function updateGroup(request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const group = await findGroup(tenantId, id);
  if (!group) {
    return NextResponse.json({ error: 'Group not found' }, { status: 404 });
  }

  const { values, errors } = validateGroup(body, { partial: true });
  if (errors.length) {
    return NextResponse.json({ error: errors.join('; '), errors }, { status: 400 });
  }
  if (Object.keys(values).length === 0) {
    return NextResponse.json({ error: 'No supported fields to update' }, { status: 400 });
  }

  const previousName = group.name;

  if (values.name && values.name !== previousName) {
    const duplicate = await MenuGroup.findOne({
      tenant: tenantId,
      name: values.name,
      _id: { $ne: group._id },
    });
    if (duplicate) {
      return NextResponse.json(
        { error: `Group "${values.name}" already exists` },
        { status: 409 }
      );
    }
  }

  Object.assign(group, values);
  await group.save();

  let renamedItems = 0;
  if (values.name && values.name !== previousName) {
    const result = await MenuItem.updateMany(
      { tenant: tenantId, group: group._id },
      { $set: { groupName: group.name } }
    );
    renamedItems = result.modifiedCount || 0;
  }

  const itemCount = await MenuItem.countDocuments({
    tenant: tenantId,
    group: group._id,
  });

  return NextResponse.json({
    group: serializeGroup(group, itemCount),
    renamedItems,
  });
}

async function deleteGroup(request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  const group = await findGroup(tenantId, id);
  if (!group) {
    return NextResponse.json({ error: 'Group not found' }, { status: 404 });
  }

  const { searchParams } = new URL(request.url);
  const reassignTo = (searchParams.get('reassignTo') || '').trim();

  let movedItems = 0;

  if (reassignTo) {
    if (reassignTo === 'none') {
      const result = await MenuItem.updateMany(
        { tenant: tenantId, group: group._id },
        { $set: { group: null, groupName: '' } }
      );
      movedItems = result.modifiedCount || 0;
    } else {
      const target = await findGroup(tenantId, reassignTo);
      if (!target || String(target._id) === String(group._id)) {
        return NextResponse.json(
          { error: 'reassignTo must name a different, existing group' },
          { status: 400 }
        );
      }
      const result = await MenuItem.updateMany(
        { tenant: tenantId, group: group._id },
        { $set: { group: target._id, groupName: target.name } }
      );
      movedItems = result.modifiedCount || 0;
    }
  } else {
    const itemCount = await MenuItem.countDocuments({
      tenant: tenantId,
      group: group._id,
    });
    if (itemCount > 0) {
      return NextResponse.json(
        {
          error: `Cannot delete "${group.name}": ${itemCount} menu item(s) are still in it. Move them to another group first.`,
          itemCount,
        },
        { status: 409 }
      );
    }
  }

  await group.deleteOne();

  return NextResponse.json({
    ok: true,
    id: String(group._id),
    name: group.name,
    movedItems,
  });
}

export const GET = withApiError(getGroup);
export const PATCH = withApiError(updateGroup);
export const DELETE = withApiError(deleteGroup);
