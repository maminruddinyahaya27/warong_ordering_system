import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import PriceHistory from '@/lib/models/PriceHistory';
import { findMenuItem, serializePriceHistory } from '@/lib/menu-service';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function getHistory(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  const { searchParams } = new URL(request.url);
  const itemKey = (searchParams.get('itemId') || searchParams.get('sku') || '').trim();
  const action = (searchParams.get('action') || '').trim();
  const priceChangesOnly = searchParams.get('priceChangesOnly') === '1';

  const limitRaw = Number.parseInt(searchParams.get('limit') || '50', 10);
  const limit = Number.isFinite(limitRaw)
    ? Math.min(Math.max(limitRaw, 1), 200)
    : 50;

  const query = { tenant: tenantId };
  if (itemKey) {
    const item = await findMenuItem(tenantId, itemKey);
    if (item) {
      query.$or = [{ itemId: item._id }, { sku: item.sku }];
    } else {
      query.sku = itemKey;
    }
  }
  if (action) query.action = action;

  let entries = await PriceHistory.find(query)
    .sort({ createdAt: -1 })
    .limit(limit)
    .lean();

  if (priceChangesOnly) {
    entries = entries.filter(
      (entry) => entry.action !== 'update' || entry.oldPrice !== entry.newPrice
    );
  }

  return NextResponse.json({
    entries: entries.map(serializePriceHistory),
    count: entries.length,
  });
}

export const GET = withApiError(getHistory);
