import { NextResponse } from 'next/server';

import { withApiError } from '@/lib/api';
import OnlineOrder from '@/lib/models/OnlineOrder';
import { resolveTable } from '@/lib/public-ordering';
import { HttpError } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// Public: the customer's confirmation screen polls this.
//   GET /api/public/orders/<ref>?t=<tenantId>&table=<tableToken>
async function getPublicOrder(request, { params }) {
  const { searchParams } = new URL(request.url);
  const { tenant, table } = await resolveTable({
    tenantRef: searchParams.get('t'),
    tableToken: searchParams.get('table'),
  });

  const { ref } = await params;
  const order = await OnlineOrder.findOne({
    tenant: tenant._id,
    table: table._id,
    ref: String(ref || '').toUpperCase(),
  }).lean();

  if (!order) throw new HttpError(404, 'Order not found');

  return NextResponse.json({
    ref: order.ref,
    status: order.status,
    table: { label: order.tableLabel },
    total: order.total,
    note: order.note,
    rejectReason: order.rejectReason || '',
    items: order.items.map((item) => ({ name: item.name, qty: item.qty })),
  });
}

export const GET = withApiError(getPublicOrder);
