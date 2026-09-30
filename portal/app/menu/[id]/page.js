import Link from 'next/link';
import { notFound } from 'next/navigation';
import { dbConnect } from '@/lib/mongodb';
import Station from '@/lib/models/Station';
import MenuItem from '@/lib/models/MenuItem';
import MenuGroup from '@/lib/models/MenuGroup';
import PriceHistory from '@/lib/models/PriceHistory';
import {
  ensureGroups,
  findMenuItem,
  getSettings,
  serializeGroup,
  serializeMenuItem,
  serializePriceHistory,
} from '@/lib/menu-service';
import MenuItemForm from '@/components/MenuItemForm';
import ConfigError from '@/components/ConfigError';
import { formatDateTime, formatMoney, formatPriceChange } from '@/lib/format';
import { requireTenant } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function loadItem(id) {
  await dbConnect();
  const tenant = await requireTenant();
  await ensureGroups(tenant);

  const item = await findMenuItem(tenant, id);
  if (!item) return null;

  const [stationDocs, menuStations, settings, groupDocs, history] =
    await Promise.all([
      Station.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
      MenuItem.distinct('station', { tenant: tenant._id }),
      getSettings(tenant),
      MenuGroup.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
      PriceHistory.find({ tenant: tenant._id, $or: [{ itemId: item._id }, { sku: item.sku }] })
        .sort({ createdAt: -1 })
        .limit(30)
        .lean(),
    ]);

  const stations = [
    ...new Set([
      ...stationDocs.map((station) => station.name),
      ...menuStations.filter(Boolean),
    ]),
  ].sort((a, b) => a.localeCompare(b));

  return {
    item: serializeMenuItem(item),
    stations,
    groups: groupDocs.map((group) => serializeGroup(group)),
    currency: settings.currency || 'RM',
    history: history.map(serializePriceHistory),
  };
}

export default async function MenuItemDetailPage({ params, searchParams }) {
  const { id } = await params;
  const resolvedSearch = (await searchParams) || {};
  // Where to return after saving: the menu list with its filters intact.
  const returnTo =
    typeof resolvedSearch.from === 'string' && resolvedSearch.from.startsWith('/menu')
      ? resolvedSearch.from
      : '/menu';

  let data = null;
  let error = null;
  try {
    data = await loadItem(id);
  } catch (loadError) {
    error = loadError;
  }

  if (error) {
    return (
      <>
        <div className="page-head">
          <div>
            <h1>Menu item</h1>
          </div>
          <span className="spacer" />
          <Link className="btn" href="/menu">
            Back to menu
          </Link>
        </div>
        <ConfigError error={error} />
      </>
    );
  }

  if (!data) notFound();

  const { item, currency, stations, groups, history } = data;

  return (
    <>
      <div className="page-head">
        <div>
          <h1>{item.name}</h1>
          <p>
            <span className="mono">{item.sku}</span> · {item.station} ·{' '}
            {item.group || 'Ungrouped'} · {formatMoney(item.price, currency)}
            {item.available ? '' : ' · sold out'}
          </p>
        </div>
        <span className="spacer" />
        <Link className="btn" href="/menu">
          Back to menu
        </Link>
      </div>

      <div className="split">
        <MenuItemForm
          item={item}
          stations={stations}
          groups={groups}
          currency={currency}
          returnTo={returnTo}
        />

        <section className="card">
          <header>
            <h2>Price history</h2>
            <span className="spacer" />
            <Link className="btn-link" href={`/history?itemId=${item.id}`}>
              Open in history
            </Link>
          </header>
          <div className="card-body tight">
            {history.length === 0 ? (
              <div className="empty">No changes recorded yet.</div>
            ) : (
              <div className="table-scroll">
                <table className="data">
                  <thead>
                    <tr>
                      <th>When</th>
                      <th>Change</th>
                      <th>By</th>
                    </tr>
                  </thead>
                  <tbody>
                    {history.map((entry) => (
                      <tr key={entry.id}>
                        <td className="muted small">{formatDateTime(entry.createdAt)}</td>
                        <td className="num">{formatPriceChange(entry, currency)}</td>
                        <td className="muted small">
                          {entry.changedBy}
                          {entry.note ? (
                            <div className="muted small">{entry.note}</div>
                          ) : null}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </section>
      </div>
    </>
  );
}
