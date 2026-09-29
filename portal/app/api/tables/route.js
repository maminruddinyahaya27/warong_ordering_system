import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import Table from '@/lib/models/Table';
import Tenant from '@/lib/models/Tenant';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';
import { randomToken } from '@/lib/crypto';
import { publicBase, serializeTable } from '@/lib/tables';

export const dynamic = 'force-dynamic';

async function listTables(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  const [tenant, tables] = await Promise.all([
    Tenant.findById(tenantId).lean(),
    Table.find({ tenant: tenantId }).sort({ sortOrder: 1, label: 1 }).lean(),
  ]);

  const base = publicBase(request);
  return NextResponse.json({
    tables: tables.map((table) =>
      serializeTable(table, String(tenant?._id || ''), base)
    ),
  });
}

// Creates one or many tables. Existing labels are left untouched, so a
// half-finished "create tables 1-20" can simply be re-run.
async function createTables(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const labels = Array.isArray(body?.labels)
    ? body.labels.map((label) => String(label).trim())
    : [];
  const single = String(body?.label || '').trim();
  if (single) labels.push(single);

  const unique = [...new Set(labels.filter(Boolean))];
  if (unique.length === 0) {
    return NextResponse.json(
      { error: 'Provide a label or a list of labels' },
      { status: 400 }
    );
  }

  const [tenant, existing] = await Promise.all([
    Tenant.findById(tenantId).lean(),
    Table.find({ tenant: tenantId }).select('label sortOrder').lean(),
  ]);

  const taken = new Set(existing.map((table) => table.label));
  let nextOrder =
    existing.reduce((max, table) => Math.max(max, table.sortOrder ?? 0), 0) + 1;

  const created = [];
  for (const label of unique) {
    if (taken.has(label)) continue;
    const doc = await Table.create({
      tenant: tenantId,
      label,
      token: randomToken().slice(0, 16),
      active: true,
      sortOrder: nextOrder,
    });
    nextOrder += 1;
    created.push(doc);
  }

  const base = publicBase(request);
  return NextResponse.json(
    {
      tables: created.map((table) =>
        serializeTable(table, String(tenant?._id || ''), base)
      ),
      created: created.length,
      skipped: unique.length - created.length,
    },
    { status: 201 }
  );
}

export const GET = withApiError(listTables);
export const POST = withApiError(createTables);
