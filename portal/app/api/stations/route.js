import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import Station from '@/lib/models/Station';
import MenuItem from '@/lib/models/MenuItem';
import { ensureStations } from '@/lib/menu-service';
import { validateStation } from '@/lib/validate';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function getStations() {
  await dbConnect();
  const { tenantId } = await requireSession();
  await ensureStations(tenantId);

  const [stations, counts] = await Promise.all([
    Station.find({ tenant: tenantId }).sort({ sortOrder: 1, name: 1 }).lean(),
    MenuItem.aggregate([
      { $match: { tenant: tenantId } },
      { $group: { _id: '$station', count: { $sum: 1 } } },
    ]),
  ]);

  const countMap = new Map(counts.map((row) => [row._id, row.count]));
  const known = new Set(stations.map((station) => station.name));

  const items = stations.map((station, index) => ({
    id: String(station._id),
    name: station.name,
    printerName: station.printerName || '',
    sortOrder: Number.isFinite(station.sortOrder) ? station.sortOrder : index,
    itemCount: countMap.get(station.name) || 0,
  }));

  for (const row of counts) {
    if (!known.has(row._id)) {
      items.push({
        id: `orphan:${row._id}`,
        name: row._id,
        printerName: '',
        sortOrder: items.length,
        itemCount: row.count,
        orphan: true,
      });
    }
  }

  return NextResponse.json({ stations: items });
}

async function createStation(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { values, errors } = validateStation(body);
  if (errors.length) {
    return NextResponse.json({ error: errors.join('; '), errors }, { status: 400 });
  }

  const existing = await Station.findOne({
    tenant: tenantId,
    name: values.name,
  });
  if (existing) {
    return NextResponse.json(
      { error: `Station ${values.name} already exists` },
      { status: 409 }
    );
  }

  const last = await Station.findOne({ tenant: tenantId }, { sortOrder: 1 })
    .sort({ sortOrder: -1 })
    .lean();
  const sortOrder =
    values.sortOrder ?? (last && Number.isFinite(last.sortOrder) ? last.sortOrder + 1 : 1);

  const station = await Station.create({
    ...values,
    tenant: tenantId,
    sortOrder,
  });

  return NextResponse.json(
    {
      station: {
        id: String(station._id),
        name: station.name,
        printerName: station.printerName || '',
        sortOrder: station.sortOrder,
        itemCount: 0,
      },
    },
    { status: 201 }
  );
}

export const GET = withApiError(getStations);
export const POST = withApiError(createStation);
