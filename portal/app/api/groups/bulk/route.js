import { NextResponse } from 'next/server';
import mongoose from 'mongoose';

import { dbConnect } from '@/lib/mongodb';
import MenuGroup from '@/lib/models/MenuGroup';
import MenuItem from '@/lib/models/MenuItem';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// Bulk delete menu groups. A group that still holds items is skipped, exactly
// like the single delete, so items are never silently orphaned.
//   POST { ids: ["<groupId>", ...] }
async function bulkDeleteGroups(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const ids = Array.isArray(body?.ids)
    ? [...new Set(body.ids.map(String))].filter((id) => mongoose.isValidObjectId(id))
    : [];
  if (ids.length === 0) {
    return NextResponse.json({ error: 'ids must be a non-empty array' }, { status: 400 });
  }

  const groups = await MenuGroup.find({ tenant: tenantId, _id: { $in: ids } });

  let deleted = 0;
  const blocked = [];
  for (const group of groups) {
    const itemCount = await MenuItem.countDocuments({
      tenant: tenantId,
      group: group._id,
    });
    if (itemCount > 0) {
      blocked.push(`${group.name} (${itemCount} item${itemCount === 1 ? '' : 's'})`);
      continue;
    }
    await group.deleteOne();
    deleted += 1;
  }

  return NextResponse.json({
    ok: true,
    deleted,
    skipped: ids.length - deleted,
    blocked,
  });
}

export const POST = withApiError(bulkDeleteGroups);
