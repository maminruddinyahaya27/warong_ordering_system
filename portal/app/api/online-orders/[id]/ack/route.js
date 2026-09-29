import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import OnlineOrder from '@/lib/models/OnlineOrder';
import { withApiError } from '@/lib/api';
import { HttpError, tenantForRequest } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// For the POS Hub: marks a QR order as handled so it is never imported twice.
//   POST { status: 'imported' | 'rejected', hubOrderNo?, reason? }
async function ackOnlineOrder(request, { params }) {
  await dbConnect();

  const tenant = await tenantForRequest(request);
  if (!tenant) throw new HttpError(401, 'A tenant API key is required');

  const { id } = await params;
  if (!/^[0-9a-f]{24}$/i.test(String(id))) {
    throw new HttpError(404, 'Order not found');
  }

  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }

  const status = body?.status === 'rejected' ? 'rejected' : 'imported';

  const updated = await OnlineOrder.findOneAndUpdate(
    { _id: id, tenant: tenant._id },
    {
      $set: {
        status,
        rejectReason: String(body?.reason || '').slice(0, 200),
        hubOrderNo: String(body?.hubOrderNo || ''),
        importedAt: new Date(),
      },
    },
    { new: true }
  ).lean();

  if (!updated) throw new HttpError(404, 'Order not found');

  return NextResponse.json({
    ok: true,
    id: String(updated._id),
    status: updated.status,
  });
}

export const POST = withApiError(ackOnlineOrder);
