import { NextResponse } from 'next/server';

import { withApiError } from '@/lib/api';
import OnlineOrder from '@/lib/models/OnlineOrder';
import {
  createOrderRef,
  priceOrder,
  resolveTable,
} from '@/lib/public-ordering';

export const dynamic = 'force-dynamic';

// Public: a customer submits their table order.
//   POST { t: tenantId, table: tableToken, items: [{ sku, qty, note }], note }
async function createPublicOrder(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { tenant, table } = await resolveTable({
    tenantRef: body?.t,
    tableToken: body?.table,
  });

  const items = await priceOrder(tenant, body?.items);
  const note = String(body?.note || '').slice(0, 200);
  const total = items.reduce((sum, item) => sum + item.price * item.qty, 0);

  let ref = createOrderRef();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const clash = await OnlineOrder.findOne({ tenant: tenant._id, ref });
    if (!clash) break;
    ref = createOrderRef();
  }

  await OnlineOrder.create({
    tenant: tenant._id,
    table: table._id,
    tableLabel: table.label,
    ref,
    items,
    note,
    total,
    status: 'pending',
  });

  return NextResponse.json(
    {
      ok: true,
      ref,
      status: 'pending',
      total,
      table: { label: table.label },
      message: 'Order sent to the counter. Please pay at the counter.',
    },
    { status: 201 }
  );
}

export const POST = withApiError(createPublicOrder);
