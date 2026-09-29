import { NextResponse } from 'next/server';
import mongoose from 'mongoose';

import { dbConnect } from '@/lib/mongodb';
import Station from '@/lib/models/Station';
import MenuItem from '@/lib/models/MenuItem';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// Bulk delete stations. Stations still used by menu items are skipped, exactly
// like the single delete.
//   POST { ids: ["<stationId>", ...] }
async function bulkDeleteStations(request) {
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

  const stations = await Station.find({ tenant: tenantId, _id: { $in: ids } });

  let deleted = 0;
  const blocked = [];
  for (const station of stations) {
    const itemCount = await MenuItem.countDocuments({
      tenant: tenantId,
      station: station.name,
    });
    if (itemCount > 0) {
      blocked.push(`${station.name} (${itemCount} item${itemCount === 1 ? '' : 's'})`);
      continue;
    }
    await station.deleteOne();
    deleted += 1;
  }

  return NextResponse.json({
    ok: true,
    deleted,
    skipped: ids.length - deleted,
    blocked,
  });
}

export const POST = withApiError(bulkDeleteStations);
