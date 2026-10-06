import Link from 'next/link';
import { dbConnect } from '@/lib/mongodb';
import MenuItem from '@/lib/models/MenuItem';
import MenuGroup from '@/lib/models/MenuGroup';
import Station from '@/lib/models/Station';
import {
  ensureGroups,
  getSettings,
  serializeMenuItem,
  serializeGroup,
} from '@/lib/menu-service';
import MenuFilters from '@/components/MenuFilters';
import MenuTable from '@/components/MenuTable';
import ConfigError from '@/components/ConfigError';
import { requireTenant } from '@/lib/auth';

export const dynamic = 'force-dynamic';

const UNGROUPED = 'Ungrouped';

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function readParam(searchParams, key) {
  const value = searchParams[key];
  if (Array.isArray(value)) return value[0] || '';
  return typeof value === 'string' ? value : '';
}

async function loadMenu(filters) {
  await dbConnect();
  const tenant = await requireTenant();
  await ensureGroups(tenant);

  const query = { tenant: tenant._id };
  if (filters.search) {
    const safe = escapeRegex(filters.search);
    query.$or = [
      { name: { $regex: safe, $options: 'i' } },
      { sku: { $regex: safe, $options: 'i' } },
    ];
  }
  if (filters.station) query.station = filters.station;
  if (filters.available === 'available') query.available = true;
  if (filters.available === 'unavailable') query.available = false;

  if (filters.group === 'none') {
    query.group = null;
  } else if (filters.group) {
    query.group = filters.group;
  }

  const [items, settings, stationDocs, menuStations, groupDocs, counts] =
    await Promise.all([
      MenuItem.find(query).sort({ sortOrder: 1, name: 1 }),
      getSettings(tenant),
      Station.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
      MenuItem.distinct('station', { tenant: tenant._id }),
      MenuGroup.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
      MenuItem.aggregate([
        { $match: { tenant: tenant._id } },
        { $group: { _id: '$group', count: { $sum: 1 } } },
      ]),
    ]);

  const countMap = new Map(counts.map((row) => [String(row._id), row.count]));

  const stations = [
    ...new Set([
      ...stationDocs.map((station) => station.name),
      ...menuStations.filter(Boolean),
    ]),
  ].sort((a, b) => a.localeCompare(b));

  const groups = groupDocs.map((group) =>
    serializeGroup(group, countMap.get(String(group._id)) || 0)
  );

  return {
    items: items.map(serializeMenuItem),
    stations,
    groups,
    currency: settings.currency || 'RM',
  };
}

function buildSections(items, groups) {
  const buckets = new Map();
  for (const group of groups) buckets.set(group.name, []);
  buckets.set(UNGROUPED, []);

  for (const item of items) {
    const key = item.group || UNGROUPED;
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push(item);
  }

  return [...buckets.entries()]
    .filter(([, sectionItems]) => sectionItems.length > 0)
    .map(([name, sectionItems]) => ({
      name,
      id: groups.find((group) => group.name === name)?.id || null,
      items: sectionItems,
    }));
}

export default async function MenuPage({ searchParams }) {
  const resolved = (await searchParams) || {};
  const filters = {
    search: readParam(resolved, 'search'),
    station: readParam(resolved, 'station'),
    group: readParam(resolved, 'group'),
    available: readParam(resolved, 'available'),
  };
  const view = readParam(resolved, 'view') === 'table' ? 'table' : 'grouped';

  let data = null;
  let error = null;
  try {
    data = await loadMenu(filters);
  } catch (loadError) {
    error = loadError;
  }

  const viewParams = new URLSearchParams();
  for (const [key, value] of Object.entries(filters)) {
    if (value) viewParams.set(key, value);
  }
  const groupedHref = (() => {
    const params = new URLSearchParams(viewParams);
    params.delete('view');
    const query = params.toString();
    return query ? `/menu?${query}` : '/menu';
  })();
  const tableHref = (() => {
    const params = new URLSearchParams(viewParams);
    params.set('view', 'table');
    return `/menu?${params.toString()}`;
  })();

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Menu &amp; prices</h1>
          <p>
            {view === 'grouped'
              ? 'Items grouped into sections. Edit prices inline.'
              : 'Flat list of every item. Edit prices inline.'}
          </p>
        </div>
        <span className="spacer" />
        <div className="actions">
          <Link
            className={`btn btn-sm${view === 'grouped' ? ' btn-primary' : ''}`}
            href={groupedHref}
          >
            Grouped
          </Link>
          <Link
            className={`btn btn-sm${view === 'table' ? ' btn-primary' : ''}`}
            href={tableHref}
          >
            Table
          </Link>
          <Link className="btn btn-primary" href="/menu/new">
            + Add menu item
          </Link>
        </div>
      </div>

      {error ? (
        <ConfigError error={error} />
      ) : (
        <>
          <section className="card">
            <div className="card-body">
              <MenuFilters
                stations={data.stations}
                groups={data.groups}
                initial={filters}
                resultCount={data.items.length}
              />
            </div>
          </section>

          {data.items.length === 0 ? (
            <section className="card">
              <div className="empty">
                No menu items match this filter.{' '}
                <Link href="/menu/new">Add one</Link> or{' '}
                <Link href="/menu">clear the filters</Link>.
              </div>
            </section>
          ) : view === 'table' ? (
            <section className="card">
              <header>
                <h2>All items</h2>
                <span className="spacer" />
                <Link className="btn-link" href="/api/export?format=array">
                  Export JSON
                </Link>
              </header>
              <MenuTable
                items={data.items}
                currency={data.currency}
                groups={data.groups}
              />
            </section>
          ) : (
            buildSections(data.items, data.groups).map((section) => (
              <section className="card" key={section.name}>
                <header>
                  <h2>{section.name}</h2>
                  <span className="badge">{section.items.length}</span>
                  <span className="spacer" />
                  {section.id ? (
                    <Link
                      className="btn-link"
                      href={`/menu/new?group=${section.id}`}
                    >
                      + Add item to {section.name}
                    </Link>
                  ) : null}
                </header>
                <MenuTable
                  items={section.items}
                  currency={data.currency}
                  showGroup={false}
                  groups={data.groups}
                />
              </section>
            ))
          )}
        </>
      )}
    </>
  );
}
