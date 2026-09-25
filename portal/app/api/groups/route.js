import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import MenuGroup from '@/lib/models/MenuGroup';
import MenuItem from '@/lib/models/MenuItem';
import {
  ensureGroups,
  nextGroupSortOrder,
  serializeGroup,
} from '@/lib/menu-service';
import { validateGroup } from '@/lib/validate';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function getGroups() {
  await dbConnect();
  const { tenantId } = await requireSession();
  await ensureGroups(tenantId);

  const [groups, counts, ungroupedCount] = await Promise.all([
    MenuGroup.find({ tenant: tenantId }).sort({ sortOrder: 1, name: 1 }).lean(),
    MenuItem.aggregate([
      { $match: { tenant: tenantId, group: { $ne: null } } },
      { $group: { _id: '$group', count: { $sum: 1 } } },
    ]),
    MenuItem.countDocuments({ tenant: tenantId, group: null }),
  ]);

  const countMap = new Map(counts.map((row) => [String(row._id), row.count]));

  return NextResponse.json({
    groups: groups.map((group) =>
      serializeGroup(group, countMap.get(String(group._id)) || 0)
    ),
    ungroupedCount,
  });
}

async function createGroup(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { values, errors } = validateGroup(body);
  if (errors.length) {
    return NextResponse.json({ error: errors.join('; '), errors }, { status: 400 });
  }

  const existing = await MenuGroup.findOne({
    tenant: tenantId,
    name: values.name,
  });
  if (existing) {
    return NextResponse.json(
      { error: `Group "${values.name}" already exists` },
      { status: 409 }
    );
  }

  const sortOrder = values.sortOrder ?? (await nextGroupSortOrder(tenantId));
  const group = await MenuGroup.create({
    ...values,
    tenant: tenantId,
    sortOrder,
  });

  return NextResponse.json({ group: serializeGroup(group, 0) }, { status: 201 });
}

export const GET = withApiError(getGroups);
export const POST = withApiError(createGroup);
