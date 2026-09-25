import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import MenuItem from '@/lib/models/MenuItem';
import Station from '@/lib/models/Station';
import PriceHistory from '@/lib/models/PriceHistory';
import { serializePriceHistory } from '@/lib/menu-service';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function getStats() {
  await dbConnect();
  const { tenantId } = await requireSession();

  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  const scope = { tenant: tenantId };

  const [
    totalItems,
    availableItems,
    drinkItems,
    stationCount,
    priceStats,
    stationBreakdown,
    groupBreakdown,
    ungroupedItems,
    recentChanges,
    priceChangesLast30Days,
  ] = await Promise.all([
    MenuItem.countDocuments(scope),
    MenuItem.countDocuments({ ...scope, available: true }),
    MenuItem.countDocuments({ ...scope, options: 'drink' }),
    Station.countDocuments(scope),
    MenuItem.aggregate([
      { $match: scope },
      {
        $group: {
          _id: null,
          averagePrice: { $avg: '$price' },
          cheapest: { $min: '$price' },
          mostExpensive: { $max: '$price' },
        },
      },
    ]),
    MenuItem.aggregate([
      { $match: scope },
      {
        $group: {
          _id: '$station',
          count: { $sum: 1 },
          averagePrice: { $avg: '$price' },
        },
      },
      { $sort: { count: -1, _id: 1 } },
    ]),
    MenuItem.aggregate([
      { $match: scope },
      {
        $group: {
          _id: '$groupName',
          count: { $sum: 1 },
        },
      },
      { $sort: { count: -1, _id: 1 } },
    ]),
    MenuItem.countDocuments({ ...scope, group: null }),
    PriceHistory.find(scope).sort({ createdAt: -1 }).limit(8).lean(),
    PriceHistory.countDocuments({
      ...scope,
      action: 'update',
      createdAt: { $gte: thirtyDaysAgo },
    }),
  ]);

  const stats = priceStats[0] || { averagePrice: 0, cheapest: 0, mostExpensive: 0 };

  return NextResponse.json({
    totalItems,
    availableItems,
    unavailableItems: totalItems - availableItems,
    drinkItems,
    stationCount,
    averagePrice: Math.round((stats.averagePrice || 0) * 100) / 100,
    cheapest: stats.cheapest ?? 0,
    mostExpensive: stats.mostExpensive ?? 0,
    priceChangesLast30Days,
    stationBreakdown: stationBreakdown.map((row) => ({
      station: row._id ?? 'Unassigned',
      count: row.count,
      averagePrice: Math.round((row.averagePrice || 0) * 100) / 100,
    })),
    groupBreakdown: groupBreakdown.map((row) => ({
      group: row._id || 'Ungrouped',
      count: row.count,
    })),
    ungroupedItems: ungroupedItems,
    recentChanges: recentChanges.map(serializePriceHistory),
  });
}

export const GET = withApiError(getStats);
