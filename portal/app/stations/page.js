import { dbConnect } from '@/lib/mongodb';
import Station from '@/lib/models/Station';
import MenuItem from '@/lib/models/MenuItem';
import { ensureStations } from '@/lib/menu-service';
import StationManager from '@/components/StationManager';
import ConfigError from '@/components/ConfigError';
import { requireTenant } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function loadStations() {
  await dbConnect();
  const tenant = await requireTenant();
  await ensureStations(tenant);

  const [stations, counts] = await Promise.all([
    Station.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
    MenuItem.aggregate([
      { $match: { tenant: tenant._id } },
      { $group: { _id: '$station', count: { $sum: 1 } } },
    ]),
  ]);

  const countMap = new Map(counts.map((row) => [row._id, row.count]));
  const known = new Set(stations.map((station) => station.name));

  const list = stations.map((station, index) => ({
    id: String(station._id),
    name: station.name,
    printerName: station.printerName || '',
    sortOrder: Number.isFinite(station.sortOrder) ? station.sortOrder : index,
    itemCount: countMap.get(station.name) || 0,
  }));

  for (const row of counts) {
    if (!known.has(row._id)) {
      list.push({
        id: `orphan:${row._id}`,
        name: row._id,
        printerName: '',
        sortOrder: list.length,
        itemCount: row.count,
        orphan: true,
      });
    }
  }

  return list;
}

export default async function StationsPage() {
  let stations = null;
  let error = null;
  try {
    stations = await loadStations();
  } catch (loadError) {
    error = loadError;
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Kitchen stations</h1>
          <p>Route menu items to the right station and printer.</p>
        </div>
      </div>

      {error ? <ConfigError error={error} /> : <StationManager stations={stations} />}
    </>
  );
}
