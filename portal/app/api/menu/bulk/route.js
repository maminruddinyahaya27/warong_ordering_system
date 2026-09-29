import { NextResponse } from 'next/server';
import mongoose from 'mongoose';

import { dbConnect } from '@/lib/mongodb';
import MenuItem from '@/lib/models/MenuItem';
import { logPriceChange } from '@/lib/menu-service';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// Bulk delete menu items (portal → Menu & Prices → select rows).
//   POST { ids: ["<menuItemId>", ...] }
async function bulkDeleteMenu(request) {
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

  const items = await MenuItem.find({ tenant: tenantId, _id: { $in: ids } });

  let deleted = 0;
  for (const item of items) {
    await logPriceChange({
      tenant: tenantId,
      item,
      action: 'delete',
      oldPrice: item.price,
      newPrice: null,
      changedBy: 'bulk-delete',
      note: body?.note || 'Bulk delete from the portal',
    });
    await item.deleteOne();
    deleted += 1;
  }

  return NextResponse.json({
    ok: true,
    deleted,
    skipped: ids.length - deleted,
  });
}

export const POST = withApiError(bulkDeleteMenu);
