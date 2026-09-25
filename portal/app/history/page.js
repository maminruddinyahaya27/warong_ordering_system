import Link from 'next/link';
import { dbConnect } from '@/lib/mongodb';
import PriceHistory from '@/lib/models/PriceHistory';
import {
  findMenuItem,
  getSettings,
  serializePriceHistory,
} from '@/lib/menu-service';
import { formatDateTime, formatPriceChange } from '@/lib/format';
import ConfigError from '@/components/ConfigError';
import { requireTenant } from '@/lib/auth';

export const dynamic = 'force-dynamic';

function readParam(searchParams, key) {
  const value = searchParams[key];
  if (Array.isArray(value)) return value[0] || '';
  return typeof value === 'string' ? value : '';
}

function actionBadge(action) {
  if (action === 'create') return 'badge-ok';
  if (action === 'delete') return 'badge-err';
  return 'badge-warn';
}

async function loadHistory({ itemId, action, priceChangesOnly }) {
  await dbConnect();
  const tenant = await requireTenant();

  const query = { tenant: tenant._id };
  if (itemId) {
    const item = await findMenuItem(tenant, itemId);
    if (item) {
      query.$or = [{ itemId: item._id }, { sku: item.sku }];
    } else {
      query.sku = itemId;
    }
  }
  if (action) query.action = action;

  const [settings, limit] = await Promise.all([
    getSettings(tenant),
    Promise.resolve(100),
  ]);

  let entries = await PriceHistory.find(query)
    .sort({ createdAt: -1 })
    .limit(limit)
    .lean();

  if (priceChangesOnly) {
    entries = entries.filter(
      (entry) => entry.action !== 'update' || entry.oldPrice !== entry.newPrice
    );
  }

  return {
    currency: settings.currency || 'RM',
    entries: entries.map(serializePriceHistory),
  };
}

function buildHref(current, patch) {
  const params = new URLSearchParams();
  const merged = { ...current, ...patch };
  for (const [key, value] of Object.entries(merged)) {
    if (value) params.set(key, value);
  }
  const query = params.toString();
  return query ? `/history?${query}` : '/history';
}

export default async function HistoryPage({ searchParams }) {
  const resolved = (await searchParams) || {};
  const current = {
    itemId: readParam(resolved, 'itemId'),
    action: readParam(resolved, 'action'),
    priceChangesOnly: readParam(resolved, 'priceChangesOnly'),
  };

  let data = null;
  let error = null;
  try {
    data = await loadHistory(current);
  } catch (loadError) {
    error = loadError;
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Price history</h1>
          <p>Every create, price change and deletion, newest first.</p>
        </div>
      </div>

      {error ? (
        <ConfigError error={error} />
      ) : (
        <>
          <section className="card">
            <div className="card-body">
              <div className="actions">
                <Link
                  className={`btn btn-sm${current.priceChangesOnly === '1' ? ' btn-primary' : ''}`}
                  href={buildHref(current, {
                    priceChangesOnly: current.priceChangesOnly === '1' ? '' : '1',
                  })}
                >
                  Price changes only
                </Link>
                <Link
                  className={`btn btn-sm${current.action === '' ? ' btn-primary' : ''}`}
                  href={buildHref(current, { action: '' })}
                >
                  All actions
                </Link>
                <Link
                  className={`btn btn-sm${current.action === 'create' ? ' btn-primary' : ''}`}
                  href={buildHref(current, { action: 'create' })}
                >
                  Created
                </Link>
                <Link
                  className={`btn btn-sm${current.action === 'update' ? ' btn-primary' : ''}`}
                  href={buildHref(current, { action: 'update' })}
                >
                  Updates
                </Link>
                <Link
                  className={`btn btn-sm${current.action === 'delete' ? ' btn-primary' : ''}`}
                  href={buildHref(current, { action: 'delete' })}
                >
                  Deleted
                </Link>
                {current.itemId ? (
                  <Link className="btn btn-sm" href={buildHref({ ...current, itemId: '' }, {})}>
                    Clear item filter
                  </Link>
                ) : null}
              </div>
            </div>
          </section>

          <section className="card">
            <header>
              <h2>Entries</h2>
              <span className="spacer" />
              <span className="muted small">{data.entries.length} shown</span>
            </header>
            <div className="card-body tight">
              {data.entries.length === 0 ? (
                <div className="empty">No history entries match this filter.</div>
              ) : (
                <div className="table-scroll">
                  <table className="data">
                    <thead>
                      <tr>
                        <th>When</th>
                        <th>Item</th>
                        <th>Action</th>
                        <th>Change</th>
                        <th>Station</th>
                        <th>By</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.entries.map((entry) => (
                        <tr key={entry.id}>
                          <td className="muted small">{formatDateTime(entry.createdAt)}</td>
                          <td>
                            {entry.itemId ? (
                              <Link href={`/menu/${entry.itemId}`}>{entry.name}</Link>
                            ) : (
                              entry.name
                            )}
                            <div className="muted mono small">{entry.sku}</div>
                          </td>
                          <td>
                            <span className={`badge ${actionBadge(entry.action)}`}>
                              {entry.action}
                            </span>
                          </td>
                          <td className="num">{formatPriceChange(entry, data.currency)}</td>
                          <td className="muted small">{entry.station || '—'}</td>
                          <td className="muted small">
                            {entry.changedBy}
                            {entry.note ? <div>{entry.note}</div> : null}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          </section>
        </>
      )}
    </>
  );
}
