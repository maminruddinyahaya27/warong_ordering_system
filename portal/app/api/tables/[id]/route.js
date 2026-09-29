import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import Table from '@/lib/models/Table';
import { withApiError } from '@/lib/api';
import { HttpError, requireSession } from '@/lib/auth';
import { publicBase, serializeTable } from '@/lib/tables';

export const dynamic = 'force-dynamic';

async function findTable(tenantId, id) {
  if (!/^[0-9a-f]{24}$/i.test(String(id))) {
    throw new HttpError(404, 'Table not found');
  }
  const table = await Table.findOne({ _id: id, tenant: tenantId });
  if (!table) throw new HttpError(404, 'Table not found');
  return table;
}

async function updateTable(request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;
  const table = await findTable(tenantId, id);

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  if (body?.label !== undefined) {
    const label = String(body.label).trim();
    if (!label) throw new HttpError(400, 'Label cannot be empty');
    if (label !== table.label) {
      const clash = await Table.findOne({
        tenant: tenantId,
        label,
        _id: { $ne: table._id },
      });
      if (clash) throw new HttpError(409, `Table "${label}" already exists`);
      table.label = label;
    }
  }
  if (body?.active !== undefined) table.active = Boolean(body.active);
  if (body?.sortOrder !== undefined && Number.isFinite(Number(body.sortOrder))) {
    table.sortOrder = Number(body.sortOrder);
  }

  await table.save();

  return NextResponse.json({
    table: serializeTable(table, String(tenantId), publicBase(request)),
  });
}

async function deleteTable(request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;
  const table = await findTable(tenantId, id);

  await table.deleteOne();
  return NextResponse.json({ ok: true, id: String(table._id), label: table.label });
}

export const PATCH = withApiError(updateTable);
export const DELETE = withApiError(deleteTable);
