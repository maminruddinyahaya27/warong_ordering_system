import { NextResponse } from 'next/server';
import mongoose from 'mongoose';

import { dbConnect } from '@/lib/mongodb';
import Table from '@/lib/models/Table';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// Bulk delete tables (and their QR codes).
//   POST { ids: ["<tableId>", ...] }
async function bulkDeleteTables(request) {
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

  const result = await Table.deleteMany({ tenant: tenantId, _id: { $in: ids } });

  return NextResponse.json({
    ok: true,
    deleted: result.deletedCount ?? 0,
    skipped: ids.length - (result.deletedCount ?? 0),
  });
}

export const POST = withApiError(bulkDeleteTables);
