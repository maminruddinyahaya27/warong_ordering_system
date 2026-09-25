import Link from 'next/link';
import { dbConnect } from '@/lib/mongodb';
import MenuItem from '@/lib/models/MenuItem';
import Station from '@/lib/models/Station';
import MenuGroup from '@/lib/models/MenuGroup';
import PriceHistory from '@/lib/models/PriceHistory';
import {
  getSettings,
  serializePriceHistory,
} from '@/lib/menu-service';
import { requireTenant } from '@/lib/auth';
import {
  formatDateTime,
  formatMoney,
  formatPercent,
  formatPriceChange,
} from '@/lib/format';
import ConfigError from '@/components/ConfigError';

export const dynamic = 'force-dynamic';

async function loadDashboard() {
  await dbConnect();
  const tenant = await requireTenant();

  const [
    settings,
    totalItems,
    availableItems,
    stationCount,
    priceStats,
    stationBreakdownRaw,
    recentChanges,
    groupDocs,
    groupCounts,
  ] = await Promise.all([
    getSettings(tenant),
    MenuItem.countDocuments({ tenant }),
    MenuItem.countDocuments({ tenant, available: true }),
    Station.countDocuments({ tenant }),
    MenuItem.aggregate([
      { $match: { tenant: tenant._id } },
      { $group: { _id: null, averagePrice: { $avg: '$price' }, cheapest: { $min: '$price' }, mostExpensive: { $max: '$price' } } },
    ]),
    MenuItem.aggregate([
      { $match: { tenant: tenant._id } },
      { $group: { _id: '$station', count: { $sum: 1 }, averagePrice: { $avg: '$price' } } },
      { $sort: { count: -1, _id: 1 } },
    ]),
    PriceHistory.find({ tenant: tenant._id }).sort({ createdAt: -1 }).limit(10).lean(),
    MenuGroup.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
    MenuItem.aggregate([
      { $match: { tenant: tenant._id } },
      { $group: { _id: '$group', count: { $sum: 1 } } },
    ]),
  ]);

  const stats = priceStats[0] || { averagePrice: 0, cheapest: 0, mostExpensive: 0 };

  const stationBreakdown = stationBreakdownRaw.map((row) => ({
    station: row._id ?? 'Unassigned',
    count: row.count,
    averagePrice: Math.round((row.averagePrice || 0) * 100) / 100,
  }));

  const groupCountMap = new Map(
    groupCounts.map((row) => [String(row._id), row.count])
  );

  return {
    settings: {
      restaurantName: settings.restaurantName || 'Warong',
      currency: settings.currency || 'RM',
      taxRate: typeof settings.taxRate === 'number' ? settings.taxRate : 0.1,
    },
    totalItems,
    availableItems,
    stationCount,
    stats,
    stationBreakdown,
    groups: groupDocs.map((group) => ({
      id: String(group._id),
      name: group.name,
      description: group.description || '',
      itemCount: groupCountMap.get(String(group._id)) || 0,
    })),
    ungroupedItems: groupCountMap.get('null') || 0,
    recentChanges: recentChanges.map(serializePriceHistory),
  };
}

export default async function DashboardPage() {
  let data = null;
  let error = null;

  try {
    data = await loadDashboard();
  } catch (loadError) {
    error = loadError;
  }

  if (error) {
    return (
      <>
        <div className="page-head">
          <div>
            <h1>Dashboard</h1>
            <p>Restaurant menu and pricing overview.</p>
          </div>
        </div>
        <ConfigError error={error} />
      </>
    );
  }

  const { settings, stats } = data;
  const currency = settings.currency;
  const unavailable = data.totalItems - data.availableItems;

  return (
    <>
      <div className="page-head">
        <div>
          <h1>{settings.restaurantName} menu</h1>
          <p>
            {data.totalItems} item{data.totalItems === 1 ? '' : 's'} across{' '}
            {data.stationCount} station{data.stationCount === 1 ? '' : 's'} · tax{' '}
            {formatPercent(settings.taxRate)}
          </p>
        </div>
        <span className="spacer" />
        <div className="actions">
          <Link className="btn btn-primary" href="/menu/new">
            + Add menu item
          </Link>
          <Link className="btn" href="/menu">
            Manage menu
          </Link>
        </div>
      </div>

      <div className="stats">
        <div className="stat">
          <div className="value">{data.totalItems}</div>
          <div className="label">Menu items</div>
        </div>
        <div className="stat">
          <div className="value">{data.availableItems}</div>
          <div className="label">Available</div>
        </div>
        <div className="stat">
          <div className="value" style={{ color: unavailable ? 'var(--warn)' : undefined }}>
            {unavailable}
          </div>
          <div className="label">Sold out / hidden</div>
        </div>
        <div className="stat">
          <div className="value">{formatMoney(stats.averagePrice, currency)}</div>
          <div className="label">Average price</div>
        </div>
        <div className="stat">
          <div className="value">{data.stationCount}</div>
          <div className="label">Stations</div>
        </div>
      </div>

      <div className="split">
        <section className="card">
          <header>
            <h2>By station</h2>
            <span className="spacer" />
            <Link className="btn-link" href="/stations">
              Manage
            </Link>
          </header>
          <div className="card-body tight">
            {data.stationBreakdown.length === 0 ? (
              <div className="empty">
                No menu items yet. <Link href="/menu/new">Add the first item</Link> or run{' '}
                <span className="mono">npm run seed</span>.
              </div>
            ) : (
              <div className="table-scroll">
                <table className="data">
                  <thead>
                    <tr>
                      <th>Station</th>
                      <th>Items</th>
                      <th>Average price</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.stationBreakdown.map((row) => (
                      <tr key={row.station}>
                        <td>
                          <Link href={`/menu?station=${encodeURIComponent(row.station)}`}>
                            {row.station}
                          </Link>
                        </td>
                        <td className="num">{row.count}</td>
                        <td className="num">
                          {formatMoney(row.averagePrice, currency)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </section>

        <section className="card">
          <header>
            <h2>Latest changes</h2>
            <span className="spacer" />
            <Link className="btn-link" href="/history">
              Full history
            </Link>
          </header>
          <div className="card-body tight">
            {data.recentChanges.length === 0 ? (
              <div className="empty">No changes recorded yet.</div>
            ) : (
              <div className="table-scroll">
                <table className="data">
                  <thead>
                    <tr>
                      <th>Item</th>
                      <th>Change</th>
                      <th>When</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.recentChanges.map((entry) => (
                      <tr key={entry.id}>
                        <td>
                          <div>{entry.name}</div>
                          <div className="muted mono small">{entry.sku}</div>
                        </td>
                        <td className="num">{formatPriceChange(entry, currency)}</td>
                        <td className="muted small">{formatDateTime(entry.createdAt)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </section>
      </div>

      <section className="card">
        <header>
          <h2>Groups</h2>
          <span className="spacer" />
          <Link className="btn-link" href="/groups">
            Manage groups
          </Link>
        </header>
        <div className="card-body tight">
          {data.groups.length === 0 ? (
            <div className="empty">
              No groups yet. <Link href="/groups">Create the first group</Link>{' '}
              and start adding items into it.
            </div>
          ) : (
            <div className="table-scroll">
              <table className="data">
                <thead>
                  <tr>
                    <th>Group</th>
                    <th>Items</th>
                    <th style={{ textAlign: 'right' }}>Add</th>
                  </tr>
                </thead>
                <tbody>
                  {data.groups.map((group) => (
                    <tr key={group.id}>
                      <td>
                        <Link href={`/menu?group=${group.id}`}>{group.name}</Link>
                        {group.description ? (
                          <div className="muted small">{group.description}</div>
                        ) : null}
                      </td>
                      <td className="num">{group.itemCount}</td>
                      <td style={{ textAlign: 'right' }}>
                        <Link
                          className="btn btn-sm"
                          href={`/menu/new?group=${group.id}`}
                        >
                          + Add item
                        </Link>
                      </td>
                    </tr>
                  ))}
                  {data.ungroupedItems > 0 ? (
                    <tr>
                      <td>
                        <Link href="/menu?group=none">Ungrouped</Link>
                      </td>
                      <td className="num">{data.ungroupedItems}</td>
                      <td />
                    </tr>
                  ) : null}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </section>

      <section className="card">
        <header>
          <h2>Export to the ordering apps</h2>
        </header>
        <div className="card-body">
          <p className="muted small" style={{ marginTop: 0 }}>
            The static POS screens (<span className="mono">index1.html</span>,{' '}
            <span className="mono">index2.html</span>) read their menu from a JSON feed.
            Use these endpoints to keep them in sync with this portal.
          </p>
          <div className="actions">
            <a className="btn" href="/api/export?format=grouped&download=1">
              Download grouped (by section)
            </a>
            <a className="btn" href="/api/export?format=array&download=1">
              Download array format
            </a>
            <a className="btn" href="/api/export?format=object&download=1">
              Download object format
            </a>
            <a className="btn" href="/api/export?format=grouped">
              Preview JSON
            </a>
          </div>
          <pre className="code" style={{ marginTop: 14 }}>{`const res = await fetch('/api/export?format=grouped');
const { menu } = await res.json();
// menu -> [{ name: 'Rice', items: [{ id, name, price, station, group }] }]`}</pre>
        </div>
      </section>
    </>
  );
}
