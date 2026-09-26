import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import MenuGroup from '@/lib/models/MenuGroup';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// Reorders a restaurant's menu groups. The POS Hub and waiter apps show groups
// in this order, so this is what makes a busy menu easy to navigate.
//
//   POST { "ids": ["<groupId>", "<groupId>", ...] }
//
// Groups missing from `ids` keep a stable place at the end, so a partial list
// can never leave two groups sharing a sort order.
async function reorderGroups(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const ids = Array.isArray(body?.ids)
    ? [...new Set(body.ids.map((value) => String(value)))]
    : [];
  if (ids.length === 0) {
    return NextResponse.json({ error: 'ids must be a non-empty array' }, { status: 400 });
  }

  const existing = await MenuGroup.find({ tenant: tenantId }).select('_id').lean();
  const known = existing.map((group) => String(group._id));
  const knownSet = new Set(known);

  const unknown = ids.filter((id) => !knownSet.has(id));
  if (unknown.length > 0) {
    return NextResponse.json(
      { error: 'Some groups do not belong to this restaurant' },
      { status: 400 }
    );
  }

  const ordered = [...ids, ...known.filter((id) => !ids.includes(id))];

  await Promise.all(
    ordered.map((id, index) =>
      MenuGroup.updateOne(
        { _id: id, tenant: tenantId },
        { $set: { sortOrder: index } }
      )
    )
  );

  return NextResponse.json({ ok: true, order: ordered });
}

export const POST = withApiError(reorderGroups);
