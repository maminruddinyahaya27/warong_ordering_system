import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import OnlineOrder from '@/lib/models/OnlineOrder';
import { withApiError } from '@/lib/api';
import { HttpError, tenantForRequest } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// For the POS Hub: orders customers placed from table QR codes and that the
// hub has not imported yet. Authenticated with the tenant API key.
async function pendingOnlineOrders(request) {
  await dbConnect();

  const tenant = await tenantForRequest(request);
  if (!tenant) throw new HttpError(401, 'A tenant API key is required');

  const orders = await OnlineOrder.find({
    tenant: tenant._id,
    status: 'pending',
  })
    .sort({ createdAt: 1 })
    .limit(20)
    .lean();

  return NextResponse.json({
    count: orders.length,
    orders: orders.map((order) => ({
      id: String(order._id),
      ref: order.ref,
      table: order.tableLabel,
      note: order.note || '',
      total: order.total || 0,
      createdAt: order.createdAt,
      items: order.items.map((item) => ({
        sku: item.sku,
        name: item.name,
        qty: item.qty,
        price: item.price,
        station: item.station || '',
        note: item.note || '',
      })),
    })),
  });
}

export const GET = withApiError(pendingOnlineOrders);
